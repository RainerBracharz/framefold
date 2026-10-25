//
//  SoundLibraryTests.swift
//  FrameFoldTests
//
//  Die im Code erzeugten Geräusche: jedes muss hörbar, normalisiert und
//  bei jedem Erzeugen gleich sein – und als Datei lesbar.
//

import XCTest
import AVFoundation
@testable import FrameFold

final class SoundLibraryTests: XCTestCase {

    func testEveryEffectIsAudibleAndNormalized() {
        for effect in SoundEffect.allCases {
            let samples = SoundLibrary.render(effect)
            XCTAssertGreaterThan(samples.count, Int(SoundLibrary.rate * 0.02), "\(effect) zu kurz")
            XCTAssertLessThan(samples.count, Int(SoundLibrary.rate * 2), "\(effect) zu lang")
            let peak = samples.map { abs($0) }.max() ?? 0
            XCTAssertEqual(peak, 0.89, accuracy: 0.001, "\(effect) nicht normalisiert")
            XCTAssertFalse(samples.contains { !$0.isFinite }, "\(effect) enthält NaN")
        }
    }

    func testRenderIsDeterministic() {
        for effect in [SoundEffect.whoosh, .splash, .drumroll] {
            XCTAssertEqual(SoundLibrary.render(effect), SoundLibrary.render(effect))
        }
    }

    func testFileIsReadable() throws {
        let url = try SoundLibrary.file(for: .tada)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, AVAudioFramePosition(SoundLibrary.render(.tada).count))
        XCTAssertEqual(file.processingFormat.sampleRate, SoundLibrary.rate)
    }
}
