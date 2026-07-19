import Foundation
import AVFoundation
import SwiftUI

/// Ein Keyframe-Kandidat in der Review-Ansicht.
struct ReviewFrame: Identifiable {
    let id: Int          // Millisekunden-Zeitstempel (stabil über Neuberechnungen)
    let time: Double
    var thumbnail: UIImage?
    var selected: Bool = true
}

/// Orchestriert die Pipeline in zwei Phasen:
/// 1. Analyse (Sampling → Bewegungs-Scores) – wird GECACHT
/// 2. Review (Ruhefenster + Handprüfung → Kandidaten; Empfindlichkeit
///    live nachregelbar ohne Neuanalyse; Frames einzeln abwählbar)
/// 3. Assembly erst auf Knopfdruck.
@MainActor
final class ProcessingViewModel: ObservableObject {

    @Published var stage: PipelineStage = .idle
    @Published var result: PipelineResult?
    @Published var settings = PipelineSettings()
    @Published var reviewFrames: [ReviewFrame] = []
    @Published var isRecomputing = false
    /// Quelle des letzten Laufs – für "Als Projekt sichern"
    private(set) var lastVideoURL: URL?

    private let analyzer = FrameAnalyzer()
    private let assembler = StopMotionAssembler()
    /// CoreML-Modell (RF-DETR), falls gebündelt – sonst Apples Vision
    private let handDetector: HandDetecting = HandDetectorFactory.make()

    // Analyse-Cache: einmal gerechnet, beliebig oft neu ausgewertet
    private var cachedFrames: [FrameAnalyzer.AnalyzedFrame] = []
    private var cachedAsset: AVURLAsset?
    private var handCache: [Int: Bool] = [:]        // Zeit (ms) → Hände sichtbar
    private var thumbCache: [Int: UIImage] = [:]    // Zeit (ms) → Vorschaubild
    private var discardedForHands = 0
    private var recomputeTask: Task<Void, Never>?

    var selectedCount: Int { reviewFrames.filter(\.selected).count }

    // MARK: Phase 1 – Analyse (einmal pro Video)

    func process(videoURL: URL) {
        stage = .sampling(progress: 0)
        result = nil
        reviewFrames = []
        lastVideoURL = videoURL
        cachedFrames = []
        handCache = [:]
        thumbCache = [:]

        Task {
            do {
                let asset = AVURLAsset(url: videoURL)
                self.cachedAsset = asset
                self.cachedFrames = try await analyzer.analyze(asset: asset, settings: settings) { p in
                    Task { @MainActor in self.stage = .analyzing(progress: p) }
                }
                try await self.computeCandidates(reportProgress: true)
                self.stage = .reviewing
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Phase 2 – Kandidaten aus dem Cache (bei Regleränderung erneut)

    /// Wird vom Empfindlichkeits-Regler aufgerufen: bricht eine laufende
    /// Neuberechnung ab und startet frisch – ohne das Video neu zu lesen.
    func recomputeFromCache() {
        guard !cachedFrames.isEmpty else { return }
        recomputeTask?.cancel()
        isRecomputing = true
        recomputeTask = Task {
            try? await self.computeCandidates(reportProgress: false)
            if !Task.isCancelled { self.isRecomputing = false }
        }
    }

    private func computeCandidates(reportProgress: Bool) async throws {
        guard let asset = cachedAsset else { return }
        let settings = self.settings

        let windows = KeyframeSelector.stillWindows(frames: cachedFrames, settings: settings)
        guard !windows.isEmpty else {
            if reportProgress { throw PipelineError.noKeyframesFound }
            reviewFrames = []
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 640)

        var chosen: [(time: Double, gray: [UInt8], w: Int, h: Int)] = []
        var discardedHands = 0

        for (index, window) in windows.enumerated() {
            if Task.isCancelled { return }
            let candidates = KeyframeSelector.rankedCandidates(in: window)
            for candidate in candidates {
                let key = Int(candidate.seconds * 1000)
                var hasHands = false
                if settings.removeHands {
                    if let cached = handCache[key] {
                        hasHands = cached
                    } else {
                        let time = CMTime(seconds: candidate.seconds, preferredTimescale: 600)
                        if let cgImage = try? await generator.image(at: time).image {
                            hasHands = handDetector.containsHands(
                                cgImage: cgImage, confidence: settings.handConfidence)
                        }
                        handCache[key] = hasHands
                    }
                }
                if hasHands {
                    discardedHands += 1
                    continue
                }
                chosen.append((candidate.seconds, candidate.grayPixels,
                               candidate.width, candidate.height))
                break
            }
            if reportProgress {
                let p = Double(index + 1) / Double(windows.count)
                await MainActor.run { self.stage = .checkingHands(progress: p) }
            }
        }

        // dHash-Dedup benachbarter Keyframes
        var deduped: [Double] = []
        var lastHash: UInt64? = nil
        for frame in chosen {
            let hash = Algorithms.dHash(gray: frame.gray, width: frame.w, height: frame.h)
            if let last = lastHash,
               Algorithms.hammingDistance(hash, last) < settings.dedupHashThreshold {
                continue
            }
            deduped.append(frame.time)
            lastHash = hash
        }
        self.discardedForHands = discardedHands

        // Vorschaubilder (aus dem Cache, fehlende nachladen)
        var frames: [ReviewFrame] = []
        for time in deduped {
            if Task.isCancelled { return }
            let key = Int(time * 1000)
            var thumb = thumbCache[key]
            if thumb == nil {
                let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                if let cgImage = try? await generator.image(at: cmTime).image {
                    thumb = UIImage(cgImage: cgImage)
                    thumbCache[key] = thumb
                }
            }
            frames.append(ReviewFrame(id: key, time: time, thumbnail: thumb))
        }
        self.reviewFrames = frames
    }

    func toggleFrame(_ id: Int) {
        guard let index = reviewFrames.firstIndex(where: { $0.id == id }) else { return }
        reviewFrames[index].selected.toggle()
    }

    // MARK: Phase 3 – Assembly (auf Knopfdruck)

    func createVideo() {
        guard let asset = cachedAsset else { return }
        let times = reviewFrames.filter(\.selected).map(\.time)
        guard !times.isEmpty else { return }
        let duration = cachedFrames.last?.seconds ?? 0
        let discarded = discardedForHands
        stage = .assembling(progress: 0)

        Task {
            do {
                let outputURL = try await assembler.assemble(
                    asset: asset, keyframeTimes: times, settings: settings
                ) { p in
                    Task { @MainActor in self.stage = .assembling(progress: p) }
                }
                self.result = PipelineResult(
                    keyframeTimes: times,
                    outputURL: outputURL,
                    sourceDuration: duration,
                    discardedForHands: discarded,
                    discardedAsDuplicates: 0)
                self.stage = .done
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Zurück von der Ergebnis- zur Review-Ansicht (Cache bleibt erhalten).
    func backToReview() {
        guard !reviewFrames.isEmpty else { return }
        stage = .reviewing
    }
}
