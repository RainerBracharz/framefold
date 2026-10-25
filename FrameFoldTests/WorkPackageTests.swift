//
//  WorkPackageTests.swift
//  FrameFoldTests
//
//  Werk als Datei: Ein exportiertes Werk muss vollständig wieder
//  ankommen – als Kopie, ohne Papierkorb –, und eine präparierte Datei
//  darf nichts außerhalb ihres Werkordners schreiben.
//

import XCTest
@testable import FrameFold

@MainActor
final class WorkPackageTests: XCTestCase {

    private var root: URL!
    private var scratch: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-pkg-store-\(UUID().uuidString)")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ff-pkg-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        suiteName = "ff-pkg-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: scratch)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRoundTripCreatesIndependentCopyWithoutTrash() async throws {
        let store = ProjectStore(root: root, defaults: defaults)
        var project = store.createProject(name: "Faltung / Nr. 3")
        for marker in UInt8(1)...UInt8(3) {
            _ = store.appendFrame(jpegData: Data([0xFF, 0xD8, marker, 0xFF, 0xD9]), to: store.projects.first { $0.id == project.id }!)
        }
        project = store.projects.first { $0.id == project.id }!
        store.removeFrames(named: [project.frameFilenames[1]], from: project)
        project = store.projects.first { $0.id == project.id }!
        store.setTitles(title: "Titel", credits: "Ende", in: project.id)
        project = store.projects.first { $0.id == project.id }!
        XCTAssertEqual(project.trashCount, 1)

        let file = try await store.exportPackage(of: project)
        XCTAssertEqual(file.pathExtension, "framefold")
        XCTAssertFalse(file.lastPathComponent.contains("/"))

        let imported = try await store.importPackage(from: file)
        XCTAssertNotEqual(imported.id, project.id)
        XCTAssertEqual(imported.name, project.name)
        XCTAssertEqual(imported.frameFilenames, project.frameFilenames)
        XCTAssertEqual(imported.titleText, "Titel")
        XCTAssertEqual(imported.trashCount, 0)
        XCTAssertEqual(store.projects.count, 2)

        // Bilder Byte für Byte gleich, Papierkorb nicht mitgereist
        let urls = store.frameURLs(for: imported)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) },
                       try store.frameURLs(for: project).map { try Data(contentsOf: $0) })
        let importedDir = root.appendingPathComponent(imported.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedDir.appendingPathComponent(project.trashFilenames![0]).path))

        // Übersteht ein Neuladen
        let reloaded = ProjectStore(root: root, defaults: defaults)
        XCTAssertEqual(reloaded.projects.first { $0.id == imported.id }?.frameFilenames, project.frameFilenames)
    }

    func testRejectsPathTraversal() throws {
        let evil = scratch.appendingPathComponent("boese.framefold")
        let payload = scratch.appendingPathComponent("payload")
        try Data("x".utf8).write(to: payload)
        try WorkPackage.write(files: [(name: "../ausbruch.txt", url: payload)], to: evil)
        let target = scratch.appendingPathComponent("ziel")
        XCTAssertThrowsError(try WorkPackage.read(evil, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("ausbruch.txt").path))
    }

    func testRejectsForeignAndTruncatedFiles() async throws {
        let foreign = scratch.appendingPathComponent("fremd.framefold")
        try Data("kein Werk".utf8).write(to: foreign)
        XCTAssertThrowsError(try WorkPackage.read(foreign, into: scratch.appendingPathComponent("a")))

        let payload = scratch.appendingPathComponent("bild.jpg")
        try Data(repeating: 7, count: 5000).write(to: payload)
        let full = scratch.appendingPathComponent("voll.framefold")
        try WorkPackage.write(files: [(name: "000000.jpg", url: payload)], to: full)
        let cut = scratch.appendingPathComponent("halb.framefold")
        try Data(try Data(contentsOf: full).prefix(2000)).write(to: cut)
        XCTAssertThrowsError(try WorkPackage.read(cut, into: scratch.appendingPathComponent("b")))

        // Ohne Manifest kein Werk – und keine Spur im Speicher
        let store = ProjectStore(root: root, defaults: defaults)
        do {
            _ = try await store.importPackage(from: full)
            XCTFail("Import ohne Manifest darf nicht gelingen")
        } catch {}
        XCTAssertTrue(store.projects.isEmpty)
    }

    func testFilenameIsSafe() {
        XCTAssertEqual(WorkPackage.filename(for: "a/b:c"), "a-b-c.framefold")
        XCTAssertEqual(WorkPackage.filename(for: "   "), "FrameFold.framefold")
    }
}
