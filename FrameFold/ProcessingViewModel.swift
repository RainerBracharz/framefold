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

        // Handprüfung RUNDENWEISE statt Frame für Frame:
        // Runde 0 prüft die besten Kandidaten ALLER Fenster in einem einzigen
        // sequentiellen Decoder-Durchlauf (statt einem teuren Seek pro Frame).
        // Nur Fenster, deren Kandidat durchfällt, gehen mit ihrem nächstbesten
        // in die nächste Runde. Dekodierung + Vision laufen dabei abseits des
        // MainActors – die UI bleibt flüssig.
        let candidates = windows.map { KeyframeSelector.rankedCandidates(in: $0) }
        var chosenPerWindow = [(time: Double, gray: [UInt8], w: Int, h: Int)?](
            repeating: nil, count: windows.count)
        var discardedHands = 0

        if settings.removeHands {
            var pending = Array(windows.indices)
            var round = 0
            let totalWindows = windows.count
            while !pending.isEmpty {
                if Task.isCancelled { return }
                var stillPending: [Int] = []
                var needCheck: [(window: Int, time: Double)] = []

                for wi in pending {
                    // alle Kandidaten dieses Fensters zeigen Hände → Fenster entfällt
                    guard round < candidates[wi].count else { continue }
                    let c = candidates[wi][round]
                    let key = Int(c.seconds * 1000)
                    if let cached = handCache[key] {
                        if cached { discardedHands += 1; stillPending.append(wi) }
                        else { chosenPerWindow[wi] = (c.seconds, c.grayPixels, c.width, c.height) }
                    } else {
                        needCheck.append((wi, c.seconds))
                    }
                }

                if !needCheck.isEmpty {
                    needCheck.sort { $0.time < $1.time }
                    let resolvedSoFar = totalWindows - pending.count
                    let checkCount = needCheck.count
                    let detected = await BatchFrameDecoder.detectHands(
                        asset: asset, times: needCheck.map(\.time),
                        detector: handDetector, confidence: settings.handConfidence
                    ) { p in
                        guard reportProgress else { return }
                        let overall = (Double(resolvedSoFar) + p * Double(checkCount))
                            / Double(totalWindows)
                        Task { @MainActor in
                            self.stage = .checkingHands(progress: min(1, overall))
                        }
                    }
                    if Task.isCancelled { return }
                    for (wi, time) in needCheck {
                        let key = Int(time * 1000)
                        let check = detected[key]
                        let hasHands = check?.hasHands ?? false
                        handCache[key] = hasHands
                        if let image = check?.image, thumbCache[key] == nil {
                            thumbCache[key] = image // Vorschaubild gratis mitgenommen
                        }
                        if hasHands { discardedHands += 1; stillPending.append(wi) }
                        else {
                            let c = candidates[wi][round]
                            chosenPerWindow[wi] = (c.seconds, c.grayPixels, c.width, c.height)
                        }
                    }
                }
                pending = stillPending
                round += 1
            }
        } else {
            for (wi, cands) in candidates.enumerated() {
                if let c = cands.first {
                    chosenPerWindow[wi] = (c.seconds, c.grayPixels, c.width, c.height)
                }
            }
        }

        let chosen = chosenPerWindow.compactMap { $0 }

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

        // Vorschaubilder: fehlende in EINEM Decoder-Durchlauf nachladen
        let missing = deduped.filter { thumbCache[Int($0 * 1000)] == nil }
        if !missing.isEmpty {
            let thumbs = await BatchFrameDecoder.thumbnails(asset: asset, times: missing)
            for (key, image) in thumbs { thumbCache[key] = image }
        }
        if Task.isCancelled { return }
        self.reviewFrames = deduped.map { time in
            let key = Int(time * 1000)
            return ReviewFrame(id: key, time: time, thumbnail: thumbCache[key])
        }
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

/// Batch-Dekodierung abseits des MainActors: alle angefragten Zeiten werden
/// in EINEM sequentiellen Decoder-Durchlauf geliefert (statt einem Seek pro
/// Frame, der jeweils vom letzten Sync-Frame neu dekodieren müsste).
/// Bewusst KEIN @MainActor – Vision-Handerkennung und Dekodierung blockieren
/// so nie die Oberfläche.
private enum BatchFrameDecoder {

    struct CheckResult {
        let hasHands: Bool
        let image: UIImage?   // dekodiertes Bild gleich mitliefern → dient später als Vorschaubild
    }

    /// Prüft die Frames an den gegebenen Zeiten auf Hände.
    /// Ergebnis: Zeit-Schlüssel (Millisekunden) → Ergebnis inkl. Bild,
    /// damit die Vorschau NICHT noch einmal dekodieren muss.
    static func detectHands(
        asset: AVAsset,
        times: [Double],
        detector: HandDetecting,
        confidence: Float,
        progress: @escaping (Double) -> Void
    ) async -> [Int: CheckResult] {
        guard !times.isEmpty else { return [:] }
        let generator = makeGenerator(asset: asset)
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }

        var out: [Int: CheckResult] = [:]
        var index = 0
        for await result in generator.images(for: cmTimes) {
            if Task.isCancelled { break }
            let key = Int(times[index] * 1000)
            if case .success(requestedTime: _, image: let cgImage, actualTime: _) = result {
                let hasHands = detector.containsHands(cgImage: cgImage, confidence: confidence)
                out[key] = CheckResult(
                    hasHands: hasHands,
                    image: hasHands ? nil : UIImage(cgImage: cgImage))
            } else {
                out[key] = CheckResult(hasHands: false, image: nil) // im Zweifel behalten
            }
            index += 1
            progress(Double(index) / Double(cmTimes.count))
        }
        return out
    }

    /// Lädt Vorschaubilder für die gegebenen Zeiten.
    /// Ergebnis: Zeit-Schlüssel (Millisekunden) → Bild.
    static func thumbnails(asset: AVAsset, times: [Double]) async -> [Int: UIImage] {
        guard !times.isEmpty else { return [:] }
        let generator = makeGenerator(asset: asset)
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }

        var out: [Int: UIImage] = [:]
        var index = 0
        for await result in generator.images(for: cmTimes) {
            if Task.isCancelled { break }
            if case .success(requestedTime: _, image: let cgImage, actualTime: _) = result {
                out[Int(times[index] * 1000)] = UIImage(cgImage: cgImage)
            }
            index += 1
        }
        return out
    }

    private static func makeGenerator(asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 640)
        return generator
    }
}
