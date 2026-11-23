//
//  DeviceStubs.swift
//  FrameFoldTests
//
//  Auf einem echten iPhone fehlen die Testzugänge, die es nur im Simulator
//  und in der Mac-Debug-Fassung gibt. Damit das Test-Paket trotzdem auf
//  dem Gerät läuft (Export-Tests mit echtem Encoder und echter
//  Speichergrenze), stehen hier Platzhalter. Tests, die sie brauchen,
//  scheitern auf dem Gerät mit klarer Meldung; man startet dort gezielt
//  -only-testing:FrameFoldTests/LongExportTests und …/ExportTortureTests.
//

#if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import XCTest
@testable import FrameFold

extension LiveCaptureController {
    func startWithoutCamera(onCapture: @escaping (Data) -> Void) {
        XCTFail("startWithoutCamera gibt es nur im Simulator und am Mac")
    }
    static func makeSimulatedFrame(step: Int, moving: Bool, progress: Double) -> CGImage? {
        XCTFail("makeSimulatedFrame gibt es nur im Simulator und am Mac")
        return nil
    }
}
#endif
