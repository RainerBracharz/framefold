import Foundation
import UIKit

/// Der Kontaktbogen als druckfertiges PDF: alle Frames eines Projekts
/// im Katalog-Layout auf A4 – zum Ausdrucken, Aufhängen und Wiederfalten.
/// Damit schließt sich der Kreis Bild → Objekt → Bild auf Papier.
enum ContactSheetRenderer {

    /// A4 in PostScript-Punkten
    private static let pageSize = CGSize(width: 595.2, height: 841.8)
    private static let margin: Double = 40
    private static let gutter: Double = 6
    private static let columns = 4
    private static let captionHeight: Double = 46

    /// Rendert die Frames als mehrseitiges PDF und liefert die Datei-URL.
    static func render(
        title: String,
        dateText: String,
        frameURLs: [URL]
    ) -> URL? {
        guard !frameURLs.isEmpty else { return nil }

        let pages = Algorithms.contactSheetLayout(
            count: frameURLs.count,
            pageWidth: pageSize.width, pageHeight: pageSize.height,
            margin: margin, gutter: gutter,
            columns: columns, captionHeight: captionHeight)
        guard !pages.isEmpty else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kontaktbogen-\(UUID().uuidString).pdf")

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize))

        do {
            var frameIndex = 0
            try renderer.writePDF(to: outputURL) { ctx in
                for (pageNumber, rects) in pages.enumerated() {
                    ctx.beginPage()
                    drawCaption(title: title, dateText: dateText,
                                frameCount: frameURLs.count,
                                page: pageNumber + 1, pageCount: pages.count)

                    for rect in rects {
                        guard frameIndex < frameURLs.count else { break }
                        let url = frameURLs[frameIndex]
                        frameIndex += 1

                        if let data = try? Data(contentsOf: url),
                           let image = UIImage(data: data) {
                            drawAspectFill(image: image, in: rect)
                        }
                        // Haarlinienrahmen wie im Kontaktbogen der App
                        let cg = ctx.cgContext
                        cg.setStrokeColor(UIColor(white: 0.72, alpha: 1).cgColor)
                        cg.setLineWidth(0.5)
                        cg.stroke(rect)

                        // Frame-Nummer unter der Zelle
                        let numText = String(format: "%03d", frameIndex)
                        draw(text: numText, size: 6, tracking: 1.2,
                             color: UIColor(white: 0.45, alpha: 1),
                             at: CGPoint(x: rect.minX + 1, y: rect.maxY + 2))
                    }
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }

    // MARK: Zeichnen

    private static func drawCaption(
        title: String, dateText: String,
        frameCount: Int, page: Int, pageCount: Int
    ) {
        // Kopfzeile im Katalog-Stil
        draw(text: title.uppercased(), size: 10, tracking: 2.4,
             color: UIColor(white: 0.09, alpha: 1),
             at: CGPoint(x: margin, y: margin))
        let meta = "\(frameCount) FRAMES · \(dateText)"
            + (pageCount > 1 ? " · BOGEN \(page)/\(pageCount)" : "")
        draw(text: meta, size: 7, tracking: 2.0,
             color: UIColor(white: 0.45, alpha: 1),
             at: CGPoint(x: margin, y: margin + 16))
    }

    private static func draw(
        text: String, size: CGFloat, tracking: CGFloat,
        color: UIColor, at point: CGPoint
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .kern: tracking
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: point)
    }

    private static func drawAspectFill(image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width,
                        rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale,
                              height: image.size.height * scale)
        let drawOrigin = CGPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2)

        if let cg = UIGraphicsGetCurrentContext() {
            cg.saveGState()
            cg.clip(to: rect)
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
            cg.restoreGState()
        }
    }
}
