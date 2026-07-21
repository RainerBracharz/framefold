import Foundation
import UIKit

/// Erzeugt aus einem Bild eine druckbare A4-Faltvorlage: das Bild plus ein
/// trianguliertes Falzraster mit gestrichelten Falzlinien und einer
/// durchgezogenen Schnittkante. Zum Ausdrucken, Ausschneiden und Nachfalten –
/// bringt das digitale Bild zurück aufs Papier (Objekt → Bild → Objekt).
enum FoldTemplateRenderer {

    private static let pageSize = CGSize(width: 595.2, height: 841.8) // A4 pt
    private static let margin: CGFloat = 48

    static func render(image: UIImage, title: String, cols: Int = 4, rows: Int = 5) -> URL? {
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
                         color: UIColor(white: 0.09, alpha: 1),
                         at: CGPoint(x: margin, y: margin))
                drawText("FALTVORLAGE · ENTLANG DER GESTRICHELTEN LINIEN FALTEN",
                         size: 7, tracking: 2.0, color: UIColor(white: 0.45, alpha: 1),
                         at: CGPoint(x: margin, y: margin + 16))

                // Bildbereich (unter der Kopfzeile), Seitenverhältnis wahren
                let top = margin + 44
                let avail = CGRect(x: margin, y: top,
                                   width: pageSize.width - 2 * margin,
                                   height: pageSize.height - top - margin)
                let scale = min(avail.width / image.size.width, avail.height / image.size.height)
                let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let imgRect = CGRect(x: avail.midX - drawSize.width / 2,
                                     y: avail.minY,
                                     width: drawSize.width, height: drawSize.height)
                image.draw(in: imgRect)

                // Falzlinien über das Bild
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
            }
            return outputURL
        } catch {
            return nil
        }
    }

    private static func drawText(_ text: String, size: CGFloat, tracking: CGFloat,
                                 color: UIColor, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .kern: tracking
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
    }
}
