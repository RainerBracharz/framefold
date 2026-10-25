//
//  StudioTests.swift
//  FrameFoldTests
//
//  Die Mac-Arbeitsfläche: Wiedergabe-Logik, Masken, Mittelung, Zeitraffer,
//  Notizen und die Profi-Exporte (ProRes, Bildsequenz).
//

import XCTest
import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import FrameFold

final class StudioTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-studio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func solid(_ white: CGFloat, width: Int = 64, height: Int = 48) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(white: white, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.cgImage!
    }

    private func gray(of image: CGImage) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(px[0])
    }

    // MARK: Wiedergabe

    func testPlaybackRangeRespectsLoopMarks() {
        XCTAssertNil(StudioPlayback.range(count: 0, loopIn: nil, loopOut: nil))
        XCTAssertEqual(StudioPlayback.range(count: 10, loopIn: nil, loopOut: nil), 0...9)
        XCTAssertEqual(StudioPlayback.range(count: 10, loopIn: 3, loopOut: 6), 3...6)
        XCTAssertEqual(StudioPlayback.range(count: 10, loopIn: 8, loopOut: 2), 8...8, "Ende vor Anfang")
        XCTAssertEqual(StudioPlayback.range(count: 5, loopIn: nil, loopOut: 40), 0...4)
    }

    func testShortPlayTakesLastFrames() {
        XCTAssertEqual(StudioPlayback.shortRange(count: 30, frames: 12), 18...29)
        XCTAssertEqual(StudioPlayback.shortRange(count: 5, frames: 12), 0...4)
        XCTAssertNil(StudioPlayback.shortRange(count: 0, frames: 12))
    }

    func testStepEndsAtLiveAndStopsAtFirst() {
        XCTAssertEqual(StudioPlayback.step(from: nil, by: -1, count: 5), 4, "von Live zurück aufs letzte Bild")
        XCTAssertNil(StudioPlayback.step(from: 4, by: 1, count: 5), "hinter dem letzten kommt Live")
        XCTAssertEqual(StudioPlayback.step(from: 0, by: -1, count: 5), 0)
        XCTAssertNil(StudioPlayback.step(from: nil, by: 1, count: 5))
        XCTAssertNil(StudioPlayback.step(from: nil, by: -1, count: 0), "ohne Bilder bleibt es live")
    }

    // MARK: Masken

    func testMaskRectIsCentredAndKeepsRatio() {
        let canvas = CGSize(width: 1600, height: 900)
        let scope = studioMaskRect(in: canvas, ratio: 2.39)
        XCTAssertEqual(scope.width, 1600)
        XCTAssertEqual(scope.width / scope.height, 2.39, accuracy: 0.01)
        XCTAssertEqual(scope.midY, 450, accuracy: 0.5)
        let square = studioMaskRect(in: canvas, ratio: 1)
        XCTAssertEqual(square, CGRect(x: 350, y: 0, width: 900, height: 900))
        XCTAssertEqual(studioMaskRect(in: canvas, ratio: nil), CGRect(origin: .zero, size: canvas))
    }

    // MARK: Aufnahme

    func testAverageOfFrames() throws {
        let mean = try XCTUnwrap(LiveCaptureController.average([solid(0.2), solid(0.6), solid(0.4)]))
        XCTAssertEqual(gray(of: mean), Int((0.4 * 255).rounded()), accuracy: 2)
        XCTAssertNil(LiveCaptureController.average([]))
        let one = solid(0.5)
        XCTAssertTrue(LiveCaptureController.average([one]) === one)
        // Bilder anderer Größe zählen nicht mit
        let mixed = try XCTUnwrap(LiveCaptureController.average([solid(0.2), solid(1, width: 10, height: 10), solid(0.6)]))
        XCTAssertEqual(gray(of: mixed), Int((0.4 * 255).rounded()), accuracy: 2)
    }

    func testIntervalLimits() {
        let now = Date()
        XCTAssertFalse(LiveCaptureController.intervalFinished(taken: 3, limit: nil, end: nil, now: now))
        XCTAssertTrue(LiveCaptureController.intervalFinished(taken: 10, limit: 10, end: nil, now: now))
        XCTAssertFalse(LiveCaptureController.intervalFinished(taken: 9, limit: 10, end: nil, now: now))
        XCTAssertTrue(LiveCaptureController.intervalFinished(taken: 0, limit: nil, end: now, now: now))
        XCTAssertFalse(LiveCaptureController.intervalFinished(taken: 0, limit: nil, end: now.addingTimeInterval(60), now: now))
    }

    // MARK: Einstellungen

    func testSettingsSurviveMissingKeys() throws {
        let json = #"{"mask":"scope","onionFrames":3,"unknown":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(StudioSettings.self, from: json)
        XCTAssertEqual(settings.mask, .scope)
        XCTAssertEqual(settings.onionFrames, 3)
        XCTAssertEqual(settings.averageFrames, 1, "fehlende Felder bekommen den Standard")
        let broken = #"{"mask":"keinFormat","gridRows":4}"#.data(using: .utf8)!
        let fallback = try JSONDecoder().decode(StudioSettings.self, from: broken)
        XCTAssertEqual(fallback.mask, MaskAspect.none)
        XCTAssertEqual(fallback.gridRows, 4)
    }

    // MARK: Notizen

    @MainActor
    func testNotesAreStoredPerFrameNumber() {
        let suite = "ff-studio-notes-\(UUID().uuidString)"
        let store = ProjectStore(root: dir.appendingPathComponent("store"), defaults: UserDefaults(suiteName: suite)!)
        let project = store.createProject(name: "A")
        store.setNote("  Arm heben ", forFrame: 12, in: project)
        XCTAssertEqual(store.projects[0].note(forFrame: 12), "Arm heben")
        XCTAssertNil(store.projects[0].note(forFrame: 11))
        store.setNote("", forFrame: 12, in: store.projects[0])
        XCTAssertNil(store.projects[0].notes, "leere Notiz entfernt den Eintrag")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: Export

    private func frames(_ count: Int) throws -> [URL] {
        try (0..<count).map { i in
            let url = dir.appendingPathComponent("f\(i).jpg")
            let image = UIImage(cgImage: solid(CGFloat(i) / CGFloat(max(1, count - 1)), width: 320, height: 240))
            try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
            return url
        }
    }

    func testProResExportIsQuickTime() async throws {
        var settings = PipelineSettings()
        settings.outputFPS = 24
        settings.alignFrames = false
        settings.deflicker = false
        settings.videoCodec = .prores422
        let film = try await StopMotionAssembler().assemble(imageURLs: try frames(4), settings: settings) { _ in }
        XCTAssertEqual(film.pathExtension, "mov")
        let track = try await XCTUnwrapAsync(AVURLAsset(url: film).loadTracks(withMediaType: .video).first)
        let formats = try await track.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first))
        XCTAssertEqual(codec, kCMVideoCodecType_AppleProRes422)
    }

    func testImageSequenceWritesNumberedFiles() throws {
        let urls = try frames(3)
        for format in SequenceFormat.allCases {
            let folder = try StopMotionAssembler.exportSequence(urls, name: "Werk/1", format: format)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTAssertEqual(names, ["Werk-1_0001", "Werk-1_0002", "Werk-1_0003"].map { "\($0).\(format.fileExtension)" })
            let first = folder.appendingPathComponent(names[0])
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(first as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.type.identifier)
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }
    }

    // MARK: Lupe und Kamera-Ordner

    func testLoupeRectZoomsAndStaysInside() {
        let size = CGSize(width: 6000, height: 4000)
        let mid = studioLoupeRect(imageSize: size, center: CGPoint(x: 0.5, y: 0.5), zoom: 4, aspect: 1.6)
        XCTAssertEqual(mid.width, 1500)
        XCTAssertEqual(mid.height, 938, accuracy: 1)
        XCTAssertEqual(mid.midX, 3000, accuracy: 1)
        let corner = studioLoupeRect(imageSize: size, center: CGPoint(x: 1, y: 0), zoom: 2, aspect: 1.6)
        XCTAssertEqual(corner.maxX, 6000)
        XCTAssertEqual(corner.minY, 0)
    }

    func testWatchFolderListsImagesInCameraOrder() throws {
        for name in ["IMG_10.JPG", "IMG_9.jpg", "IMG_11.CR3", ".hidden.jpg", "notes.txt", "IMG_12.tif"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(StudioFolderWatch.imageFiles(in: dir), ["IMG_9.jpg", "IMG_10.JPG", "IMG_11.CR3", "IMG_12.tif"])
    }

    func testWatchFolderKeepsJPEGBytesAndConvertsOthers() throws {
        let jpeg = dir.appendingPathComponent("a.jpg")
        let original = try XCTUnwrap(UIImage(cgImage: solid(0.3, width: 400, height: 300)).jpegData(compressionQuality: 0.8))
        try original.write(to: jpeg)
        let (image, data) = try XCTUnwrap(StudioFolderWatch.load(jpeg))
        XCTAssertEqual(data, original, "JPEG bleibt Byte für Byte")
        XCTAssertEqual(image.width, 400)

        let tiff = dir.appendingPathComponent("b.tif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, solid(0.7, width: 640, height: 480), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let (converted, jpegData) = try XCTUnwrap(StudioFolderWatch.load(tiff))
        XCTAssertEqual(converted.width, 640)
        XCTAssertEqual(Array(jpegData.prefix(2)), [0xFF, 0xD8], "als JPEG abgelegt")
        XCTAssertNil(StudioFolderWatch.load(dir.appendingPathComponent("fehlt.jpg")))
    }

    @MainActor
    func testCommitWithOriginalDataDeliversThoseBytes() async throws {
        let controller = LiveCaptureController()
        let delivered = expectation(description: "Bild ins Werk")
        var received: Data?
        controller.startWithoutCamera { data in received = data; delivered.fulfill() }
        let bytes = try XCTUnwrap(UIImage(cgImage: solid(0.5)).jpegData(compressionQuality: 0.5))
        controller.commit(frame: solid(0.5), originalData: bytes)
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(received, bytes)
        XCTAssertEqual(controller.capturedCount, 1)
        controller.stop()
    }

    func testShutterLabel() {
        XCTAssertEqual(LiveCaptureController.shutterLabel(1.0 / 250), "1/250 s")
        XCTAssertEqual(LiveCaptureController.shutterLabel(0.5), "0.5 s")
    }

    private func XCTUnwrapAsync<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
}
