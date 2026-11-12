//
//  FoldSequenceTests.swift
//  FrameFoldTests
//
//  Geführte Faltfolgen: Das Faltmodell muss Flächen und Lagen richtig
//  führen, sonst vergleicht die Kamera mit einem falschen Umriss.
//

import XCTest
@testable import FrameFold

final class FoldSequenceTests: XCTestCase {

    private func area(_ faces: [FoldSequence.Face]) -> Double {
        FoldSequence.mask(of: faces, size: 96).area
    }

    func testFlatSheetCoversOneSheetArea() {
        let states = FoldSequence.letter.states
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(area(states[0]), 1, accuracy: 0.03)
    }

    func testDiagonalFoldHalvesTheOutline() {
        let states = FoldSequence.dog.states
        XCTAssertEqual(area(states[1]), 0.5, accuracy: 0.03)
        // Zwei Lagen, die bewegte liegt oben
        XCTAssertEqual(states[1].count, 2)
        XCTAssertEqual(Set(states[1].map(\.layer)), [0, 1])
    }

    func testLetterFoldsToAThird() {
        let states = FoldSequence.letter.states
        XCTAssertEqual(area(states[1]), 2.0 / 3, accuracy: 0.03)
        XCTAssertEqual(area(states[2]), 1.0 / 3, accuracy: 0.03)
        // Drei Lagen übereinander, jede in eigener Höhe
        XCTAssertEqual(Set(states[2].map(\.layer)).count, 3)
    }

    func testPaperIsNeitherCreatedNorLost() {
        // Die Summe der Lagenflächen bleibt bei jeder Faltung ein Blatt.
        func polygonArea(_ p: [CGPoint]) -> Double {
            var twice = 0.0
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                twice += Double(a.x * b.y - b.x * a.y)
            }
            return abs(twice) / 2
        }
        for sequence in FoldSequence.all {
            for state in sequence.states {
                XCTAssertEqual(state.map { polygonArea($0.polygon) }.reduce(0, +), 1, accuracy: 1e-6,
                               "\(sequence.id)")
            }
        }
    }

    func testCupFlapsEndOnTheOppositeEdges() {
        // Nach den beiden Eckfalten liegt alles Papier im Dreieck des ersten Schritts.
        let states = FoldSequence.cup.states
        let triangle = FoldSequence.mask(of: states[1], size: 96)
        let folded = FoldSequence.mask(of: states[3], size: 96)
        let outside = zip(folded.cells, triangle.cells).filter { $0 && !$1 }.count
        XCTAssertLessThan(Double(outside) / Double(folded.cells.count), 0.005)
        XCTAssertLessThan(folded.area, triangle.area)
    }

    func testFrontFlapDoesNotChangeTheOutlineButTheBackFlapDoes() {
        let cup = FoldSequence.cup
        XCTAssertTrue(cup.isVerifiable(step: 0))
        XCTAssertTrue(cup.isVerifiable(step: 1))
        XCTAssertTrue(cup.isVerifiable(step: 2))
        XCTAssertFalse(cup.isVerifiable(step: 3), "vordere Klappe: hintere Lage bleibt stehen")
        XCTAssertTrue(cup.isVerifiable(step: 4))
        // Die hintere Klappe liegt nach der Bergfalte unter allem.
        let last = cup.states[5]
        let lowest = last.map(\.layer).min()
        XCTAssertNotNil(lowest)
        XCTAssertLessThan(lowest ?? 0, 0)
    }

    func testEveryStepOfLetterAndDogIsVerifiable() {
        for sequence in [FoldSequence.letter, .dog] {
            for index in sequence.steps.indices {
                XCTAssertTrue(sequence.isVerifiable(step: index), "\(sequence.id) Schritt \(index)")
            }
        }
    }

    func testObservedOutlineConfirmsOnlyTheFoldedStep() {
        let dog = FoldSequence.dog
        let states = dog.states
        let flat = FoldSequence.mask(of: states[0])
        let triangle = FoldSequence.mask(of: states[1])
        XCTAssertFalse(dog.isFolded(step: 0, observed: flat), "flaches Blatt ist noch kein Dreieck")
        XCTAssertTrue(dog.isFolded(step: 0, observed: triangle))
        XCTAssertFalse(dog.isFolded(step: 1, observed: triangle), "das erste Ohr fehlt noch")
        XCTAssertTrue(dog.isFolded(step: 1, observed: FoldSequence.mask(of: states[2])))
    }

    func testSlightlyShiftedPaperStillMatches() {
        // Das Blatt liegt nie genau: zwei Prozent Versatz dürfen nicht stören.
        let cup = FoldSequence.cup
        let folded = cup.states[1]
        let shifted = folded.map { face in
            FoldSequence.Face(polygon: face.polygon.map { CGPoint(x: $0.x + 0.02, y: $0.y - 0.02) }, layer: face.layer)
        }
        XCTAssertTrue(cup.isFolded(step: 0, observed: FoldSequence.mask(of: shifted)))
    }
}
