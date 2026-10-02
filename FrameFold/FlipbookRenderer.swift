import Foundation
import UIKit

/// Das Daumenkino als druckfertiges PDF: Aus der Stopmotion wird wieder ein
/// Objekt aus Papier. Bild → Objekt → Bild, und am Ende wieder Objekt.
///
/// Aufbau eines Blattes: links die Bindekante mit Blattnummer (dort wird
/// geklammert oder geleimt), rechts das Bild. Die Blätter stoßen auf dem
/// Bogen direkt aneinander, Schnittmarken sitzen im Rand. Blatt 1 ist das
/// Deckblatt; kurze Serien laufen mehrmals durch, damit das Büchlein dick
/// genug zum Blättern wird.
enum FlipbookRenderer {

    /// A4 in PostScript-Punkten
    private static let pageSize = CGSize(width: 595.2, height: 841.8)
    private static let margin: Double = 28
    private static let footer: Double = 28

    private static let ink = UIColor(white: 0.09, alpha: 1)
    private static let graphite = UIColor(white: 0.45, alpha: 1)
    private static let hairline = UIColor(white: 0.72, alpha: 1)

    static func render(title: String, dateText: String, frameURLs: [URL]) -> URL? {
        guard let first = frameURLs.first,
              let firstImage = UIImage(contentsOfFile: first.path),
              firstImage.size.height > 0
        else { return nil }

        let aspect = Double(firstImage.size.width / firstImage.size.height)
        let cells = Algorithms.flipbookLayout(
            imageAspect: aspect,
            pageWidth: pageSize.width, pageHeight: pageSize.height,
            margin: margin, footer: footer)
        let sequence = Algorithms.flipbookSequence(frameCount: frameURLs.count)
        guard !cells.isEmpty, !sequence.isEmpty else { return nil }

        let sheets = Int((Double(sequence.count) / Double(cells.count)).rounded(.up))
        let leafCount = sequence.count
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daumenkino-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        // Bilder nur einmal dekodieren, auch wenn die Serie mehrfach durchläuft;
        // dabei auf Druckgröße verkleinern, sonst wird das PDF unnötig schwer.
        var cache: [Int: UIImage] = [:]
        func image(_ i: Int) -> UIImage? {
            if let hit = cache[i] { return hit }
            guard let full = UIImage(contentsOfFile: frameURLs[i].path) else { return nil }
            let target = CGSize(width: 900, height: 900 / aspect)
            let scaled = UIGraphicsImageRenderer(size: target).image { _ in
                full.draw(in: CGRect(origin: .zero, size: target))
            }
            cache[i] = scaled
            return scaled
        }

        do {
            try renderer.writePDF(to: outputURL) { ctx in
                var leaf = 0
                for sheet in 0..<sheets {
                    ctx.beginPage()
                    let cg = ctx.cgContext
                    for cell in cells {
                        guard leaf < sequence.count else { break }
                        if let frame = sequence[leaf] {
                            if let img = image(frame) {
                                img.draw(in: cell.image)
                            }
                            cg.setStrokeColor(hairline.cgColor)
                            cg.setLineWidth(0.3)
                            cg.stroke(cell.image)
                        } else {
                            drawCover(in: cell, title: title, dateText: dateText,
                                      leafCount: leafCount)
                        }
                        drawBinding(cell: cell, number: leaf + 1, in: cg)
                        drawCutLines(around: cell.page, in: cg)
                        leaf += 1
                    }
                    drawFooter(sheet: sheet + 1, sheets: sheets, title: title)
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }

    // MARK: Zeichnen

    /// Bindekante: schmaler Streifen links, Blattnummer quer gestellt,
    /// eine gepunktete Linie markiert, bis wohin die Klammer reicht.
    private static func drawBinding(cell: Algorithms.FlipbookCell, number: Int, in cg: CGContext) {
        let b = cell.binding
        cg.saveGState()
        cg.setStrokeColor(hairline.cgColor)
        cg.setLineWidth(0.4)
        cg.setLineDash(phase: 0, lengths: [1.5, 2.5])
        cg.move(to: CGPoint(x: b.maxX - 4, y: b.minY + 6))
        cg.addLine(to: CGPoint(x: b.maxX - 4, y: b.maxY - 6))
        cg.strokePath()
        cg.restoreGState()

        // Nummer um 90° gedreht, von unten lesbar wie auf einem Buchrücken
        let text = NSAttributedString(string: String(format: "%03d", number), attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 7, weight: .medium),
            .foregroundColor: graphite, .kern: 1.2])
        cg.saveGState()
        cg.translateBy(x: b.minX + 12, y: b.maxY - 8)
        cg.rotate(by: -.pi / 2)
        text.draw(at: .zero)
        cg.restoreGState()
    }

    /// Schnittlinie um jedes Blatt – sehr hell, damit sie beim Schneiden
    /// hilft, aber im fertigen Büchlein nicht stört (sie wird ja abgeschnitten).
    private static func drawCutLines(around rect: CGRect, in cg: CGContext) {
        cg.saveGState()
        cg.setStrokeColor(UIColor(white: 0.82, alpha: 1).cgColor)
        cg.setLineWidth(0.3)
        cg.stroke(rect)
        cg.restoreGState()
    }

    private static func drawCover(in cell: Algorithms.FlipbookCell, title: String,
                                  dateText: String, leafCount: Int) {
        let r = cell.image
        let serif = UIFont(name: "Fraunces-Italic", size: 17)
            ?? UIFont.italicSystemFont(ofSize: 17)
        let titleText = NSAttributedString(string: title, attributes: [
            .font: serif, .foregroundColor: ink])
        titleText.draw(with: CGRect(x: r.minX + 4, y: r.minY + 8,
                                    width: r.width - 8, height: r.height * 0.55),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                       context: nil)

        let meta = String(format: String(localized: "Daumenkino · %lld Blätter"), leafCount)
            .uppercased() + "\n" + dateText.uppercased()
        NSAttributedString(string: meta, attributes: [
            .font: UIFont.systemFont(ofSize: 6.5, weight: .medium),
            .foregroundColor: graphite, .kern: 1.4]
        ).draw(with: CGRect(x: r.minX + 4, y: r.maxY - 30, width: r.width - 8, height: 26),
               options: [.usesLineFragmentOrigin], context: nil)

        NSAttributedString(string: "FRAMEFOLD", attributes: [
            .font: UIFont.systemFont(ofSize: 6, weight: .semibold),
            .foregroundColor: graphite, .kern: 2]
        ).draw(at: CGPoint(x: r.maxX - 52, y: r.maxY - 12))
    }

    private static func drawFooter(sheet: Int, sheets: Int, title: String) {
        let instructions = String(localized: "Entlang der hellen Linien schneiden · in Reihenfolge stapeln, Blatt 001 oben · an der Bindekante klammern oder leimen · am rechten Rand blättern")
        let line = sheets > 1
            ? instructions + "   ·   " + String(format: String(localized: "Bogen %lld/%lld"), sheet, sheets)
            : instructions
        NSAttributedString(string: line.uppercased(), attributes: [
            .font: UIFont.systemFont(ofSize: 5.5, weight: .medium),
            .foregroundColor: graphite, .kern: 1.0]
        ).draw(with: CGRect(x: margin, y: pageSize.height - margin - footer + 10,
                            width: pageSize.width - 2 * margin, height: footer),
               options: [.usesLineFragmentOrigin], context: nil)
    }
}
