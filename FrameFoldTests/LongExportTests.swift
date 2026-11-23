//
//  LongExportTests.swift
//  FrameFoldTests
//
//  Export langer Werke mit Fotos in Kameragröße. Anlass: Bewertung im
//  US-Store vom 15.11.2026 („83 frames, every time it gets to the end of the
//  export step, it crashes and no video files created“).
//
//  Der Test baut Werke mit 83, 150 und 300 Bildern aus Fotos, wie die Kamera
//  sie ablegt (12 MP quer gespeichert mit Dreh-Vermerk „hochkant“, dazu 48 MP),
//  und schickt sie durch dieselbe Kette wie „Exportieren“ in der Werkansicht:
//  Montage → Schlusskarte (TitleSequence.wrap) → Tonspur (addingSoundtrack).
//  Gemessen wird der höchste Speicherbedarf des Prozesses (phys_footprint,
//  dieselbe Zahl, nach der iOS Apps beendet). Ein iPhone mit 4 GB beendet
//  eine App im Vordergrund um 2 GB, eines mit 3 GB um 1,4 GB.
//
//  Die Werte je Lauf stehen im Testprotokoll („LANGER EXPORT …“).
//

import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import FrameFold

@MainActor
final class LongExportTests: XCTestCase {

    /// Grenze für den Spitzenbedarf während eines Exports. Darunter läuft der
    /// Export auch auf einem iPhone mit 3 GB Arbeitsspeicher.
    static let footprintLimitMB = 900.0

    /// Die langen Läufe (alle Auflösungen, 48 MP, 150 und 300 Bilder, zusammen
    /// einige Minuten) nur auf Wunsch: Datei /tmp/ff-long-export anlegen oder
    /// FF_LONG_EXPORT=1. Aussagekräftig am Mac (Hardware-Encoder wie am
    /// iPhone): xcodebuild test … -destination 'platform=macOS,variant=Mac Catalyst'
    /// -only-testing:FrameFoldTests/LongExportTests. In der CI läuft nur der
    /// Fall aus der Bewertung.
    static var fullRun: Bool {
        ProcessInfo.processInfo.environment["FF_LONG_EXPORT"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/ff-long-export")
    }

    /// Im Simulator kodiert eine Software das Video und hält bei 4K und
    /// Original viele Bilder vor (am Mac mit Hardware-Encoder: 4K 535 MB,
    /// im Simulator 1,7 GB). Dort wird der Speicher nur bei 1080p bewertet.
    func assertFootprint(_ run: Run, _ resolution: ExportResolution, _ label: String) {
        #if targetEnvironment(simulator)
        guard resolution == .p1080 else { return }
        #endif
        XCTAssertLessThan(run.peakMB, Self.footprintLimitMB, "\(label): Speicherbedarf")
    }

    // MARK: Speicher messen

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Misst alle 20 ms den Speicherbedarf, bis `stop()` gerufen wird.
    final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0.0
        private var running = true
        private var thread: Thread?

        init() {
            let t = Thread { [unowned self] in
                while true {
                    let v = LongExportTests.footprintMB()
                    lock.lock(); peak = max(peak, v); let go = running; lock.unlock()
                    if !go { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            thread = t
            t.start()
        }

        func stop() -> Double {
            lock.lock(); running = false; let p = peak; lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            return p
        }
    }

    // MARK: Fotos wie aus der Kamera

    /// Ein Foto mit Struktur (Verlauf, Raster, verschobenes Objekt), damit
    /// Ausrichtung, Flimmerausgleich und Encoder echte Arbeit haben.
    /// `orientation` 6 = Pixel quer gespeichert, gemeint hochkant (iPhone im Hochformat).
    nonisolated static func writePhoto(to url: URL, width: Int, height: Int, step: Int, orientation: Int) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "LongExport", code: 1)
        }
        let grad = CGGradient(colorsSpace: cs, colors: [UIColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1).cgColor,
                                                          UIColor(red: 0.35, green: 0.32, blue: 0.30, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setStrokeColor(UIColor(white: 0.2, alpha: 0.5).cgColor)
        ctx.setLineWidth(CGFloat(max(2, width / 800)))
        let cell = max(40, width / 24)
        for x in stride(from: 0, to: width, by: cell) { ctx.stroke(CGRect(x: x, y: 0, width: 1, height: height)) }
        for y in stride(from: 0, to: height, by: cell) { ctx.stroke(CGRect(x: 0, y: y, width: width, height: 1)) }
        // Die „Figur“ wandert je Bild ein Stück
        let s = CGFloat(width) / 8
        let x = CGFloat(width) * 0.15 + CGFloat(step % 40) * CGFloat(width) * 0.016
        ctx.setFillColor(UIColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1).cgColor)
        ctx.fill(CGRect(x: x, y: CGFloat(height) * 0.4, width: s, height: s * 1.4))
        ctx.setFillColor(UIColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: x + s * 0.2, y: CGFloat(height) * 0.4 + s * 1.45, width: s * 0.6, height: s * 0.6))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "LongExport", code: 2)
        }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation,
                                                 kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "LongExport", code: 3) }
    }

    /// `count` Bilder; nur acht verschiedene Motive werden gerechnet, der Rest sind Kopien
    /// (die Kette dekodiert trotzdem jede Datei einzeln).
    func makeWork(count: Int, width: Int, height: Int, orientation: Int) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("longexport-\(width)x\(height)-o\(orientation)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var originals: [URL] = []
        for i in 0..<8 {
            let url = dir.appendingPathComponent("src-\(i).jpg")
            try autoreleasepool { try Self.writePhoto(to: url, width: width, height: height, step: i * 5, orientation: orientation) }
            originals.append(url)
        }
        var urls: [URL] = []
        for i in 0..<count {
            let url = dir.appendingPathComponent(String(format: "frame-%04d.jpg", i))
            try FileManager.default.copyItem(at: originals[i % 8], to: url)
            urls.append(url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return urls
    }

    // MARK: Die Kette wie „Exportieren“ in der Werkansicht

    struct Run { let peakMB: Double; let seconds: Double; let duration: Double; let size: CGSize; let bytes: Int }

    func exportLikeWorkView(_ urls: [URL], settings: PipelineSettings, brandCard: Bool = true) async throws -> Run {
        let start = Date()
        let before = Self.footprintMB()
        let sampler = PeakSampler()
        var url: URL
        do {
            url = try await StopMotionAssembler().assemble(imageURLs: urls, settings: settings) { _ in }
            let wrapped = try await TitleSequence.wrap(film: url, title: nil, subtitle: "", credits: nil,
                                                       brandCard: brandCard, settings: settings)
            url = try await AudioMixer.underlay([], under: wrapped.url)
        } catch {
            _ = sampler.stop()
            throw error
        }
        let peak = sampler.stop()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let natural = try await track.load(.naturalSize)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let run = Run(peakMB: peak - before, seconds: Date().timeIntervalSince(start), duration: duration,
                      size: CGSize(width: abs(natural.width), height: abs(natural.height)), bytes: bytes)
        return run
    }

    func report(_ label: String, _ run: Run, frames: Int) {
        print(String(format: "LANGER EXPORT %@: %d Bilder, Spitze +%.0f MB, %.1f s Rechenzeit, Film %.2f s, %.0f×%.0f, %.1f MB",
                     label, frames, run.peakMB, run.seconds, run.duration, run.size.width, run.size.height,
                     Double(run.bytes) / 1_048_576))
    }

    // MARK: Tests

    /// Der Fall aus der Bewertung: 83 Bilder, Standardeinstellungen, 12-MP-Fotos hochkant.
    func test83FramesDefaultSettings() async throws {
        let urls = try makeWork(count: 83, width: 4032, height: 3024, orientation: 6)
        let settings = PipelineSettings()
        let run = try await exportLikeWorkView(urls, settings: settings)
        report("83 / Standard / 12 MP hochkant", run, frames: 83)
        let expected = Double(83) / Double(settings.outputFPS) + TitleSequence.brandSeconds
        XCTAssertEqual(run.duration, expected, accuracy: 0.25, "Filmlänge")
        XCTAssertLessThan(run.size.width, run.size.height, "Hochkant-Fotos ergeben einen Hochkant-Film")
        XCTAssertGreaterThan(run.bytes, 10_000, "Film geschrieben")
        XCTAssertLessThan(run.peakMB, Self.footprintLimitMB, "Speicherbedarf")
    }

    /// Jede Auflösungsstufe mit 83 Bildern, Ausrichtung und Flimmerausgleich an.
    func test83FramesEveryResolution() async throws {
        try XCTSkipUnless(Self.fullRun, "lange Läufe nur am Mac oder mit FF_LONG_EXPORT=1")
        let urls = try makeWork(count: 83, width: 4032, height: 3024, orientation: 6)
        for resolution in ExportResolution.allCases {
            var settings = PipelineSettings()
            settings.exportResolution = resolution
            let run = try await exportLikeWorkView(urls, settings: settings)
            report("83 / \(resolution.rawValue) / 12 MP hochkant", run, frames: 83)
            XCTAssertGreaterThan(run.bytes, 10_000, "\(resolution.rawValue): Film geschrieben")
            assertFootprint(run, resolution, resolution.rawValue)
        }
    }

    /// 48-MP-Fotos (iPhone Pro, „ProRAW/48 MP“ aus), 83 Bilder, 1080p und Original.
    func test83FramesFrom48MegapixelPhotos() async throws {
        try XCTSkipUnless(Self.fullRun, "lange Läufe nur am Mac oder mit FF_LONG_EXPORT=1")
        let urls = try makeWork(count: 83, width: 8064, height: 6048, orientation: 6)
        for resolution in [ExportResolution.p1080, .original] {
            var settings = PipelineSettings()
            settings.exportResolution = resolution
            let run = try await exportLikeWorkView(urls, settings: settings)
            report("83 / \(resolution.rawValue) / 48 MP hochkant", run, frames: 83)
            XCTAssertGreaterThan(run.bytes, 10_000, "\(resolution.rawValue): Film geschrieben")
            XCTAssertLessThanOrEqual(max(run.size.width, run.size.height), StopMotionAssembler.originalEdgeLimit, "Kante begrenzt")
            assertFootprint(run, resolution, resolution.rawValue)
        }
    }

    /// Mit Überblendung, Echo, Standbild am Ende und Schleife hin und zurück.
    func test83FramesWithEffectsAndHold() async throws {
        try XCTSkipUnless(Self.fullRun, "lange Läufe nur am Mac oder mit FF_LONG_EXPORT=1")
        let urls = try makeWork(count: 83, width: 4032, height: 3024, orientation: 6)
        var settings = PipelineSettings()
        settings.transitionFrames = 2
        settings.interferenzEcho = true
        settings.holdLastFrameSeconds = 2
        settings.loopMode = .boomerang
        let run = try await exportLikeWorkView(urls, settings: settings)
        report("83 / Effekte+Halten+Schleife", run, frames: 83)
        XCTAssertGreaterThan(run.bytes, 10_000, "Film geschrieben")
        XCTAssertLessThan(run.peakMB, Self.footprintLimitMB, "Speicherbedarf")
    }

    /// Wächst der Speicher mit der Bildzahl? 83, 150 und 300 Bilder dürfen
    /// sich in der Spitze kaum unterscheiden.
    func testFootprintDoesNotGrowWithFrameCount() async throws {
        try XCTSkipUnless(Self.fullRun, "lange Läufe nur am Mac oder mit FF_LONG_EXPORT=1")
        var peaks: [Int: Double] = [:]
        for count in [83, 150, 300] {
            let urls = try makeWork(count: count, width: 4032, height: 3024, orientation: 6)
            let run = try await exportLikeWorkView(urls, settings: PipelineSettings())
            report("\(count) / Standard / 12 MP hochkant", run, frames: count)
            XCTAssertGreaterThan(run.bytes, 10_000, "\(count): Film geschrieben")
            peaks[count] = run.peakMB
        }
        let p83 = try XCTUnwrap(peaks[83]), p300 = try XCTUnwrap(peaks[300])
        XCTAssertLessThan(p300, p83 * 1.5 + 100, "Speicher wächst mit der Bildzahl (83: \(Int(p83)) MB, 300: \(Int(p300)) MB)")
    }
}

/// Nur zur Ursachensuche: welche Stufe kostet Speicher und Zeit? (FF_DIAG=1)
@MainActor
final class LongExportDiagnosis: XCTestCase {
    /// Echter App-Wechsel am Gerät: langer Export über ExportSafety.perform
    /// (wie in der App); währenddessen von Hand die App wechseln.
    func testRealBackgroundSwitch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FF_DIAG"] == "1" || FileManager.default.fileExists(atPath: "/tmp/ff-diag"))
        let helper = LongExportTests()
        let urls = try helper.makeWork(count: 1200, width: 4032, height: 3024, orientation: 6)
        var s = PipelineSettings(); s.exportResolution = .uhd
        print("DIAGNOSE Wechsel: Export startet jetzt")
        let t = Date()
        var attempts = 0
        var marks: [String] = []
        let outcome = try await ExportSafety.perform(project: UUID(), settings: s) { s in
            attempts += 1
            return try await StopMotionAssembler().assemble(imageURLs: urls, settings: s) { p in
                let step = Int(p * 20)
                if marks.count < step { marks.append(String(format: "%d%%@%.0fs", step * 5, Date().timeIntervalSince(t))) }
            }
        }
        let tracks = try await AVURLAsset(url: outcome.url).loadTracks(withMediaType: .video)
        print(String(format: "DIAGNOSE Wechsel: fertig nach %.0f s, Versuche %d, sicher %@, Bildspur %@ | %@",
                     Date().timeIntervalSince(t), attempts, outcome.usedSafeSettings ? "ja" : "nein",
                     tracks.isEmpty ? "fehlt" : "da", marks.joined(separator: " ")))
        XCTAssertFalse(tracks.isEmpty)
    }

    /// Mehrere Exporte hintereinander: bleibt nach jedem etwas liegen?
    func testRepeatedExportsDoNotAccumulate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FF_DIAG"] == "1" || FileManager.default.fileExists(atPath: "/tmp/ff-diag"))
        let helper = LongExportTests()
        let urls = try helper.makeWork(count: 40, width: 4032, height: 3024, orientation: 6)
        let dir = FileManager.default.temporaryDirectory
        let background = dir.appendingPathComponent("diag-bg3.jpg")
        try LongExportTests.writePhoto(to: background, width: 1920, height: 1080, step: 0, orientation: 1)
        let overlays = [FrameOverlay(kind: .text, firstFrame: 0, lastFrame: 39, text: "Eins")]
        let moves = [CameraMove(firstFrame: 5, lastFrame: 35, from: Framing(x: 0.3, y: 0.5, zoom: 1),
                                to: Framing(x: 0.7, y: 0.4, zoom: 2), smooth: true)]
        var line: [String] = [String(format: "start %.0f", LongExportTests.footprintMB())]
        for round in 1...8 {
            var s = PipelineSettings()
            s.exportResolution = round % 2 == 0 ? .uhd : .p1080
            s.videoCodec = round % 3 == 0 ? .h264 : .hevc
            s.look = FilmLook.allCases[round % FilmLook.allCases.count]
            s.transitionFrames = 1
            let comp = GreenScreenCompositor(key: .green, background: background, fps: s.outputFPS)
            let film = try await StopMotionAssembler().assemble(imageURLs: urls, settings: s, greenScreen: comp,
                                                                overlays: overlays, cameraMoves: moves, overlayFolder: dir) { _ in }
            let wrapped = try await TitleSequence.wrap(film: film, title: "T", subtitle: "", credits: nil, brandCard: true, settings: s)
            let gif = try await GIFMaker.make(from: wrapped.url)
            for u in [film, wrapped.url, gif] { try? FileManager.default.removeItem(at: u) }
            try await Task.sleep(nanoseconds: 500_000_000)
            line.append(String(format: "%d:%.0f/frei %@", round, LongExportTests.footprintMB(),
                               ExportSafety.availableMB().map { String(Int($0)) } ?? "?"))
        }
        print("DIAGNOSE Folge (MB nach jedem Export): " + line.joined(separator: " | "))
    }

    /// Alles zugleich in 4K, mit Speicherverlauf während des Exports.
    func testEverythingProgress() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FF_DIAG"] == "1" || FileManager.default.fileExists(atPath: "/tmp/ff-diag"))
        let helper = LongExportTests()
        let urls = try helper.makeWork(count: 60, width: 4032, height: 3024, orientation: 6)
        let dir = FileManager.default.temporaryDirectory
        let background = dir.appendingPathComponent("diag-bg2.jpg")
        try LongExportTests.writePhoto(to: background, width: 1920, height: 1080, step: 0, orientation: 1)
        let overlays = [FrameOverlay(kind: .text, firstFrame: 0, lastFrame: 40, text: "Kapitel eins"),
                        FrameOverlay(kind: .bubble, firstFrame: 15, lastFrame: 45, x: 0.5, y: 0.25, text: "Hallo!", size: 0.1, color: .white)]
        let moves = [CameraMove(firstFrame: 10, lastFrame: 50, from: Framing(x: 0.3, y: 0.5, zoom: 1),
                                to: Framing(x: 0.7, y: 0.4, zoom: 3), smooth: true)]
        let combos: [(String, (inout PipelineSettings) -> Void)] = [
            ("alles", { $0.transitionFrames = 2; $0.interferenzEcho = true; $0.paperRelief = true; $0.loopMode = .boomerang; $0.holdLastFrameSeconds = 1; $0.look = FilmLook.allCases.last! }),
            ("ohne Effekte", { $0.loopMode = .boomerang; $0.holdLastFrameSeconds = 1 }),
            ("nur Effekte", { $0.transitionFrames = 2; $0.interferenzEcho = true; $0.paperRelief = true }),
        ]
        for (name, apply) in combos {
            var s = PipelineSettings(); apply(&s); s.exportResolution = .uhd
            let comp = GreenScreenCompositor(key: .green, background: background, fps: s.outputFPS)
            let before = LongExportTests.footprintMB(); let sampler = LongExportTests.PeakSampler(); let t = Date()
            var marks: [String] = []
            do {
                let url = try await StopMotionAssembler().assemble(imageURLs: urls, settings: s, greenScreen: comp,
                                                                   overlays: overlays, cameraMoves: moves, overlayFolder: dir) { p in
                    let step = Int(p * 10)
                    if marks.count < step { marks.append(String(format: "%d%%:%.0f", step * 10, LongExportTests.footprintMB() - before)) }
                }
                try? FileManager.default.removeItem(at: url)
                print(String(format: "DIAGNOSE %@ 4K: Spitze +%.0f MB, %.1f s | %@", name, sampler.stop() - before, Date().timeIntervalSince(t), marks.joined(separator: " ")))
            } catch {
                print(String(format: "DIAGNOSE %@ 4K: FEHLER %@ nach %.1f s, Spitze +%.0f MB | %@", name, "\(error)", Date().timeIntervalSince(t), sampler.stop() - before, marks.joined(separator: " ")))
            }
        }
    }

    func testWhichStageCosts() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FF_DIAG"] == "1" || FileManager.default.fileExists(atPath: "/tmp/ff-diag"))
        let helper = LongExportTests()
        let urls = try helper.makeWork(count: 40, width: 4032, height: 3024, orientation: 6)
        let dir = FileManager.default.temporaryDirectory
        let background = dir.appendingPathComponent("diag-bg.jpg")
        try LongExportTests.writePhoto(to: background, width: 1920, height: 1080, step: 0, orientation: 1)
        let overlays = [
            FrameOverlay(kind: .text, firstFrame: 0, lastFrame: 39, text: "Kapitel eins"),
            FrameOverlay(kind: .bubble, firstFrame: 0, lastFrame: 39, x: 0.5, y: 0.25, text: "Hallo!", size: 0.1, color: .white),
            FrameOverlay(kind: .drawing, firstFrame: 0, lastFrame: 39,
                         strokes: [OverlayStroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.6)], width: 0.02, color: .red)]),
        ]
        let moves = [CameraMove(firstFrame: 0, lastFrame: 39, from: Framing(x: 0.3, y: 0.5, zoom: 1),
                                to: Framing(x: 0.7, y: 0.4, zoom: 3), smooth: true)]
        typealias V = (String, (inout PipelineSettings) -> Void, Bool, Bool, Bool)
        let variants: [V] = [
            ("nichts", { _ in }, false, false, false),
            ("Greenscreen", { _ in }, true, false, false),
            ("Einblendungen", { _ in }, false, true, false),
            ("Kamerafahrt", { _ in }, false, false, true),
            ("Überblendung", { $0.transitionFrames = 2 }, false, false, false),
            ("Echo", { $0.interferenzEcho = true }, false, false, false),
            ("Papierrelief", { $0.paperRelief = true }, false, false, false),
            ("Look", { $0.look = FilmLook.allCases.last! }, false, false, false),
            ("Boomerang+Halten", { $0.loopMode = .boomerang; $0.holdLastFrameSeconds = 1 }, false, false, false),
        ]
        for (name, apply, green, over, move) in variants {
            var s = PipelineSettings(); apply(&s); s.exportResolution = .uhd
            let comp = green ? GreenScreenCompositor(key: .green, background: background, fps: s.outputFPS) : nil
            let before = LongExportTests.footprintMB(); let sampler = LongExportTests.PeakSampler(); let t = Date()
            let url = try await StopMotionAssembler().assemble(imageURLs: urls, settings: s, greenScreen: comp,
                                                               overlays: over ? overlays : [], cameraMoves: move ? moves : [],
                                                               overlayFolder: dir) { _ in }
            let peak = sampler.stop()
            print(String(format: "DIAGNOSE %@: Spitze +%.0f MB, %.1f s", name, peak - before, Date().timeIntervalSince(t)))
            try? FileManager.default.removeItem(at: url)
        }
    }
}
