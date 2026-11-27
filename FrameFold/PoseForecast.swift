import UIKit
import CoreGraphics

/// Zwiebelhaut in die Zukunft: Aus den letzten zwei Aufnahmen schätzt
/// FrameFold, wie sich das Bewegte von Bild zu Bild verschiebt, und zeigt,
/// wo es im nächsten Bild läge. Läuft ganz auf dem Gerät, ohne Netz.
///
/// Verfahren: Beide Bilder werden klein gerechnet. Für jede Zelle eines
/// Rasters, in der sich etwas verändert hat, sucht die Schätzung im vorigen
/// Bild die passende Stelle (Blockvergleich). Treffer gelten nur, wenn auch
/// die Fundstelle im vorigen Bild verändert ist. So zählt freigelegter
/// Hintergrund nicht als Bewegung. Große Sprünge findet der Blockvergleich
/// zuverlässiger als ein optischer Fluss, und Stop-Motion springt oft weit.
enum PoseForecast {

    /// Graustufen- und Farbbild in fester Arbeitsgröße.
    struct Raster {
        let width: Int
        let height: Int
        var gray: [Float]   // 0…255
        var rgba: [UInt8]

        init(width: Int, height: Int, gray: [Float], rgba: [UInt8]) {
            self.width = width; self.height = height; self.gray = gray; self.rgba = rgba
        }

        /// Zeichnet `image` in `width` × passender Höhe.
        init?(_ image: CGImage, width: Int) {
            guard image.width > 0, image.height > 0 else { return nil }
            let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            var gray = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                gray[i] = 0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])
            }
            self.init(width: width, height: height, gray: gray, rgba: rgba)
        }
    }

    /// Eine bewegte Rasterzelle: Lage im letzten Bild und Verschiebung pro
    /// Bild, beides in Pixeln der Arbeitsgröße.
    struct Cell: Equatable {
        let x: Int, y: Int
        var dx: Float, dy: Float
    }

    struct Motion {
        let width: Int
        let height: Int
        let cellSize: Int
        let cells: [Cell]

        /// Typische Schrittweite des Bewegten, als Anteil der Bildbreite.
        var stepFraction: Double {
            guard !cells.isEmpty else { return 0 }
            let lengths = cells.map { Double(hypot($0.dx, $0.dy)) }.sorted()
            return lengths[lengths.count / 2] / Double(width)
        }

        /// Ab hier springt die Bewegung sichtbar: Zwischenbilder würden sie
        /// weicher machen.
        static let largeStep = 0.06
        var isLargeStep: Bool { stepFraction > Self.largeStep }

        /// Wie viele Zwischenbilder den Schritt auf eine ruhige Weite brächten.
        var suggestedInbetweens: Int {
            guard isLargeStep else { return 0 }
            return min(4, max(1, Int((stepFraction / 0.035).rounded(.up)) - 1))
        }
    }

    static let workWidth = 160
    static let cellSize = 8

    /// Bewegung zwischen `previous` und `last`. Leer, wenn sich nichts
    /// Zusammenhängendes bewegt hat (Rauschen, Lichtflackern, Hand im Bild).
    static func motion(previous: Raster, last: Raster, cellSize: Int = cellSize) -> Motion {
        let w = last.width, h = last.height
        guard previous.width == w, previous.height == h, w >= cellSize * 2, h >= cellSize * 2 else {
            return Motion(width: w, height: h, cellSize: cellSize, cells: [])
        }
        // Gleichmäßige Helligkeitsänderung (Licht, Belichtung) herausrechnen
        let n = Float(w * h)
        let offset = last.gray.reduce(0, +) / n - previous.gray.reduce(0, +) / n
        let prev = previous.gray.map { $0 + offset }
        let cur = last.gray

        var changed = [Bool](repeating: false, count: w * h)
        var changedCount = 0
        for i in 0..<(w * h) where abs(cur[i] - prev[i]) > 22 { changed[i] = true; changedCount += 1 }
        // Ändert sich fast das ganze Bild, ist es ein Schnitt oder die Kamera
        // hat sich bewegt – daraus folgt kein nächster Schritt
        if Float(changedCount) > n * 0.45 {
            return Motion(width: w, height: h, cellSize: cellSize, cells: [])
        }
        // Halbe Auflösung für die grobe Suche (2 × 2 gemittelt)
        let hw = w / 2, hh = h / 2
        func half(_ v: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: hw * hh)
            for y in 0..<hh { for x in 0..<hw {
                let i = 2 * y * w + 2 * x
                out[y * hw + x] = (v[i] + v[i + 1] + v[i + w] + v[i + w + 1]) / 4
            } }
            return out
        }
        let curHalf = half(cur), prevHalf = half(prev)
        let hc = cellSize / 2
        func coarseCost(_ cx: Int, _ cy: Int, _ dx: Int, _ dy: Int) -> Float {
            var sum: Float = 0
            for y in cy..<(cy + hc) {
                let row = y * hw, prow = (y - dy) * hw
                for x in cx..<(cx + hc) { sum += abs(curHalf[row + x] - prevHalf[prow + x - dx]) }
            }
            return sum
        }

        func changedFraction(_ cx: Int, _ cy: Int) -> Float {
            var hits = 0, total = 0
            for y in max(0, cy)..<min(h, cy + cellSize) {
                for x in max(0, cx)..<min(w, cx + cellSize) {
                    total += 1; if changed[y * w + x] { hits += 1 }
                }
            }
            return total == 0 ? 0 : Float(hits) / Float(total)
        }
        /// Mittlere Abweichung der Zelle (cx, cy) im letzten Bild von der um
        /// (dx, dy) zurückversetzten Stelle im vorigen.
        func cost(_ cx: Int, _ cy: Int, _ dx: Int, _ dy: Int) -> Float {
            var sum: Float = 0
            for y in cy..<(cy + cellSize) {
                let py = y - dy
                let row = y * w, prow = py * w
                for x in cx..<(cx + cellSize) {
                    sum += abs(cur[row + x] - prev[prow + x - dx])
                }
            }
            return sum / Float(cellSize * cellSize)
        }
        func texture(_ cx: Int, _ cy: Int) -> Float {
            var mean: Float = 0
            for y in cy..<(cy + cellSize) { for x in cx..<(cx + cellSize) { mean += cur[y * w + x] } }
            mean /= Float(cellSize * cellSize)
            var v: Float = 0
            for y in cy..<(cy + cellSize) { for x in cx..<(cx + cellSize) { let d = cur[y * w + x] - mean; v += d * d } }
            return (v / Float(cellSize * cellSize)).squareRoot()
        }

        let radius = max(4, w * 18 / 100)
        var found: [Cell] = []
        for cy in stride(from: 0, through: h - cellSize, by: cellSize) {
            for cx in stride(from: 0, through: w - cellSize, by: cellSize) {
                guard changedFraction(cx, cy) > 0.25 else { continue }
                // Einfarbige Flächen passen überall – keine verlässliche Richtung
                guard texture(cx, cy) > 6 else { continue }
                let still = cost(cx, cy, 0, 0)
                var best = Float.greatestFiniteMagnitude, bdx = 0, bdy = 0
                func consider(_ dx: Int, _ dy: Int) {
                    let px = cx - dx, py = cy - dy
                    guard px >= 0, py >= 0, px + cellSize <= w, py + cellSize <= h else { return }
                    let c = cost(cx, cy, dx, dy)
                    // Bei Gleichstand die kürzere Verschiebung
                    if c < best - 0.01 || (abs(c - best) <= 0.01 && dx * dx + dy * dy < bdx * bdx + bdy * bdy) {
                        best = c; bdx = dx; bdy = dy
                    }
                }
                // Grob in halber Auflösung (gemittelt, daher auch bei feinem
                // Muster wie Holzmaserung verlässlich), dann fein um den Treffer
                let hx = cx / 2, hy = cy / 2, hr = radius / 2
                var cBest = Float.greatestFiniteMagnitude, cdx = 0, cdy = 0
                for dy in -hr...hr {
                    guard hy - dy >= 0, hy - dy + hc <= hh else { continue }
                    for dx in -hr...hr {
                        guard hx - dx >= 0, hx - dx + hc <= hw else { continue }
                        let c = coarseCost(hx, hy, dx, dy)
                        if c < cBest - 0.01 || (abs(c - cBest) <= 0.01 && dx * dx + dy * dy < cdx * cdx + cdy * cdy) {
                            cBest = c; cdx = dx; cdy = dy
                        }
                    }
                }
                for dy in (2 * cdy - 2)...(2 * cdy + 2) { for dx in (2 * cdx - 2)...(2 * cdx + 2) { consider(dx, dy) } }
                guard bdx * bdx + bdy * bdy >= 4, best < 14, best < still * 0.5 else { continue }
                // Die Fundstelle muss sich selbst verändert haben: Dort stand
                // das Bewegte vorher. Sonst ist es freigelegter Hintergrund.
                guard changedFraction(cx - bdx, cy - bdy) > 0.2 else { continue }
                found.append(Cell(x: cx, y: cy, dx: Float(bdx), dy: Float(bdy)))
            }
        }

        // Einzelne Ausreißer verwerfen, Nachbarn glätten (Median)
        let byPos = Dictionary(uniqueKeysWithValues: found.map { (($0.x / cellSize) * 100_000 + $0.y / cellSize, $0) })
        func neighbors(_ c: Cell) -> [Cell] {
            var out: [Cell] = []
            for oy in -1...1 { for ox in -1...1 where ox != 0 || oy != 0 {
                if let nb = byPos[(c.x / cellSize + ox) * 100_000 + c.y / cellSize + oy] { out.append(nb) }
            } }
            return out
        }
        var cleaned: [Cell] = []
        for c in found {
            let nbs = neighbors(c)
            guard !nbs.isEmpty else { continue }
            let group = nbs + [c]
            let mx = group.map(\.dx).sorted()[group.count / 2]
            let my = group.map(\.dy).sorted()[group.count / 2]
            // Weicht die Zelle stark von ihrer Umgebung ab, gilt der Median
            if hypot(c.dx - mx, c.dy - my) > 4 {
                cleaned.append(Cell(x: c.x, y: c.y, dx: mx, dy: my))
            } else {
                cleaned.append(c)
            }
        }
        // Mindestgröße: Ein paar Zellen sind Rauschen, kein Gegenstand
        if cleaned.count < 3 { cleaned = [] }
        return Motion(width: w, height: h, cellSize: cellSize, cells: cleaned)
    }

    /// Das Bewegte aus `last`, um `pace` Schritte weitergeschoben, warm
    /// getönt, auf durchsichtigem Grund – in der Größe von `last`.
    /// Mit `previous` zeigt der Geist nur, was sich in der Zelle verändert
    /// hat (Umriss und Muster des Bewegten), statt ganzer Kacheln.
    static func ghost(of motion: Motion, last: Raster, previous: Raster? = nil, pace: Double = 1) -> CGImage? {
        guard !motion.cells.isEmpty else { return nil }
        let w = last.width, h = last.height
        var keep: [Float]?
        if let previous, previous.width == w, previous.height == h {
            let n = Float(w * h)
            let offset = last.gray.reduce(0, +) / n - previous.gray.reduce(0, +) / n
            var m = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) where abs(last.gray[i] - previous.gray[i] - offset) > 22 { m[i] = 1 }
            // Etwas aufweiten, damit dünne Kanten als Linie stehen bleiben
            keep = boxBlur(m, w, h, radius: max(1, w / 240))
        }
        let scale = Double(w) / Double(motion.width)
        let size = max(1, Int((Double(motion.cellSize) * scale).rounded()))
        // Farbe und Deckung getrennt sammeln, die Deckung danach weich
        // ausblenden – nur zum Rand hin, nicht an den Fugen der Zellen
        var color = [Float](repeating: 0, count: w * h * 3)
        var covered = [Float](repeating: 0, count: w * h)
        // Amber #D99B2B, zur Hälfte untergemischt: Die Zukunft hebt sich von
        // der Zwiebelhaut der Vergangenheit ab
        let tint: (Float, Float, Float) = (217, 155, 43)
        for c in motion.cells {
            let sx = Int((Double(c.x) * scale).rounded()), sy = Int((Double(c.y) * scale).rounded())
            let ox = Int((Double(c.dx) * scale * pace).rounded()), oy = Int((Double(c.dy) * scale * pace).rounded())
            for y in 0..<size {
                let srcY = sy + y, dstY = srcY + oy
                guard srcY < h, dstY >= 0, dstY < h else { continue }
                for x in 0..<size {
                    let srcX = sx + x, dstX = srcX + ox
                    guard srcX < w, dstX >= 0, dstX < w else { continue }
                    if let keep, keep[srcY * w + srcX] <= 0 { continue }
                    let s = (srcY * w + srcX) * 4, d = dstY * w + dstX
                    color[d * 3] = Float(last.rgba[s]) * 0.5 + tint.0 * 0.5
                    color[d * 3 + 1] = Float(last.rgba[s + 1]) * 0.5 + tint.1 * 0.5
                    color[d * 3 + 2] = Float(last.rgba[s + 2]) * 0.5 + tint.2 * 0.5
                    covered[d] = 1
                }
            }
        }
        let alpha = boxBlur(covered, w, h, radius: max(1, keep == nil ? size / 3 : size / 8))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where covered[i] > 0 {
            let a = alpha[i]
            out[i * 4] = UInt8(min(255, color[i * 3] * a))
            out[i * 4 + 1] = UInt8(min(255, color[i * 3 + 1] * a))
            out[i * 4 + 2] = UInt8(min(255, color[i * 3 + 2] * a))
            out[i * 4 + 3] = UInt8(min(255, a * 255))
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Getrennter Kastenfilter (waagrecht, dann senkrecht), mit laufender
    /// Summe: Aufwand unabhängig vom Radius.
    static func boxBlur(_ v: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        guard w > 0, h > 0 else { return v }
        var tmp = v, out = v
        v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    var sum: Float = 0
                    for k in 0...min(w - 1, r) { sum += src[row + k] }
                    for x in 0..<w {
                        let lo = max(0, x - r), hi = min(w - 1, x + r)
                        dst[row + x] = sum / Float(hi - lo + 1)
                        if x + r + 1 < w { sum += src[row + x + r + 1] }
                        if x - r >= 0 { sum -= src[row + x - r] }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for x in 0..<w {
                    var sum: Float = 0
                    for k in 0...min(h - 1, r) { sum += src[k * w + x] }
                    for y in 0..<h {
                        let lo = max(0, y - r), hi = min(h - 1, y + r)
                        dst[y * w + x] = sum / Float(hi - lo + 1)
                        if y + r + 1 < h { sum += src[(y + r + 1) * w + x] }
                        if y - r >= 0 { sum -= src[(y - r) * w + x] }
                    }
                }
            }
        }
        return out
    }

    /// Ergebnis für den Sucher.
    struct Forecast {
        let ghost: CGImage
        let motion: Motion
    }

    /// Ganze Schätzung aus zwei Bildern; `nil`, wenn sich nichts erkennbar bewegt.
    static func forecast(previous: CGImage, last: CGImage, pace: Double = 1, ghostWidth: Int = 360) -> Forecast? {
        guard let p = Raster(previous, width: workWidth), let l = Raster(last, width: workWidth),
              p.height == l.height else { return nil }
        let m = motion(previous: p, last: l)
        guard !m.cells.isEmpty, let big = Raster(last, width: ghostWidth),
              let before = Raster(previous, width: ghostWidth),
              let image = ghost(of: m, last: big, previous: before, pace: pace) else { return nil }
        return Forecast(ghost: image, motion: m)
    }
}

/// Tempo des nächsten Schritts gegenüber dem letzten.
enum ForecastPace: String, Codable, CaseIterable, Identifiable {
    case even, slowing, speeding
    var id: String { rawValue }
    var factor: Double {
        switch self {
        case .even: 1
        case .slowing: 0.6
        case .speeding: 1.4
        }
    }
    var label: LocalizedStringResource {
        switch self {
        case .even: "Gleich weit"
        case .slowing: "Langsamer werden"
        case .speeding: "Schneller werden"
        }
    }
}

/// Hält die Vorhersage für den Live-Sucher aktuell: rechnet nach jeder
/// Aufnahme neu, im Hintergrund.
@MainActor
final class PoseForecaster: ObservableObject {
    @Published private(set) var ghost: UIImage?
    @Published private(set) var inbetweens = 0
    private var task: Task<Void, Never>?

    func update(previous: Data?, last: Data?, pace: Double) {
        task?.cancel()
        // Der alte Geist gehört zum vorigen Bildpaar: sofort weg, sonst steht
        // er bis zur neuen Schätzung genau auf der gerade gemachten Aufnahme
        ghost = nil; inbetweens = 0
        guard let previous, let last else { return }
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> PoseForecast.Forecast? in
                guard let p = UIImage(data: previous)?.cgImage, let l = UIImage(data: last)?.cgImage else { return nil }
                return PoseForecast.forecast(previous: p, last: l, pace: pace)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.ghost = result.map { UIImage(cgImage: $0.ghost) }
            self.inbetweens = result?.motion.suggestedInbetweens ?? 0
        }
    }

    /// Studio: aus den Bilddateien des Werks.
    func update(previousURL: URL?, lastURL: URL?, pace: Double) {
        task?.cancel()
        ghost = nil; inbetweens = 0
        guard let previousURL, let lastURL else { return }
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> PoseForecast.Forecast? in
                guard let p = UIImage(contentsOfFile: previousURL.path)?.cgImage,
                      let l = UIImage(contentsOfFile: lastURL.path)?.cgImage else { return nil }
                return PoseForecast.forecast(previous: p, last: l, pace: pace, ghostWidth: 640)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.ghost = result.map { UIImage(cgImage: $0.ghost) }
            self.inbetweens = result?.motion.suggestedInbetweens ?? 0
        }
    }

    func clear() {
        task?.cancel(); ghost = nil; inbetweens = 0
    }
}
