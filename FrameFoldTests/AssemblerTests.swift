//
//  AssemblerTests.swift
//  FrameFoldTests
//
//  Der Video-Zusammenbau mit synthetischen Bildern: Bilder unterschiedlicher
//  Größe müssen den Rahmen füllen, und die Überblendungen zwischen
//  ausgerichteten Bildern dürfen nicht springen.
//

import XCTest
import AVFoundation
import ImageIO
import UIKit
@testable import FrameFold

final class AssemblerTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-assembler-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Hilfen

    private func save(_ image: UIImage, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(image.jpegData(compressionQuality: 0.95)).write(to: url)
        return url
    }

    private func solid(_ color: UIColor, width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Kräftig strukturiertes Motiv (Kacheln in festen Grautönen), um
    /// `shift` Pixel nach rechts verschoben – Futter für die Ausrichtung.
    private func pattern(shift: Int, width: Int = 640, height: Int = 480) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var seed: UInt64 = 7
            for gy in 0..<12 {
                for gx in 0..<16 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let g = CGFloat((seed >> 33) % 256) / 255
                    UIColor(white: g, alpha: 1).setFill()
                    ctx.fill(CGRect(x: gx * 40 + shift, y: gy * 40, width: 40, height: 40))
                }
            }
        }
    }

    /// Bild zum Zeitpunkt `seconds` aus dem fertigen Video.
    private func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// RGB des Pixels (x, y) – y von oben gezählt.
    private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// Mittlere Helligkeitsdifferenz zweier gleich großer Bilder (0…1).
    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 160, h = 120
        func gray(_ img: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        let ga = gray(a), gb = gray(b)
        // Rand auslassen: dort darf die Ausrichtung Lücken lassen
        var sum = 0.0, n = 0.0
        for y in 12..<(h - 12) { for x in 16..<(w - 16) {
            sum += abs(Double(ga[y * w + x]) - Double(gb[y * w + x])); n += 1
        } }
        return sum / n / 255
    }

    private func baseSettings() -> PipelineSettings {
        var s = PipelineSettings()
        s.loopMode = .none
        s.transitionFrames = 0
        s.alignFrames = false
        s.interferenzEcho = false
        s.paperRelief = false
        s.printLook = false
        s.holdLastFrameSeconds = 0
        s.aspect = .original
        s.outputFPS = 2
        return s
    }

    // MARK: Tests

    /// Reel-Fall: Titelkarte in anderer Größe als die Werkbilder. Das zweite
    /// Bild muss den Rahmen füllen – früher landete es klein in einer Ecke.
    func testImageOfDifferentSizeFillsFrame() async throws {
        let big = try save(solid(.red, width: 1080, height: 1920), "a.jpg")
        let small = try save(solid(.blue, width: 540, height: 960), "b.jpg")

        let url = try await StopMotionAssembler().assemble(
            imageURLs: [big, small], settings: baseSettings()) { _ in }

        let second = try await frame(url, at: 0.75)   // 2 fps: Bild 2 ab 0,5 s
        for (x, y) in [(20, 20), (second.width - 20, second.height - 20),
                       (second.width / 2, second.height / 2)] {
            let c = rgb(second, x, y)
            XCTAssertGreaterThan(c.b, 0.6, "Pixel (\(x), \(y)) sollte blau sein: \(c)")
            XCTAssertLessThan(c.r, 0.35, "Pixel (\(x), \(y)) sollte blau sein: \(c)")
        }
    }

    /// Zweites Bild ist dasselbe Motiv, verschoben. Mit Ausrichtung liegt es
    /// deckungsgleich auf dem ersten – und die Überblendung dazwischen muss
    /// das ebenfalls tun, statt zum unausgerichteten Bild zu springen.
    func testBlendFramesAreAligned() async throws {
        let a = try save(pattern(shift: 0), "a.jpg")
        let b = try save(pattern(shift: 24), "b.jpg")
        var settings = baseSettings()
        settings.alignFrames = true
        settings.transitionFrames = 2
        settings.transitionStyle = .crease

        let url = try await StopMotionAssembler().assemble(
            imageURLs: [a, b], settings: settings) { _ in }

        // Schritte bei 2 fps: Keyframe A (0 s), Blende 1 (0,5 s), Blende 2 (1 s), Keyframe B (1,5 s)
        let first = try await frame(url, at: 0.25)
        let blend = try await frame(url, at: 1.25)
        let last = try await frame(url, at: 1.75)

        // Unausgerichtet liegen die Motive weit auseinander (~0,19). Die
        // Ausrichtung auf diesem künstlichen Kachelmuster ist nicht exakt,
        // halbiert den Abstand aber sicher. Entscheidend: Die Blende ist so
        // gut ausgerichtet wie der Keyframe – sie springt nicht.
        let unaligned = meanDifference(pattern(shift: 0).cgImage!, pattern(shift: 24).cgImage!)
        let keyframe = meanDifference(first, last)
        let blended = meanDifference(first, blend)
        XCTAssertLessThan(keyframe, unaligned * 0.7, "Keyframe B sollte ausgerichtet sein")
        XCTAssertLessThan(blended, keyframe + 0.02,
                          "Die Blende sollte so gut ausgerichtet sein wie der Keyframe (\(blended) vs. \(keyframe))")
    }

    /// GIF aus dem fertigen Film: Endlosschleife, ein Bild je Filmbild, die
    /// Farben in der richtigen Reihenfolge, längste Seite höchstens 640 px.
    func testGIFFromFilm() async throws {
        let frames = try [UIColor.red, .green, .blue, .white].enumerated().map { i, c in
            try save(solid(c, width: 1080, height: 1440), "\(i).jpg")
        }
        var settings = baseSettings()
        settings.outputFPS = 4
        let film = try await StopMotionAssembler().assemble(imageURLs: frames, settings: settings) { _ in }

        let gif = try await GIFMaker.make(from: film)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 4, "ein GIF-Bild je Filmbild")
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        XCTAssertEqual(loop, 0, "GIF soll endlos laufen")

        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(first.width, first.height), 640)
        XCTAssertGreaterThan(rgb(first, first.width / 2, first.height / 2).r, 0.6, "Bild 1 rot")
        let third = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 2, nil))
        XCTAssertGreaterThan(rgb(third, third.width / 2, third.height / 2).b, 0.6, "Bild 3 blau")
    }
}
