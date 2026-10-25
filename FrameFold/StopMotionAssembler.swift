import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Baut aus Keyframes das Stopmotion-Video.
/// Zwei Quellen über dieselbe Kernlogik:
///  - Keyframes aus einem Quellvideo (Zeitstempel + AVAssetImageGenerator)
///  - Bildsequenzen (Live-Capture / Projekte, JPEGs von Disk)
/// Unterstützt Center-Crop-Presets (9:16, 1:1, 16:9), Loop-Modi
/// (Boomerang/Rückwärts) und optionales Frame-Alignment.
final class StopMotionAssembler {

    // MARK: Quelle A: Video-Keyframes

    func assemble(
        asset: AVAsset,
        keyframeTimes: [Double],
        settings: PipelineSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !keyframeTimes.isEmpty else { throw PipelineError.noKeyframesFound }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = keyframeTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }

        if settings.loopMode == .none {
            // Frames werden monoton aufsteigend gebraucht → direkt aus EINEM
            // sequentiellen Decoder-Durchlauf streamen. Das erspart den teuren
            // Einzel-Seek pro Keyframe (der jeweils vom letzten Sync-Frame des
            // Videos neu dekodieren muss).
            let source = SequentialFrameSource(generator: generator, times: times)
            return try await write(
                frameCount: times.count,
                settings: settings,
                frameProvider: { index in try await source.frame(at: index) },
                progress: progress
            )
        }

        // Rückwärts/Boomerang greifen wahlfrei auf Frames zu: Keyframes einmal
        // sequentiell extrahieren (schnell), dann vom Zwischenspeicher montieren.
        let tmpDir = FileManager.default.temporaryDirectory
        let batchID = UUID().uuidString
        var extracted: [URL] = []
        var index = 0
        for await result in generator.images(for: times) {
            if case .success(requestedTime: _, image: let image, actualTime: _) = result,
               let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.95) {
                let url = tmpDir.appendingPathComponent("ff-kf-\(batchID)-\(index).jpg")
                try? data.write(to: url)
                extracted.append(url)
            }
            index += 1
            progress(0.3 * Double(index) / Double(times.count))
        }
        guard !extracted.isEmpty else { throw PipelineError.noKeyframesFound }
        defer { for url in extracted { try? FileManager.default.removeItem(at: url) } }

        return try await assemble(imageURLs: extracted, settings: settings) { p in
            progress(0.3 + 0.7 * p)
        }
    }

    // MARK: Quelle B: Bildsequenz (Live-Capture / Projekte)

    func assemble(
        imageURLs: [URL],
        settings: PipelineSettings,
        greenScreen: GreenScreenCompositor? = nil,
        overlays: [FrameOverlay] = [],
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !imageURLs.isEmpty else { throw PipelineError.noKeyframesFound }
        return try await write(
            frameCount: imageURLs.count,
            settings: settings,
            frameProvider: { index in
                guard let data = try? Data(contentsOf: imageURLs[index]),
                      let image = UIImage(data: data)?.cgImage else {
                    throw PipelineError.exportFailed
                }
                // Greenscreen vor allem anderen: Flimmerausgleich und
                // Effekte sehen schon das fertige Bild mit Hintergrund.
                var result = image
                if let greenScreen { result = await greenScreen.composite(result, index: index) }
                // Text, Sprechblasen, Zeichnungen obenauf
                if !overlays.isEmpty, let drawn = OverlayRenderer.apply(overlays, frame: index, to: result) {
                    result = drawn
                }
                return result
            },
            progress: progress
        )
    }

    // MARK: Kern

    private func write(
        frameCount: Int,
        settings: PipelineSettings,
        frameProvider rawProvider: @escaping (Int) async throws -> CGImage,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // Farblook direkt an der Quelle: Flimmerausgleich und Effekte sehen
        // schon das fertige Bild.
        let look = settings.look
        let frameProvider: (Int) async throws -> CGImage = look == .original ? rawProvider : { index in
            let image = try await rawProvider(index)
            return Self.apply(look: look, to: image) ?? image
        }
        let order = settings.loopMode.frameOrder(count: frameCount)

        // Ausgabegröße aus dem ersten Frame + Crop-Preset ableiten
        let firstImage = try await frameProvider(order[0])
        let cropRect = Self.cropRect(
            imageWidth: firstImage.width, imageHeight: firstImage.height,
            targetRatio: settings.aspect.ratio)
        // Ausgabegröße: ggf. auf 1080p begrenzt – schnellerer Encode,
        // deutlich kleinere Dateien, für Social-Clips ohne sichtbaren Verlust
        let (width, height) = Algorithms.exportSize(
            cropWidth: cropRect.width, cropHeight: cropRect.height,
            maxDimension: settings.exportResolution.maxDimension)
        let renderScale = CGFloat(width) / max(1, cropRect.width)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("framefold-\(UUID().uuidString).\(settings.videoCodec.fileExtension)")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.videoCodec.fileType)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.videoCodec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])

        guard writer.canAdd(input) else { throw PipelineError.exportFailed }
        writer.add(input)
        guard writer.startWriting() else { throw PipelineError.exportFailed }
        writer.startSession(atSourceTime: .zero)

        // Wartet, bis der Encoder wieder Daten annimmt. Scheitert der Writer
        // (Speicher voll, Encoder-Fehler), bliebe `isReadyForMoreMediaData`
        // für immer falsch – darum abbrechen statt endlos zu warten.
        func waitUntilReady() async throws {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw PipelineError.exportFailed }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        let frameDuration = CMTime(value: 1, timescale: settings.outputFPS)
        let aligner = settings.alignFrames ? FrameAligner() : nil

        // Render-Plan: Reihenfolge + optionale Falz-Blenden-Zwischenframes
        let steps = Algorithms.renderPlan(order: order, transitionFrames: settings.transitionFrames)

        // Effekt-Geometrie EINMAL berechnen statt pro Frame
        let facets: [Algorithms.Facet] =
            (settings.transitionStyle == .facet && settings.transitionFrames > 0)
            ? Algorithms.facetPlan(width: Double(width), height: Double(height), cols: 6, rows: 6)
            : []
        let weave: [Algorithms.WeaveStrip] =
            (settings.transitionStyle == .weave && settings.transitionFrames > 0)
            ? Algorithms.weavePlan(width: Double(width), strips: 9)
            : []
        let reliefFacets: [Algorithms.Facet] = settings.paperRelief
            ? Algorithms.facetPlan(width: Double(width), height: Double(height), cols: 6, rows: 6)
            : []

        // Flimmerausgleich: die Helligkeit jedes Bildes einmal messen und
        // daraus je Bild einen Faktor bestimmen (Median der Nachbarn).
        var gains = [Double](repeating: 1, count: frameCount)
        if settings.deflicker, frameCount >= 3 {
            var lumas: [Double] = []
            lumas.reserveCapacity(frameCount)
            for i in 0..<frameCount {
                try Task.checkCancellation()
                let img = i == order[0] ? firstImage : try await frameProvider(i)
                lumas.append(Self.meanLuma(img))
            }
            gains = Algorithms.deflickerGains(lumas)
        }
        func corrected(_ img: CGImage, _ index: Int) -> CGImage {
            let gain = gains[index]
            guard abs(gain - 1) > 0.01 else { return img }
            return Self.applyGain(img, gain) ?? img
        }

        // Kleiner Frame-Cache (Basis + Overlay), damit lange Videos nicht
        // komplett im Speicher liegen. Der erste Frame ist schon geladen.
        var cache: [Int: CGImage] = [order[0]: corrected(firstImage, order[0])]
        func image(at index: Int) async throws -> CGImage {
            if let cached = cache[index] { return cached }
            let img = corrected(try await frameProvider(index), index)
            if cache.count > 3 { cache.removeAll() }
            cache[index] = img
            return img
        }

        // Echo-Rekursion: der zuletzt geschriebene Output-Frame
        var lastComposed: CGImage? = nil
        let echo = settings.interferenzEcho ? max(0, min(0.5, settings.echoStrength)) : 0

        // Ausgerichtete Bilder pro Index. Die Ausrichtung bezieht sich immer
        // auf das erste Bild, das Ergebnis hängt also nur vom Bild selbst ab –
        // so lassen sich auch beide Bilder einer Überblendung ausrichten.
        // Früher geschah das nur für Keyframes: Die Blenden dazwischen lagen
        // unausgerichtet, und das Bild sprang zu Beginn und Ende jeder Blende.
        // Stufe 1: Homographie (korrigiert auch Verdrehung/Neigung),
        // Stufe 2: Verschiebungs-Fallback per Block-Matching.
        var alignedCache: [Int: (image: CGImage, offset: CGPoint)] = [:]
        func aligned(at index: Int) async throws -> (image: CGImage, offset: CGPoint) {
            if let hit = alignedCache[index] { return hit }
            let raw = try await image(at: index)
            var result = (image: raw, offset: CGPoint.zero)
            if let aligner {
                if let warped = aligner.warp(raw) {
                    result.image = warped
                } else {
                    result.offset = aligner.register(raw)
                }
            }
            // Basis und Überblendbild genügen – lange Filme bleiben klein.
            if alignedCache.count > 2 { alignedCache.removeAll() }
            alignedCache[index] = result
            return result
        }

        for (position, step) in steps.enumerated() {
            let base = try await aligned(at: step.baseIndex)
            let baseImage = base.image
            let offset = base.offset
            var overlayImage: CGImage? = nil
            var overlayOffset: CGPoint = .zero
            if let overlayIndex = step.overlayIndex {
                let overlay = try await aligned(at: overlayIndex)
                overlayImage = overlay.image
                overlayOffset = overlay.offset
            }

            guard let pixelBuffer = Self.renderStep(
                base: baseImage, overlay: overlayImage, revealProgress: step.progress,
                previousComposed: lastComposed, echoStrength: echo,
                transitionStyle: settings.transitionStyle, facets: facets, weave: weave,
                reliefFacets: reliefFacets, reliefStrength: settings.reliefStrength,
                printLook: settings.printLook,
                cropRect: cropRect, referenceWidth: firstImage.width, referenceHeight: firstImage.height,
                width: width, height: height, scale: renderScale,
                offset: offset, overlayOffset: overlayOffset, pool: adaptor.pixelBufferPool,
                composedOut: &lastComposed) else { continue }

            try await waitUntilReady()
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(position))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw PipelineError.exportFailed
            }
            progress(Double(position + 1) / Double(steps.count))
        }

        // Standbild am Ende: das Schlussbild wird als Wiederholung angehängt,
        // damit der Film nicht abreißt. Identische Frames kosten dank
        // Zwischenbild-Kompression praktisch keine Dateigröße.
        let holdFrames = Int((settings.holdLastFrameSeconds * Double(settings.outputFPS)).rounded())
        if holdFrames > 0, let finalImage = lastComposed {
            for i in 0..<holdFrames {
                try await waitUntilReady()
                guard let buffer = Self.buffer(from: finalImage,
                                               width: width, height: height,
                                               pool: adaptor.pixelBufferPool) else { break }
                let time = CMTimeMultiply(frameDuration, multiplier: Int32(steps.count + i))
                adaptor.append(buffer, withPresentationTime: time)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw PipelineError.exportFailed }
        return outputURL
    }

    /// Zeichnet ein fertig komponiertes Bild 1:1 in einen neuen Pixel-Buffer –
    /// für das Standbild am Ende.
    private static func buffer(from image: CGImage, width: Int, height: Int,
                               pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                                &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Center-Crop-Rechteck (delegiert an Algorithms).
    static func cropRect(imageWidth: Int, imageHeight: Int, targetRatio: Double?) -> CGRect {
        Algorithms.cropRect(imageWidth: imageWidth, imageHeight: imageHeight, targetRatio: targetRatio)
    }

    /// Rendert einen Schritt des Plans in einen Pixel-Buffer:
    /// Basis-Frame + optionale Falz-Blende (Overlay wird entlang der Diagonale
    /// aufgedeckt) + optionales Interferenz-Echo (vorheriger Output-Frame
    /// schimmert durch). `composedOut` erhält das fertige Bild für das Echo
    /// des nächsten Frames.
    private static func renderStep(
        base: CGImage, overlay: CGImage?, revealProgress: Double,
        previousComposed: CGImage?, echoStrength: Double,
        transitionStyle: TransitionStyle, facets: [Algorithms.Facet],
        weave: [Algorithms.WeaveStrip],
        reliefFacets: [Algorithms.Facet], reliefStrength: Double, printLook: Bool,
        cropRect: CGRect, referenceWidth: Int, referenceHeight: Int,
        width: Int, height: Int, scale: CGFloat,
        offset: CGPoint, overlayOffset: CGPoint = .zero, pool: CVPixelBufferPool?,
        composedOut: inout CGImage?
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high

        // Bild so zeichnen, dass cropRect (plus Alignment-Offset) den Buffer
        // füllt – skaliert auf die Ausgabegröße
        //
        // Ausschnitt und Maßstab stammen vom ersten Bild. Hat ein Bild eine
        // andere Größe (Video plus Live-Aufnahmen, zwei Kameras am Mac, die
        // Titelkarte im Reel), füllt es den Rahmen stattdessen für sich –
        // sonst erschiene es verschoben oder winzig in einer Ecke.
        func drawRect(for image: CGImage, offset: CGPoint) -> CGRect {
            if image.width == referenceWidth && image.height == referenceHeight {
                return CGRect(
                    x: (-cropRect.minX + offset.x) * scale,
                    y: (-(CGFloat(image.height) - cropRect.maxY) + offset.y) * scale,
                    width: CGFloat(image.width) * scale,
                    height: CGFloat(image.height) * scale)
            }
            let fill = max(CGFloat(width) / CGFloat(max(1, image.width)),
                           CGFloat(height) / CGFloat(max(1, image.height)))
            let w = CGFloat(image.width) * fill, h = CGFloat(image.height) * fill
            return CGRect(x: (CGFloat(width) - w) / 2 + offset.x * scale,
                          y: (CGFloat(height) - h) / 2 + offset.y * scale,
                          width: w, height: h)
        }
        let bufferRect = CGRect(x: 0, y: 0, width: width, height: height)
        // Puffer aus dem Pool tragen noch das vorige Bild – erst leeren.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bufferRect)

        // 1) Echo-Grundlage: vorheriger Output-Frame
        let useEcho = echoStrength > 0 && previousComposed != nil
        if useEcho, let prev = previousComposed {
            context.draw(prev, in: bufferRect)
        }

        // 2) Aktuellen Inhalt zeichnen (bei Echo halbtransparent darüber)
        if useEcho {
            context.setAlpha(CGFloat(1 - echoStrength))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.draw(base, in: drawRect(for: base, offset: offset))

        // 3) Übergang: Overlay aufdecken – als Falzkante oder als Facetten.
        if let overlay, revealProgress > 0 {
            switch transitionStyle {
            case .crease:
                let legs = Algorithms.foldRevealLegs(
                    progress: revealProgress,
                    width: Double(width), height: Double(height))
                context.saveGState()
                let clip = CGMutablePath()
                clip.move(to: CGPoint(x: 0, y: 0))
                clip.addLine(to: CGPoint(x: legs.lx, y: 0))
                clip.addLine(to: CGPoint(x: 0, y: legs.ly))
                clip.closeSubpath()
                context.addPath(clip)
                context.clip()
                context.draw(overlay, in: drawRect(for: overlay, offset: overlayOffset))
                context.restoreGState()
                // Falzlicht: helle Falzkante + Schlagschatten dahinter
                // (Licht von links oben, wie in Tolinos Aufnahmen)
                context.setStrokeColor(CGColor(gray: 0.05, alpha: 0.22))
                context.setLineWidth(4)
                context.move(to: CGPoint(x: legs.lx + 3, y: 0))
                context.addLine(to: CGPoint(x: 0, y: legs.ly + 3))
                context.strokePath()
                context.setStrokeColor(CGColor(gray: 0.95, alpha: 0.8))
                context.setLineWidth(2)
                context.move(to: CGPoint(x: legs.lx, y: 0))
                context.addLine(to: CGPoint(x: 0, y: legs.ly))
                context.strokePath()

            case .facet:
                // Triangulierte Facetten klappen diagonal gestaffelt um
                // (Geometrie wurde einmalig in write() berechnet).
                let od = drawRect(for: overlay, offset: overlayOffset)
                for f in facets {
                    let a = Algorithms.facetAlpha(phase: f.phase, progress: revealProgress)
                    if a <= 0 { continue }
                    context.saveGState()
                    let tri = CGMutablePath()
                    tri.move(to: f.a); tri.addLine(to: f.b); tri.addLine(to: f.c); tri.closeSubpath()
                    context.addPath(tri)
                    context.clip()
                    context.setAlpha(CGFloat(a))
                    context.draw(overlay, in: od)
                    context.setAlpha(1)
                    if a < 1 { // Falzlicht: klappende Facette liegt im Schatten
                        context.addPath(tri)
                        context.setFillColor(CGColor(gray: 0, alpha: (1 - a) * 0.2))
                        context.fillPath()
                        context.addPath(tri)
                        context.setStrokeColor(CGColor(gray: 0.96, alpha: 0.45))
                        context.setLineWidth(1.5)
                        context.strokePath()
                    }
                    context.restoreGState()
                }

            case .weave:
                // Der nächste Frame wird als Streifen "eingewoben" – abwechselnd
                // von oben und unten, gestaffelt (nach Tolinos Webtechnik).
                let od = drawRect(for: overlay, offset: overlayOffset)
                let bufferH = Double(height)
                for strip in weave {
                    let reveal = Algorithms.weaveReveal(phase: strip.phase, progress: revealProgress)
                    if reveal <= 0 { continue }
                    let stripH = bufferH * reveal
                    // CG-Ursprung ist unten links: "von oben" = oberer Bildbereich
                    let clipRect = strip.fromTop
                        ? CGRect(x: strip.x, y: bufferH - stripH, width: strip.width, height: stripH)
                        : CGRect(x: strip.x, y: 0, width: strip.width, height: stripH)
                    context.saveGState()
                    context.clip(to: clipRect)
                    context.draw(overlay, in: od)
                    context.restoreGState()
                    if reveal < 1 { // Webkante betonen
                        let edgeY = strip.fromTop ? bufferH - stripH : stripH
                        context.setStrokeColor(CGColor(gray: 0.95, alpha: 0.7))
                        context.setLineWidth(2)
                        context.move(to: CGPoint(x: strip.x, y: edgeY))
                        context.addLine(to: CGPoint(x: strip.x + strip.width, y: edgeY))
                        context.strokePath()
                    }
                }
                // Vertikale Webfugen mit zartem Schatten (Über-/Unter-Effekt)
                context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.16))
                context.setLineWidth(1.5)
                for strip in weave.dropFirst() {
                    context.move(to: CGPoint(x: strip.x, y: 0))
                    context.addLine(to: CGPoint(x: strip.x, y: bufferH))
                }
                context.strokePath()
            }
        }
        if useEcho {
            context.endTransparencyLayer()
            context.setAlpha(1)
        }

        // 4) Papierrelief: jede Facette liegt anders im Licht – das Bild wirkt
        //    wie gefaltetes, wieder abfotografiertes Papier (Bild → Objekt → Bild)
        if !reliefFacets.isEmpty {
            for (index, facet) in reliefFacets.enumerated() {
                let shade = Algorithms.facetShade(
                    index: index, phase: facet.phase, strength: reliefStrength)
                let tri = CGMutablePath()
                tri.move(to: facet.a); tri.addLine(to: facet.b)
                tri.addLine(to: facet.c); tri.closeSubpath()
                if abs(shade) >= 0.005 {
                    context.addPath(tri)
                    context.setFillColor(CGColor(gray: shade > 0 ? 1 : 0, alpha: abs(shade)))
                    context.fillPath()
                }
                // hauchfeine Falzlinien des Reliefs
                context.addPath(tri)
                context.setStrokeColor(CGColor(gray: 0.1, alpha: 0.05))
                context.setLineWidth(1)
                context.strokePath()
            }
        }

        // 5) Druckbild: Schwarzweiß (Blend-Modus „color" nimmt die Farbe,
        //    lässt die Helligkeit) + warmer Papierton übers Multiplizieren
        if printLook {
            context.saveGState()
            context.setBlendMode(.color)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(bufferRect)
            context.setBlendMode(.multiply)
            // Kräftigerer warmer Papierton (Blau deutlich stärker gedämpft):
            // der Druck liegt sichtbar auf cremefarbenem Papier statt fast neutralgrau.
            context.setFillColor(CGColor(red: 0.98, green: 0.94, blue: 0.85, alpha: 1))
            context.fill(bufferRect)
            context.restoreGState()
        }

        // 6) Fertiges Bild für das Echo des nächsten Frames sichern
        composedOut = context.makeImage()
        return pixelBuffer
    }
}

/// Liefert Frames aus einem EINZIGEN sequentiellen Decoder-Durchlauf für
/// monoton aufsteigende Index-Anfragen (Normalmodus). Hält nur ein kleines
/// Fenster im Speicher (aktueller + nächster Frame für Übergänge), sodass
/// auch lange Sequenzen nicht den Speicher füllen.
private final class SequentialFrameSource {

    private var iterator: AVAssetImageGenerator.Images.AsyncIterator
    private var window: [Int: CGImage] = [:]
    private var nextIndex = 0

    init(generator: AVAssetImageGenerator, times: [CMTime]) {
        iterator = generator.images(for: times).makeAsyncIterator()
    }

    func frame(at index: Int) async throws -> CGImage {
        if let cached = window[index] { return cached }
        while nextIndex <= index {
            guard let result = await iterator.next() else {
                throw PipelineError.exportFailed
            }
            if case .success(requestedTime: _, image: let image, actualTime: _) = result {
                window[nextIndex] = image
            }
            nextIndex += 1
        }
        // Fenster klein halten: nur Vorgänger + aktueller Frame bleiben
        window = window.filter { $0.key >= index - 1 }
        guard let image = window[index] else { throw PipelineError.exportFailed }
        return image
    }
}

// MARK: - Flimmerausgleich

extension StopMotionAssembler {
    private static let gainContext = CIContext(options: [.cacheIntermediates: false])

    /// Mittlere Helligkeit (0…1) auf einem 32 × 32-Graubild – schnell genug,
    /// um jedes Bild eines langen Films einmal zu messen.
    static func meanLuma(_ image: CGImage) -> Double {
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(px.reduce(0) { $0 + Int($1) }) / Double(px.count) / 255
    }

    /// Hellt ein Bild um `gain` (gemessen im sRGB-Wert) auf oder ab. Core
    /// Image rechnet linear – daher die Belichtung um 2,2 × log₂(gain).
    static func applyGain(_ image: CGImage, _ gain: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(2.2 * log2(gain), forKey: kCIInputEVKey)
        guard let output = filter.outputImage else { return nil }
        return gainContext.createCGImage(output, from: input.extent)
    }
}

// MARK: - GIF

/// Macht aus dem fertigen Film ein endlos laufendes GIF – für Messenger,
/// Schulplattformen und Präsentationen, die kein Video abspielen. Aus dem
/// Film statt aus den Einzelbildern, damit Format, Ausrichtung,
/// Überblendungen und Abspielmodus genau stimmen.
enum GIFMaker {
    /// Längste Seite in Pixeln, höchstens so viele Bilder pro Sekunde und
    /// insgesamt: hält die Datei bei langen Filmen handlich.
    static let maxSide: CGFloat = 640
    static let maxFPS: Double = 15
    static let maxFrames = 400

    static func make(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.exportFailed
        }
        let duration = try await asset.load(.duration).seconds
        let nominal = Double(try await track.load(.nominalFrameRate))
        var fps = min(nominal > 0 ? nominal : 10, maxFPS)
        if duration * fps > Double(maxFrames) { fps = Double(maxFrames) / duration }
        let count = max(1, Int((duration * fps).rounded(.down)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 600)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("framefold-\(UUID().uuidString.prefix(8)).gif")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw PipelineError.exportFailed
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1.0 / fps,
            kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps
        ]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: (Double(i) + 0.5) / fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(dest, image, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw PipelineError.exportFailed }
        return url
    }
}

// MARK: Tonspur

extension StopMotionAssembler {
    /// Legt eine Audiodatei unter den fertigen Film. Der Ton wird auf die
    /// Filmlänge gekürzt; ist er kürzer, endet er einfach früher. Bild und
    /// Ton werden nur umverpackt (kein neues Kodieren) – deshalb schnell.
    /// MP4, wo der Ton es zulässt, sonst QuickTime.
    static func addAudio(_ audioURL: URL, to videoURL: URL) async throws -> URL {
        let video = AVURLAsset(url: videoURL)
        let audio = AVURLAsset(url: audioURL)
        guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audio.loadTracks(withMediaType: .audio).first else {
            throw PipelineError.exportFailed
        }
        let duration = try await video.load(.duration)
        let audioDuration = try await audio.load(.duration)

        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PipelineError.exportFailed
        }
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)),
                              of: audioTrack, at: .zero)

        for type in [AVFileType.mp4, .mov] {
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
                  session.supportedFileTypes.contains(type) else { continue }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("framefold-\(UUID().uuidString.prefix(8)).\(type == .mp4 ? "mp4" : "mov")")
            session.outputURL = url
            session.outputFileType = type
            await withCheckedContinuation { cont in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed { return url }
        }
        throw PipelineError.exportFailed
    }
}

// MARK: Bildsequenz

/// Format der Einzelbilder beim Sequenz-Export.
enum SequenceFormat: String, CaseIterable, Identifiable {
    case png, tiff, jpeg
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var type: UTType {
        switch self {
        case .png: return .png
        case .tiff: return .tiff
        case .jpeg: return .jpeg
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

extension StopMotionAssembler {
    /// Schreibt die Bilder in voller Auflösung als nummerierte Einzelbilder
    /// in einen neuen Ordner („Werk_0001.png“ …) – für Schnitt, Compositing
    /// und Archiv. Gibt den Ordner zurück.
    static func exportSequence(_ urls: [URL], name: String, format: SequenceFormat,
                               progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let safe = WorkPackage.safeName(name)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("framefold-\(UUID().uuidString.prefix(6))", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, url) in urls.enumerated() {
            let target = folder.appendingPathComponent(String(format: "%@_%04d.%@", safe, i + 1, format.fileExtension))
            if format == .jpeg {
                try FileManager.default.copyItem(at: url, to: target)   // schon JPEG – verlustfrei kopieren
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let dest = CGImageDestinationCreateWithURL(target as CFURL, format.type.identifier as CFString, 1, nil)
                else { throw PipelineError.exportFailed }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { throw PipelineError.exportFailed }
            }
            progress(Double(i + 1) / Double(urls.count))
        }
        return folder
    }
}

// MARK: Farblook

extension StopMotionAssembler {
    private static let lookContext = CIContext(options: [.cacheIntermediates: false])

    /// Farblook auf ein Bild anwenden (nil = unverändert lassen).
    static func apply(look: FilmLook, to image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output: CIImage
        switch look {
        case .original:
            return nil
        case .blackWhite:
            output = input.applyingFilter("CIPhotoEffectNoir")
        case .warm:
            output = input.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 0)])
        case .cool:
            output = input.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8200, y: 0)])
        case .vivid:
            output = input.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.12])
        case .faded:
            output = input.applyingFilter("CIPhotoEffectFade")
        }
        return lookContext.createCGImage(output, from: input.extent)
    }
}
