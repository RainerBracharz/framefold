//
//  DialogueAudioTests.swift
//  FrameFoldTests
//
//  Stufe 2 des Studios: Mundformen, Dialog-Lesen, Tonspuren, Mischung und
//  Wellenform.
//

import XCTest
import AVFoundation
import UIKit
@testable import FrameFold

final class DialogueAudioTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-dialogue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Sinus mit `seconds` Länge und Amplitude `level` als WAV.
    private func tone(_ name: String, seconds: Double, level: Float = 0.5) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let count = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(count) { data[i] = level * Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) }
        try file.write(from: buffer)
        return url
    }

    // MARK: Mundformen

    func testPhonemeGuessCoversBasicSounds() {
        XCTAssertEqual(Phoneme.guess(for: "Mama"), [.mbp, .ai, .mbp, .ai])
        XCTAssertEqual(Phoneme.guess(for: "Fee"), [.fv, .e])
        XCTAssertEqual(Phoneme.guess(for: "Hallo").first, .etc)
        XCTAssertEqual(Phoneme.guess(for: "Haus"), [.etc, .ai, .u, .etc], "„au“ öffnet und rundet")
        XCTAssertEqual(Phoneme.guess(for: "…"), [.rest])
        XCTAssertEqual(Phoneme.guess(for: "Öl"), [.o, .l], "Umlaute werden zum Grundvokal")
    }

    func testSpreadFillsAllFrames() {
        XCTAssertEqual(Phoneme.spread([.mbp, .ai], over: 4), [.mbp, .mbp, .ai, .ai])
        XCTAssertEqual(Phoneme.spread([.mbp, .ai, .o], over: 2), [.mbp, .ai])
        XCTAssertEqual(Phoneme.spread([.o], over: 0), [])
    }

    // MARK: Dialog-Lesen

    func testWordsBecomeFrameEntriesWithRests() {
        // 12 fps: „Mama“ 0,0–0,5 s (Bilder 1–6), Pause, „Fee“ ab 1,0 s (Bild 13)
        let words = [TimedWord(text: "Mama", start: 0, duration: 0.5),
                     TimedWord(text: "Fee", start: 1.0, duration: 0.25)]
        let entries = DialogueReading.entries(for: words, character: "Anna", fps: 12)
        XCTAssertEqual(entries.first?.frame, 1)
        XCTAssertEqual(entries.first?.word, "Mama")
        XCTAssertEqual(entries.first?.phoneme, .mbp)
        XCTAssertTrue(entries.contains { $0.frame == 7 && $0.phoneme == .rest }, "Mund schließt in der Pause")
        let fee = entries.first { $0.word == "Fee" }
        XCTAssertEqual(fee?.frame, 13)
        XCTAssertEqual(entries.last?.phoneme, .rest)
        XCTAssertEqual(Set(entries.map(\.frame)).count, entries.count, "je Bild höchstens ein Eintrag")
    }

    func testOffsetShiftsEntries() {
        let words = [TimedWord(text: "O", start: 0, duration: 0.1)]
        let entries = DialogueReading.entries(for: words, character: "A", fps: 10, offsetFrames: 24)
        XCTAssertEqual(entries.first?.frame, 25)
    }

    func testCurrentEntryHoldsUntilNextChange() {
        let entries = [DialogueEntry(frame: 3, character: "A", phoneme: .o, word: "Oh"),
                       DialogueEntry(frame: 7, character: "A", phoneme: .rest, word: nil),
                       DialogueEntry(frame: 5, character: "B", phoneme: .e, word: nil)]
        XCTAssertNil(DialogueReading.current(in: entries, frame: 2, character: "A"))
        XCTAssertEqual(DialogueReading.current(in: entries, frame: 6, character: "A")?.phoneme, .o)
        XCTAssertEqual(DialogueReading.current(in: entries, frame: 7, character: "A")?.phoneme, .rest)
        XCTAssertEqual(DialogueReading.current(in: entries, frame: 9, character: "B")?.phoneme, .e)
    }

    // MARK: Spuren im Werk

    @MainActor
    func testTracksAndDialogueInStore() throws {
        let suite = "ff-dialogue-\(UUID().uuidString)"
        let store = ProjectStore(root: dir.appendingPathComponent("store"), defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var project = store.createProject(name: "A")
        let music = try tone("musik.wav", seconds: 1)
        XCTAssertTrue(store.setAudio(from: music, for: project))
        project = store.projects[0]
        XCTAssertEqual(project.allAudioTracks.count, 1, "Musik der Werkansicht zählt als Spur")

        let voice = try XCTUnwrap(store.addAudioTrack(from: try tone("stimme.wav", seconds: 1), startFrame: 12, to: project))
        project = store.projects[0]
        XCTAssertEqual(project.allAudioTracks.map(\.startFrame), [0, 12])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: voice, in: project).path))

        // Die Musikspur verschieben macht sie zur gewöhnlichen Spur
        var legacy = project.allAudioTracks[0]
        legacy.startFrame = 5
        store.updateAudioTrack(legacy, in: project)
        project = store.projects[0]
        XCTAssertNil(project.audioFilename)
        XCTAssertEqual(project.allAudioTracks.map(\.startFrame).sorted(), [5, 12])
        XCTAssertEqual(project.audioSources(fps: 10, store: store).map(\.start).sorted(), [0.5, 1.2])

        store.removeAudioTrack(voice, from: project)
        XCTAssertEqual(store.projects[0].allAudioTracks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: voice, in: project).path))

        store.setDialogue(frame: 4, character: "Anna", phoneme: .o, word: " Oh ", in: store.projects[0])
        store.setDialogue(frame: 2, character: "Ben", phoneme: .e, word: nil, in: store.projects[0])
        XCTAssertEqual(store.projects[0].characters, ["Ben", "Anna"])
        XCTAssertEqual(store.projects[0].dialogue?.first { $0.character == "Anna" }?.word, "Oh")
        store.replaceDialogue(of: "Anna", with: [], in: store.projects[0])
        XCTAssertEqual(store.projects[0].characters, ["Ben"])
        store.setDialogue(frame: 2, character: "Ben", phoneme: nil, word: nil, in: store.projects[0])
        XCTAssertNil(store.projects[0].dialogue)
    }

    @MainActor
    func testLegacyTrackPromotionIsIdempotent() throws {
        let suite = "ff-legacy-\(UUID().uuidString)"
        let store = ProjectStore(root: dir.appendingPathComponent("store2"), defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let project = store.createProject(name: "A")
        XCTAssertTrue(store.setAudio(from: try tone("m.wav", seconds: 1), for: project))
        // Zwei schnelle Änderungen mit derselben (Musik-)Kennung, wie beim Ziehen
        store.updateAudioTrack(id: Project.legacyTrackID, in: project.id) { $0.volume = 0.5 }
        store.updateAudioTrack(id: Project.legacyTrackID, in: project.id) { $0.volume = 0.3 }
        let tracks = store.projects[0].allAudioTracks
        XCTAssertEqual(tracks.count, 1, "keine doppelte Spur")
        XCTAssertEqual(tracks.first?.volume ?? 0, 0.3, accuracy: 0.001)
        let file = store.url(for: tracks[0], in: store.projects[0])
        store.removeAudioTrack(tracks[0], from: store.projects[0])
        XCTAssertTrue(store.projects[0].allAudioTracks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testStoppedSessionDropsPendingAveragedCapture() async throws {
        let controller = LiveCaptureController()
        var delivered = 0
        controller.startWithoutCamera { _ in delivered += 1 }
        controller.averageFrames = 4
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }.cgImage!
        controller.prepareCapture(fallback: frame)
        XCTAssertTrue(controller.isPreparingCapture)
        controller.stop()
        XCTAssertFalse(controller.isPreparingCapture)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(delivered, 0, "Bild der beendeten Sitzung verfällt")
    }

    // MARK: Mischung und Wellenform

    func testMixPlacesTracksAtTheirStart() throws {
        let a = try tone("a.wav", seconds: 0.5, level: 0.5)
        let b = try tone("b.wav", seconds: 0.5, level: 0.5)
        let mix = try AudioMixer.mix([AudioSource(url: a, start: 0, volume: 1),
                                      AudioSource(url: b, start: 1.5, volume: 0.5)], duration: 2.5)
        let file = try AVAudioFile(forReading: mix)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2.5, accuracy: 0.1)

        let peaks = Waveform.peaks(of: mix, perSecond: 10)
        XCTAssertGreaterThan(peaks[2], 0.3, "erste Spur am Anfang")
        XCTAssertLessThan(peaks[10], 0.05, "Stille dazwischen")
        XCTAssertGreaterThan(peaks[17], 0.1, "zweite Spur ab 1,5 s")
        XCTAssertLessThan(peaks[17], peaks[2], "zweite Spur leiser")
    }

    func testCombinedWaveformAppliesOffsetAndVolume() throws {
        let a = try tone("c.wav", seconds: 1, level: 0.8)
        let combined = Waveform.combined([AudioSource(url: a, start: 2, volume: 0.5)], perSecond: 10)
        XCTAssertEqual(combined.count, 30, accuracy: 1)
        XCTAssertEqual(combined[5], 0)
        XCTAssertEqual(combined[25], 0.4, accuracy: 0.05)
        XCTAssertEqual(XSheetView.level(peaks: [0, 0.2, 0.9, 0.1], frame: 0, fps: 60), 0.2, "Bild 1 bei 60 fps = 2 Werte")
    }

    func testMixWithoutSourcesFails() {
        XCTAssertThrowsError(try AudioMixer.mix([], duration: 1))
    }
}
