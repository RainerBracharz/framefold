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

    /// Muster mit Berg und Tal werden quadratisch gedruckt
    var isSquare: Bool { self != .grid }

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
    var id: String { rawValue }
    var pattern: FoldPattern? {
        switch self {
        case .off: return nil
        case .hypar: return .hypar
        case .circularPleat: return .circularPleat
        case .miura: return .miura
        }
    }
    var label: String { pattern?.label ?? String(localized: "aus") }

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

    /// Ganzes Muster quadratisch und mittig in `rect` (ohne Blatterkennung).
    func draw(in ctx: inout GraphicsContext, rect: CGRect, opacity: Double = 0.8) {
        let side = min(rect.width, rect.height) * 0.9
        let s = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        draw(in: &ctx, quad: [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY),
                              CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX, y: s.maxY)],
             step: nil, opacity: opacity)
    }

    var stepCount: Int { unitSteps.steps.count }
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

    var body: some View {
        Canvas { ctx, size in
            guard let paperQuad else { return }
            let image = Self.imageRect(aspect: imageAspect, in: size, fills: fills)
            let quad = paperQuad.map { CGPoint(x: image.minX + $0.x * image.width, y: image.minY + $0.y * image.height) }
            guide.draw(in: &ctx, quad: quad, step: step.map { max(0, $0) })
        }
        .opacity(paperQuad == nil ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: paperQuad == nil)
        .overlay(alignment: .bottom) {
            if guide != .off {
                Text(label)
                    .font(Theme.mono(11)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55))
                    .padding(.bottom, 10)
            }
        }
        .allowsHitTesting(false)
    }

    private var label: String {
        guard paperQuad != nil else { return String(localized: "Faltmuster: Blatt nicht erkannt") }
        guard let rawStep = step else { return guide.label }
        let step = max(0, rawStep)
        let n = guide.stepCount
        return step >= n ? String(localized: "Faltmuster: alle \(n) Schritte gefaltet")
                         : String(localized: "Faltmuster: Schritt \(step + 1) von \(n)")
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
                let sub = pattern == .grid
                    ? "FALTVORLAGE · ENTLANG DER GESTRICHELTEN LINIEN FALTEN"
                    : String(localized: "FALTVORLAGE · \(pattern.label.uppercased())")
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
