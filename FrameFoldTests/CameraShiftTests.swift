//
//  CameraShiftTests.swift
//  FrameFoldTests
//
//  „Kamera verrutscht?“ im echten Ablauf: Ruhephasen und Hand im Wechsel,
//  10 Bilder/s. Wird die Kamera nach ein paar Bildern verschoben, warnt der
//  Sucher; bleibt sie stehen, nicht – auch wenn sich das Werk verändert.
//

import XCTest
import CoreGraphics
@testable import FrameFold

@MainActor
final class CameraShiftTests: XCTestCase {

    private var controller: LiveCaptureController!

    override func setUp() async throws {
        controller = LiveCaptureController()
        controller.startWithoutCamera { _ in }
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
    }

    /// Tisch mit Maserung (Kacheln), in der Mitte das Werk (je Schritt etwas
    /// anders), auf Wunsch eine Hand. `shift` verschiebt das ganze Bild – so,
    /// als wäre die Kamera angestoßen worden.
    private func frame(step: Int, hand: Bool, shift: Int) -> CGImage {
        let w = 640, h = 360
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 11
        for gy in 0..<10 {
            for gx in 0..<18 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let g = CGFloat((seed >> 33) % 200 + 30) / 255
                ctx.setFillColor(red: g, green: g * 0.9, blue: g * 0.8, alpha: 1)
                ctx.fill(CGRect(x: gx * 40 - 40 + shift, y: gy * 40 - 20, width: 40, height: 40))
            }
        }
        ctx.setFillColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
        ctx.fill(CGRect(x: 220 + shift, y: 100, width: 200, height: 160))
        ctx.setFillColor(red: 0.85, green: 0.6, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 240 + shift + step * 12, y: 130, width: 40, height: 40))
        if hand {
            ctx.setFillColor(red: 0.85, green: 0.65, blue: 0.55, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 200, y: 120, width: 260, height: 160))
        }
        return ctx.makeImage()!
    }

    /// Ruhe – Hand – Ruhe …; ab Zyklus `shiftFrom` steht die Kamera versetzt.
    private func run(cycles: Int, shiftFrom: Int?, shift: Int = 24) async {
        let still = 30, move = 6
        for c in 0..<cycles {
            let s = (shiftFrom.map { c >= $0 } ?? false) ? shift : 0
            for i in 0..<(still + move) {
                let cg = frame(step: c, hand: i >= still, shift: s)
                let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(cg, targetWidth: 160)
                controller.analyze(gray: gray, w: w, h: h, fullFrame: cg)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await controller.flushCaptures()
    }

    func testWarnsWhenCameraIsBumped() async {
        await run(cycles: 6, shiftFrom: 3)
        XCTAssertTrue(controller.cameraShifted, "verschobene Kamera nicht erkannt")
        controller.acceptCameraPosition()
        XCTAssertFalse(controller.cameraShifted, "„Passt so“ nimmt die Warnung nicht zurück")
    }

    func testNoWarningWhenOnlyTheWorkChanges() async {
        await run(cycles: 6, shiftFrom: nil)
        XCTAssertFalse(controller.cameraShifted, "Warnung, obwohl die Kamera stand")
    }
}
