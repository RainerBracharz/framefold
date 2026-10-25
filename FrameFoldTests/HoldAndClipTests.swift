//
//  HoldAndClipTests.swift
//  FrameFoldTests
//
//  „Halten“ setzt Kopien direkt hinter das Bild; Kürzen und Blenden einer
//  Tonspur ergibt eine Datei mit der richtigen Länge und leisen Rändern.
//

import XCTest
import AVFoundation
@testable import FrameFold

@MainActor
final class HoldAndClipTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-hold-\(UUID().uuidString)")
        suiteName = "ff-hold-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testHoldInsertsCopiesRightAfterFrame() throws {
        let store = ProjectStore(root: root, defaults: UserDefaults(suiteName: suiteName)!)
        let project = store.createProject(name: "Halten")
        for marker in UInt8(1)...UInt8(3) {
            _ = store.appendFrame(jpegData: Data([0xFF, 0xD8, marker, 0xFF, 0xD9]), to: store.projects[0])
        }
        let before = store.projects[0].frameFilenames
        store.holdFrame(named: before[1], frames: 3, in: store.projects[0])
        let after = store.projects.first { $0.id == project.id }!.frameFilenames
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[1], before[1])
        XCTAssertEqual(after[4], before[2])
        let urls = store.frameURLs(for: store.projects[0])
        XCTAssertEqual(try Data(contentsOf: urls[2]), try Data(contentsOf: urls[1]))
        XCTAssertEqual(try Data(contentsOf: urls[3]), try Data(contentsOf: urls[1]))
        XCTAssertEqual(Set(after).count, 5, "Jede Kopie braucht einen eigenen Dateinamen")
    }

    func testShapedClipHasLengthAndFades() throws {
        // 2 s Rechteckton mit voller Lautstärke
        let rate = 44_100.0
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("ff-test-ton-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: source) }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.5 }
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)

        var track = AudioTrack(name: "Ton", filename: "x")
        track.trimStart = 0.5
        track.maxLength = 1.0
        track.fadeIn = 0.2
        track.fadeOut = 0.2
        XCTAssertTrue(track.isShaped)
        let url = try AudioShaper.shaped(source, track: track)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / rate, 1.0, accuracy: 0.01)
        var samples: [Float] = []
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        while file.framePosition < file.length {
            try file.read(into: chunk)
            guard chunk.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
        }
        let data = samples
        let n = samples.count
        XCTAssertEqual(n, Int(file.length))
        XCTAssertLessThan(abs(data[0]), 0.01, "Einblenden beginnt still")
        XCTAssertLessThan(abs(data[n - 1]), 0.01, "Ausblenden endet still")
        XCTAssertEqual(data[n / 2], 0.5, accuracy: 0.001, "Mitte unverändert")
        // Gleiche Einstellung → dieselbe Datei aus dem Zwischenspeicher
        XCTAssertEqual(try AudioShaper.shaped(source, track: track), url)
        XCTAssertFalse(AudioTrack(name: "a", filename: "b").isShaped)
    }

    func testOldTrackWithoutClipFieldsStillDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Alt","filename":"a.m4a","startFrame":3,"volume":1,"muted":false}"#
        let track = try JSONDecoder().decode(AudioTrack.self, from: Data(json.utf8))
        XCTAssertEqual(track.startFrame, 3)
        XCTAssertFalse(track.isShaped)
    }
}
