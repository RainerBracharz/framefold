//
//  MotionControlTests.swift
//  FrameFoldTests
//
//  Motion Control: Befehle und Antworten des Textprotokolls, Bahn zwischen
//  den gemerkten Positionen.
//

import XCTest
@testable import FrameFold

final class MotionControlTests: XCTestCase {
    func testProtocolLines() {
        XCTAssertEqual(MotionProtocol.move(axis: 2, to: -350), "mm 2 -350\n")
        XCTAssertEqual(MotionProtocol.parse("hi 3\r\n"), .hello(axes: 3))
        XCTAssertEqual(MotionProtocol.parse("hi 99"), .hello(axes: 8), "höchstens 8 Achsen")
        XCTAssertEqual(MotionProtocol.parse("ok 1"), .arrived(axis: 1))
        XCTAssertEqual(MotionProtocol.parse("pr 10 -20"), .positions([10, -20]))
        XCTAssertEqual(MotionProtocol.parse("er Endschalter"), .error("Endschalter"))
        XCTAssertNil(MotionProtocol.parse("quatsch"))
        XCTAssertNil(MotionProtocol.parse(""))
    }

    func testPathBetweenKeys() {
        let keys = [MotionKey(frame: 0, positions: [0, 1000]), MotionKey(frame: 10, positions: [1000, 1000])]
        XCTAssertEqual(MotionProtocol.positions(keys, at: 5, axes: 2, smooth: false), [500, 1000])
        XCTAssertEqual(MotionProtocol.positions(keys, at: 1, axes: 2, smooth: true)[0], 28, "weich: langsamer Anfang")
        XCTAssertEqual(MotionProtocol.positions(keys, at: 30, axes: 2, smooth: false), [1000, 1000])
        XCTAssertEqual(MotionProtocol.positions([], at: 3, axes: 2, smooth: false), [0, 0])
    }
}
