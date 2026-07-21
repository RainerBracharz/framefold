import Foundation
import CoreGraphics

/// Gleicht Verwacklung zwischen Keyframes aus – wichtig, wenn das iPhone
/// nicht auf einem Stativ steht, sondern über die Arbeit gehalten wird.
///
/// Jeder Frame wird gegen einen FESTEN Referenzframe (den ersten) ausgerichtet,
/// nicht gegen den Vorgänger – dadurch entsteht kein aufsummierter Drift über
/// lange Sequenzen. Die Verschiebung wird selbst per Block-Matching auf einer
/// Graustufen-Verkleinerung geschätzt (Algorithms.estimateTranslation), die
/// deterministisch und unit-getestet ist.
///
/// Grenzen: korrigiert Verschiebung (das Dominante beim Handhalten) sehr gut;
/// starke Verdrehung/Neigung bleibt teilweise bestehen. Für makellose
/// Ergebnisse ist eine feste Auflage/Stativ weiterhin am besten.
final class FrameAligner {

    private var referenceGray: [UInt8]?
    private var refW = 0
    private var refH = 0

    /// Analysebreite für die Schätzung (klein = schnell, robust).
    private let analysisWidth = 160
    /// Maximale Korrektur als Anteil der Breite (15 %).
    private let maxShiftFraction = 0.15

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
        referenceGray = nil
        refW = 0; refH = 0
    }
}
