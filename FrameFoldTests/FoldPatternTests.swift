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
}
