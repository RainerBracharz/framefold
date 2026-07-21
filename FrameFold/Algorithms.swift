import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Die komplette pure Algorithmus-Logik der App – bewusst ohne Apple-
/// Framework-Abhängigkeiten, damit sie auf Linux kompiliert und getestet
/// werden kann (siehe linux-tests/ im Paket). FrameAnalyzer, KeyframeSelector
/// und StopMotionAssembler delegieren hierher.
enum Algorithms {

    // MARK: Bewegungsanalyse

    /// Mittlere absolute Graustufendifferenz zweier gleich großer Bilder.
    static func motionScore(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    /// 1D-Otsu (128 Bins): trennt den Ruhe-Cluster (Sensorrauschen)
    /// vom Bewegungs-Cluster (Hände/Objektbewegung).
    static func otsuThreshold(_ values: [Double], bins: Int = 128) -> Double {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return values.first ?? 0
        }
        var hist = [Int](repeating: 0, count: bins)
        let scale = Double(bins) / (hi - lo)
        for v in values {
            let b = min(bins - 1, Int((v - lo) * scale))
            hist[b] += 1
        }
        let centers = (0..<bins).map { lo + (Double($0) + 0.5) * (hi - lo) / Double(bins) }
        let total = Double(values.count)
        let totalMean = zip(hist, centers).reduce(0.0) { $0 + Double($1.0) * $1.1 } / total

        // Bei klar getrennten Clustern ist die Zwischenklassen-Varianz auf
        // einem ganzen Plateau leerer Bins maximal. Wir nehmen die MITTE
        // des Plateaus (nicht den ersten Treffer), damit die Schwelle in der
        // Lücke zwischen Ruhe- und Bewegungs-Cluster liegt statt direkt an
        // der Rauschkante. (Von der CI auf macOS aufgedeckt.)
        var bestVar = -1.0
        var firstBest = 0, lastBest = 0
        var w0 = 0.0, sum0 = 0.0
        for i in 0..<(bins - 1) {
            w0 += Double(hist[i])
            guard w0 > 0 else { continue }
            let w1 = total - w0
            guard w1 > 0 else { break }
            sum0 += Double(hist[i]) * centers[i]
            let m0 = sum0 / w0
            let m1 = (totalMean * total - sum0) / w1
            let between = w0 * w1 * (m0 - m1) * (m0 - m1)
            if between > bestVar {
                bestVar = between
                firstBest = i
                lastBest = i
            } else if between == bestVar {
                lastBest = i
            }
        }
        return centers[(firstBest + lastBest) / 2]
    }

    /// Adaptive Schwelle: Otsu mit Perzentil-Untergrenze (Empfindlichkeits-Regler).
    static func motionThreshold(scores: [Double], percentile: Double) -> Double {
        guard !scores.isEmpty else { return 0 }
        let sorted = scores.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * percentile)))
        return max(otsuThreshold(scores), sorted[idx])
    }

    /// Zerlegt eine Motion-Score-Folge in Ruhefenster (Index-Bereiche).
    static func stillWindowRanges(
        motionScores: [Double], threshold: Double, minFrames: Int
    ) -> [Range<Int>] {
        var windows: [Range<Int>] = []
        var start: Int? = nil
        for (i, score) in motionScores.enumerated() {
            if score <= threshold {
                if start == nil { start = i }
            } else {
                if let s = start, i - s >= minFrames { windows.append(s..<i) }
                start = nil
            }
        }
        if let s = start, motionScores.count - s >= minFrames {
            windows.append(s..<motionScores.count)
        }
        return windows
    }

    // MARK: Schärfe & Hashing

    /// Laplacian-Varianz als Schärfemaß (höher = schärfer).
    static func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count == width * height else { return 0 }
        var values: [Double] = []
        values.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let lap = -4.0 * Double(gray[idx])
                    + Double(gray[idx - 1]) + Double(gray[idx + 1])
                    + Double(gray[idx - width]) + Double(gray[idx + width])
                values.append(lap)
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// dHash (difference hash): 64-Bit-Hash aus 9x8-Verkleinerung.
    static func dHash(gray: [UInt8], width: Int, height: Int) -> UInt64 {
        guard width > 0, height > 0, gray.count == width * height else { return 0 }
        let hw = 9, hh = 8
        var small = [UInt8](repeating: 0, count: hw * hh)
        for y in 0..<hh {
            for x in 0..<hw {
                let sx = min(width - 1, x * width / hw)
                let sy = min(height - 1, y * height / hh)
                small[y * hw + x] = gray[sy * width + sx]
            }
        }
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<hh {
            for x in 0..<(hw - 1) {
                if small[y * hw + x] > small[y * hw + x + 1] {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: Render-Plan (Falz-Blende & Reihenfolge)

    /// Ein Schritt des Render-Plans: Basis-Frame, optional ein Overlay-Frame,
    /// der per Falz-Blende (progress 0..1) aufgedeckt wird.
    struct RenderStep: Equatable {
        let baseIndex: Int
        let overlayIndex: Int?
        let progress: Double
    }

    /// Baut aus der Abspielreihenfolge den Render-Plan.
    /// transitionFrames = Zahl der Zwischenframes pro Übergang (0 = harte Schnitte).
    static func renderPlan(order: [Int], transitionFrames: Int) -> [RenderStep] {
        guard !order.isEmpty else { return [] }
        var steps: [RenderStep] = []
        for (i, index) in order.enumerated() {
            steps.append(RenderStep(baseIndex: index, overlayIndex: nil, progress: 0))
            if transitionFrames > 0, i < order.count - 1 {
                let next = order[i + 1]
                for k in 1...transitionFrames {
                    let t = Double(k) / Double(transitionFrames + 1)
                    steps.append(RenderStep(baseIndex: index, overlayIndex: next, progress: t))
                }
            }
        }
        return steps
    }

    /// Falz-Blende: Der neue Frame wird von der linken oberen Ecke her
    /// entlang einer Diagonale aufgedeckt – wie ein umgeschlagenes Blatt.
    /// Liefert die Schenkellängen des Aufdeck-Dreiecks (0,0)-(lx,0)-(0,ly).
    /// Bei progress 1 deckt das Dreieck (2w, 2h) das gesamte Rechteck ab.
    static func foldRevealLegs(progress: Double, width: Double, height: Double) -> (lx: Double, ly: Double) {
        let t = max(0, min(1, progress))
        return (2 * width * t, 2 * height * t)
    }

    // MARK: Facetten-Übergang (trianguliert – nach Tolinos Faltstruktur)

    /// Ein dreieckiges Facettenfeld mit „Phase" (0..1) = Zeitpunkt im Übergang,
    /// zu dem die Facette umklappt (diagonal gestaffelt von oben links).
    struct Facet: Equatable {
        let a: CGPoint; let b: CGPoint; let c: CGPoint
        let phase: Double
    }

    /// Zerlegt eine Fläche in cols×rows Zellen, je zwei Dreiecke – jede Facette
    /// bekommt eine diagonale Phase, sodass die Faltung wie eine Welle läuft.
    static func facetPlan(width: Double, height: Double, cols: Int, rows: Int) -> [Facet] {
        guard cols > 0, rows > 0, width > 0, height > 0 else { return [] }
        var facets: [Facet] = []
        let cw = width / Double(cols), ch = height / Double(rows)
        let maxIdx = Double((cols - 1) + (rows - 1))
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = Double(c) * cw, y0 = Double(r) * ch
                let x1 = x0 + cw, y1 = y0 + ch
                let phase = maxIdx > 0 ? Double(c + r) / maxIdx : 0
                facets.append(Facet(a: CGPoint(x: x0, y: y0), b: CGPoint(x: x1, y: y0),
                                    c: CGPoint(x: x0, y: y1), phase: phase))
                facets.append(Facet(a: CGPoint(x: x1, y: y0), b: CGPoint(x: x1, y: y1),
                                    c: CGPoint(x: x0, y: y1), phase: phase))
            }
        }
        return facets
    }

    /// Deckkraft einer Facette bei gegebenem Fortschritt (weiche Kante).
    static func facetAlpha(phase: Double, progress: Double, feather: Double = 0.28) -> Double {
        guard feather > 0 else { return progress >= phase ? 1 : 0 }
        return max(0, min(1, (progress - phase) / feather))
    }

    // MARK: Faltvorlage (druckbares Falzmuster)

    struct FoldLine: Equatable { let p0: CGPoint; let p1: CGPoint; let cut: Bool }

    /// Falzlinien für die Druckvorlage: Außenkante als Schnittlinie (cut=true),
    /// innen ein trianguliertes Falzraster (cut=false) zum Nachfalten.
    static func foldTemplateLines(rect: CGRect, cols: Int, rows: Int) -> [FoldLine] {
        guard cols > 0, rows > 0, rect.width > 0, rect.height > 0 else { return [] }
        var lines: [FoldLine] = []
        let x0 = rect.minX, y0 = rect.minY, w = rect.width, h = rect.height
        let cw = w / Double(cols), ch = h / Double(rows)

        // Außenkante (Schnitt)
        lines.append(FoldLine(p0: CGPoint(x: x0, y: y0), p1: CGPoint(x: x0 + w, y: y0), cut: true))
        lines.append(FoldLine(p0: CGPoint(x: x0 + w, y: y0), p1: CGPoint(x: x0 + w, y: y0 + h), cut: true))
        lines.append(FoldLine(p0: CGPoint(x: x0 + w, y: y0 + h), p1: CGPoint(x: x0, y: y0 + h), cut: true))
        lines.append(FoldLine(p0: CGPoint(x: x0, y: y0 + h), p1: CGPoint(x: x0, y: y0), cut: true))

        // innere Senkrechten / Waagrechten (Falz)
        for c in 1..<max(1, cols) {
            let x = x0 + Double(c) * cw
            lines.append(FoldLine(p0: CGPoint(x: x, y: y0), p1: CGPoint(x: x, y: y0 + h), cut: false))
        }
        for r in 1..<max(1, rows) {
            let y = y0 + Double(r) * ch
            lines.append(FoldLine(p0: CGPoint(x: x0, y: y), p1: CGPoint(x: x0 + w, y: y), cut: false))
        }
        // Diagonalen pro Zelle (Triangulierung)
        for r in 0..<rows {
            for c in 0..<cols {
                let cx = x0 + Double(c) * cw, cy = y0 + Double(r) * ch
                lines.append(FoldLine(p0: CGPoint(x: cx, y: cy),
                                      p1: CGPoint(x: cx + cw, y: cy + ch), cut: false))
            }
        }
        return lines
    }

    // MARK: Ausstellungs-Reel

    /// Gesamtzahl der Bilder eines Reels: pro Werk eine gehaltene Titelkarte
    /// (titleHold Bilder) plus dessen Frames.
    static func reelFrameCount(frameCounts: [Int], titleHold: Int) -> Int {
        frameCounts.reduce(0) { $0 + $1 } + max(0, titleHold) * frameCounts.count
    }

    // MARK: Kontaktbogen-Layout

    /// Rasterlayout für den Kontaktbogen: quadratische Zellen in `columns`
    /// Spalten, seitenweise. Liefert pro Seite die Zell-Rechtecke.
    static func contactSheetLayout(
        count: Int,
        pageWidth: Double, pageHeight: Double,
        margin: Double, gutter: Double,
        columns: Int, captionHeight: Double
    ) -> [[CGRect]] {
        guard count > 0, columns > 0 else { return [] }
        let cellW = (pageWidth - 2 * margin - Double(columns - 1) * gutter) / Double(columns)
        guard cellW > 0 else { return [] }
        let cellH = cellW // quadratische Kontaktbogen-Zellen
        let usableH = pageHeight - 2 * margin - captionHeight
        let rowsPerPage = max(1, Int((usableH + gutter) / (cellH + gutter)))
        let perPage = rowsPerPage * columns

        var pages: [[CGRect]] = []
        var placed = 0
        while placed < count {
            var rects: [CGRect] = []
            let onThisPage = min(perPage, count - placed)
            for i in 0..<onThisPage {
                let row = i / columns
                let col = i % columns
                rects.append(CGRect(
                    x: margin + Double(col) * (cellW + gutter),
                    y: margin + captionHeight + Double(row) * (cellH + gutter),
                    width: cellW, height: cellH))
            }
            pages.append(rects)
            placed += onThisPage
        }
        return pages
    }

    // MARK: Stabilisierung (Verwacklung)

    /// Schätzt die Verschiebung zwischen zwei gleich großen Graustufenbildern
    /// per Block-Matching (minimale mittlere absolute Differenz über ein
    /// Suchfenster). Ergebnis (dx, dy): So weit ist der Inhalt von `current`
    /// gegenüber `reference` verschoben — d. h. current[x+dx, y+dy] ≈ reference[x, y].
    /// Zum Ausrichten wird `current` um (−dx, −dy) zurückgeschoben.
    /// Deterministisch und unit-getestet (kein Vision-Blackbox, exakte Vorzeichen).
    static func estimateTranslation(
        reference: [UInt8], current: [UInt8],
        width: Int, height: Int, maxShift: Int, sampleStep: Int = 2
    ) -> (dx: Int, dy: Int) {
        guard width > 0, height > 0,
              reference.count == width * height,
              current.count == width * height else { return (0, 0) }
        let step = max(1, sampleStep)
        var best = (dx: 0, dy: 0)
        var bestScore = Double.greatestFiniteMagnitude

        for sy in -maxShift...maxShift {
            for sx in -maxShift...maxShift {
                var sum = 0.0
                var n = 0
                var y = max(0, -sy)
                let yEnd = min(height, height - sy)
                while y < yEnd {
                    var x = max(0, -sx)
                    let xEnd = min(width, width - sx)
                    let refRow = y * width
                    let curRow = (y + sy) * width + sx
                    while x < xEnd {
                        let d = Int(reference[refRow + x]) - Int(current[curRow + x])
                        sum += Double(abs(d))
                        n += 1
                        x += step
                    }
                    y += step
                }
                guard n > 0 else { continue }
                // kleiner Strafterm bevorzugt die kleinste Verschiebung bei Gleichstand
                let score = sum / Double(n) + 0.001 * Double(abs(sx) + abs(sy))
                if score < bestScore {
                    bestScore = score
                    best = (sx, sy)
                }
            }
        }
        return best
    }

    // MARK: Export-Geometrie

    /// Center-Crop-Rechteck für ein Ziel-Seitenverhältnis (Breite/Höhe).
    /// nil = Originalformat behalten.
    static func cropRect(imageWidth: Int, imageHeight: Int, targetRatio: Double?) -> CGRect {
        let w = Double(imageWidth), h = Double(imageHeight)
        guard let ratio = targetRatio, ratio > 0 else {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }
        let currentRatio = w / h
        if currentRatio > ratio {
            let newW = h * ratio
            return CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
        } else {
            let newH = w / ratio
            return CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
        }
    }
}
