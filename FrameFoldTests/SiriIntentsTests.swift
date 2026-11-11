//
//  SiriIntentsTests.swift
//  FrameFoldTests
//
//  Die Siri-Befehle schicken nur Nachrichten an die Ansichten. Geprüft wird,
//  dass sie ohne laufende Aufnahme nichts auslösen und dass sie das richtige
//  Werk weiterreichen. Eigener Ordner, keine echten Werke.
//

import XCTest
@testable import FrameFold

@MainActor
final class SiriIntentsTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var previousStore: ProjectStore?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-siri-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "ff-siri-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        previousStore = SiriBridge.store
        SiriBridge.store = ProjectStore(root: root, defaults: defaults)
        SiriBridge.controller = nil
        SiriBridge.pendingExport = nil
        ContinueWork.pending = nil
        OpenWork.pending = nil
    }

    override func tearDown() async throws {
        SiriBridge.store = previousStore
        SiriBridge.pendingExport = nil
        ContinueWork.pending = nil
        OpenWork.pending = nil
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCaptureCommandsRefuseWithoutRunningCapture() async {
        let sent = expectation(forNotification: .ffCaptureNow, object: nil)
        sent.isInverted = true
        do { _ = try await CaptureFrameIntent().perform(); XCTFail("ohne Aufnahme darf nichts auslösen") }
        catch { XCTAssertEqual(error as? SiriIntentError, .notCapturing) }
        do { _ = try await UndoLastFrameIntent().perform(); XCTFail() }
        catch { XCTAssertEqual(error as? SiriIntentError, .notCapturing) }
        do { _ = try await FinishCaptureIntent().perform(); XCTFail() }
        catch { XCTAssertEqual(error as? SiriIntentError, .notCapturing) }
        await fulfillment(of: [sent], timeout: 0.3)
    }

    func testStartCaptureWithoutWorkCreatesOneAndHandsItToTheCamera() async throws {
        let store = try XCTUnwrap(SiriBridge.store)
        XCTAssertTrue(store.projects.isEmpty)
        // Die Nachricht trägt das Werk; `ContinueWork.pending` räumt der
        // Kamera-Tab der Test-App gleich wieder ab.
        var handed: UUID?
        let sent = expectation(forNotification: .ffContinueWork, object: nil) { note in
            handed = note.object as? UUID
            return true
        }
        _ = try await StartCaptureIntent().perform()
        await fulfillment(of: [sent], timeout: 1)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(handed, store.projects.first?.id)
    }

    func testStartCaptureContinuesTheNamedWork() async throws {
        let store = try XCTUnwrap(SiriBridge.store)
        _ = store.createProject(name: "Eins")
        let second = store.createProject(name: "Zwei")
        let intent = StartCaptureIntent()
        intent.work = WorkEntity(second)
        var handed: UUID?
        let sent = expectation(forNotification: .ffContinueWork, object: nil) { note in
            handed = note.object as? UUID
            return true
        }
        _ = try await intent.perform()
        await fulfillment(of: [sent], timeout: 1)
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(handed, second.id)
    }

    func testExportRefusesAnEmptyWork() async throws {
        let store = try XCTUnwrap(SiriBridge.store)
        let empty = store.createProject(name: "Leer")
        let intent = ExportFilmIntent()
        intent.work = WorkEntity(empty)
        do { _ = try await intent.perform(); XCTFail("leeres Werk darf nicht exportieren") }
        catch { XCTAssertEqual(error as? SiriIntentError, .workEmpty) }
        XCTAssertNil(SiriBridge.pendingExport)
    }

    func testWorkQueryFindsWorksByName() async throws {
        let store = try XCTUnwrap(SiriBridge.store)
        _ = store.createProject(name: "Kranich")
        _ = store.createProject(name: "Hypar")
        let found = try await WorkQuery().entities(matching: "kran")
        XCTAssertEqual(found.map(\.name), ["Kranich"])
        let all = try await WorkQuery().suggestedEntities()
        XCTAssertEqual(all.count, 2)
    }
}
