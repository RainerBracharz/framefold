//
//  WorkPackageTests.swift
//  FrameFoldTests
//
//  Werk als Datei: Ein exportiertes Werk muss vollständig wieder
//  ankommen – als Kopie, ohne Papierkorb –, und eine präparierte Datei
//  darf nichts außerhalb ihres Werkordners schreiben.
//

import XCTest
import UIKit
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

    /// Ein echtes, winziges JPEG – der Import prüft den Inhalt.
    private func jpeg(_ shade: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor(white: shade, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    func testRoundTripCreatesIndependentCopyWithoutTrash() async throws {
        let store = ProjectStore(root: root, defaults: defaults)
        var project = store.createProject(name: "Faltung / Nr. 3")
        for marker in UInt8(1)...UInt8(3) {
            _ = store.appendFrame(jpegData: jpeg(CGFloat(marker) / 4), to: store.projects.first { $0.id == project.id }!)
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

    func testManifestCannotReferenceOutsideFiles() async throws {
        let store = ProjectStore(root: root, defaults: defaults)
        let keeper = store.createProject(name: "Bleibt")
        _ = store.appendFrame(jpegData: Data([0xFF, 0xD8, 1, 0xFF, 0xD9]), to: keeper)

        // Präpariertes Manifest: Spur, Ton und Hintergrund zeigen auf „..“
        let manifest = scratch.appendingPathComponent("manifest.json")
        let json = """
        {"id":"\(UUID().uuidString)","name":"Böse","createdAtISO":"2026-10-25T00:00:00Z",
         "frameFilenames":["000000.jpg","..",""],"audioFilename":"..",
         "audioTracks":[{"id":"\(UUID().uuidString)","name":"x","filename":"..","startFrame":0,"volume":1,"muted":false}],
         "greenScreen":{"key":"green","backgroundFilename":"../.."}}
        """
        try Data(json.utf8).write(to: manifest)
        let frame = scratch.appendingPathComponent("000000.jpg")
        try jpeg(0.3).write(to: frame)
        let evil = scratch.appendingPathComponent("boese.framefold")
        try WorkPackage.write(files: [(name: "manifest.json", url: manifest), (name: "000000.jpg", url: frame)], to: evil)

        let imported = try await store.importPackage(from: evil)
        XCTAssertEqual(imported.frameFilenames, ["000000.jpg"])
        XCTAssertNil(imported.audioFilename)
        XCTAssertNil(imported.audioTracks)
        XCTAssertNil(imported.greenScreen?.backgroundFilename)

        // Auch ein Entfernen danach darf nichts außerhalb anrühren
        store.removeAudio(from: imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(keeper.id.uuidString).path))
        XCTAssertEqual(store.projects.count, 2)
    }

    func testImportClampsNumbersAndDropsBadMedia() async throws {
        let store = ProjectStore(root: root, defaults: defaults)
        let manifest = scratch.appendingPathComponent("manifest.json")
        let json = """
        {"id":"\(UUID().uuidString)","name":"Groß","createdAtISO":"2026-10-25T00:00:00Z",
         "frameFilenames":["000000.jpg","000001.jpg","000000.jpg"],"nextFrameNumber":0,
         "audioTracks":[{"id":"\(UUID().uuidString)","name":"x","filename":"spur.caf","startFrame":9223372036854775807,
                         "volume":1e300,"muted":false,"trimStart":1e300,"fadeOut":-5}],
         "overlays":[{"id":"\(UUID().uuidString)","kind":"text","firstFrame":9223372036854775807,"lastFrame":-3,
                      "x":1e300,"y":-1,"text":"Hi","size":1e300,"color":"white","strokes":[]}]}
        """
        try Data(json.utf8).write(to: manifest)
        let good = scratch.appendingPathComponent("000000.jpg")
        try jpeg(0.5).write(to: good)
        let fake = scratch.appendingPathComponent("000001.jpg")
        try Data("kein Bild".utf8).write(to: fake)
        let notAudio = scratch.appendingPathComponent("spur.caf")
        try Data("kein Ton".utf8).write(to: notAudio)
        let pkg = scratch.appendingPathComponent("gross.framefold")
        try WorkPackage.write(files: [(name: "manifest.json", url: manifest), (name: "000000.jpg", url: good),
                                      (name: "000001.jpg", url: fake), (name: "spur.caf", url: notAudio)], to: pkg)

        let imported = try await store.importPackage(from: pkg)
        XCTAssertEqual(imported.frameFilenames, ["000000.jpg"], "Kein Bild und Doppeltes fallen weg")
        XCTAssertEqual(imported.nextFrameNumber, 1, "Nächstes Bild überschreibt nichts")
        XCTAssertNil(imported.audioTracks, "Kein Ton fällt weg")
        let overlay = try XCTUnwrap(imported.overlays?.first)
        XCTAssertEqual(overlay.firstFrame, 0)
        XCTAssertEqual(overlay.lastFrame, 0)
        XCTAssertEqual(overlay.x, 1)
        XCTAssertEqual(overlay.size, 0.3)
        let dir = root.appendingPathComponent(imported.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("000001.jpg").path),
                       "Unbrauchbares bleibt draußen")

        // Ein neues Bild bekommt eine freie Nummer
        let added = store.appendFrame(jpegData: jpeg(0.9), to: store.projects.first { $0.id == imported.id }!)
        XCTAssertEqual(added, "000001.jpg")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("000000.jpg")), try jpeg(0.5))
    }

    func testPackageRejectsDuplicatesAndTrashName() throws {
        let file = scratch.appendingPathComponent("x")
        try Data("x".utf8).write(to: file)
        for names in [["a.jpg", "a.jpg"], ["trash"]] {
            let pkg = scratch.appendingPathComponent("p-\(UUID().uuidString).framefold")
            try WorkPackage.write(files: names.map { (name: $0, url: file) }, to: pkg)
            XCTAssertThrowsError(try WorkPackage.read(pkg, into: scratch.appendingPathComponent(UUID().uuidString)), "\(names)")
        }
    }

    func testSafeNames() {
        XCTAssertEqual(WorkPackage.safeName(".."), "FrameFold")
        XCTAssertEqual(WorkPackage.safeName("."), "FrameFold")
        XCTAssertEqual(WorkPackage.safeName("..geheim"), "geheim")
        XCTAssertEqual(WorkPackage.safeName(String(repeating: "a", count: 300)).count, 100)
    }

    func testUndoRestoresRemovedTrackFile() throws {
        let store = ProjectStore(root: root, defaults: defaults)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let project = store.createProject(name: "Ton")
        let sound = scratch.appendingPathComponent("ton.caf")
        try Data(repeating: 1, count: 100).write(to: sound)
        undo.beginUndoGrouping()
        let track = store.addAudioTrack(from: sound, to: project)!
        undo.endUndoGrouping()
        let fileURL = store.url(for: track, in: store.projects[0])
        undo.beginUndoGrouping()
        store.removeAudioTrack(track, from: store.projects[0])
        undo.endUndoGrouping()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        undo.undo()
        XCTAssertEqual(store.projects[0].allAudioTracks.map(\.id), [track.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Datei kommt aus dem Papierkorb zurück")
    }

    func testFilenameIsSafe() {
        XCTAssertEqual(WorkPackage.filename(for: "a/b:c"), "a-b-c.framefold")
        XCTAssertEqual(WorkPackage.filename(for: "   "), "FrameFold.framefold")
    }
}
