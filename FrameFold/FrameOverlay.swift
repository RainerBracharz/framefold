import CoreGraphics
import UIKit

/// Farben für Text, Sprechblasen und Zeichnungen.
enum OverlayColor: String, Codable, CaseIterable, Identifiable {
    case white, black, amber, red, blue, green
    var id: String { rawValue }
    var ui: UIColor {
        switch self {
        case .white: return .white
        case .black: return UIColor(white: 0.08, alpha: 1)
        case .amber: return .ffAmber
        case .red: return UIColor(red: 0.86, green: 0.2, blue: 0.18, alpha: 1)
        case .blue: return UIColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 1)
        case .green: return UIColor(red: 0.2, green: 0.65, blue: 0.3, alpha: 1)
        }
    }
}

/// Ein Strich einer Zeichnung, in Bildkoordinaten 0…1.
struct OverlayStroke: Codable, Equatable {
    var points: [CGPoint]
    /// Strichstärke als Anteil der Bildhöhe
    var width: Double
    var color: OverlayColor
}

/// Text, Sprechblase oder Zeichnung über den Bildern `firstFrame…lastFrame`
/// (0-basiert). Positionen und Größen relativ zum Bild, damit sie in jeder
/// Auflösung und jedem Export gleich sitzen.
struct FrameOverlay: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case text, bubble, drawing }

    var id = UUID()
    var kind: Kind
    var firstFrame: Int
    var lastFrame: Int
    /// Mittelpunkt (Text, Sprechblase)
    var x = 0.5
    var y = 0.2
    var text = ""
    /// Schriftgröße als Anteil der Bildhöhe
    var size = 0.06
    var color: OverlayColor = .white
    var strokes: [OverlayStroke] = []

    func covers(_ frame: Int) -> Bool { frame >= firstFrame && frame <= lastFrame }
}

/// Zeichnet Einblendungen – für Export, Betrachter und Editor gleich.
enum OverlayRenderer {

    /// Einblendungen über ein Bild legen (nil = keine trifft dieses Bild).
    static func apply(_ overlays: [FrameOverlay], frame index: Int, to image: CGImage) -> CGImage? {
        let active = overlays.filter { $0.covers(index) }
        guard !active.isEmpty else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            draw(active, in: ctx.cgContext, size: size)
        }.cgImage
    }

    /// In einen Kontext mit Ursprung oben links zeichnen.
    static func draw(_ overlays: [FrameOverlay], in cg: CGContext, size: CGSize) {
        UIGraphicsPushContext(cg)
        defer { UIGraphicsPopContext() }
        // Zeichnungen zuerst, Text liegt obenauf
        for overlay in overlays where overlay.kind == .drawing { drawStrokes(overlay.strokes, in: cg, size: size) }
        for overlay in overlays where overlay.kind != .drawing { drawText(overlay, size: size) }
    }

    private static func drawStrokes(_ strokes: [OverlayStroke], in cg: CGContext, size: CGSize) {
        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for stroke in strokes where !stroke.points.isEmpty {
            cg.setStrokeColor(stroke.color.ui.cgColor)
            cg.setLineWidth(max(1, stroke.width * size.height))
            let pts = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            cg.beginPath()
            cg.move(to: pts[0])
            if pts.count == 1 { cg.addLine(to: pts[0]) }
            for p in pts.dropFirst() { cg.addLine(to: p) }
            cg.strokePath()
        }
        cg.restoreGState()
    }

    static func font(_ size: CGFloat) -> UIFont {
        UIFont(name: "Inter-SemiBold", size: size) ?? UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// Rahmen, den Text oder Sprechblase einnehmen (für Treffer im Editor).
    static func frame(of overlay: FrameOverlay, size: CGSize) -> CGRect {
        let text = layoutText(overlay, size: size)
        let pad = overlay.kind == .bubble ? overlay.size * size.height * 0.6 : 0
        let w = text.width + pad * 2, h = text.height + pad * 2
        return CGRect(x: overlay.x * size.width - w / 2, y: overlay.y * size.height - h / 2, width: w, height: h)
    }

    private static func layoutText(_ overlay: FrameOverlay, size: CGSize) -> CGSize {
        let attr = attributed(overlay, size: size)
        let bounds = attr.boundingRect(with: CGSize(width: size.width * 0.8, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], context: nil)
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private static func attributed(_ overlay: FrameOverlay, size: CGSize) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let fontSize = max(8, overlay.size * size.height)
        var attrs: [NSAttributedString.Key: Any] = [.font: font(fontSize), .paragraphStyle: para]
        if overlay.kind == .bubble {
            // Schrift in der Gegenfarbe der Blase
            let light: Set<OverlayColor> = [.white, .amber]
            attrs[.foregroundColor] = light.contains(overlay.color) ? UIColor(white: 0.08, alpha: 1) : UIColor.white
        } else {
            attrs[.foregroundColor] = overlay.color.ui
            // Kontur in der Gegenfarbe – lesbar auf jedem Hintergrund
            attrs[.strokeColor] = overlay.color == .black ? UIColor.white : UIColor(white: 0.05, alpha: 1)
            attrs[.strokeWidth] = -3.0
        }
        return NSAttributedString(string: overlay.text.isEmpty ? " " : overlay.text, attributes: attrs)
    }

    private static func drawText(_ overlay: FrameOverlay, size: CGSize) {
        let rect = frame(of: overlay, size: size)
        if overlay.kind == .bubble {
            let radius = min(rect.height / 2, overlay.size * size.height)
            let bubble = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            // Zipfel nach unten links
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - 1))
            tail.addLine(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.maxY + rect.height * 0.45))
            tail.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - 1))
            tail.close()
            overlay.color.ui.setFill()
            bubble.fill(); tail.fill()
            UIColor(white: 0.08, alpha: 1).setStroke()
            bubble.lineWidth = max(1.5, overlay.size * size.height * 0.08)
            tail.lineWidth = bubble.lineWidth
            bubble.stroke(); tail.stroke()
            // Naht zwischen Blase und Zipfel überdecken
            overlay.color.ui.setFill()
            UIBezierPath(rect: CGRect(x: rect.minX + rect.width * 0.22 + bubble.lineWidth,
                                      y: rect.maxY - bubble.lineWidth * 1.5,
                                      width: rect.width * 0.16 - bubble.lineWidth * 2,
                                      height: bubble.lineWidth * 2)).fill()
        }
        let text = layoutText(overlay, size: size)
        attributed(overlay, size: size).draw(with: CGRect(x: rect.midX - text.width / 2, y: rect.midY - text.height / 2,
                                                         width: text.width, height: text.height),
                                             options: [.usesLineFragmentOrigin], context: nil)
    }
}
