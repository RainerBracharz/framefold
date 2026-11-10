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
    @Published var settings = PipelineSettings.restored() {
        didSet { settings.persist() }
    }

    /// Im Werk geänderte Export-Einstellungen übernehmen, wenn der Video-Tab
    /// wieder erscheint – sonst überschriebe seine ältere Kopie sie bei der
    /// nächsten Änderung.
    func reloadSettings() {
        let latest = PipelineSettings.restored()
        if latest != settings { settings = latest }
    }
    @Published var reviewFrames: [ReviewFrame] = []
    @Published var isRecomputing = false
    /// Quelle des letzten Laufs – für "Als Projekt sichern"
    private(set) var lastVideoURL: URL?

    private let analyzer = FrameAnalyzer()
    private let assembler = StopMotionAssembler()
    private let handDetector: HandDetecting = VisionHandDetector()

    // Analyse-Cache: einmal gerechnet, beliebig oft neu ausgewertet
    private var cachedFrames: [FrameAnalyzer.AnalyzedFrame] = []
    private var cachedAsset: AVURLAsset?
    /// Handprüfung je ruhigem Fenster, gemessen an eval/hands und eval/run_eval.py.
    static let handSampleCount = 9
    static let handWindowShare = 0.5
    static let handNeighborSeconds = 0.2
    private var handCache: [Int: Bool] = [:]        // Zeit (ms) → Hände sichtbar
    private var thumbCache: [Int: UIImage] = [:]    // Zeit (ms) → Vorschaubild
    private var discardedForHands = 0
    private var discardedAsDuplicates = 0
    private var recomputeTask: Task<Void, Never>?
    /// Laufende Analyse oder Montage – abbrechbar, und ein neuer Lauf
    /// beendet den alten, statt dass dessen Ergebnis später alles überschreibt.
    private var workTask: Task<Void, Never>?
    private var runID = 0

    /// Fortschritt eines Laufs übernehmen – aber nur, solange er noch
    /// arbeitet. Die Meldungen kommen verzögert auf dem MainActor an; eine
    /// verspätete setzte sonst ein fertiges Ergebnis oder die Bildauswahl
    /// zurück auf „Baue Stopmotion …", und die App schien zu hängen.
    private func report(_ progress: PipelineStage, run id: Int) {
        guard runID == id else { return }
        switch stage {
        case .idle, .reviewing, .done, .failed: return
        default: stage = progress
        }
    }

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

        let id = startRun()
        workTask = Task {
            do {
                let asset = AVURLAsset(url: videoURL)
                let frames = try await analyzer.analyze(asset: asset, settings: settings) { p in
                    Task { @MainActor in self.report(.analyzing(progress: p), run: id) }
                }
                guard self.runID == id else { return }
                self.cachedAsset = asset
                self.cachedFrames = frames
                try await self.computeCandidates(reportProgress: true)
                guard self.runID == id, !Task.isCancelled else { return }
                self.stage = .reviewing
            } catch is CancellationError {
                // abgebrochen – `cancel()` hat den Zustand schon gesetzt
            } catch {
                if self.runID == id { self.stage = .failed(error.localizedDescription) }
            }
        }
    }

    /// Neuer Lauf: den alten beenden und eine frische Kennung vergeben.
    private func startRun() -> Int {
        workTask?.cancel()
        recomputeTask?.cancel()
        isRecomputing = false   // die abgebrochene Neuberechnung setzt es nicht mehr zurück
        runID += 1
        return runID
    }

    /// Abbrechen-Knopf: Eine Analyse führt zurück zum Start, eine Montage
    /// zurück zur Bildauswahl (die Analyse bleibt erhalten).
    func cancel() {
        let wasAssembling: Bool
        if case .assembling = stage { wasAssembling = true } else { wasAssembling = false }
        workTask?.cancel()
        recomputeTask?.cancel()
        runID += 1
        isRecomputing = false
        stage = wasAssembling && !reviewFrames.isEmpty ? .reviewing : .idle
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

        // Handprüfung in zwei Schritten, jeweils in einem einzigen sequentiellen
        // Decoder-Durchlauf (statt einem teuren Seek pro Frame), abseits des
        // MainActors – die UI bleibt flüssig.
        //
        // 1. Stichprobe: bis zu neun Bilder je Fenster, gleichmäßig über die Zeit
        //    verteilt. Zeigt mehr als die Hälfte Hände, ruht dort eine Hand und
        //    das Fenster entfällt. Früher wurde stattdessen Kandidat um Kandidat
        //    probiert, bis einer durchkam – bei einer ruhenden Hand war das genau
        //    das Bild, auf dem die Erkennung sie übersah (eval/hands: Lehrfilm,
        //    22 behaltene Bilder, 15 davon mit Hand; jetzt 6, davon 1).
        // 2. Runden: das schärfste Bild gilt erst als handfrei, wenn auch seine
        //    Nachbarn bis 0,2 s davor und danach keine Hand zeigen. Ein einzelner
        //    Aussetzer der Erkennung reicht so nicht mehr.
        let candidates = windows.map { KeyframeSelector.rankedCandidates(in: $0) }
        var chosenPerWindow = [(time: Double, gray: [UInt8], w: Int, h: Int)?](
            repeating: nil, count: windows.count)
        var discardedHands = 0

        if settings.removeHands {
            let totalWindows = windows.count
            let byTime = windows.map { $0.frames.map(\.seconds) }
            func key(_ t: Double) -> Int { Int(t * 1000) }

            /// Prüft alle noch unbekannten Zeiten und legt sie in handCache ab.
            /// Vorschaubilder nur für `keep`, sonst wüchse der Speicher mit jeder Stichprobe.
            func check(_ times: [Double], keep: Set<Int>, resolved: Int, share: Double) async {
                let unknown = Array(Set(times.filter { handCache[key($0)] == nil }.map(key)))
                    .sorted().map { Double($0) / 1000 }
                guard !unknown.isEmpty else { return }
                let id = runID
                let detected = await BatchFrameDecoder.detectHands(
                    asset: asset, times: unknown,
                    detector: handDetector, confidence: settings.handConfidence
                ) { p in
                    guard reportProgress else { return }
                    let overall = (Double(resolved) + p * share) / Double(totalWindows)
                    Task { @MainActor in
                        self.report(.checkingHands(progress: min(1, overall)), run: id)
                    }
                }
                // Abgebrochen: nur merken, was wirklich geprüft wurde – sonst
                // gälten ungeprüfte Bilder für immer als handfrei.
                for t in unknown {
                    let k = key(t)
                    guard let result = detected[k] else {
                        if !Task.isCancelled { handCache[k] = false }
                        continue
                    }
                    handCache[k] = result.hasHands
                    if keep.contains(k), let image = result.image, thumbCache[k] == nil {
                        thumbCache[k] = image // Vorschaubild gratis mitgenommen
                    }
                }
            }
            func hasHands(_ t: Double) -> Bool { handCache[key(t)] ?? false }

            // 1. Stichprobe
            let samples: [[Double]] = byTime.map { ts in
                guard ts.count > Self.handSampleCount else { return ts }
                let n = Self.handSampleCount
                return (0..<n).map { ts[Int((Double($0) * Double(ts.count - 1) / Double(n - 1)).rounded())] }
            }
            await check(samples.flatMap { $0 }, keep: [], resolved: 0, share: Double(totalWindows) / 2)
            if Task.isCancelled { return }
            var pending: [Int] = []
            for wi in windows.indices {
                let hits = samples[wi].filter(hasHands).count
                if Double(hits) > Double(samples[wi].count) * Self.handWindowShare {
                    discardedHands += 1
                } else {
                    pending.append(wi)
                }
            }

            // 2. Runden mit Nachbarprüfung
            var round = 0
            while !pending.isEmpty {
                if Task.isCancelled { return }
                var groups: [(window: Int, times: [Double])] = []
                for wi in pending {
                    // alle Kandidaten dieses Fensters zeigen Hände → Fenster entfällt
                    guard round < candidates[wi].count else { continue }
                    let t = candidates[wi][round].seconds
                    let near = byTime[wi].filter { abs($0 - t) <= Self.handNeighborSeconds + 1e-6 }
                    groups.append((wi, [t] + near))
                }
                let resolved = totalWindows - pending.count
                let keep = Set(groups.map { key($0.times[0]) })
                await check(groups.flatMap(\.times), keep: keep,
                            resolved: totalWindows / 2 + resolved / 2,
                            share: Double(groups.count) / 2)
                if Task.isCancelled { return }
                var stillPending: [Int] = []
                for (wi, times) in groups {
                    if times.contains(where: hasHands) {
                        discardedHands += 1
                        stillPending.append(wi)
                    } else {
                        let c = candidates[wi][round]
                        chosenPerWindow[wi] = (c.seconds, c.grayPixels, c.width, c.height)
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

        // Duplikate: gegen das zuletzt BEHALTENE Bild, im stärksten von 8×8
        // Rasterfeldern, Helligkeit ausgeglichen. Maßstab ist die Bewegungs-
        // schwelle dieses Videos – was darunter bleibt, ist derselbe Stand.
        // (Vorher dHash 9×8: sah bei kleinem Werk fast nur den Tisch und warf
        // echte Arbeitsschritte weg. Siehe eval/HILLCLIMB.md.)
        let dupLimit = settings.dedupBlockFactor
            * KeyframeSelector.motionThreshold(frames: cachedFrames, settings: settings)
        var deduped: [Double] = []
        var lastGray: [UInt8]? = nil
        var duplicates = 0
        for frame in chosen {
            if let last = lastGray, last.count == frame.gray.count,
               Algorithms.maxBlockDifference(frame.gray, last, width: frame.w, height: frame.h) < dupLimit {
                duplicates += 1
                continue
            }
            deduped.append(frame.time)
            lastGray = frame.gray
        }
        self.discardedForHands = discardedHands
        self.discardedAsDuplicates = duplicates

        // Vorschaubilder: fehlende in EINEM Decoder-Durchlauf nachladen
        let missing = deduped.filter { thumbCache[Int($0 * 1000)] == nil }
        if !missing.isEmpty {
            let thumbs = await BatchFrameDecoder.thumbnails(asset: asset, times: missing)
            for (key, image) in thumbs { thumbCache[key] = image }
        }
        if Task.isCancelled { return }
        // Abgewählte Bilder bleiben abgewählt, wenn der Regler neu rechnet.
        let deselected = Set(reviewFrames.filter { !$0.selected }.map(\.id))
        self.reviewFrames = deduped.map { time in
            let key = Int(time * 1000)
            return ReviewFrame(id: key, time: time, thumbnail: thumbCache[key],
                               selected: !deselected.contains(key))
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
        let duplicates = discardedAsDuplicates
        stage = .assembling(progress: 0)

        let id = startRun()
        workTask = Task {
            do {
                let outputURL = try await assembler.assemble(
                    asset: asset, keyframeTimes: times, settings: settings
                ) { p in
                    Task { @MainActor in self.report(.assembling(progress: p), run: id) }
                }
                guard self.runID == id else { return }
                self.result = PipelineResult(
                    keyframeTimes: times,
                    outputURL: outputURL,
                    sourceDuration: duration,
                    discardedForHands: discarded,
                    discardedAsDuplicates: duplicates)
                self.stage = .done
            } catch is CancellationError {
            } catch {
                if self.runID == id { self.stage = .failed(error.localizedDescription) }
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
