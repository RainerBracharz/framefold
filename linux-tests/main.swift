// Linux-Testsuite für die pure Algorithmus-Logik der App.
// Kompiliert Algorithms.swift + Models.swift mit echtem Swift (ohne Apple-
// Frameworks) und prüft alle Kernpfade. Läuft in der Cloud-Umgebung:
//   swiftc -o tests Algorithms.swift Models.swift Tests.swift && ./tests

import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("  ✓ \(name)")
    } else {
        print("  ✗ FEHLER: \(name)")
        failures += 1
    }
}

// MARK: motionScore
print("motionScore:")
check(Algorithms.motionScore([10, 20], [10, 20]) == 0, "identische Bilder → 0")
check(Algorithms.motionScore([0, 0], [10, 20]) == 15, "mittlere Differenz korrekt")
check(Algorithms.motionScore([], []) == 0, "leer → 0")
check(Algorithms.motionScore([1], [1, 2]) == 0, "ungleiche Größe → 0")

// MARK: Otsu + motionThreshold
print("otsuThreshold / motionThreshold:")
// Bimodale Verteilung wie im echten Video: Rauschen um 1, Bewegung um 20
let noise = (0..<65).map { _ in Double.random(in: 0.5...1.5) }
let movement = (0..<35).map { _ in Double.random(in: 15...25) }
let thr = Algorithms.motionThreshold(scores: noise + movement, percentile: 0.35)
check(thr > 1.5 && thr < 15, "Schwelle trennt die Cluster (\(String(format: "%.2f", thr)))")
check(Algorithms.otsuThreshold([]) == 0, "leer → 0")
check(Algorithms.otsuThreshold([3.0]) == 3.0, "ein Wert → dieser Wert")
check(Algorithms.otsuThreshold([2.0, 2.0, 2.0]) == 2.0, "konstant → dieser Wert")

// MARK: stillWindowRanges
print("stillWindowRanges:")
// 8 Ruhephasen à 6 Frames, getrennt durch Bewegungsphasen à 3 Frames
var scores: [Double] = []
for _ in 0..<8 {
    scores += Array(repeating: 0.8, count: 6)
    scores += Array(repeating: 20.0, count: 3)
}
scores.removeLast(3)
let windows = Algorithms.stillWindowRanges(motionScores: scores, threshold: 2.0, minFrames: 3)
check(windows.count == 8, "8 Ruhefenster erkannt (\(windows.count))")
check(windows.allSatisfy { $0.count == 6 }, "alle Fenster 6 Frames lang")
let tiny = Algorithms.stillWindowRanges(motionScores: [0.1, 9, 0.1], threshold: 1, minFrames: 2)
check(tiny.isEmpty, "zu kurze Fenster werden verworfen")
let all = Algorithms.stillWindowRanges(motionScores: [0.1, 0.2, 0.3], threshold: 1, minFrames: 2)
check(all == [0..<3], "durchgehend ruhig → ein Fenster bis zum Ende")

// MARK: laplacianVariance
print("laplacianVariance:")
let w = 20, h = 20
let flat = [UInt8](repeating: 128, count: w * h)
var checkered = [UInt8]()
for y in 0..<h { for x in 0..<w { checkered.append((x + y) % 2 == 0 ? 0 : 255) } }
let sharpFlat = Algorithms.laplacianVariance(gray: flat, width: w, height: h)
let sharpChecker = Algorithms.laplacianVariance(gray: checkered, width: w, height: h)
check(sharpFlat == 0, "homogenes Bild → Schärfe 0")
check(sharpChecker > sharpFlat, "Kanten → höhere Schärfe")
check(Algorithms.laplacianVariance(gray: [1, 2], width: 2, height: 1) == 0, "zu klein → 0")

// MARK: dHash + hamming
print("dHash / hammingDistance:")
var gradient = [UInt8]()
for _ in 0..<h { for x in 0..<w { gradient.append(UInt8(x * 12)) } }
var gradientR = [UInt8]()
for _ in 0..<h { for x in 0..<w { gradientR.append(UInt8(255 - x * 12)) } }
let h1 = Algorithms.dHash(gray: gradient, width: w, height: h)
let h2 = Algorithms.dHash(gray: gradient, width: w, height: h)
let h3 = Algorithms.dHash(gray: gradientR, width: w, height: h)
check(h1 == h2, "gleiches Bild → gleicher Hash")
check(Algorithms.hammingDistance(h1, h2) == 0, "Distanz zu sich selbst 0")
check(Algorithms.hammingDistance(h1, h3) > 30, "gegenläufige Gradienten → große Distanz")
check(Algorithms.dHash(gray: [], width: 0, height: 0) == 0, "leer → 0")

// MARK: cropRect
print("cropRect:")
for (iw, ih) in [(3840, 2160), (2160, 3840), (1920, 1080), (1080, 1920)] {
    for (name, ratio) in [("9:16", 9.0/16.0), ("1:1", 1.0), ("16:9", 16.0/9.0)] {
        let r = Algorithms.cropRect(imageWidth: iw, imageHeight: ih, targetRatio: ratio)
        let ok = r.minX >= 0 && r.minY >= 0
            && r.maxX <= Double(iw) + 1e-9 && r.maxY <= Double(ih) + 1e-9
            && abs(r.width / r.height - ratio) < 1e-9
            && abs(r.midX - Double(iw) / 2) < 1e-9
            && abs(r.midY - Double(ih) / 2) < 1e-9
        check(ok, "\(iw)x\(ih) → \(name) zentriert & maßhaltig")
    }
}
let orig = Algorithms.cropRect(imageWidth: 100, imageHeight: 50, targetRatio: nil)
check(orig == CGRect(x: 0, y: 0, width: 100, height: 50), "nil-Ratio → Original")

// MARK: LoopMode.frameOrder (aus Models.swift)
print("LoopMode.frameOrder:")
check(LoopMode.none.frameOrder(count: 5) == [0, 1, 2, 3, 4], "Normal")
check(LoopMode.reverse.frameOrder(count: 5) == [4, 3, 2, 1, 0], "Rückwärts")
check(LoopMode.boomerang.frameOrder(count: 5) == [0, 1, 2, 3, 4, 3, 2, 1], "Boomerang ohne Doppel-Endpunkte")
check(LoopMode.boomerang.frameOrder(count: 2) == [0, 1], "Boomerang bei 2 Frames")
check(LoopMode.boomerang.frameOrder(count: 1) == [0], "Boomerang bei 1 Frame")

// MARK: renderPlan (Falz-Blende)
print("renderPlan:")
let planNone = Algorithms.renderPlan(order: [0, 1, 2], transitionFrames: 0)
check(planNone.count == 3, "ohne Blende: 1 Schritt pro Frame")
check(planNone.allSatisfy { $0.overlayIndex == nil }, "ohne Blende: keine Overlays")
let plan2 = Algorithms.renderPlan(order: [0, 1, 2], transitionFrames: 2)
check(plan2.count == 3 + 2 * 2, "2 Blendenframes pro Übergang (\(plan2.count))")
check(plan2[0] == Algorithms.RenderStep(baseIndex: 0, overlayIndex: nil, progress: 0), "Start = purer Frame")
check(plan2[1].overlayIndex == 1 && abs(plan2[1].progress - 1.0/3.0) < 1e-9, "1. Blende: Overlay 1, t=1/3")
check(plan2[2].overlayIndex == 1 && abs(plan2[2].progress - 2.0/3.0) < 1e-9, "2. Blende: t=2/3")
check(plan2.last == Algorithms.RenderStep(baseIndex: 2, overlayIndex: nil, progress: 0), "Ende = purer letzter Frame")
check(plan2.filter { $0.overlayIndex == nil }.map(\.baseIndex) == [0, 1, 2], "alle Keyframes erhalten")
let planBoom = Algorithms.renderPlan(order: LoopMode.boomerang.frameOrder(count: 4), transitionFrames: 1)
check(planBoom.count == 6 + 5, "Boomerang(4) + Blende(1): 11 Schritte (\(planBoom.count))")
check(Algorithms.renderPlan(order: [], transitionFrames: 2).isEmpty, "leer → leer")
check(Algorithms.renderPlan(order: [7], transitionFrames: 3).count == 1, "1 Frame → keine Blende")

// MARK: foldRevealLegs
print("foldRevealLegs:")
let l0 = Algorithms.foldRevealLegs(progress: 0, width: 100, height: 50)
let l1 = Algorithms.foldRevealLegs(progress: 1, width: 100, height: 50)
let lHalf = Algorithms.foldRevealLegs(progress: 0.5, width: 100, height: 50)
check(l0.lx == 0 && l0.ly == 0, "t=0 → nichts aufgedeckt")
check(l1.lx == 200 && l1.ly == 100, "t=1 → Dreieck deckt Rechteck (Ecke (w,h) liegt auf Hypotenuse)")
check(lHalf.lx == 100 && lHalf.ly == 50, "t=0.5 → Diagonale erreicht")
check(Algorithms.foldRevealLegs(progress: 2, width: 10, height: 10).lx == 20, "progress wird auf 1 begrenzt")
check(Algorithms.foldRevealLegs(progress: -1, width: 10, height: 10).lx == 0, "progress wird auf 0 begrenzt")

// MARK: contactSheetLayout
print("contactSheetLayout:")
let sheets = Algorithms.contactSheetLayout(
    count: 23, pageWidth: 595.2, pageHeight: 841.8,
    margin: 40, gutter: 6, columns: 4, captionHeight: 46)
let allRects = sheets.flatMap { $0 }
check(allRects.count == 23, "alle 23 Zellen platziert (\(allRects.count))")
check(sheets.count >= 1, "mindestens eine Seite")
check(allRects.allSatisfy {
    $0.minX >= 40 - 1e-9 && $0.maxX <= 595.2 - 40 + 1e-9 &&
    $0.minY >= 40 + 46 - 1e-9 && $0.maxY <= 841.8 - 40 + 1e-9
}, "alle Zellen innerhalb Satzspiegel + Kopfzeile")
check(allRects.allSatisfy { abs($0.width - $0.height) < 1e-9 }, "Zellen quadratisch")
// keine Überlappung auf der ersten Seite
var overlap = false
let first = sheets[0]
for i in 0..<first.count {
    for j in (i+1)..<first.count where first[i].intersects(first[j]) {
        overlap = true
    }
}
check(!overlap, "keine Überlappungen")
check(Algorithms.contactSheetLayout(count: 0, pageWidth: 595, pageHeight: 842,
                                    margin: 40, gutter: 6, columns: 4,
                                    captionHeight: 46).isEmpty, "0 Frames → leer")
// viele Frames → mehrere Seiten, vollständig
let big = Algorithms.contactSheetLayout(count: 100, pageWidth: 595.2, pageHeight: 841.8,
                                        margin: 40, gutter: 6, columns: 4, captionHeight: 46)
check(big.flatMap { $0 }.count == 100, "100 Frames vollständig auf \(big.count) Seiten")

// MARK: estimateTranslation (Verwacklungs-Korrektur)
print("estimateTranslation:")
// Referenzbild mit Struktur (Gradient + Block), current = um (dx,dy) verschoben.
func shifted(_ ref: [UInt8], w: Int, h: Int, dx: Int, dy: Int) -> [UInt8] {
    // current[x+dx, y+dy] == reference[x,y]  ⇒  current[cx,cy] = reference[cx-dx, cy-dy]
    var out = [UInt8](repeating: 0, count: w * h)
    for cy in 0..<h {
        for cx in 0..<w {
            let rx = cx - dx, ry = cy - dy
            if rx >= 0, rx < w, ry >= 0, ry < h {
                out[cy * w + cx] = ref[ry * w + rx]
            }
        }
    }
    return out
}
let rw = 60, rh = 40
var refImg = [UInt8](repeating: 0, count: rw * rh)
for y in 0..<rh { for x in 0..<rw {
    var v = (x * 3 + y * 5) % 256
    if x >= 20 && x < 30 && y >= 12 && y < 22 { v = 240 }   // Kontrastblock
    refImg[y * rw + x] = UInt8(v)
}}
for (tdx, tdy) in [(0,0),(3,0),(0,2),(4,3),(-3,2),(-5,-4),(6,-2)] {
    let cur = shifted(refImg, w: rw, h: rh, dx: tdx, dy: tdy)
    let (dx, dy) = Algorithms.estimateTranslation(
        reference: refImg, current: cur, width: rw, height: rh, maxShift: 8, sampleStep: 1)
    check(dx == tdx && dy == tdy, "Verschiebung (\(tdx),\(tdy)) korrekt erkannt → (\(dx),\(dy))")
}
// identische Bilder → keine Verschiebung
let (zx, zy) = Algorithms.estimateTranslation(
    reference: refImg, current: refImg, width: rw, height: rh, maxShift: 6)
check(zx == 0 && zy == 0, "identisch → (0,0)")
// Fehlerfälle
check(Algorithms.estimateTranslation(reference: [], current: [], width: 0, height: 0, maxShift: 4) == (0,0),
      "leer → (0,0)")

// MARK: Facetten-Übergang
print("facetPlan / facetAlpha:")
let facets = Algorithms.facetPlan(width: 600, height: 400, cols: 6, rows: 6)
check(facets.count == 6 * 6 * 2, "6×6 Zellen → 72 Facetten (\(facets.count))")
check(facets.allSatisfy { $0.phase >= 0 && $0.phase <= 1 }, "alle Phasen in [0,1]")
check(facets.first!.phase == 0, "erste Facette (oben links) Phase 0")
check(facets.last!.phase == 1, "letzte Facette (unten rechts) Phase 1")
check(Algorithms.facetAlpha(phase: 0.5, progress: 0.4) == 0, "Fortschritt vor Phase → 0")
check(Algorithms.facetAlpha(phase: 0.5, progress: 0.5) == 0, "genau an der Phase → 0")
check(Algorithms.facetAlpha(phase: 0.5, progress: 1.0) == 1, "weit danach → 1 (geklammert)")
check(abs(Algorithms.facetAlpha(phase: 0.5, progress: 0.64, feather: 0.28) - 0.5) < 0.01, "weiche Kante linear")
check(Algorithms.facetPlan(width: 0, height: 10, cols: 4, rows: 4).isEmpty, "0-Breite → leer")

// MARK: Faltvorlage-Linien
print("foldTemplateLines:")
let fr = CGRect(x: 10, y: 20, width: 200, height: 300)
let flines = Algorithms.foldTemplateLines(rect: fr, cols: 4, rows: 5)
check(flines.filter { $0.cut }.count == 4, "4 Schnittkanten (Rahmen)")
check(flines.contains { !$0.cut }, "innere Falzlinien vorhanden")
check(flines.allSatisfy {
    $0.p0.x >= fr.minX - 1e-9 && $0.p0.x <= fr.maxX + 1e-9 &&
    $0.p1.x >= fr.minX - 1e-9 && $0.p1.x <= fr.maxX + 1e-9 &&
    $0.p0.y >= fr.minY - 1e-9 && $0.p0.y <= fr.maxY + 1e-9 &&
    $0.p1.y >= fr.minY - 1e-9 && $0.p1.y <= fr.maxY + 1e-9
}, "alle Linien innerhalb des Bildrahmens")
// 4 Schnitt + 3 Senkrechte + 4 Waagrechte + 20 Diagonalen = 31
check(flines.count == 4 + 3 + 4 + 20, "Linienzahl stimmt (\(flines.count))")

// MARK: Reel-Bildzahl
print("reelFrameCount:")
check(Algorithms.reelFrameCount(frameCounts: [10, 20, 5], titleHold: 12) == 35 + 36, "Frames + Titelkarten je Werk")
check(Algorithms.reelFrameCount(frameCounts: [], titleHold: 12) == 0, "keine Werke → 0")
check(Algorithms.reelFrameCount(frameCounts: [8], titleHold: 0) == 8, "ohne Titelkarte → nur Frames")

// MARK: Ende-zu-Ende: synthetisches Video als Zahlenfolge
print("Ende-zu-Ende (synthetische Sequenz):")
// 8 Szenen: Ruhe (Rauschen ~1) und Übergänge (~20), wie make_test_video.py
var e2eScores: [Double] = []
var rng = SystemRandomNumberGenerator()
for _ in 0..<8 {
    e2eScores += (0..<6).map { _ in Double.random(in: 0.5...1.5, using: &rng) }
    e2eScores += (0..<4).map { _ in Double.random(in: 15...25, using: &rng) }
}
e2eScores.removeLast(4)
let e2eThr = Algorithms.motionThreshold(scores: e2eScores, percentile: 0.35)
let e2eWindows = Algorithms.stillWindowRanges(motionScores: e2eScores, threshold: e2eThr, minFrames: 3)
check(e2eWindows.count == 8, "Otsu + Fensterung findet 8/8 Szenen (\(e2eWindows.count))")

print("")
if failures == 0 {
    print("ALLE TESTS BESTANDEN ✓")
    exit(0)
} else {
    print("\(failures) TEST(S) FEHLGESCHLAGEN ✗")
    exit(1)
}
