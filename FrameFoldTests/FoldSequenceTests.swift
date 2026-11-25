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

    // MARK: Umriss aus dem Kamerabild

    /// Tisch dunkel, Papier hell; `faces` in Blattkoordinaten auf dem Viereck `quad`.
    private func picture(_ faces: [FoldSequence.Face], quad: CGRect, size: CGSize = CGSize(width: 320, height: 240)) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.92, alpha: 1).setFill()
            for face in faces {
                let path = UIBezierPath()
                for (i, p) in face.polygon.enumerated() {
                    let q = CGPoint(x: quad.minX + p.x * quad.width, y: quad.minY + p.y * quad.height)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                path.close()
                path.fill()
            }
        }.cgImage!
    }

    func testCameraOutlineFollowsTheFoldedPaper() throws {
        let dog = FoldSequence.dog
        let states = dog.states
        let sheet = CGRect(x: 110, y: 70, width: 100, height: 100)
        let quad = [CGPoint(x: 110.0 / 320, y: 70.0 / 240), CGPoint(x: 210.0 / 320, y: 70.0 / 240),
                    CGPoint(x: 210.0 / 320, y: 170.0 / 240), CGPoint(x: 110.0 / 320, y: 170.0 / 240)]
        let reference = try XCTUnwrap(FoldReference(frame: picture(states[0], quad: sheet), quad: quad))

        let flat = try XCTUnwrap(reference.mask(of: picture(states[0], quad: sheet)))
        XCTAssertEqual(flat.area, 1, accuracy: 0.08)
        XCTAssertFalse(dog.isFolded(step: 0, observed: flat))

        let triangle = try XCTUnwrap(reference.mask(of: picture(states[1], quad: sheet)))
        XCTAssertEqual(triangle.area, 0.5, accuracy: 0.06)
        XCTAssertTrue(dog.isFolded(step: 0, observed: triangle))
        XCTAssertFalse(dog.isFolded(step: 1, observed: triangle))
    }

    func testEverySequenceIsConfirmedStepByStepFromThePicture() throws {
        // Der ganze Weg wie in der Kamera: Bild → Umriss → Prüfung, für alle Folgen.
        let sheet = CGRect(x: 110, y: 70, width: 100, height: 100)
        let quad = [CGPoint(x: 110.0 / 320, y: 70.0 / 240), CGPoint(x: 210.0 / 320, y: 70.0 / 240),
                    CGPoint(x: 210.0 / 320, y: 170.0 / 240), CGPoint(x: 110.0 / 320, y: 170.0 / 240)]
        for sequence in FoldSequence.all {
            let states = sequence.states
            let reference = try XCTUnwrap(FoldReference(frame: picture(states[0], quad: sheet), quad: quad))
            for index in sequence.steps.indices where sequence.isVerifiable(step: index) {
                let before = try XCTUnwrap(reference.mask(of: picture(states[index], quad: sheet)))
                let after = try XCTUnwrap(reference.mask(of: picture(states[index + 1], quad: sheet)))
                XCTAssertFalse(sequence.isFolded(step: index, observed: before), "\(sequence.id) Schritt \(index): noch nicht gefaltet")
                XCTAssertTrue(sequence.isFolded(step: index, observed: after), "\(sequence.id) Schritt \(index): gefaltet")
            }
        }
    }

    func testStepLabelSaysWhenTheCameraDoesNotCheck() {
        let quad = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.3, y: 0.7)]
        let checked = FoldGuideOverlay.label(guide: .cup, paperQuad: quad, step: 4, checked: true)
        let unchecked = FoldGuideOverlay.label(guide: .cup, paperQuad: quad, step: 4, checked: false)
        XCTAssertNotEqual(checked, unchecked)
        // Vor dem ersten Bild steht nur der Name, ohne Schrittzahl.
        XCTAssertEqual(FoldGuideOverlay.label(guide: .cup, paperQuad: quad, step: 0, checked: false), FoldGuide.cup.label)
        // Gewöhnliche Faltmuster kennen keine Prüfung.
        XCTAssertEqual(FoldGuideOverlay.label(guide: .hypar, paperQuad: quad, step: 1, checked: false),
                       FoldGuideOverlay.label(guide: .hypar, paperQuad: quad, step: 1, checked: true))
    }

    func testPaperInTableColourGivesNoReference() {
        // Lässt sich das Papier nicht vom Tisch trennen, gibt es keine Prüfung –
        // die Kamera löst dann wie gewohnt aus.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let plain = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }.cgImage!
        let quad = [CGPoint(x: 0.35, y: 0.3), CGPoint(x: 0.65, y: 0.3), CGPoint(x: 0.65, y: 0.7), CGPoint(x: 0.35, y: 0.7)]
        XCTAssertNil(FoldReference(frame: plain, quad: quad))
    }

    // MARK: Faltmuster auf dem flachen Blatt

    private func mid(_ c: FoldSequence.Crease) -> CGPoint {
        CGPoint(x: (c.a.x + c.b.x) / 2, y: (c.a.y + c.b.y) / 2)
    }

    func testLetterLeavesTwoHorizontalCreases() {
        let creases = FoldSequence.letter.creases
        XCTAssertEqual(creases.count, 2)
        for (step, y) in [(0, 2.0 / 3), (1, 1.0 / 3)] {
            XCTAssertEqual(creases[step].count, 1)
            let c = creases[step][0]
            XCTAssertEqual(c.a.y, y, accuracy: 1e-6)
            XCTAssertEqual(c.b.y, y, accuracy: 1e-6)
            XCTAssertEqual(abs(c.b.x - c.a.x), 1, accuracy: 1e-6, "über die ganze Breite")
            XCTAssertEqual(c.kind, .valley)
        }
    }

    func testDogFirstCreaseIsTheDiagonal() {
        let first = FoldSequence.dog.creases[0]
        XCTAssertEqual(first.count, 1)
        let c = first[0]
        let ends = Set([c.a, c.b].map { "\(Int(($0.x * 1000).rounded())),\(Int(($0.y * 1000).rounded()))" })
        XCTAssertEqual(ends, ["1000,0", "0,1000"])
        XCTAssertEqual(FoldSequence.dog.creases.count, 4)
        // Ohren und Schnauze liegen auf dem Blatt, nicht außerhalb
        for crease in FoldSequence.dog.creases.flatMap({ $0 }) {
            for p in [crease.a, crease.b] {
                XCTAssertTrue((-1e-6...1 + 1e-6).contains(p.x) && (-1e-6...1 + 1e-6).contains(p.y))
            }
        }
    }

    func testCupFlapsLandOnDifferentHalves() {
        let creases = FoldSequence.cup.creases
        XCTAssertEqual(creases.count, 5)
        XCTAssertEqual(creases[3].count, 1, "nur die vordere Klappe")
        XCTAssertEqual(creases[4].count, 1, "nur die hintere Klappe")
        let front = mid(creases[3][0]), back = mid(creases[4][0])
        // Die Diagonale (0,0)–(1,1) trennt die Blatthälften: Die vordere Klappe
        // stammt aus der umgelegten unteren Hälfte, die hintere aus der oberen.
        XCTAssertGreaterThan(front.y - front.x, 0)
        XCTAssertLessThan(back.y - back.x, 0)
        // Beide Klappen zeigen auf der Vorderseite als Bergfalte
        XCTAssertEqual(creases[3][0].kind, .mountain)
        XCTAssertEqual(creases[4][0].kind, .mountain)
    }

    func testFoldingKeepsTheSheetMapping() {
        // Jede Lage bildet über toSheet wieder auf das Blatt ab
        for sequence in FoldSequence.all {
            for face in sequence.states.last! {
                for p in face.polygon.map({ $0.applying(face.toSheet) }) {
                    XCTAssertTrue((-1e-6...1 + 1e-6).contains(p.x) && (-1e-6...1 + 1e-6).contains(p.y), sequence.id)
                }
            }
        }
    }
}
