import Foundation
import AVFoundation
import CoreVideo
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
                return image
            },
            progress: progress
        )
    }

    // MARK: Kern

    private func write(
        frameCount: Int,
        settings: PipelineSettings,
        frameProvider: @escaping (Int) async throws -> CGImage,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
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
            .appendingPathComponent("framefold-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: settings.outputFPS)
        let aligner = settings.alignFrames ? FrameAligner() : nil

        // Render-Plan: Reihenfolge + optionale Falz-Blenden-Zwischenframes
        let steps = Algorithms.renderPlan(order: order, transitionFrames: settings.transitionFrames)

        // Facetten-Geometrie EINMAL berechnen statt pro Zwischenframe
        let facets: [Algorithms.Facet] =
            (settings.transitionStyle == .facet && settings.transitionFrames > 0)
            ? Algorithms.facetPlan(width: Double(width), height: Double(height), cols: 6, rows: 6)
            : []

        // Kleiner Frame-Cache (Basis + Overlay), damit lange Videos nicht
        // komplett im Speicher liegen. Der erste Frame ist schon geladen.
        var cache: [Int: CGImage] = [order[0]: firstImage]
        func image(at index: Int) async throws -> CGImage {
            if let cached = cache[index] { return cached }
            let img = try await frameProvider(index)
            if cache.count > 3 { cache.removeAll() }
            cache[index] = img
            return img
        }

        // Echo-Rekursion: der zuletzt geschriebene Output-Frame
        var lastComposed: CGImage? = nil
        let echo = settings.interferenzEcho ? max(0, min(0.5, settings.echoStrength)) : 0

        for (position, step) in steps.enumerated() {
            var baseImage = try await image(at: step.baseIndex)
            var overlayImage: CGImage? = nil
            if let overlayIndex = step.overlayIndex {
                overlayImage = try await image(at: overlayIndex)
            }

            // Alignment nur auf echten Keyframes fortschreiben (nicht auf Blenden).
            // Stufe 1: Homographie (korrigiert auch Verdrehung/Neigung),
            // Stufe 2: Verschiebungs-Fallback per Block-Matching.
            var offset: CGPoint = .zero
            if step.overlayIndex == nil, let aligner {
                if let warped = aligner.warp(baseImage) {
                    baseImage = warped
                } else {
                    offset = aligner.register(baseImage)
                }
            }

            guard let pixelBuffer = Self.renderStep(
                base: baseImage, overlay: overlayImage, revealProgress: step.progress,
                previousComposed: lastComposed, echoStrength: echo,
                transitionStyle: settings.transitionStyle, facets: facets,
                cropRect: cropRect, width: width, height: height, scale: renderScale,
                offset: offset, pool: adaptor.pixelBufferPool,
                composedOut: &lastComposed) else { continue }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(position))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            progress(Double(position + 1) / Double(steps.count))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw PipelineError.exportFailed }
        return outputURL
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
        cropRect: CGRect, width: Int, height: Int, scale: CGFloat,
        offset: CGPoint, pool: CVPixelBufferPool?,
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
        func drawRect(for image: CGImage) -> CGRect {
            CGRect(
                x: (-cropRect.minX + offset.x) * scale,
                y: (-(CGFloat(image.height) - cropRect.maxY) + offset.y) * scale,
                width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale)
        }
        let bufferRect = CGRect(x: 0, y: 0, width: width, height: height)

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
        context.draw(base, in: drawRect(for: base))

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
                context.draw(overlay, in: drawRect(for: overlay))
                context.setStrokeColor(CGColor(gray: 0.95, alpha: 0.8))
                context.setLineWidth(2)
                context.move(to: CGPoint(x: legs.lx, y: 0))
                context.addLine(to: CGPoint(x: 0, y: legs.ly))
                context.strokePath()
                context.restoreGState()

            case .facet:
                // Triangulierte Facetten klappen diagonal gestaffelt um
                // (Geometrie wurde einmalig in write() berechnet).
                let od = drawRect(for: overlay)
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
                    if a < 1 { // Kante der gerade klappenden Facette betonen
                        context.addPath(tri)
                        context.setStrokeColor(CGColor(gray: 0.96, alpha: 0.45))
                        context.setLineWidth(1.5)
                        context.strokePath()
                    }
                    context.restoreGState()
                }
            }
        }
        if useEcho {
            context.endTransparencyLayer()
            context.setAlpha(1)
        }

        // 4) Fertiges Bild für das Echo des nächsten Frames sichern
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
