import Foundation
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
