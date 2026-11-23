//
//  ExportTortureTests.swift
//  FrameFoldTests
//
//  Belastungstest für den Export: Der Film muss nach getaner Arbeit immer
//  entstehen. Geprüft werden die Absicherung (ExportSafety) und jeder
//  Exportweg mit allem, was ein Werk enthalten kann.
//
//  Teil 1 (läuft immer, auch in der CI): beschädigte und fehlende Bilder,
//  zweiter Versuch mit sicheren Einstellungen, Speicherprüfung vor dem
//  Start, Pause im Hintergrund, Erkennen eines abgebrochenen Exports.
//
//  Teil 2 (nur mit /tmp/ff-long-export oder FF_LONG_EXPORT=1, am besten am
//  Mac mit Hardware-Encoder): alle Codecs × Auflösungen, Ton, Titel,
//  Abspann, Schlusskarte, Greenscreen, Einblendungen, Kamerafahrt, GIF,
//  Bildfolge, Ausstellung, 1 bis 1000 Bilder, Bildraten 1 bis 60,
//  gemischte Formate. Jeder Lauf misst den Speicherbedarf.
//
//  Vor jeder Einreichung: `fastlane export_check` (siehe Fastfile).
//

import XCTest
import AVFoundation
import UIKit
@testable import FrameFold

@MainActor
final class ExportTortureTests: XCTestCase {

    // MARK: Hilfen

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("torture-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ExportSafety.setBackground(false)
    }

    override func tearDown() async throws {
        ExportSafety.setBackground(false)
        try? FileManager.default.removeItem(at: dir)
    }

    /// `count` Fotos; `variants` verschiedene Motive, der Rest Kopien.
    private func photos(_ count: Int, width: Int = 1600, height: Int = 1200, orientation: Int = 1,
                        variants: Int = 6, name: String = "f") throws -> [URL] {
        var originals: [URL] = []
        for i in 0..<min(variants, count) {
            let url = dir.appendingPathComponent("\(name)-src-\(i).jpg")
            try autoreleasepool {
                try LongExportTests.writePhoto(to: url, width: width, height: height, step: i * 4, orientation: orientation)
            }
            originals.append(url)
        }
        return try (0..<count).map { i in
            let url = dir.appendingPathComponent(String(format: "\(name)-%05d.jpg", i))
            try FileManager.default.copyItem(at: originals[i % originals.count], to: url)
            return url
        }
    }

    private func tone(seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("tone-\(UUID().uuidString.prefix(4)).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.06) }
        try file.write(from: buffer)
        return url
    }

    private struct Film { let url: URL; let duration: Double; let size: CGSize; let frames: Int; let hasAudio: Bool }

    private func inspect(_ url: URL) async throws -> Film {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "keine Bildspur in \(url.lastPathComponent)")
        let size = try await track.load(.naturalSize)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        return Film(url: url, duration: duration, size: CGSize(width: abs(size.width), height: abs(size.height)),
                    frames: frames, hasAudio: !audio.isEmpty)
    }

    /// Misst den Spitzenbedarf eines Laufs (MB über dem Stand davor).
    private func measured<T>(_ work: () async throws -> T) async throws -> (T, Double) {
        let before = LongExportTests.footprintMB()
        let sampler = LongExportTests.PeakSampler()
        do {
            let result = try await work()
            return (result, sampler.stop() - before)
        } catch {
            _ = sampler.stop()
            throw error
        }
    }

    /// Grenze je Auflösung (Mac/iPhone mit Hardware-Encoder). Im Simulator
    /// kodiert eine Software und hält mehr Bilder vor; dort nur 1080p.
    /// `heavy`: Greenscreen, Einblendungen, Kamerafahrt und Effekte zugleich –
    /// die Kamerafahrt lädt Bilder doppelt so groß (zum Hineinzoomen).
    private func assertMemory(_ mb: Double, _ resolution: ExportResolution, _ codec: VideoCodec, _ label: String,
                              heavy: Bool = false) {
        #if targetEnvironment(simulator)
        guard resolution == .p1080, codec == .hevc || codec == .h264 else { return }
        #endif
        let limit: Double
        switch resolution {
        case .p1080: limit = heavy ? 700 : 400
        case .uhd: limit = heavy ? 1150 : 900
        case .original: limit = heavy ? 1200 : 1100
        }
        XCTAssertLessThan(mb, limit, "\(label): Speicher \(Int(mb)) MB über der Grenze \(Int(limit)) MB")
        print(String(format: "BELASTUNG %@: %.0f MB", label, mb))
    }

    // MARK: Teil 1 – Absicherung

    func testCorruptAndMissingFramesAreReplaced() async throws {
        var urls = try photos(30)
        try Data("kein Bild".utf8).write(to: urls[3])                       // Unsinn statt JPEG
        let half = try Data(contentsOf: urls[10]); try half.prefix(200).write(to: urls[10])   // abgeschnitten
        try FileManager.default.removeItem(at: urls[20])                       // fehlt ganz
        urls[25] = dir.appendingPathComponent("gibt-es-nicht.jpg")
        let outcome = try await ExportSafety.perform(project: nil, settings: PipelineSettings()) { s in
            try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
        }
        let film = try await inspect(outcome.url)
        XCTAssertEqual(film.frames, 30, "jedes Bild hat einen Platz im Film")
        XCTAssertEqual(outcome.skippedFrames, 4, "vier ersetzte Bilder gemeldet")
        XCTAssertNotNil(ExportSafety.notice(for: outcome))
    }

    func testAllFramesUnreadableFailsCleanly() async throws {
        let urls = (0..<5).map { dir.appendingPathComponent("fehlt-\($0).jpg") }
        do {
            _ = try await ExportSafety.perform(project: nil, settings: PipelineSettings()) { s in
                try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
            }
            XCTFail("ohne lesbares Bild darf kein Film entstehen")
        } catch {
            // erwartet: Fehler statt Absturz
        }
    }

    func testFailedExportIsRetriedWithSafeSettings() async throws {
        let urls = try photos(12)
        var wanted = PipelineSettings()
        wanted.exportResolution = .uhd
        wanted.videoCodec = .hevc
        var attempts: [PipelineSettings] = []
        let outcome = try await ExportSafety.perform(project: nil, settings: wanted) { s in
            attempts.append(s)
            if attempts.count == 1 { throw PipelineError.exportFailed }      // erster Versuch scheitert
            return try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
        }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[1], ExportSafety.safe(wanted))
        XCTAssertTrue(outcome.usedSafeSettings)
        let film = try await inspect(outcome.url)
        XCTAssertEqual(film.frames, 12)
        XCTAssertLessThanOrEqual(max(film.size.width, film.size.height), 1920)
    }

    func testCancellationIsNotRetried() async throws {
        var attempts = 0
        do {
            _ = try await ExportSafety.perform(project: nil, settings: PipelineSettings()) { _ in
                attempts += 1
                throw CancellationError()
            }
            XCTFail("Abbruch muss als Abbruch ankommen")
        } catch is CancellationError {
            XCTAssertEqual(attempts, 1, "kein zweiter Versuch nach Abbruch")
        }
    }

    func testLowMemoryStartsSmaller() {
        var s = PipelineSettings(); s.exportResolution = .original
        XCTAssertEqual(ExportSafety.fitted(s, availableMB: 5000).exportResolution, .original)
        XCTAssertEqual(ExportSafety.fitted(s, availableMB: 1200).exportResolution, .uhd)
        XCTAssertEqual(ExportSafety.fitted(s, availableMB: 300).exportResolution, .p1080)
        XCTAssertEqual(ExportSafety.fitted(s, availableMB: 50).exportResolution, .p1080, "kleiner als 1080p geht es nicht")
        XCTAssertEqual(ExportSafety.fitted(s, availableMB: nil).exportResolution, .original, "Mac: unbekannt = wie gewünscht")
    }

    func testExportPausesInBackgroundAndFinishes() async throws {
        let urls = try photos(40)
        let task = Task { @MainActor in
            try await ExportSafety.perform(project: nil, settings: PipelineSettings()) { s in
                try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        ExportSafety.setBackground(true)
        let pausedAt = Date()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        ExportSafety.setBackground(false)
        let outcome = try await task.value
        XCTAssertGreaterThan(Date().timeIntervalSince(pausedAt), 1.4)
        let film = try await inspect(outcome.url)
        XCTAssertEqual(film.frames, 40, "nach der Pause vollständig")
    }

    func testInterruptedExportIsDetectedAndUsesSafeSettings() async throws {
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "ff.exportRunning")   // wie nach einem Absturz
        ExportSafety.install()
        XCTAssertTrue(ExportSafety.interruptedProjects.contains(id))
        XCTAssertNil(UserDefaults.standard.string(forKey: "ff.exportRunning"))
        let urls = try photos(6)
        var wanted = PipelineSettings(); wanted.exportResolution = .original
        var used: PipelineSettings?
        let outcome = try await ExportSafety.perform(project: id, settings: wanted) { s in
            used = s
            return try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
        }
        XCTAssertEqual(used, ExportSafety.safe(wanted), "nach Absturz gleich sicher")
        XCTAssertTrue(outcome.usedSafeSettings)
        XCTAssertFalse(ExportSafety.interruptedProjects.contains(id), "nach Erfolg wieder normal")
    }

    func testMarkerIsClearedAfterEveryExport() async throws {
        let urls = try photos(3)
        _ = try await ExportSafety.perform(project: UUID(), settings: PipelineSettings()) { s in
            XCTAssertNotNil(UserDefaults.standard.string(forKey: "ff.exportRunning"), "während des Exports gesetzt")
            return try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
        }
        XCTAssertNil(UserDefaults.standard.string(forKey: "ff.exportRunning"))
        _ = try? await ExportSafety.perform(project: UUID(), settings: PipelineSettings()) { _ in throw PipelineError.exportFailed }
        XCTAssertNil(UserDefaults.standard.string(forKey: "ff.exportRunning"), "auch nach Fehler entfernt")
    }

    // MARK: Teil 2 – jeder Weg, jede Einstellung

    private func requireFullRun() throws {
        try XCTSkipUnless(LongExportTests.fullRun, "lange Läufe nur mit /tmp/ff-long-export oder FF_LONG_EXPORT=1")
    }

    /// Alle Codecs × Auflösungen, 83 Bilder 12 MP hochkant, mit Ton,
    /// Titel, Abspann und Schlusskarte – die ganze Kette der Werkansicht.
    func testEveryCodecAndResolutionWithTitlesAndSound() async throws {
        try requireFullRun()
        let urls = try photos(83, width: 4032, height: 3024, orientation: 6)
        let music = try tone(seconds: 6)
        for codec in VideoCodec.allCases {
            for resolution in ExportResolution.allCases {
                var s = PipelineSettings(); s.videoCodec = codec; s.exportResolution = resolution
                let label = "\(codec.rawValue)/\(resolution.rawValue)"
                let (url, mb) = try await measured {
                    let film = try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
                    let wrapped = try await TitleSequence.wrap(film: film, title: "Titel", subtitle: "2026", credits: "Abspann",
                                                               brandCard: true, settings: s)
                    return try await AudioMixer.underlay([AudioSource(url: music, start: wrapped.lead, volume: 1)], under: wrapped.url)
                }
                let film = try await inspect(url)
                let expected = 83.0 / Double(s.outputFPS) + TitleSequence.titleSeconds + TitleSequence.creditsSeconds
                XCTAssertEqual(film.duration, expected, accuracy: 0.6, "\(label): Länge")
                XCTAssertTrue(film.hasAudio, "\(label): Ton")
                XCTAssertLessThan(film.size.width, film.size.height, "\(label): hochkant")
                assertMemory(mb, resolution, codec, label)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Greenscreen, Einblendungen, Kamerafahrt, Effekte, Looks und Formate zusammen.
    func testEverythingAtOnce() async throws {
        try requireFullRun()
        let urls = try photos(60, width: 4032, height: 3024, orientation: 6)
        let background = dir.appendingPathComponent("bg.jpg")
        try LongExportTests.writePhoto(to: background, width: 1920, height: 1080, step: 0, orientation: 1)
        let overlays = [
            FrameOverlay(kind: .text, firstFrame: 0, lastFrame: 40, text: "Kapitel eins"),
            FrameOverlay(kind: .bubble, firstFrame: 15, lastFrame: 45, x: 0.5, y: 0.25, text: "Hallo!", size: 0.1, color: .white),
            FrameOverlay(kind: .drawing, firstFrame: 20, lastFrame: 59,
                         strokes: [OverlayStroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.6)], width: 0.02, color: .red)]),
        ]
        let moves = [CameraMove(firstFrame: 10, lastFrame: 50, from: Framing(x: 0.3, y: 0.5, zoom: 1),
                                to: Framing(x: 0.7, y: 0.4, zoom: 3), smooth: true)]
        // Jedes Format und jede Auflösung mindestens einmal (alle 12 Paare
        // dauerten am Mac 27 Minuten; der Test ist Pflicht vor jeder Einreichung).
        let pairs: [(AspectPreset, ExportResolution)] = [(.original, .p1080), (.original, .uhd), (.original, .original)]
            + AspectPreset.allCases.filter { $0 != .original }.enumerated().map { i, a in
                (a, ExportResolution.allCases[i % ExportResolution.allCases.count]) }
        for (aspect, resolution) in pairs {
            do {
                var s = PipelineSettings()
                s.aspect = aspect; s.exportResolution = resolution
                s.transitionFrames = 2; s.interferenzEcho = true; s.paperRelief = true
                s.loopMode = .boomerang; s.holdLastFrameSeconds = 1
                s.look = FilmLook.allCases.last ?? s.look
                let label = "alles/\(aspect.rawValue)/\(resolution.rawValue)"
                let compositor = try XCTUnwrap(GreenScreenCompositor(key: .green, background: background, fps: s.outputFPS))
                let (url, mb) = try await measured {
                    try await StopMotionAssembler().assemble(imageURLs: urls, settings: s, greenScreen: compositor,
                                                             overlays: overlays, cameraMoves: moves, overlayFolder: dir) { _ in }
                }
                let film = try await inspect(url)
                XCTAssertGreaterThan(film.frames, 100, "\(label): Bilder")
                assertMemory(mb, resolution, s.videoCodec, label, heavy: true)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Von 1 bis 1000 Bildern, Bildraten 1 bis 60; der Speicher bleibt gleich.
    func testFrameCountsAndRates() async throws {
        try requireFullRun()
        let urls = try photos(1000, width: 4032, height: 3024, orientation: 6, variants: 10)
        var peaks: [Int: Double] = [:]
        for (count, fps) in [(1, 12), (2, 1), (83, 60), (500, 24), (1000, 12)] as [(Int, Int32)] {
            var s = PipelineSettings(); s.outputFPS = fps
            let (url, mb) = try await measured {
                try await StopMotionAssembler().assemble(imageURLs: Array(urls.prefix(count)), settings: s) { _ in }
            }
            let film = try await inspect(url)
            XCTAssertEqual(film.frames, count, "\(count) Bilder bei \(fps) fps")
            XCTAssertEqual(film.duration, Double(count) / Double(fps), accuracy: 0.1)
            assertMemory(mb, .p1080, .hevc, "\(count) Bilder/\(fps) fps")
            peaks[count] = mb
            try? FileManager.default.removeItem(at: url)
        }
        let p83 = try XCTUnwrap(peaks[83]), p1000 = try XCTUnwrap(peaks[1000])
        XCTAssertLessThan(p1000, p83 * 1.5 + 100, "Speicher wächst mit der Bildzahl")
    }

    /// Hochkant, quer, 48 MP, klein und Dreh-Vermerke gemischt in einem Werk.
    func testMixedSourcesInOneWork() async throws {
        try requireFullRun()
        var urls: [URL] = []
        urls += try photos(20, width: 4032, height: 3024, orientation: 6, name: "hoch")
        urls += try photos(20, width: 4032, height: 3024, orientation: 1, name: "quer")
        urls += try photos(10, width: 8064, height: 6048, orientation: 8, name: "gross")
        urls += try photos(10, width: 320, height: 240, orientation: 3, name: "klein")
        for resolution in ExportResolution.allCases {
            var s = PipelineSettings(); s.exportResolution = resolution
            let (url, mb) = try await measured {
                try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { _ in }
            }
            let film = try await inspect(url)
            XCTAssertEqual(film.frames, 60)
            assertMemory(mb, resolution, .hevc, "gemischt/\(resolution.rawValue)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// GIF, Bildfolge und Ausstellung aus langen Werken.
    func testGIFSequenceAndExhibition() async throws {
        try requireFullRun()
        let urls = try photos(400, width: 4032, height: 3024, orientation: 6)
        let (film, mbFilm) = try await measured {
            try await StopMotionAssembler().assemble(imageURLs: urls, settings: PipelineSettings()) { _ in }
        }
        assertMemory(mbFilm, .p1080, .hevc, "Film für GIF")
        let (gif, mbGIF) = try await measured { try await GIFMaker.make(from: film) }
        XCTAssertGreaterThan((try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0, 10_000)
        assertMemory(mbGIF, .p1080, .hevc, "GIF")
        for format in SequenceFormat.allCases {
            let (folder, mb) = try await measured {
                try StopMotionAssembler.exportSequence(urls, name: "Lang", format: format)
            }
            let count = try FileManager.default.contentsOfDirectory(atPath: folder.path).count
            XCTAssertEqual(count, 400, "Bildfolge \(format)")
            assertMemory(mb, .p1080, .hevc, "Bildfolge \(format)")
            try? FileManager.default.removeItem(at: folder)
        }
        let works = (0..<3).map { ExhibitionBuilder.Work(title: "Werk \($0)", year: "2026", frames: Array(urls.prefix(60))) }
        let (reel, mbReel) = try await measured {
            try await ExportSafety.perform(project: nil, settings: PipelineSettings()) { s in
                try await ExhibitionBuilder.build(works: works, settings: s) { _ in }
            }.url
        }
        let reelFilm = try await inspect(reel)
        XCTAssertGreaterThan(reelFilm.frames, 180)
        assertMemory(mbReel, .p1080, .hevc, "Ausstellung")
    }
}
