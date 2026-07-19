import Foundation
import AVFoundation
import CoreImage
import Accelerate
import UIKit

/// Extrahiert Frames in niedriger Auflösung und berechnet Bewegungs- und Schärfe-Metriken.
final class FrameAnalyzer {

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    struct AnalyzedFrame {
        let seconds: Double
        let motionScore: Double   // mittlere absolute Differenz zum Vorgänger (0 beim ersten Frame)
        let grayPixels: [UInt8]   // downgesampeltes Graustufenbild (für dHash & Debug)
        let width: Int
        let height: Int
    }

    /// Sampelt das Video mit `settings.samplingFPS` und liefert Bewegungs-Scores.
    func analyze(
        asset: AVAsset,
        settings: PipelineSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> [AnalyzedFrame] {
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw PipelineError.emptyVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: settings.analysisWidth * 2, height: settings.analysisWidth * 2)

        let step = 1.0 / settings.samplingFPS
        var times: [CMTime] = []
        var t = 0.0
        while t < duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }

        var results: [AnalyzedFrame] = []
        var previousGray: [UInt8]? = nil
        var grayWidth = 0, grayHeight = 0

        for (index, time) in times.enumerated() {
            guard let cgImage = try? await generator.image(at: time).image else { continue }

            let (gray, w, h) = Self.grayscaleDownsampled(cgImage, targetWidth: Int(settings.analysisWidth))
            grayWidth = w; grayHeight = h

            var motion = 0.0
            if let prev = previousGray, prev.count == gray.count {
                motion = Algorithms.motionScore(gray, prev)
            }
            previousGray = gray

            results.append(AnalyzedFrame(
                seconds: time.seconds,
                motionScore: motion,
                grayPixels: gray,
                width: grayWidth,
                height: grayHeight
            ))
            progress(Double(index + 1) / Double(times.count))
        }
        return results
    }

    /// Konvertiert ein CGImage in ein downgesampeltes Graustufen-Array.
    static func grayscaleDownsampled(_ image: CGImage, targetWidth: Int) -> ([UInt8], Int, Int) {
        let aspect = Double(image.height) / Double(image.width)
        let w = targetWidth
        let h = max(1, Int(Double(targetWidth) * aspect))

        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buffer in
            if let context = CGContext(
                data: buffer.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) {
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return (pixels, w, h)
    }

    /// Laplacian-Varianz als Schärfemaß (delegiert an Algorithms).
    static func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Double {
        Algorithms.laplacianVariance(gray: gray, width: width, height: height)
    }

    /// dHash für Deduplizierung (delegiert an Algorithms).
    static func dHash(gray: [UInt8], width: Int, height: Int) -> UInt64 {
        Algorithms.dHash(gray: gray, width: width, height: height)
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        Algorithms.hammingDistance(a, b)
    }
}

enum PipelineError: LocalizedError {
    case emptyVideo
    case noKeyframesFound
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .emptyVideo: return "Das Video ist leer oder konnte nicht gelesen werden."
        case .noKeyframesFound: return "Keine ruhigen Momente gefunden – versuche die Empfindlichkeit zu erhöhen."
        case .exportFailed: return "Das Stopmotion-Video konnte nicht geschrieben werden."
        }
    }
}
