import Foundation
import AVFoundation
import SwiftUI

/// Orchestriert die komplette Pipeline:
/// Sampling → Ruhefenster → Handprüfung → Dedup → Assembly.
@MainActor
final class ProcessingViewModel: ObservableObject {

    @Published var stage: PipelineStage = .idle
    @Published var result: PipelineResult?
    @Published var settings = PipelineSettings()
    /// Quelle des letzten Laufs – für "Als Projekt sichern"
    private(set) var lastVideoURL: URL?

    private let analyzer = FrameAnalyzer()
    private let assembler = StopMotionAssembler()
    /// CoreML-Modell (RF-DETR), falls gebündelt – sonst Apples Vision
    private let handDetector: HandDetecting = HandDetectorFactory.make()

    func process(videoURL: URL) {
        stage = .sampling(progress: 0)
        result = nil
        lastVideoURL = videoURL

        Task {
            do {
                let output = try await runPipeline(videoURL: videoURL)
                self.result = output
                self.stage = .done
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func runPipeline(videoURL: URL) async throws -> PipelineResult {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let settings = self.settings

        // [1] + [2] Sampling & Bewegungsanalyse (niedrige Auflösung)
        let frames = try await analyzer.analyze(asset: asset, settings: settings) { p in
            Task { @MainActor in self.stage = .analyzing(progress: p) }
        }

        // [3] Ruhefenster finden
        await MainActor.run { self.stage = .selectingKeyframes }
        let windows = KeyframeSelector.stillWindows(frames: frames, settings: settings)
        guard !windows.isEmpty else { throw PipelineError.noKeyframesFound }

        // [4] Pro Fenster: bester Frame ohne Hände; dHash-Dedup gegen den Vorgänger
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 640) // reicht für Handerkennung

        var keyframeTimes: [Double] = []
        var lastHash: UInt64? = nil
        var discardedHands = 0
        var discardedDupes = 0

        for (index, window) in windows.enumerated() {
            let candidates = KeyframeSelector.rankedCandidates(in: window)
            var chosen: FrameAnalyzer.AnalyzedFrame? = nil

            for candidate in candidates {
                if settings.removeHands {
                    let time = CMTime(seconds: candidate.seconds, preferredTimescale: 600)
                    guard let cgImage = try? await generator.image(at: time).image else { continue }
                    if handDetector.containsHands(cgImage: cgImage, confidence: settings.handConfidence) {
                        discardedHands += 1
                        continue
                    }
                }
                chosen = candidate
                break
            }

            if let chosen {
                let hash = FrameAnalyzer.dHash(gray: chosen.grayPixels,
                                               width: chosen.width, height: chosen.height)
                if let last = lastHash,
                   FrameAnalyzer.hammingDistance(hash, last) < settings.dedupHashThreshold {
                    discardedDupes += 1
                } else {
                    keyframeTimes.append(chosen.seconds)
                    lastHash = hash
                }
            }
            await MainActor.run {
                self.stage = .checkingHands(progress: Double(index + 1) / Double(windows.count))
            }
        }

        guard !keyframeTimes.isEmpty else { throw PipelineError.noKeyframesFound }

        // [5] Assembly in voller Auflösung
        let outputURL = try await assembler.assemble(
            asset: asset, keyframeTimes: keyframeTimes, settings: settings
        ) { p in
            Task { @MainActor in self.stage = .assembling(progress: p) }
        }

        return PipelineResult(
            keyframeTimes: keyframeTimes,
            outputURL: outputURL,
            sourceDuration: duration,
            discardedForHands: discardedHands,
            discardedAsDuplicates: discardedDupes
        )
    }
}
