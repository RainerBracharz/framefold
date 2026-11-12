import Foundation
import CoreGraphics

/// Geführte Faltfolgen: ein Blatt, Schritt für Schritt an geraden Linien
/// gefaltet. Jede Faltung spiegelt einen Teil des Blatts an der Faltlinie –
/// mehr braucht es für viele traditionelle Modelle nicht.
///
/// Aus der Folge entsteht für jeden Schritt der Umriss, den das Papier danach
/// hat. Die Kamera vergleicht ihn mit dem, was auf dem Tisch liegt: Stimmt der
/// Umriss und sind die Hände weg, ist der Schritt gefaltet. Die Prüfung der
/// Faltung ist damit der Auslöser.
///
/// Koordinaten: das Blatt als Einheitsquadrat, (0, 0) oben links, y nach unten
/// – wie im Kamerabild. Diese Datei kommt ohne UIKit und SwiftUI aus.
struct FoldSequence: Identifiable, Equatable {

    enum Kind: Equatable { case valley, mountain }

    /// Welche Lagen eine Faltung mitnimmt
    enum Layers: Equatable {
        /// alle Lagen auf der bewegten Seite
        case all
        /// nur die oberste Lage (z. B. die vordere Klappe des Bechers)
        case front
        /// nur die unterste Lage
        case back
    }

    struct Step: Equatable {
        /// Zwei Punkte der Faltlinie
        let a: CGPoint
        let b: CGPoint
        /// Ein Punkt auf der Seite, die sich bewegt
        let moving: CGPoint
        var kind: Kind = .valley
        var layers: Layers = .all
    }

    /// Eine Lage des gefalteten Blatts: ein konvexes Vieleck und seine Höhe im Stapel
    struct Face: Equatable {
        var polygon: [CGPoint]
        var layer: Int
    }

    let id: String
    let steps: [Step]

    // MARK: Falten

    /// Zustand des Blatts vor dem ersten Schritt und nach jedem Schritt
    /// (`steps.count + 1` Einträge).
    var states: [[Face]] {
        let sheet = Face(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                   CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], layer: 0)
        var out: [[Face]] = [[sheet]]
        for step in steps { out.append(Self.fold(out[out.count - 1], step)) }
        return out
    }

    static func fold(_ faces: [Face], _ step: Step) -> [Face] {
        // Normale der Faltlinie, zur bewegten Seite hin
        let dx = step.b.x - step.a.x, dy = step.b.y - step.a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-9 else { return faces }
        var nx = -dy / length, ny = dx / length
        if (step.moving.x - step.a.x) * nx + (step.moving.y - step.a.y) * ny < 0 { nx = -nx; ny = -ny }
        func distance(_ p: CGPoint) -> CGFloat { (p.x - step.a.x) * nx + (p.y - step.a.y) * ny }

        var staying: [Face] = [], moving: [Face] = []
        for face in faces {
            let (inside, outside) = split(face.polygon, distance)
            if let inside { moving.append(Face(polygon: inside, layer: face.layer)) }
            if let outside { staying.append(Face(polygon: outside, layer: face.layer)) }
        }
        guard !moving.isEmpty else { return faces }

        // Nur die oberste oder unterste Lage: der Rest der bewegten Seite bleibt liegen
        let movingLayers = moving.map(\.layer)
        switch step.layers {
        case .all: break
        case .front:
            let top = movingLayers.max()!
            staying += moving.filter { $0.layer != top }
            moving = moving.filter { $0.layer == top }
        case .back:
            let bottom = movingLayers.min()!
            staying += moving.filter { $0.layer != bottom }
            moving = moving.filter { $0.layer == bottom }
        }

        // Spiegeln; die bewegten Lagen landen in umgekehrter Reihenfolge
        // obenauf (Talfalte) oder darunter (Bergfalte).
        let all = (staying + moving).map(\.layer)
        let highest = all.max()!, lowest = all.min()!
        let movingTop = moving.map(\.layer).max()!, movingBottom = moving.map(\.layer).min()!
        let flipped = moving.map { face -> Face in
            let polygon = face.polygon.map { p -> CGPoint in
                let d = distance(p)
                return CGPoint(x: p.x - 2 * d * nx, y: p.y - 2 * d * ny)
            }
            let layer = step.kind == .valley ? highest + 1 + (movingTop - face.layer)
                                             : lowest - 1 - (face.layer - movingBottom)
            return Face(polygon: polygon, layer: layer)
        }
        return staying + flipped
    }

    /// Teilt ein konvexes Vieleck an einer Geraden (`distance` > 0 = bewegte Seite).
    private static func split(_ polygon: [CGPoint], _ distance: (CGPoint) -> CGFloat)
        -> (inside: [CGPoint]?, outside: [CGPoint]?) {
        var inside: [CGPoint] = [], outside: [CGPoint] = []
        let eps: CGFloat = 1e-9
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            let dp = distance(p), dq = distance(q)
            if dp >= -eps { inside.append(p) }
            if dp <= eps { outside.append(p) }
            if (dp > eps && dq < -eps) || (dp < -eps && dq > eps) {
                let t = dp / (dp - dq)
                let cut = CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
                inside.append(cut); outside.append(cut)
            }
        }
        func valid(_ points: [CGPoint]) -> [CGPoint]? {
            guard points.count >= 3 else { return nil }
            var twice: CGFloat = 0
            for i in points.indices {
                let p = points[i], q = points[(i + 1) % points.count]
                twice += p.x * q.y - q.x * p.y
            }
            return abs(twice) > 1e-7 ? points : nil
        }
        return (valid(inside), valid(outside))
    }

    // MARK: Umriss

    /// Umriss als Raster: `size` × `size` Felder über dem Blatt samt Rand
    /// (`margin` je Seite), weil eine Klappe über die Blattkante ragen kann.
    struct Mask: Equatable {
        static let margin: CGFloat = 0.25
        let size: Int
        var cells: [Bool]

        /// Mittelpunkt des Felds in Blattkoordinaten
        static func point(_ column: Int, _ row: Int, size: Int) -> CGPoint {
            let span = 1 + 2 * margin
            return CGPoint(x: -margin + (CGFloat(column) + 0.5) / CGFloat(size) * span,
                           y: -margin + (CGFloat(row) + 0.5) / CGFloat(size) * span)
        }

        /// Aus einer Probe je Feld (z. B. „ist hier Papier?“ im Kamerabild)
        init(size: Int = 48, _ isPaper: (CGPoint) -> Bool) {
            self.size = size
            var cells = [Bool](repeating: false, count: size * size)
            for row in 0..<size {
                for column in 0..<size { cells[row * size + column] = isPaper(Self.point(column, row, size: size)) }
            }
            self.cells = cells
        }

        /// Anteil der Fläche, der Papier ist, in Blattflächen (1 = das flache Blatt)
        var area: Double {
            let span = Double(1 + 2 * Self.margin)
            return Double(cells.filter { $0 }.count) / Double(size * size) * span * span
        }

        /// Übereinstimmung zweier Umrisse: Schnittmenge durch Vereinigung (0…1)
        func overlap(with other: Mask) -> Double {
            guard size == other.size else { return 0 }
            var both = 0, either = 0
            for i in cells.indices {
                if cells[i] && other.cells[i] { both += 1 }
                if cells[i] || other.cells[i] { either += 1 }
            }
            return either == 0 ? 1 : Double(both) / Double(either)
        }
    }

    static func mask(of faces: [Face], size: Int = 48) -> Mask {
        Mask(size: size) { point in faces.contains { contains($0.polygon, point) } }
    }

    private static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: Prüfung

    /// Geprüft wird nur dort, wo ein Schritt den Umriss ändert: Felder, die
    /// vorher Papier waren und danach frei sind, oder umgekehrt. Der Vergleich
    /// über den ganzen Umriss wäre zu grob – ein kleines Ohr ändert ihn kaum,
    /// ein leicht verrutschtes Blatt schon.
    ///
    /// Ab diesem Anteil passender Felder gilt ein Schritt als gefaltet.
    static let matchThreshold = 0.7
    /// So viel Fläche (in Blattflächen) muss sich ändern, damit der Umriss etwas aussagt.
    static let minimumChange = 0.015

    /// Wie weit ist Schritt `index` gefaltet (0…1)? Anteil der Felder, die
    /// sich mit dem Schritt ändern und im Kamerabild schon so aussehen wie danach.
    /// `nil`, wenn der Schritt den Umriss nicht ändert.
    func progress(step index: Int, observed: Mask) -> Double? {
        let states = self.states
        guard index >= 0, index + 1 < states.count else { return nil }
        let before = Self.mask(of: states[index], size: observed.size)
        let after = Self.mask(of: states[index + 1], size: observed.size)
        var changed = 0, matching = 0
        for i in before.cells.indices where before.cells[i] != after.cells[i] {
            changed += 1
            if observed.cells[i] == after.cells[i] { matching += 1 }
        }
        let span = Double(1 + 2 * Mask.margin)
        let changedArea = Double(changed) / Double(observed.size * observed.size) * span * span
        guard changedArea >= Self.minimumChange else { return nil }
        return Double(matching) / Double(changed)
    }

    /// Lässt sich Schritt `index` am Umriss erkennen? Eine Klappe, die nur die
    /// vordere von zwei gleichen Lagen umlegt, ändert den Umriss nicht – dort
    /// löst die Kamera wie gewohnt aus, sobald die Hände weg sind.
    func isVerifiable(step index: Int, size: Int = 48) -> Bool {
        let states = self.states
        guard index >= 0, index + 1 < states.count else { return false }
        return progress(step: index, observed: Self.mask(of: states[index + 1], size: size)) != nil
    }

    /// Ist Schritt `index` gefaltet? `observed` ist der Umriss aus dem Kamerabild.
    /// Zusätzlich muss das Ganze grob zum erwarteten Umriss passen – sonst
    /// zählte auch eine Hand, die zufällig die richtige Ecke verdeckt.
    func isFolded(step index: Int, observed: Mask) -> Bool {
        guard let progress = progress(step: index, observed: observed) else { return false }
        let expected = Self.mask(of: states[index + 1], size: observed.size)
        return progress >= Self.matchThreshold && observed.overlap(with: expected) >= 0.7
    }
}

// MARK: Modelle

extension FoldSequence {

    /// Traditionelle Modelle aus wenigen einfachen Faltungen.
    static let all: [FoldSequence] = [.letter, .dog, .cup]

    private static func bisector(_ p: CGPoint, onto q: CGPoint) -> (CGPoint, CGPoint) {
        // Mittelsenkrechte von p und q: die Linie, an der p auf q fällt
        let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        let direction = CGPoint(x: -(q.y - p.y), y: q.x - p.x)
        return (CGPoint(x: mid.x - direction.x, y: mid.y - direction.y),
                CGPoint(x: mid.x + direction.x, y: mid.y + direction.y))
    }

    /// Brief: unteres Drittel hoch, oberes Drittel darüber.
    static let letter = FoldSequence(id: "letter", steps: [
        Step(a: CGPoint(x: 0, y: 2.0 / 3), b: CGPoint(x: 1, y: 2.0 / 3), moving: CGPoint(x: 0.5, y: 1)),
        Step(a: CGPoint(x: 0, y: 1.0 / 3), b: CGPoint(x: 1, y: 1.0 / 3), moving: CGPoint(x: 0.5, y: 0)),
    ])

    /// Hundekopf: Ecke auf Ecke zum Dreieck, zwei Ohren, die Schnauze hoch.
    static let dog = FoldSequence(id: "dog", steps: [
        Step(a: CGPoint(x: 1, y: 0), b: CGPoint(x: 0, y: 1), moving: CGPoint(x: 0, y: 0)),
        Step(a: CGPoint(x: 0.72, y: 0.28), b: CGPoint(x: 1, y: 0.45), moving: CGPoint(x: 1, y: 0)),
        Step(a: CGPoint(x: 0.28, y: 0.72), b: CGPoint(x: 0.45, y: 1), moving: CGPoint(x: 0, y: 1)),
        Step(a: CGPoint(x: 1, y: 0.8), b: CGPoint(x: 0.8, y: 1), moving: CGPoint(x: 1, y: 1)),
    ])

    /// Becher: Dreieck, beide Ecken zur Gegenseite, vordere Klappe nach vorn,
    /// hintere nach hinten.
    static let cup: FoldSequence = {
        let ratio = 2.0.squareRoot() / (1 + 2.0.squareRoot())
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 1, y: 1), apex = CGPoint(x: 1, y: 0)
        // Wo die Winkelhalbierenden der Grundecken die Gegenseiten treffen
        let d = CGPoint(x: 1, y: 1 - ratio)
        let e = CGPoint(x: ratio, y: 0)
        let left = bisector(a, onto: d), right = bisector(b, onto: e)
        return FoldSequence(id: "cup", steps: [
            Step(a: a, b: b, moving: CGPoint(x: 0, y: 1)),
            Step(a: left.0, b: left.1, moving: a),
            Step(a: right.0, b: right.1, moving: b),
            Step(a: e, b: d, moving: apex, layers: .front),
            Step(a: e, b: d, moving: apex, kind: .mountain),
        ])
    }()
}
