//
//  CameraMoveTests.swift
//  FrameFoldTests
//
//  Kamerafahrten: Ausschnitt bleibt im Bild, Fahrt läuft vom Start- zum
//  Ziel-Ausschnitt, und das Zuschneiden trifft wirklich die richtige Stelle.
//

import XCTest
import CoreGraphics
@testable import FrameFold

final class CameraMoveTests: XCTestCase {

    func testRectStaysInsideImage() {
        let size = CGSize(width: 400, height: 300)
        let corner = Framing(x: 0, y: 1, zoom: 2).rect(in: size)
        XCTAssertEqual(corner, CGRect(x: 0, y: 150, width: 200, height: 150))
        XCTAssertEqual(Framing.full.rect(in: size), CGRect(origin: .zero, size: size))
        // Unsinnige Werte bleiben harmlos
        XCTAssertEqual(Framing(x: 0.5, y: 0.5, zoom: .nan).rect(in: size), CGRect(origin: .zero, size: size))
    }

    func testMoveInterpolatesAndHolds() {
        let move = CameraMove(firstFrame: 10, lastFrame: 20,
                              from: Framing(x: 0.2, y: 0.5, zoom: 1), to: Framing(x: 0.8, y: 0.5, zoom: 4), smooth: false)
        XCTAssertEqual(move.framing(at: 10).x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(move.framing(at: 20).x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(move.framing(at: 15).x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(move.framing(at: 15).zoom, 2, accuracy: 1e-9, "Zoom geometrisch gemischt")
        XCTAssertNil(CameraMoves.framing([move], at: 3), "vor der Fahrt das ganze Bild")
        XCTAssertEqual(CameraMoves.framing([move], at: 40)?.x ?? 0, 0.8, accuracy: 1e-9, "danach bleibt das Ziel")
    }

    func testApplyCropsTheRightRegion() throws {
        // Links rot, rechts blau
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let image = try XCTUnwrap(ctx.makeImage())

        let left = try XCTUnwrap(CameraMoves.apply(Framing(x: 0.25, y: 0.5, zoom: 2), to: image))
        XCTAssertEqual(left.width, 200)
        let (r, _, b) = try pixel(left, x: 190, y: 50)
        XCTAssertGreaterThan(r, 200, "rechter Rand des Ergebnisses kommt aus der linken, roten Hälfte")
        XCTAssertLessThan(b, 50)
        XCTAssertNil(CameraMoves.apply(.full, to: image), "ganzes Bild: nichts zu tun")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
