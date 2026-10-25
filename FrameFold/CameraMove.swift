import CoreGraphics
import Foundation

/// Bildausschnitt: Mittelpunkt (0…1 relativ zum Bild) und Zoom (1 = ganzes Bild).
struct Framing: Codable, Equatable {
    var x = 0.5
    var y = 0.5
    var zoom = 1.0

    static let full = Framing()

    /// Ausschnitt in Pixeln – bleibt immer ganz im Bild.
    func rect(in size: CGSize) -> CGRect {
        let z = min(max(zoom.isFinite ? zoom : 1, 1), 4)
        let w = size.width / z, h = size.height / z
        let cx = min(max(x * size.width, w / 2), size.width - w / 2)
        let cy = min(max(y * size.height, h / 2), size.height - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func mixed(with other: Framing, _ t: Double) -> Framing {
        // Zoom geometrisch mischen – sonst wirkt der Zoom am Anfang zu schnell
        Framing(x: x + (other.x - x) * t, y: y + (other.y - y) * t,
                zoom: zoom * pow(other.zoom / zoom, t))
    }
}

/// Kamerafahrt über die Bilder `firstFrame…lastFrame` (0-basiert): von
/// einem Ausschnitt zum anderen – Schwenk, Zoom oder beides. Vor und nach
/// der Fahrt bleibt der jeweilige End-Ausschnitt stehen, bis die nächste
/// Fahrt beginnt.
struct CameraMove: Codable, Equatable, Identifiable {
    var id = UUID()
    var firstFrame: Int
    var lastFrame: Int
    var from: Framing = .full
    var to = Framing(x: 0.5, y: 0.5, zoom: 1.5)
    /// Weich anfahren und abbremsen statt gleichförmig
    var smooth = true

    func framing(at frame: Int) -> Framing {
        guard lastFrame > firstFrame else { return frame < firstFrame ? from : to }
        let raw = Double(frame - firstFrame) / Double(lastFrame - firstFrame)
        let t = min(max(raw, 0), 1)
        return from.mixed(with: to, smooth ? t * t * (3 - 2 * t) : t)
    }
}

enum CameraMoves {
    /// Ausschnitt für ein Bild – nil, wenn keine Fahrt das Bild betrifft
    /// (ganzes Bild). Nach dem Ende einer Fahrt bleibt deren Ziel stehen.
    static func framing(_ moves: [CameraMove], at frame: Int) -> Framing? {
        guard !moves.isEmpty else { return nil }
        let sorted = moves.sorted { $0.firstFrame < $1.firstFrame }
        if let active = sorted.last(where: { $0.firstFrame <= frame }) {
            let f = active.framing(at: frame)
            return f == .full ? nil : f
        }
        return nil
    }

    /// Bild auf den Ausschnitt zuschneiden und wieder auf volle Größe bringen.
    static func apply(_ framing: Framing, to image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let crop = framing.rect(in: size)
        guard crop.width < size.width - 0.5 || crop.height < size.height - 0.5,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // CGContext zählt y von unten – Ausschnitt entsprechend spiegeln
        let scale = size.width / crop.width
        let originX = -crop.minX * scale
        let originY = -(size.height - crop.maxY) * scale
        ctx.draw(image, in: CGRect(x: originX, y: originY, width: size.width * scale, height: size.height * scale))
        return ctx.makeImage()
    }
}
