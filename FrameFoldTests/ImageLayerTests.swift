//
//  ImageLayerTests.swift
//  FrameFoldTests
//
//  Bild-Ebenen: landen als Datei im Werk, werden an der richtigen Stelle
//  gezeichnet, wandern mit „Werk als Datei“ mit und gehen beim Entfernen
//  in den Papierkorb.
//

import XCTest
import UIKit
@testable import FrameFold

@MainActor
final class ImageLayerTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-layer-\(UUID().uuidString)")
        suite = "ff-layer-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func png(_ color: UIColor, size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testImageLayerIsStoredDrawnAndTravels() async throws {
        let store = ProjectStore(root: root, defaults: UserDefaults(suiteName: suite)!)
        let project = store.createProject(name: "Ebenen")
        for _ in 0..<3 {
            _ = store.appendFrame(jpegData: UIImage(data: png(.white, size: CGSize(width: 100, height: 100)))!.jpegData(compressionQuality: 0.9)!,
                                  to: store.projects[0])
        }
        let overlay = try XCTUnwrap(store.addImageOverlay(data: png(.red, size: CGSize(width: 20, height: 20)), at: 0, in: project.id))
        XCTAssertEqual(overlay.kind, .image)
        XCTAssertEqual(overlay.lastFrame, 2, "auf die vorhandenen Bilder begrenzt")
        let folder = store.folderURL(for: store.projects[0])
        let file = folder.appendingPathComponent(try XCTUnwrap(overlay.imageFilename))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Mitte des Bilds rot, Rand weiß (Ebene: 40 % Breite, mittig)
        let base = try XCTUnwrap(UIImage(data: png(.white, size: CGSize(width: 100, height: 100)))?.cgImage)
        let drawn = try XCTUnwrap(OverlayRenderer.apply([overlay], frame: 1, to: base, folder: folder))
        XCTAssertEqual(try color(drawn, x: 50, y: 50).r, 255, accuracy: 3)
        XCTAssertEqual(try color(drawn, x: 50, y: 50).g, 0, accuracy: 3)
        XCTAssertEqual(try color(drawn, x: 5, y: 5).g, 255, accuracy: 3)

        // Reist mit dem Werk-Paket mit
        let pkg = try await store.exportPackage(of: store.projects[0])
        let copy = try await store.importPackage(from: pkg)
        XCTAssertEqual(copy.overlays?.first?.kind, .image)
        let copyFile = store.folderURL(for: copy).appendingPathComponent(try XCTUnwrap(copy.overlays?.first?.imageFilename))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyFile.path))

        // Entfernen legt die Datei in den Papierkorb
        store.removeOverlay(id: overlay.id, in: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("trash").appendingPathComponent(file.lastPathComponent).path))
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(data[0]), Double(data[1]))
    }

    func testPaperHidesPhotoForRotoscoping() throws {
        let base = try XCTUnwrap(UIImage(data: png(.black, size: CGSize(width: 60, height: 60)))?.cgImage)
        var drawing = FrameOverlay(kind: .drawing, firstFrame: 0, lastFrame: 0,
                                   strokes: [OverlayStroke(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.1)], width: 0.02, color: .red)])
        let plain = try XCTUnwrap(OverlayRenderer.apply([drawing], frame: 0, to: base))
        XCTAssertLessThan(try color(plain, x: 50, y: 50).g, 5, "ohne Papier bleibt das Foto")
        drawing.paper = true
        let paper = try XCTUnwrap(OverlayRenderer.apply([drawing], frame: 0, to: base))
        XCTAssertGreaterThan(try color(paper, x: 50, y: 50).g, 240, "mit Papier ist das Foto weg")
    }

    func testVideoFramesAtFixedRate() async throws {
        // 2 s Film aus 20 Bildern bei 10 fps bauen, dann mit 6 Bildern/s einlesen
        let frames = (0..<20).map { i -> URL in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ff-roto-\(UUID().uuidString).jpg")
            try? UIImage(data: png(UIColor(white: CGFloat(i) / 20, alpha: 1), size: CGSize(width: 160, height: 120)))!
                .jpegData(compressionQuality: 0.9)!.write(to: url)
            return url
        }
        defer { frames.forEach { try? FileManager.default.removeItem(at: $0) } }
        var settings = PipelineSettings()
        settings.outputFPS = 10
        settings.deflicker = false
        settings.alignFrames = false
        settings.loopMode = .none
        settings.holdLastFrameSeconds = 0
        let movie = try await StopMotionAssembler().assemble(imageURLs: frames, settings: settings) { _ in }
        defer { try? FileManager.default.removeItem(at: movie) }

        let store = ProjectStore(root: root, defaults: UserDefaults(suiteName: suite)!)
        let project = store.createProject(name: "Roto")
        let saved = await store.importVideoFrames(from: movie, fps: 6, into: project)
        XCTAssertEqual(saved, 12)
        XCTAssertEqual(store.projects[0].frameCount, 12)
    }
}
