//
//  AutoShutterTests.swift
//  FrameFoldTests
//
//  Der Auto-Auslöser im Zeitraffer der Wirklichkeit: synthetische Bilder mit
//  10 Bildern/s, wie die Ersatzkamera im Simulator. Ein Bild pro Ruhephase
//  nach einer Bewegung – nie während der Bewegung, nie zweimal dieselbe Szene.
//

import XCTest
import CoreGraphics
@testable import FrameFold

@MainActor
final class AutoShutterTests: XCTestCase {

    private var controller: LiveCaptureController!
    private var captureTimes: [Date] = []
    /// Nummer des eingespeisten Bildes, bei dem ausgelöst wurde – unabhängig
    /// davon, wie lange das Speichern danach dauert.
    private var captureFrames: [Int] = []

    override func setUp() async throws {
        controller = LiveCaptureController()
        captureTimes = []
        captureFrames = []
        controller.startWithoutCamera { [weak self] _ in
            Task { @MainActor in self?.captureTimes.append(Date()) }
        }
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
    }

    /// Liefert `frames` Bilder im Takt von 10/s; `scene(i)` bestimmt Schritt
    /// und Bewegung des Bildes i.
    private func feed(_ frames: Int, scene: (Int) -> (step: Int, moving: Bool, progress: Double)) async {
        for i in 0..<frames {
            let s = scene(i)
            if let cg = LiveCaptureController.makeSimulatedFrame(step: s.step, moving: s.moving, progress: s.progress) {
                let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(cg, targetWidth: 160)
                let before = controller.capturedCount
                controller.analyze(gray: gray, w: w, h: h, fullFrame: cg)
                if controller.capturedCount > before { captureFrames.append(i) }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await controller.flushCaptures()
        try? await Task.sleep(nanoseconds: 200_000_000)   // Rückmeldung an den Test
    }

    /// Ruhe – Bewegung – Ruhe …: nach dem Einmessen ein Bild je Ruhephase.
    func testOneCapturePerStillPhase() async {
        let still = 30, move = 6, cycle = still + move, cycles = 6   // 3 s Ruhe: Luft für langsame Testrechner
        await feed(cycle * cycles) { i in
            let inCycle = i % cycle
            let moving = inCycle >= still
            return (i / cycle, moving, moving ? Double(inCycle - still) / Double(move) : 0)
        }
        // Die erste Ruhephase dient dem Einmessen; danach je eine Aufnahme.
        XCTAssertGreaterThanOrEqual(captureTimes.count, cycles - 2,
                                    "zu wenig ausgelöst: \(captureTimes.count) bei \(cycles) Ruhephasen")
        XCTAssertLessThanOrEqual(captureTimes.count, cycles,
                                 "zu oft ausgelöst: \(captureTimes.count) bei \(cycles) Ruhephasen")
        // Nie zweimal in derselben Ruhephase, nie während der Bewegung
        let phases = captureFrames.map { $0 / cycle }
        XCTAssertEqual(Set(phases).count, phases.count, "zwei Aufnahmen in einer Ruhephase: Bilder \(captureFrames)")
        XCTAssertTrue(captureFrames.allSatisfy { $0 % cycle < still },
                      "Aufnahme während der Bewegung: Bilder \(captureFrames)")
    }

    /// Ständige Bewegung: nichts auslösen.
    func testNoCaptureWhileMoving() async {
        await feed(80) { i in (i / 6, true, Double(i % 6) / 6) }
        XCTAssertEqual(captureTimes.count, 0, "während der Bewegung ausgelöst")
    }

    /// Nur Ruhe, nie eine Bewegung: höchstens ein Bild, keine Serie derselben Szene.
    func testStillSceneCapturesAtMostOnce() async {
        await feed(80) { _ in (0, false, 0) }
        XCTAssertLessThanOrEqual(captureTimes.count, 1, "dieselbe Szene mehrfach aufgenommen")
    }
}
