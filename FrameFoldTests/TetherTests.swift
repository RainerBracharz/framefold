//
//  TetherTests.swift
//  FrameFoldTests
//
//  Ohne angeschlossene Kamera lässt sich nur eines prüfen – aber das
//  Entscheidende: Den Auslösebefehl, den das SDK für Mac Catalyst
//  ausblendet, gibt es zur Laufzeit wirklich.
//

import XCTest
import ImageCaptureCore
@testable import FrameFold

final class TetherTests: XCTestCase {
    func testTakePictureExistsAtRuntimeOnMac() throws {
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(TetherCamera.isSupported)
        XCTAssertTrue(ICCameraDevice.instancesRespond(to: NSSelectorFromString("requestTakePicture")),
                      "requestTakePicture fehlt in Mac Catalyst – direktes Auslösen ginge nicht")
        #else
        throw XCTSkip("Nur in der Mac-Fassung")
        #endif
    }
}
