//
//  ProjectStoreTests.swift
//  FrameFoldTests
//
//  Der Projektspeicher hält die Werke der Nutzer – hier darf nichts
//  verloren gehen. Jeder Test arbeitet in einem eigenen, frischen Ordner
//  mit eigenen UserDefaults und berührt keine echten Werke.
//

import XCTest
@testable import FrameFold

@MainActor
final class ProjectStoreTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-store-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "ff-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> ProjectStore {
        ProjectStore(root: root, defaults: defaults)
    }

    private func jpeg(_ marker: UInt8 = 0) -> Data {
        // Inhalt ist egal – der Speicher schreibt die Bytes nur ab.
        Data([0xFF, 0xD8, marker, 0xFF, 0xD9])
    }

    private func projectDir(_ project: Project) -> URL {
        root.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    private func current(_ store: ProjectStore, _ project: Project) -> Project {
        store.projects.first { $0.id == project.id }!
    }

    // MARK: Anlegen & Speichern

    func testAppendFramePersistsAcrossReload() throws {
        let store = makeStore()
        let project = store.createProject(name: "Faltung")
        let first = store.appendFrame(jpegData: jpeg(1), to: project)
        let second = store.appendFrame(jpegData: jpeg(2), to: current(store, project))

        XCTAssertEqual(first, "000000.jpg")
        XCTAssertEqual(second, "000001.jpg")

        let reloaded = makeStore()
        let loaded = try XCTUnwrap(reloaded.projects.first { $0.id == project.id })
        XCTAssertEqual(loaded.name, "Faltung")
        XCTAssertEqual(loaded.frameFilenames, ["000000.jpg", "000001.jpg"])
    }

    func testEmptyNameGetsNumberedName() {
        let store = makeStore()
        let project = store.createProject(name: "   ")
        XCTAssertFalse(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testFrameNumbersDoNotCollideAfterRemoval() {
        let store = makeStore()
        let project = store.createProject(name: "A")
        for i in 0..<3 { store.appendFrame(jpegData: jpeg(UInt8(i)), to: current(store, project)) }
        store.removeFrames(at: IndexSet(integer: 2), from: current(store, project))
        let next = store.appendFrame(jpegData: jpeg(9), to: current(store, project))
        XCTAssertEqual(next, "000003.jpg", "Eine entfernte Nummer darf nicht neu vergeben werden")
    }

    // MARK: Verwerfen und Zurücknehmen

    func testRemoveFramesNamedTouchesOnlyThoseFrames() {
        let store = makeStore()
        let project = store.createProject(name: "A")
        // Ältere Sitzung …
        store.appendFrame(jpegData: jpeg(1), to: current(store, project))
        store.appendFrame(jpegData: jpeg(2), to: current(store, project))
        // … und die laufende
        let s1 = store.appendFrame(jpegData: jpeg(3), to: current(store, project))!
        let s2 = store.appendFrame(jpegData: jpeg(4), to: current(store, project))!

        store.removeFrames(named: [s1, s2], from: current(store, project))

        let after = current(store, project)
        XCTAssertEqual(after.frameFilenames, ["000000.jpg", "000001.jpg"])
        XCTAssertEqual(Set(after.trashFilenames ?? []), [s1, s2])
    }

    func testRemoveFramesNamedIgnoresUnknownNames() {
        let store = makeStore()
        let project = store.createProject(name: "A")
        store.appendFrame(jpegData: jpeg(1), to: current(store, project))
        store.removeFrames(named: ["999999.jpg"], from: current(store, project))
        XCTAssertEqual(current(store, project).frameCount, 1)
        XCTAssertNil(current(store, project).trashFilenames)
    }

    // MARK: Papierkorb

    func testTrashedFrameGetsFreshTimestamp() throws {
        let store = makeStore()
        let project = store.createProject(name: "A")
        let name = store.appendFrame(jpegData: jpeg(1), to: project)!
        // Aufnahme vor 60 Tagen
        let file = projectDir(project).appendingPathComponent(name)
        let old = Date().addingTimeInterval(-60 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        store.removeFrames(at: IndexSet(integer: 0), from: current(store, project))

        let trashed = projectDir(project).appendingPathComponent("trash").appendingPathComponent(name)
        let modified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: trashed.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified, Date().addingTimeInterval(-60),
                             "Die 30 Tage müssen ab dem Entfernen zählen")

        // Ein Neustart darf das Bild nicht löschen
        let reloaded = makeStore()
        XCTAssertEqual(current(reloaded, project).trashFilenames, [name])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testPurgeRemovesOnlyTrashOlderThan30Days() throws {
        let store = makeStore()
        let project = store.createProject(name: "A")
        let a = store.appendFrame(jpegData: jpeg(1), to: project)!
        let b = store.appendFrame(jpegData: jpeg(2), to: current(store, project))!
        store.removeFrames(at: IndexSet([0, 1]), from: current(store, project))

        let trash = projectDir(project).appendingPathComponent("trash")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-31 * 24 * 3600)],
            ofItemAtPath: trash.appendingPathComponent(a).path)

        store.purgeOldTrash()

        XCTAssertEqual(current(store, project).trashFilenames, [b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.appendingPathComponent(a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(b).path))
    }

    func testLegacyTrashIsStampedOnceBeforePurge() throws {
        // Papierkorb aus einer älteren Fassung: Datei mit altem Aufnahmedatum
        let store = makeStore()
        let project = store.createProject(name: "A")
        let name = store.appendFrame(jpegData: jpeg(1), to: project)!
        store.removeFrames(at: IndexSet(integer: 0), from: current(store, project))
        let trashed = projectDir(project).appendingPathComponent("trash").appendingPathComponent(name)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-90 * 24 * 3600)], ofItemAtPath: trashed.path)
        defaults.removeObject(forKey: "trashStampedOnce")

        // Erster Start der neuen Fassung: Frist beginnt neu, nichts wird gelöscht
        let upgraded = makeStore()
        XCTAssertEqual(current(upgraded, project).trashFilenames, [name])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertTrue(defaults.bool(forKey: "trashStampedOnce"))
    }

    func testRestoreTrashKeepsCaptureOrder() {
        let store = makeStore()
        let project = store.createProject(name: "A")
        for i in 0..<4 { store.appendFrame(jpegData: jpeg(UInt8(i)), to: current(store, project)) }
        store.removeFrames(at: IndexSet([0, 2]), from: current(store, project))
        store.restoreTrash(in: current(store, project))

        let after = current(store, project)
        XCTAssertEqual(after.frameFilenames, ["000000.jpg", "000001.jpg", "000002.jpg", "000003.jpg"])
        XCTAssertNil(after.trashFilenames)
    }

    // MARK: Beschädigtes Manifest

    func testMissingManifestIsRecoveredFromImages() throws {
        let store = makeStore()
        let project = store.createProject(name: "A")
        for i in 0..<3 { store.appendFrame(jpegData: jpeg(UInt8(i)), to: current(store, project)) }
        try FileManager.default.removeItem(at: projectDir(project).appendingPathComponent("manifest.json"))

        let reloaded = makeStore()
        let recovered = try XCTUnwrap(reloaded.projects.first { $0.id == project.id },
                                      "Das Werk darf nicht verschwinden")
        XCTAssertEqual(recovered.frameFilenames, ["000000.jpg", "000001.jpg", "000002.jpg"])
        // Weiter aufnehmen ohne Kollision
        XCTAssertEqual(reloaded.appendFrame(jpegData: jpeg(7), to: recovered), "000003.jpg")
    }

    func testTruncatedManifestIsRecoveredFromImages() throws {
        let store = makeStore()
        let project = store.createProject(name: "A")
        store.appendFrame(jpegData: jpeg(1), to: project)
        let manifest = projectDir(project).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifest)
        try data.prefix(data.count / 2).write(to: manifest)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.projects.first { $0.id == project.id }?.frameCount, 1)
    }

    func testDeleteRemovesWholeProject() {
        let store = makeStore()
        let project = store.createProject(name: "A")
        store.appendFrame(jpegData: jpeg(1), to: project)
        store.delete(current(store, project))
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir(project).path))
        XCTAssertTrue(makeStore().projects.isEmpty)
    }
}
