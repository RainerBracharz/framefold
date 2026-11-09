import XCTest
@testable import FrameFold

/// Faltmuster der Faltvorlage: Lage, Berg/Tal, Faltbarkeit (Maekawa).
final class FoldPatternTests: XCTestCase {
    private let rect = CGRect(x: 10, y: 20, width: 300, height: 300)

    private func inside(_ p: CGPoint) -> Bool { rect.insetBy(dx: -0.01, dy: -0.01).contains(p) }

    func testAllPatternsStayInsideTheSquare() {
        for pattern in FoldPattern.allCases {
            let creases = pattern.creases(in: rect)
            XCTAssertFalse(creases.isEmpty, "\(pattern)")
            for c in creases { XCTAssertTrue(inside(c.p0) && inside(c.p1), "\(pattern) \(c)") }
        }
    }

    func testPatternsWithMountainsAndValleys() {
        for pattern in [FoldPattern.hypar, .circularPleat, .miura] {
            let kinds = pattern.creases(in: rect).map(\.kind)
            XCTAssertTrue(kinds.contains(.mountain), "\(pattern)")
            XCTAssertTrue(kinds.contains(.valley), "\(pattern)")
            XCTAssertTrue(kinds.contains(.cut), "\(pattern)")
        }
    }

    func testHyparHasSevenPleatPairsOfSquares() {
        let c = Algorithms.concentricPleat(in: rect, segments: 4, pleats: 7)
        XCTAssertEqual(c.filter { $0.kind == .mountain }.count, 7 * 4)
        XCTAssertEqual(c.filter { $0.kind == .valley }.count, 7 * 4)
        // Außenring liegt genau auf dem Quadrat
        let cuts = c.filter { $0.kind == .cut }
        XCTAssertEqual(cuts.count, 4)
        for cut in cuts {
            for p in [cut.p0, cut.p1] {
                XCTAssertEqual(min(abs(p.x - rect.minX), abs(p.x - rect.maxX)), 0, accuracy: 1e-6)
                XCTAssertEqual(min(abs(p.y - rect.minY), abs(p.y - rect.maxY)), 0, accuracy: 1e-6)
            }
        }
    }

    func testCircularPleatCutsOuterAndInnerRing() {
        let c = Algorithms.concentricPleat(in: rect, segments: 96, pleats: 7)
        XCTAssertEqual(c.filter { $0.kind == .cut }.count, 2 * 96)
    }

    /// Jede innere Ecke des Miura-ori: vier Falten, Berg und Tal unterscheiden sich um zwei.
    func testMiuraInteriorVerticesSatisfyMaekawa() {
        let creases = Algorithms.miuraOri(in: rect, cols: 8, rows: 8).filter { $0.kind != .cut }
        func key(_ p: CGPoint) -> String { String(format: "%.4f,%.4f", p.x, p.y) }
        var count: [String: (m: Int, v: Int)] = [:]
        for c in creases {
            for p in [c.p0, c.p1] {
                var e = count[key(p)] ?? (0, 0)
                if c.kind == .mountain { e.m += 1 } else { e.v += 1 }
                count[key(p)] = e
            }
        }
        let interior = count.filter { $0.value.m + $0.value.v == 4 }
        XCTAssertEqual(interior.count, 7 * 7)
        for (_, e) in interior { XCTAssertEqual(abs(e.m - e.v), 2) }
    }

    func testRendererWritesAPdfForEveryPattern() throws {
        // Mit echtem Foto, falls vorhanden (Debug-Sandbox darf diesen Ordner lesen)
        let photo = UIImage(contentsOfFile: "/private/tmp/ff-simframes-mac/vorlage-test.jpg")
        let image = photo ?? UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        for pattern in FoldPattern.allCases {
            let url = try XCTUnwrap(FoldTemplateRenderer.render(image: image, title: "Test", pattern: pattern))
            let data = try Data(contentsOf: url)
            XCTAssertTrue(data.starts(with: Array("%PDF".utf8)), "\(pattern)")
            if photo != nil {
                let a = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
                a.name = "faltvorlage-\(pattern.rawValue).pdf"; a.lifetime = .keepAlways; add(a)
            }
        }
    }

    func testFoldGuideMapsToPatternsAndSurvivesSettingsRoundTrip() throws {
        XCTAssertNil(FoldGuide.off.pattern)
        XCTAssertEqual(FoldGuide.hypar.pattern, .hypar)
        var settings = StudioSettings()
        XCTAssertEqual(settings.foldGuide, .off)
        settings.foldGuide = .miura
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(StudioSettings.self, from: data).foldGuide, .miura)
        // Ältere gespeicherte Einstellungen ohne das Feld bleiben lesbar
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "foldGuide")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(StudioSettings.self, from: old).foldGuide, .off)
    }

    func testQuadMapSendsUnitCornersToQuadAndKeepsLinesStraight() throws {
        let quad = [CGPoint(x: 10, y: 20), CGPoint(x: 200, y: 40), CGPoint(x: 220, y: 260), CGPoint(x: 5, y: 230)]
        let map = try XCTUnwrap(Algorithms.QuadMap(quad))
        for (u, q) in zip([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], quad) {
            let p = map.map(u)
            XCTAssertEqual(p.x, q.x, accuracy: 1e-6); XCTAssertEqual(p.y, q.y, accuracy: 1e-6)
        }
        // Mitte einer Kante liegt auf der Kante (Geraden bleiben gerade)
        let m = map.map(CGPoint(x: 0.5, y: 0))
        let cross = (quad[1].x - quad[0].x) * (m.y - quad[0].y) - (quad[1].y - quad[0].y) * (m.x - quad[0].x)
        XCTAssertEqual(cross, 0, accuracy: 1e-6)
        XCTAssertNil(Algorithms.QuadMap([CGPoint.zero]))
    }

    func testFoldStepsFollowTheFoldingOrder() {
        XCTAssertEqual(FoldGuide.hypar.stepCount, 15)          // 14 Ringe, dann Diagonalen
        XCTAssertEqual(FoldGuide.circularPleat.stepCount, 14)  // 14 Ringe
        XCTAssertEqual(FoldGuide.miura.stepCount, 14)          // 7 Zickzackzeilen, 7 Senkrechte
        XCTAssertEqual(FoldGuide.off.stepCount, 0)
        // Ringe von außen nach innen, erster Ring ist eine Bergfalte
        let steps = FoldGuide.hypar.unitSteps.steps
        XCTAssertTrue(steps[0].allSatisfy { $0.kind == .mountain })
        XCTAssertTrue(steps[1].allSatisfy { $0.kind == .valley })
        func radius(_ s: [Algorithms.Crease]) -> Double { hypot(s[0].p0.x - 0.5, s[0].p0.y - 0.5) }
        for i in 1..<14 { XCTAssertGreaterThan(radius(steps[i - 1]), radius(steps[i])) }
        XCTAssertTrue(steps[14].allSatisfy { $0.kind == .facet })
        // Jede Falte kommt genau einmal vor
        let all = FoldPattern.miura.creases(in: CGRect(x: 0, y: 0, width: 1, height: 1)).filter { $0.kind != .cut }
        XCTAssertEqual(FoldGuide.miura.unitSteps.steps.flatMap { $0 }.count, all.count)
    }

    func testOverlayPlacesFittedAndFilledImages() {
        let size = CGSize(width: 400, height: 300)
        let fit = FoldGuideOverlay.imageRect(aspect: 1, in: size, fills: false)
        XCTAssertEqual(fit, CGRect(x: 50, y: 0, width: 300, height: 300))
        let fill = FoldGuideOverlay.imageRect(aspect: 1, in: size, fills: true)
        XCTAssertEqual(fill, CGRect(x: 0, y: -50, width: 400, height: 400))
    }

    /// Ein helles, schräg liegendes Blatt auf dunklem Tisch wird mit seinen Ecken gefunden.
    func testPaperDetectorFindsASheetOnTheTable() throws {
        let w = 640, h = 480
        let corners = [CGPoint(x: 180, y: 90), CGPoint(x: 470, y: 120), CGPoint(x: 450, y: 400), CGPoint(x: 160, y: 380)]
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let p = UIBezierPath(); p.move(to: corners[0]); corners.dropFirst().forEach { p.addLine(to: $0) }; p.close()
            UIColor(white: 0.92, alpha: 1).setFill(); p.fill()
        }
        let quad = try XCTUnwrap(PaperDetector.detect(in: try XCTUnwrap(image.cgImage)))
        XCTAssertEqual(quad.count, 4)
        for c in corners {
            let n = CGPoint(x: c.x / CGFloat(w), y: c.y / CGFloat(h))
            let nearest = quad.map { hypot($0.x - n.x, $0.y - n.y) }.min() ?? 1
            XCTAssertLessThan(nearest, 0.03, "Ecke \(c)")
        }
        // Leerer Tisch: kein Blatt
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        XCTAssertNil(PaperDetector.detect(in: try XCTUnwrap(empty.cgImage)))
    }
}
