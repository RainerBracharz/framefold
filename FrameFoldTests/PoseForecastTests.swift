//
//  PoseForecastTests.swift
//  FrameFoldTests
//
//  Zwiebelhaut in die Zukunft: Die Schätzung muss die Verschiebung eines
//  Gegenstands treffen und darf ruhige Bilder, Lichtänderungen und
//  freigelegten Hintergrund nicht als Bewegung lesen.
//

import XCTest
@testable import FrameFold

final class PoseForecastTests: XCTestCase {

    /// Gleichbleibendes Zufallsmuster als Tisch.
    private func noise(_ w: Int, _ h: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<(w * h)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) % 120) + 40
        }
    }

    /// Tisch mit einem gemusterten Quadrat (Seite `side`) bei (x, y).
    private func scene(w: Int = 160, h: Int = 120, x: Int, y: Int, side: Int = 24,
                       brightness: Float = 0, table: [Float], patch: [Float]) -> PoseForecast.Raster {
        var gray = table.map { $0 * 0.25 + 90 }   // ruhiger, aber nicht einfarbig
        for py in 0..<side { for px in 0..<side where x + px < w && y + py < h && x + px >= 0 && y + py >= 0 {
            gray[(y + py) * w + x + px] = patch[py * side + px] * 1.3
        } }
        gray = gray.map { min(255, max(0, $0 + brightness)) }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { let v = UInt8(gray[i]); rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v }
        return PoseForecast.Raster(width: w, height: h, gray: gray, rgba: rgba)
    }

    private lazy var table = noise(160, 120, seed: 7)
    private lazy var patch = noise(24, 24, seed: 99)

    func testFindsTheStepOfAMovingObject() {
        let prev = scene(x: 40, y: 50, table: table, patch: patch)
        let last = scene(x: 52, y: 46, table: table, patch: patch)
        let m = PoseForecast.motion(previous: prev, last: last)
        XCTAssertGreaterThanOrEqual(m.cells.count, 3)
        let dx = m.cells.map(\.dx).sorted()[m.cells.count / 2]
        let dy = m.cells.map(\.dy).sorted()[m.cells.count / 2]
        XCTAssertEqual(dx, 12, accuracy: 1)
        XCTAssertEqual(dy, -4, accuracy: 1)
        // Alle Zellen liegen auf dem Quadrat im letzten Bild, nicht auf dem
        // freigelegten Tisch
        for c in m.cells {
            XCTAssertTrue((52 - 8)...(52 + 24) ~= c.x && (46 - 8)...(46 + 24) ~= c.y, "\(c)")
        }
        XCTAssertEqual(m.stepFraction, 12.6 / 160, accuracy: 0.01)
        XCTAssertTrue(m.isLargeStep)
        XCTAssertGreaterThanOrEqual(m.suggestedInbetweens, 1)
    }

    func testStillFramesHaveNoMotion() {
        let a = scene(x: 40, y: 50, table: table, patch: patch)
        XCTAssertTrue(PoseForecast.motion(previous: a, last: a).cells.isEmpty)
    }

    func testBrightnessChangeIsNotMotion() {
        let a = scene(x: 40, y: 50, table: table, patch: patch)
        let b = scene(x: 40, y: 50, brightness: 30, table: table, patch: patch)
        XCTAssertTrue(PoseForecast.motion(previous: a, last: b).cells.isEmpty)
    }

    func testSceneCutIsNotMotion() {
        // Ganz anderes Bild (Schnitt, Kamera umgestellt): kein nächster Schritt
        let a = scene(x: 40, y: 50, table: table, patch: patch)
        let other = noise(160, 120, seed: 3)
        let b = PoseForecast.Raster(width: 160, height: 120, gray: other.map { $0 * 1.5 },
                                    rgba: [UInt8](repeating: 128, count: 160 * 120 * 4))
        XCTAssertTrue(PoseForecast.motion(previous: a, last: b).cells.isEmpty)
    }

    func testSmallStepNeedsNoInbetweens() {
        let prev = scene(x: 40, y: 50, table: table, patch: patch)
        let last = scene(x: 45, y: 50, table: table, patch: patch)
        let m = PoseForecast.motion(previous: prev, last: last)
        XCTAssertFalse(m.cells.isEmpty)
        XCTAssertFalse(m.isLargeStep)
        XCTAssertEqual(m.suggestedInbetweens, 0)
    }

    func testGhostSitsOneStepAhead() throws {
        let prev = scene(x: 40, y: 50, table: table, patch: patch)
        let last = scene(x: 52, y: 50, table: table, patch: patch)
        let m = PoseForecast.motion(previous: prev, last: last)
        let ghost = try XCTUnwrap(PoseForecast.ghost(of: m, last: last))
        let raster = try XCTUnwrap(PoseForecast.Raster(ghost, width: 160))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { raster.rgba[(y * 160 + x) * 4 + 3] }
        // Mitte des Quadrats im nächsten Bild (64 + 12) ist bedeckt, die alte
        // Stelle (40 + 12) und der freie Tisch nicht
        XCTAssertGreaterThan(alpha(76, 62), 200)
        XCTAssertEqual(alpha(30, 62), 0)
        XCTAssertEqual(alpha(140, 20), 0)
        // Halber Schritt beim Abbremsen
        let slow = try XCTUnwrap(PoseForecast.ghost(of: m, last: last, pace: 0.5))
        let slowRaster = try XCTUnwrap(PoseForecast.Raster(slow, width: 160))
        XCTAssertGreaterThan(slowRaster.rgba[(62 * 160 + 70) * 4 + 3], 200)
        XCTAssertEqual(slowRaster.rgba[(62 * 160 + 86) * 4 + 3], 0)
    }

    func testForecastFromImagesEndToEnd() throws {
        func image(_ r: PoseForecast.Raster) -> CGImage {
            let provider = CGDataProvider(data: Data(r.rgba) as CFData)!
            return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: r.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let prev = image(scene(x: 40, y: 50, table: table, patch: patch))
        let last = image(scene(x: 52, y: 50, table: table, patch: patch))
        let f = try XCTUnwrap(PoseForecast.forecast(previous: prev, last: last))
        XCTAssertEqual(f.ghost.width, 360)
        XCTAssertNil(PoseForecast.forecast(previous: prev, last: prev))
    }
}
