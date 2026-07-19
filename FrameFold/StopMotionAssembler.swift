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

        return try await write(
            frameCount: keyframeTimes.count,
            settings: settings,
            frameProvider: { index in
                let time = CMTime(seconds: keyframeTimes[index], preferredTimescale: 600)
                return try await generator.image(at: time).image
            },
            progress: progress
        )
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
        let width = Int(cropRect.width) - (Int(cropRect.width) % 2)
        let height = Int(cropRect.height) - (Int(cropRect.height) % 2)

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
            let baseImage = try await image(at: step.baseIndex)
            var overlayImage: CGImage? = nil
            if let overlayIndex = step.overlayIndex {
                overlayImage = try await image(at: overlayIndex)
            }

            // Alignment nur auf echten Keyframes fortschreiben (nicht auf Blenden)
            let offset: CGPoint
            if step.overlayIndex == nil {
                offset = aligner?.register(baseImage) ?? .zero
            } else {
                offset = .zero
            }

            guard let pixelBuffer = Self.renderStep(
                base: baseImage, overlay: overlayImage, revealProgress: step.progress,
                previousComposed: lastComposed, echoStrength: echo,
                cropRect: cropRect, width: width, height: height,
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
        cropRect: CGRect, width: Int, height: Int,
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

        // Bild so zeichnen, dass cropRect (plus Alignment-Offset) den Buffer füllt
        func drawRect(for image: CGImage) -> CGRect {
            CGRect(
                x: -cropRect.minX + offset.x,
                y: -(CGFloat(image.height) - cropRect.maxY) + offset.y,
                width: CGFloat(image.width),
                height: CGFloat(image.height))
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

        // 3) Falz-Blende: Overlay entlang der Diagonale aufdecken.
        //    (CoreGraphics-Ursprung ist links unten – das Aufdeck-Dreieck
        //    startet daher optisch in der linken unteren Ecke des Videos.)
        if let overlay, revealProgress > 0 {
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
            // Falzkante als Haarlinie
            context.setStrokeColor(CGColor(gray: 0.95, alpha: 0.8))
            context.setLineWidth(2)
            context.move(to: CGPoint(x: legs.lx, y: 0))
            context.addLine(to: CGPoint(x: 0, y: legs.ly))
            context.strokePath()
            context.restoreGState()
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
