import Foundation
import CoreGraphics
import CoreImage
import Vision
import simd

/// Gleicht Verwacklung zwischen Keyframes aus – wichtig, wenn das iPhone
/// nicht auf einem Stativ steht, sondern über die Arbeit gehalten wird.
///
/// Jeder Frame wird gegen einen FESTEN Referenzframe (den ersten) ausgerichtet,
/// nicht gegen den Vorgänger – dadurch entsteht kein aufsummierter Drift über
/// lange Sequenzen.
///
/// Zwei Stufen:
///  1. Homographie (Vision): korrigiert Verschiebung UND Verdrehung/Neigung.
///     Geschätzt wird auf einer Verkleinerung (schnell), angewendet auf das
///     Original per Core Image. Eine Plausibilitätsgrenze verwirft entgleiste
///     Schätzungen.
///  2. Fallback Block-Matching (Algorithms.estimateTranslation, deterministisch
///     und unit-getestet): reine Verschiebung, wenn die Homographie versagt.
final class FrameAligner {

    // Referenz für die Homographie (verkleinerte Kopie des ersten Frames)
    private var referenceSmall: CGImage?
    // Referenz für den Verschiebungs-Fallback (Graustufen)
    private var referenceGray: [UInt8]?
    private var refW = 0
    private var refH = 0

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Analysebreite der Homographie-Schätzung (klein = schnell)
    private let homographyWidth = 720
    /// Analysebreite des Verschiebungs-Fallbacks
    private let analysisWidth = 160
    /// Maximale Fallback-Korrektur als Anteil der Breite (15 %)
    private let maxShiftFraction = 0.15
    /// Plausibilität: maximale Ecken-Wanderung als Anteil der Bildgröße –
    /// größere Sprünge sind fast sicher Fehlschätzungen
    private let maxCornerShiftFraction = 0.12

    // MARK: Stufe 1 – Homographie

    /// Liefert eine perspektivisch ausgerichtete Kopie des Bildes oder nil,
    /// wenn keine verlässliche Homographie gefunden wurde (→ register(_:)
    /// als Fallback verwenden). Der erste Frame setzt die Referenz.
    func warp(_ image: CGImage) -> CGImage? {
        guard let small = downsampled(image, targetWidth: homographyWidth) else { return nil }
        guard let reference = referenceSmall else {
            referenceSmall = small
            return nil
        }

        let request = VNHomographicImageRegistrationRequest(targetedCGImage: small, options: [:])
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        // Homographie von Klein- auf Originalkoordinaten heben: H' = S·H·S⁻¹
        let s = Float(image.width) / Float(small.width)
        let S = matrix_float3x3(diagonal: SIMD3<Float>(s, s, 1))
        let Sinv = matrix_float3x3(diagonal: SIMD3<Float>(1 / s, 1 / s, 1))
        let H = S * observation.warpTransform * Sinv

        let w = Double(image.width), h = Double(image.height)
        func map(_ x: Double, _ y: Double) -> CGPoint? {
            let v = H * SIMD3<Float>(Float(x), Float(y), 1)
            guard abs(v.z) > 1e-6 else { return nil }
            return CGPoint(x: Double(v.x / v.z), y: Double(v.y / v.z))
        }
        guard let bl = map(0, 0), let br = map(w, 0),
              let tr = map(w, h), let tl = map(0, h) else { return nil }

        // Plausibilitätsgrenze: entgleiste Schätzungen verwerfen
        let limit = max(w, h) * maxCornerShiftFraction
        let pairs: [(CGPoint, CGPoint)] = [
            (bl, CGPoint(x: 0, y: 0)), (br, CGPoint(x: w, y: 0)),
            (tr, CGPoint(x: w, y: h)), (tl, CGPoint(x: 0, y: h))
        ]
        for (p, o) in pairs where abs(p.x - o.x) > limit || abs(p.y - o.y) > limit {
            return nil
        }

        // Anwenden per Core Image (Vision und CI teilen das
        // Unten-links-Koordinatensystem). Ränder, die die Verzerrung
        // freilegt, füllt das Originalbild – unauffälliger als Schwarz.
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        guard let warped = filter.outputImage else { return nil }

        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let composed = warped.cropped(to: rect).composited(over: ci)
        return ciContext.createCGImage(composed, from: rect)
    }

    // MARK: Stufe 2 – Verschiebungs-Fallback (Block-Matching)

    /// Liefert den Zeichnungs-Offset (in Pixeln des Originalbilds), mit dem
    /// `image` auf den Referenzframe ausgerichtet wird. Erster Frame → .zero.
    func register(_ image: CGImage) -> CGPoint {
        let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(image, targetWidth: analysisWidth)

        guard let reference = referenceGray, w == refW, h == refH else {
            referenceGray = gray; refW = w; refH = h
            return .zero
        }

        let maxShift = max(4, Int(Double(w) * maxShiftFraction))
        let (dx, dy) = Algorithms.estimateTranslation(
            reference: reference, current: gray,
            width: w, height: h, maxShift: maxShift)

        // Analysepixel → Originalpixel; current um (−dx,−dy) zurückschieben.
        let scale = CGFloat(image.width) / CGFloat(max(1, w))
        return CGPoint(x: -CGFloat(dx) * scale, y: CGFloat(dy) * scale)
    }

    func reset() {
        referenceSmall = nil
        referenceGray = nil
        refW = 0; refH = 0
    }

    // MARK: Hilfen

    private func downsampled(_ image: CGImage, targetWidth: Int) -> CGImage? {
        let w = min(targetWidth, image.width)
        let aspect = Double(image.height) / Double(image.width)
        let h = max(1, Int(Double(w) * aspect))
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
