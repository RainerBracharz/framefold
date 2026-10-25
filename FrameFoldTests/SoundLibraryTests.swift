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

    func testMusicHasRequestedLengthAndLevel() {
        for style in MusicStyle.allCases {
            let samples = MusicLibrary.render(style, seconds: 6)
            XCTAssertEqual(samples.count, Int(MusicLibrary.rate * 6), "\(style)")
            XCTAssertEqual(samples.map { abs($0) }.max() ?? 0, 0.8, accuracy: 0.001, "\(style)")
            XCTAssertFalse(samples.contains { !$0.isFinite }, "\(style)")
            XCTAssertLessThan(abs(samples.last ?? 1), 0.01, "\(style) endet ausgeblendet")
        }
    }

    func testMusicFileIsReadable() throws {
        let url = try MusicLibrary.file(for: .happy, seconds: 5)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / MusicLibrary.rate, 5, accuracy: 0.01)
    }

    func testVoiceEffectsKeepLengthAndSound() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for effect in VoiceEffect.allCases {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for i in 0..<44_100 { buffer.floatChannelData![0][i] = Float(sin(2 * Double.pi * 220 * Double(i) / 44_100) * 0.5) }
            let out = try AudioShaper.apply(effect, to: buffer)
            XCTAssertEqual(out.frameLength, 44_100, "\(effect)")
            let peak = (0..<Int(out.frameLength)).map { abs(out.floatChannelData![0][$0]) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.05, "\(effect) ist stumm")
        }
    }
}
