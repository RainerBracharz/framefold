//
//  ArtNetTests.swift
//  FrameFoldTests
//
//  Art-Net: Das Paket muss Byte für Byte der Spezifikation entsprechen
//  (sonst ignoriert der Knoten es), und die Stimmung je Bild muss stimmen.
//

import XCTest
@testable import FrameFold

final class ArtNetTests: XCTestCase {
    func testDMXPacketLayout() {
        let packet = [UInt8](ArtNet.dmxPacket(universe: 0x0123, sequence: 7, values: [10, 20, 30]))
        XCTAssertEqual(Array(packet[0..<8]), Array("Art-Net\0".utf8))
        XCTAssertEqual(packet[8], 0x00); XCTAssertEqual(packet[9], 0x50)    // OpCode 0x5000 LE
        XCTAssertEqual(packet[10], 0); XCTAssertEqual(packet[11], 14)       // ProtVer 14
        XCTAssertEqual(packet[12], 7)                                        // Sequence
        XCTAssertEqual(packet[14], 0x23); XCTAssertEqual(packet[15], 0x01)  // SubUni, Net
        XCTAssertEqual(packet[16], 0); XCTAssertEqual(packet[17], 4)        // Länge gerade (3 → 4)
        XCTAssertEqual(Array(packet[18...]), [10, 20, 30, 0])
        XCTAssertEqual(ArtNet.dmxPacket(universe: 0, sequence: 1, values: []).count, 20, "mindestens 2 Kanäle")
        XCTAssertEqual(ArtNet.dmxPacket(universe: 0, sequence: 1, values: [UInt8](repeating: 1, count: 600)).count, 18 + 512)
    }

    func testCuesStepAndFade() {
        let cues = [LightCue(frame: 0, values: [0, 100]), LightCue(frame: 10, values: [200, 100])]
        XCTAssertEqual(ArtNet.values(cues, at: 5, channels: 2, fade: false), [0, 100])
        XCTAssertEqual(ArtNet.values(cues, at: 5, channels: 2, fade: true), [100, 100])
        XCTAssertEqual(ArtNet.values(cues, at: 12, channels: 3, fade: true), [200, 100, 0], "nach der letzten bleibt sie")
        XCTAssertEqual(ArtNet.values([], at: 3, channels: 2, fade: true), [0, 0])
        XCTAssertEqual(ArtNet.values([LightCue(frame: 5, values: [300, -4])], at: 0, channels: 2, fade: false), [255, 0],
                       "vor der ersten Stimmung gilt die erste; Werte begrenzt")
    }
}
