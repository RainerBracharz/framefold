//
//  FirstRunTests.swift
//  FrameFoldTests
//
//  Beispielwerk beim ersten Start und Zeitpunkt der Bewertungsabfrage.
//

import XCTest
@testable import FrameFold

final class FirstRunTests: XCTestCase {

    func testReviewAsksAtThirdAndTenthFilmOncePerVersion() throws {
        let suite = "ff-review-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let asks = (1...12).map { _ in ReviewPrompt.noteFinishedFilm(defaults: defaults, version: "2.6") }
        XCTAssertEqual(asks.enumerated().filter(\.element).map { $0.offset + 1 }, [3],
                       "in derselben Version nur einmal")
        defaults.set(0, forKey: "finishedFilms")
        let next = (1...10).map { _ in ReviewPrompt.noteFinishedFilm(defaults: defaults, version: "2.7") }
        XCTAssertEqual(next.enumerated().filter(\.element).map { $0.offset + 1 }, [3])
    }

    @MainActor
    func testSampleWorkIsCreatedOnceAndOnlyWhenEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-sample-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ff-sample-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: root, defaults: defaults)
        store.createSampleIfNeeded()
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects.first?.frameCount, 22)
        // Gelöscht bleibt gelöscht – kein neues Beispiel beim nächsten Start
        store.delete(store.projects[0])
        store.createSampleIfNeeded()
        XCTAssertTrue(store.projects.isEmpty)

        // Wer schon Werke hat, bekommt keins
        let suite2 = "ff-sample2-\(UUID().uuidString)"
        let defaults2 = try XCTUnwrap(UserDefaults(suiteName: suite2))
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let store2 = ProjectStore(root: root.appendingPathComponent("b"), defaults: defaults2)
        _ = store2.createProject(name: "Eigenes")
        store2.createSampleIfNeeded()
        XCTAssertEqual(store2.projects.map(\.name), ["Eigenes"])
    }
}
