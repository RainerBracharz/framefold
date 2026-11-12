import Foundation
import SwiftUI
import UIKit

/// Faltmuster der Faltvorlage. Raster ist die bisherige Vorlage, die anderen
/// haben echte Berg- und Talfalten (Hypar und Kreisfalte nach dem Origami
/// Simulator von Amanda Ghassaei, MIT-Lizenz).
enum FoldPattern: String, CaseIterable, Identifiable {
    case grid, hypar, circularPleat, miura
    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid:          return String(localized: "Raster")
        case .hypar:         return String(localized: "Hypar")
        case .circularPleat: return String(localized: "Kreisfalte")
        case .miura:         return String(localized: "Miura-ori")
        }
    }

    /// Kurze Faltanleitung, steht auf der Vorlage
    var instructions: String {
        switch self {
        case .grid:
            return String(localized: "Entlang der gestrichelten Linien falten.")
        case .hypar:
            return String(localized: "Die Quadrate abwechselnd als Berg und Tal falten, von außen nach innen. Die Diagonalen nur leicht vorknicken und das Blatt sanft zusammenschieben, bis es sich zum Sattel wölbt.")
        case .circularPleat:
            return String(localized: "Außen und die Mitte ausschneiden. Die Kreise abwechselnd als Berg und Tal falten und den Ring zusammenschieben, bis er sich zum Sattel dreht.")
        case .miura:
            return String(localized: "Alle Linien vorfalten, Berg und Tal wie markiert. Dann zwei gegenüberliegende Ecken zusammenschieben, das Blatt legt sich flach zusammen.")
        }
    }

    func creases(in rect: CGRect) -> [Algorithms.Crease] {
        switch self {
        case .grid:
            return Algorithms.foldTemplateLines(rect: rect, cols: 4, rows: 5)
                .map { Algorithms.Crease(p0: $0.p0, p1: $0.p1, kind: $0.cut ? .cut : .facet) }
        case .hypar:
            return Algorithms.concentricPleat(in: rect, segments: 4, pleats: 7)
        case .circularPleat:
            return Algorithms.concentricPleat(in: rect, segments: 96, pleats: 7)
        case .miura:
            return Algorithms.miuraOri(in: rect, cols: 8, rows: 8)
        }
    }
}

/// Faltmuster als Hilfslinie im Sucher: ein Quadrat in der Bildmitte, damit
/// man beim Falten sieht, welche Linie als Nächstes kommt.
enum FoldGuide: String, CaseIterable, Identifiable, Codable {
    case off, hypar, circularPleat, miura
    /// Geführte Faltfolgen: Schritt für Schritt, die Kamera prüft den Umriss.
    case letter, dog, cup
    var id: String { rawValue }
    var pattern: FoldPattern? {
        switch self {
        case .off, .letter, .dog, .cup: return nil
        case .hypar: return .hypar
        case .circularPleat: return .circularPleat
        case .miura: return .miura
        }
    }
    var sequence: FoldSequence? {
        switch self {
        case .letter: return .letter
        case .dog: return .dog
        case .cup: return .cup
        default: return nil
        }
    }
    var label: String {
        switch self {
        case .letter: return String(localized: "Brief")
        case .dog: return String(localized: "Hundekopf")
        case .cup: return String(localized: "Becher")
        default: return pattern?.label ?? String(localized: "aus")
        }
    }

    /// Das Muster im Einheitsquadrat, in Faltschritte gegliedert, dazu die Schnittkanten.
    var unitSteps: (steps: [[Algorithms.Crease]], cuts: [Algorithms.Crease]) {
        guard let pattern else { return ([], []) }
        let all = pattern.creases(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let center: CGPoint? = pattern == .miura ? nil : CGPoint(x: 0.5, y: 0.5)
        return (Algorithms.foldSteps(all, concentricAround: center), all.filter { $0.kind == .cut })
    }

    /// Zeichnet das Muster auf das Viereck `quad` (Ecken in Ansichtskoordinaten,
    /// oben links beginnend im Uhrzeigersinn). `step` = aktueller Faltschritt:
    /// erledigte Falten blass, die aktuelle hell und kräftig, spätere ausgeblendet.
    /// Ohne `step` erscheint das ganze Muster.
    func draw(in ctx: inout GraphicsContext, quad: [CGPoint], step: Int?, opacity: Double = 0.85) {
        guard let map = Algorithms.QuadMap(quad) else { return }
        if let sequence {
            Self.draw(sequence, in: &ctx, map: map, framesTaken: step ?? 0, opacity: opacity)
            return
        }
        let (steps, cuts) = unitSteps
        func path(_ creases: [Algorithms.Crease], _ kind: Algorithms.CreaseKind? = nil) -> Path {
            var p = Path()
            for c in creases where kind == nil || c.kind == kind {
                p.move(to: map.map(c.p0)); p.addLine(to: map.map(c.p1))
            }
            return p
        }
        func stroke(_ creases: [Algorithms.Crease], alpha: Double, width: CGFloat) {
            for kind in [Algorithms.CreaseKind.facet, .valley, .mountain] {
                let p = path(creases, kind)
                switch kind {
                case .mountain:
                    ctx.stroke(p, with: .color(Color(red: 1.0, green: 0.36, blue: 0.3).opacity(alpha)),
                               style: StrokeStyle(lineWidth: width, dash: [7, 3, 1.5, 3]))
                case .valley:
                    ctx.stroke(p, with: .color(Color(red: 0.4, green: 0.6, blue: 1.0).opacity(alpha)),
                               style: StrokeStyle(lineWidth: width, dash: [5, 4]))
                default:
                    ctx.stroke(p, with: .color(.white.opacity(alpha)),
                               style: StrokeStyle(lineWidth: width * 0.6, dash: [1, 3]))
                }
            }
        }
        ctx.stroke(path(cuts), with: .color(.white.opacity(opacity * 0.6)), lineWidth: 1)
        guard let step else {
            stroke(steps.flatMap { $0 }, alpha: opacity, width: 1.2)
            return
        }
        let current = min(max(0, step), steps.count)
        stroke(steps.prefix(current).flatMap { $0 }, alpha: opacity * 0.3, width: 1)
        if current < steps.count { stroke(steps[current], alpha: opacity, width: 2.4) }
    }

    var stepCount: Int { sequence?.steps.count ?? unitSteps.steps.count }

    /// Faltfolge im Sucher. Vor dem ersten Bild nur der Blattrand; danach der
    /// Umriss, den das Papier nach dem nächsten Schritt haben soll, die
    /// Faltlinie und ein Pfeil von der Ecke zu ihrem Ziel. Ohne Text.
    private static func draw(_ sequence: FoldSequence, in ctx: inout GraphicsContext,
                             map: Algorithms.QuadMap, framesTaken: Int, opacity: Double) {
        let states = sequence.states
        func outline(_ faces: [FoldSequence.Face]) -> Path {
            var united = Path()
            for face in faces {
                var p = Path()
                p.addLines(face.polygon.map { map.map($0) })
                p.closeSubpath()
                united = united.isEmpty ? p : united.union(p)
            }
            return united
        }
        let amber = Color(red: 0.85, green: 0.61, blue: 0.17)
        guard framesTaken >= 1 else {
            ctx.stroke(outline(states[0]), with: .color(.white.opacity(opacity * 0.7)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            return
        }
        let index = framesTaken - 1
        guard index < sequence.steps.count else {
            ctx.stroke(outline(states[states.count - 1]), with: .color(.white.opacity(opacity * 0.4)), lineWidth: 1)
            return
        }
        let step = sequence.steps[index]
        // Wo das Papier jetzt liegt (blass) und wohin es soll (kräftig)
        ctx.stroke(outline(states[index]), with: .color(.white.opacity(opacity * 0.35)), lineWidth: 1)
        ctx.stroke(outline(states[index + 1]), with: .color(amber.opacity(opacity)), lineWidth: 2.4)

        // Faltlinie, auf das Papier des aktuellen Zustands begrenzt
        let dx = step.b.x - step.a.x, dy = step.b.y - step.a.y
        let length = max(1e-9, (dx * dx + dy * dy).squareRoot())
        let ux = dx / length, uy = dy / length
        var crease = Path()
        crease.move(to: map.map(CGPoint(x: step.a.x - ux * 2, y: step.a.y - uy * 2)))
        crease.addLine(to: map.map(CGPoint(x: step.a.x + ux * 3, y: step.a.y + uy * 3)))
        var clipped = ctx
        clipped.clip(to: outline(states[index]))
        let creaseColor = step.kind == .valley ? Color(red: 0.4, green: 0.6, blue: 1.0)
                                               : Color(red: 1.0, green: 0.36, blue: 0.3)
        clipped.stroke(crease, with: .color(creaseColor.opacity(opacity)),
                       style: StrokeStyle(lineWidth: 2, dash: step.kind == .valley ? [5, 4] : [7, 3, 1.5, 3]))

        // Pfeil: von der bewegten Ecke zu ihrem Spiegelpunkt
        var nx = -uy, ny = ux
        let side = (step.moving.x - step.a.x) * nx + (step.moving.y - step.a.y) * ny
        if side < 0 { nx = -nx; ny = -ny }
        let distance = abs(side)
        let from = map.map(step.moving)
        let to = map.map(CGPoint(x: step.moving.x - 2 * distance * nx, y: step.moving.y - 2 * distance * ny))
        let ax = to.x - from.x, ay = to.y - from.y
        let arrowLength = (ax * ax + ay * ay).squareRoot()
        guard arrowLength > 12 else { return }
        let hx = ax / arrowLength, hy = ay / arrowLength
        var arrow = Path()
        // Leicht gebogen, damit er als Bewegung über das Papier liest
        let bend = CGPoint(x: (from.x + to.x) / 2 - hy * arrowLength * 0.18,
                           y: (from.y + to.y) / 2 + hx * arrowLength * 0.18)
        arrow.move(to: from)
        arrow.addQuadCurve(to: to, control: bend)
        let tx = to.x - bend.x, ty = to.y - bend.y
        let tl = max(1e-9, (tx * tx + ty * ty).squareRoot())
        let ex = tx / tl, ey = ty / tl
        let head: CGFloat = 11
        arrow.move(to: CGPoint(x: to.x - ex * head - ey * head * 0.55, y: to.y - ey * head + ex * head * 0.55))
        arrow.addLine(to: to)
        arrow.addLine(to: CGPoint(x: to.x - ex * head + ey * head * 0.55, y: to.y - ey * head - ex * head * 0.55))
        ctx.stroke(arrow, with: .color(.white.opacity(opacity)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

/// Sucher-Ebene mit dem Faltmuster. Mit erkanntem Blatt (`paperQuad`, normiert
/// 0…1 im Kamerabild, oben links beginnend) liegt das Muster perspektivisch
/// auf dem Papier und zeigt den aktuellen Schritt; ohne Blatt blendet es aus.
struct FoldGuideOverlay: View {
    let guide: FoldGuide
    var paperQuad: [CGPoint]? = nil
    var step: Int? = nil
    /// Seitenverhältnis des Kamerabilds und wie es in der Ansicht liegt
    var imageAspect: Double = 1
    var fills = false
    /// Schrittzeile im Bild. Die iPhone-Kamera zeigt sie stattdessen in der
    /// Bedienung: Ihr Kamerabild läuft unter Kopfleiste und Bedienung hinaus.
    var showsLabel = true
    /// Faltfolge: wie weit der Schritt gefaltet ist (0…1), und ob die Kamera ihn prüft
    var progress: Double? = nil
    var checked = true

    var body: some View {
        Canvas { ctx, size in
            guard let paperQuad else { return }
            let image = Self.imageRect(aspect: imageAspect, in: size, fills: fills)
            let quad = paperQuad.map { CGPoint(x: image.minX + $0.x * image.width, y: image.minY + $0.y * image.height) }
            guide.draw(in: &ctx, quad: quad, step: step.map { max(0, $0) })
            // Faltfolge: kleiner Balken unter dem Blatt – er füllt sich, während gefaltet wird.
            if guide.sequence != nil, let progress, quad.count == 4 {
                let bottom = CGPoint(x: (quad[2].x + quad[3].x) / 2, y: max(quad[2].y, quad[3].y) + 18)
                let width: CGFloat = 96, height: CGFloat = 5
                let track = CGRect(x: bottom.x - width / 2, y: bottom.y, width: width, height: height)
                ctx.fill(Path(roundedRect: track, cornerRadius: height / 2), with: .color(.white.opacity(0.28)))
                let filled = CGRect(x: track.minX, y: track.minY, width: width * min(max(progress, 0), 1), height: height)
                ctx.fill(Path(roundedRect: filled, cornerRadius: height / 2),
                         with: .color(Color(red: 0.85, green: 0.61, blue: 0.17)))
            }
        }
        .opacity(paperQuad == nil ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: paperQuad == nil)
        .overlay(alignment: .bottom) {
            if showsLabel, guide != .off {
                Text(Self.label(guide: guide, paperQuad: paperQuad, step: step, checked: checked))
                    .font(Theme.mono(11)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55))
                    .padding(.bottom, 10)
            }
        }
        .allowsHitTesting(false)
    }

    static func label(guide: FoldGuide, paperQuad: [CGPoint]?, step: Int?, checked: Bool = true) -> String {
        guard paperQuad != nil else { return String(localized: "Faltmuster: Blatt nicht erkannt") }
        guard let rawStep = step else { return guide.label }
        // Faltfolgen zählen ab dem zweiten Bild: Das erste zeigt das flache Blatt.
        if guide.sequence != nil, rawStep <= 0 { return guide.label }
        let step = max(0, guide.sequence != nil ? rawStep - 1 : rawStep)
        let n = guide.stepCount
        if step >= n { return String(localized: "Faltmuster: alle \(n) Schritte gefaltet") }
        // Faltfolge ohne Prüfung: Die Kamera löst wie gewohnt aus, sobald die Hände weg sind.
        if guide.sequence != nil, !checked {
            return String(localized: "Faltmuster: Schritt \(step + 1) von \(n), ohne Prüfung")
        }
        return String(localized: "Faltmuster: Schritt \(step + 1) von \(n)")
    }

    /// Lage des Kamerabilds in der Ansicht (eingepasst oder füllend, mittig)
    static func imageRect(aspect: Double, in size: CGSize, fills: Bool) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let viewAspect = Double(size.width / size.height)
        let widthLimited = fills ? viewAspect > aspect : viewAspect < aspect
        let w = widthLimited ? Double(size.width) : Double(size.height) * aspect
        let h = widthLimited ? Double(size.width) / aspect : Double(size.height)
        return CGRect(x: (Double(size.width) - w) / 2, y: (Double(size.height) - h) / 2, width: w, height: h)
    }
}

/// Erzeugt aus einem Bild eine druckbare A4-Faltvorlage: das Bild plus ein
/// Falzmuster und eine durchgezogene Schnittkante. Zum Ausdrucken,
/// Ausschneiden und Nachfalten – bringt das digitale Bild zurück aufs Papier
/// (Objekt → Bild → Objekt).
enum FoldTemplateRenderer {

    private static let pageSize = CGSize(width: 595.2, height: 841.8) // A4 pt
    private static let margin: CGFloat = 48

    static func render(image: UIImage, title: String, cols: Int = 4, rows: Int = 5,
                       pattern: FoldPattern = .grid) -> URL? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("faltvorlage-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        do {
            try renderer.writePDF(to: outputURL) { ctx in
                ctx.beginPage()
                let cg = ctx.cgContext

                // Kopfzeile
                drawText(title.uppercased(), size: 11, tracking: 2.4,
                         color: UIColor.ffInk,
                         at: CGPoint(x: margin, y: margin))
                // Raster: die Anleitung selbst steht in der Kopfzeile (ohne Punkt).
                let hint = pattern == .grid
                    ? pattern.instructions.trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
                    : pattern.label
                let sub = String(localized: "FALTVORLAGE · \(hint.uppercased())")
                drawText(sub, size: 7, tracking: 2.0, color: UIColor.ffGraphite,
                         at: CGPoint(x: margin, y: margin + 16))

                let top = margin + 44
                let bottomReserve: CGFloat = pattern == .grid ? 0 : 118
                let avail = CGRect(x: margin, y: top,
                                   width: pageSize.width - 2 * margin,
                                   height: pageSize.height - top - margin - bottomReserve)

                if pattern == .grid {
                    // Bisherige Vorlage: ganzes Bild, Raster darüber
                    let scale = min(avail.width / image.size.width, avail.height / image.size.height)
                    let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let imgRect = CGRect(x: avail.midX - drawSize.width / 2, y: avail.minY,
                                         width: drawSize.width, height: drawSize.height)
                    image.draw(in: imgRect)
                    let lines = Algorithms.foldTemplateLines(rect: imgRect, cols: cols, rows: rows)
                    for line in lines {
                        if line.cut {
                            cg.setStrokeColor(UIColor(white: 0.10, alpha: 0.9).cgColor)
                            cg.setLineWidth(1.0)
                            cg.setLineDash(phase: 0, lengths: [])
                        } else {
                            cg.setStrokeColor(UIColor(white: 1, alpha: 0.75).cgColor)
                            cg.setLineWidth(0.7)
                            cg.setLineDash(phase: 0, lengths: [5, 4])
                        }
                        cg.move(to: line.p0)
                        cg.addLine(to: line.p1)
                        cg.strokePath()
                    }
                    cg.setLineDash(phase: 0, lengths: [])
                    return
                }

                // Muster mit Berg und Tal: quadratischer Ausschnitt aus der Bildmitte
                let side = min(avail.width, avail.height)
                let square = CGRect(x: avail.midX - side / 2, y: avail.minY, width: side, height: side)
                drawSquareCrop(image, in: square, context: cg)
                for c in pattern.creases(in: square) { stroke(c.p0, c.p1, kind: c.kind, cg) }
                cg.setLineDash(phase: 0, lengths: [])

                // Legende und Anleitung
                var y = square.maxY + 16
                let legend: [(Algorithms.CreaseKind, String)] = [
                    (.mountain, String(localized: "Bergfalte")),
                    (.valley, String(localized: "Talfalte")),
                    (.facet, String(localized: "leicht vorknicken")),
                    (.cut, String(localized: "schneiden")),
                ]
                var x = margin
                for (kind, text) in legend {
                    if kind == .facet && pattern != .hypar { continue }
                    stroke(CGPoint(x: x, y: y + 4), CGPoint(x: x + 26, y: y + 4), kind: kind, cg)
                    drawText(text, size: 7.5, tracking: 0.6, color: UIColor.ffInk,
                             at: CGPoint(x: x + 32, y: y - 1))
                    x += 32 + textWidth(text, size: 7.5, tracking: 0.6) + 22
                }
                cg.setLineDash(phase: 0, lengths: [])
                y += 20
                drawParagraph(pattern.instructions, size: 8.5, color: UIColor.ffInk,
                              in: CGRect(x: margin, y: y, width: pageSize.width - 2 * margin, height: 46))
                drawParagraph(String(localized: "Faltmuster nach dem Origami Simulator von Amanda Ghassaei (MIT-Lizenz)."),
                              size: 6.5, color: UIColor.ffGraphite,
                              in: CGRect(x: margin, y: pageSize.height - margin - 10,
                                         width: pageSize.width - 2 * margin, height: 12))
            }
            return outputURL
        } catch {
            return nil
        }
    }

    /// Linienstil nach üblicher Origami-Notation, zusätzlich in Farbe:
    /// Berg Strich-Punkt rot, Tal gestrichelt blau.
    private static func stroke(_ a: CGPoint, _ b: CGPoint, kind: Algorithms.CreaseKind, _ cg: CGContext) {
        switch kind {
        case .mountain:
            cg.setStrokeColor(UIColor(red: 0.85, green: 0.16, blue: 0.12, alpha: 0.95).cgColor)
            cg.setLineWidth(0.9); cg.setLineDash(phase: 0, lengths: [6, 2.5, 1.2, 2.5])
        case .valley:
            cg.setStrokeColor(UIColor(red: 0.12, green: 0.32, blue: 0.85, alpha: 0.95).cgColor)
            cg.setLineWidth(0.9); cg.setLineDash(phase: 0, lengths: [4, 3])
        case .facet:
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.8).cgColor)
            cg.setLineWidth(0.6); cg.setLineDash(phase: 0, lengths: [1, 2.5])
        case .cut:
            cg.setStrokeColor(UIColor(white: 0.10, alpha: 0.9).cgColor)
            cg.setLineWidth(1.0); cg.setLineDash(phase: 0, lengths: [])
        }
        cg.move(to: a); cg.addLine(to: b); cg.strokePath()
    }

    private static func drawSquareCrop(_ image: UIImage, in rect: CGRect, context cg: CGContext) {
        let s = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        cg.saveGState()
        cg.clip(to: rect)
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
        cg.restoreGState()
    }

    private static func attributes(_ size: CGFloat, _ tracking: CGFloat, _ color: UIColor) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .kern: tracking]
    }

    private static func textWidth(_ text: String, size: CGFloat, tracking: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: attributes(size, tracking, .black)).size().width
    }

    private static func drawParagraph(_ text: String, size: CGFloat, color: UIColor, in rect: CGRect) {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 2
        var attrs = attributes(size, 0.2, color); attrs[.paragraphStyle] = style
        attrs[.font] = UIFont.systemFont(ofSize: size, weight: .regular)
        NSAttributedString(string: text, attributes: attrs).draw(in: rect)
    }

    private static func drawText(_ text: String, size: CGFloat, tracking: CGFloat,
                                 color: UIColor, at point: CGPoint) {
        NSAttributedString(string: text, attributes: attributes(size, tracking, color)).draw(at: point)
    }
}
