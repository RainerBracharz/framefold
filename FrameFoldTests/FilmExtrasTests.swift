//
//  FilmExtrasTests.swift
//  FrameFoldTests
//
//  Greenscreen, Titelkarte und Abspann im Export.
//

import XCTest
import AVFoundation
import UIKit
@testable import FrameFold

final class FilmExtrasTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-extras-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func image(width: Int = 320, height: Int = 240, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { draw($0.cgContext) }
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    func testGreenIsReplacedByBackgroundAndRestStays() async throws {
        // links Grün, rechts Weiß
        let frame = image { ctx in
            UIColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 240))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 160, y: 0, width: 160, height: 240))
        }.cgImage!
        let background = dir.appendingPathComponent("bg.png")
        try XCTUnwrap(image(width: 64, height: 64) { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.pngData()).write(to: background)

        let compositor = try XCTUnwrap(GreenScreenCompositor(key: .green, background: background, fps: 12))
        let result = await compositor.composite(frame, index: 0)
        XCTAssertEqual(result.width, 320)
        let left = pixel(result, 40, 120), right = pixel(result, 280, 120)
        XCTAssertGreaterThan(left.r, 200, "Grün → roter Hintergrund: \(left)")
        XCTAssertLessThan(left.g, 60)
        XCTAssertGreaterThan(right.g, 230, "Weiß bleibt: \(right)")
        XCTAssertNil(GreenScreenCompositor(key: .none, background: background, fps: 12), "ohne Farbe kein Greenscreen")
        XCTAssertNil(GreenScreenCompositor(key: .green, background: nil, fps: 12), "ohne Hintergrund kein Greenscreen")
    }

    func testTitleAndCreditsWrapTheFilm() async throws {
        let urls = try (0..<4).map { i -> URL in
            let url = dir.appendingPathComponent("\(i).jpg")
            try XCTUnwrap(image { ctx in
                UIColor(white: CGFloat(i) / 4, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            }.jpegData(compressionQuality: 0.9)).write(to: url)
            return url
        }
        var settings = PipelineSettings()
        settings.outputFPS = 4
        settings.alignFrames = false
        settings.deflicker = false
        let film = try await StopMotionAssembler().assemble(imageURLs: urls, settings: settings) { _ in }
        let filmDuration = try await AVURLAsset(url: film).load(.duration).seconds

        let wrapped = try await TitleSequence.wrap(film: film, title: "Faltung", subtitle: "25. Okt. 2026",
                                                   credits: "Regie: Anna\nMusik: Ben", settings: settings)
        XCTAssertEqual(wrapped.lead, TitleSequence.titleSeconds)
        let total = try await AVURLAsset(url: wrapped.url).load(.duration).seconds
        XCTAssertEqual(total, filmDuration + TitleSequence.titleSeconds + TitleSequence.creditsSeconds, accuracy: 0.3)

        let untouched = try await TitleSequence.wrap(film: film, title: "  ", subtitle: "", credits: nil, settings: settings)
        XCTAssertEqual(untouched.url, film, "leerer Titel, kein Abspann: Film bleibt, wie er ist")
        XCTAssertEqual(untouched.lead, 0)
    }

    func testCardsHaveRequestedSize() {
        let size = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(TitleCards.title("Ein Titel", subtitle: "2026", size: size).size, size)
        XCTAssertEqual(TitleCards.credits("Zeile 1\nZeile 2", size: size).size, size)
        // Zum Ansehen: FF_CARDS_OUT=<ordner> legt beide Karten dort ab
        if let out = ProcessInfo.processInfo.environment["FF_CARDS_OUT"] {
            let wide = CGSize(width: 1920, height: 1080)
            try? TitleCards.title("Die Faltung", subtitle: "25. Okt. 2026", size: wide).pngData()?
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("titel.png"))
            try? TitleCards.credits("Idee und Animation: Anna\nMusik: Ben\nDank an die Klasse 4b", size: wide).pngData()?
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("abspann.png"))
        }
    }

    @MainActor
    func testStoreKeepsGreenScreenAndTitles() throws {
        let suite = "ff-extras-\(UUID().uuidString)"
        let store = ProjectStore(root: dir.appendingPathComponent("store"), defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let project = store.createProject(name: "A")
        store.setGreenScreenKey(.blue, in: project.id)
        let bg = dir.appendingPathComponent("bg.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: bg)
        XCTAssertTrue(store.setGreenScreenBackground(from: bg, in: project.id))
        store.setTitles(title: "Faltung", credits: "Ende", in: project.id)
        let reloaded = ProjectStore(root: dir.appendingPathComponent("store"), defaults: UserDefaults(suiteName: suite)!)
        let p = try XCTUnwrap(reloaded.projects.first)
        XCTAssertEqual(p.greenScreen?.key, .blue)
        XCTAssertNotNil(reloaded.greenScreenBackgroundURL(for: p))
        XCTAssertEqual(p.titleText, "Faltung")
        XCTAssertEqual(p.creditsText, "Ende")
    }
}
