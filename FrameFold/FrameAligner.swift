import Foundation
import Vision
import CoreGraphics

/// Gleicht kleine Verschiebungen zwischen aufeinanderfolgenden Frames aus
/// (z. B. wenn das Stativ zwischen Sessions minimal bewegt wurde).
///
/// Arbeitet inkrementell: jeder Frame wird gegen den vorherigen registriert
/// (VNTranslationalImageRegistrationRequest), die Offsets werden akkumuliert,
/// sodass alle Frames im Koordinatensystem des ersten Frames landen.
/// Nur der jeweils letzte Frame bleibt im Speicher.
final class FrameAligner {

    private var previous: CGImage?
    private var accumulated = CGPoint.zero
    /// Maximal erlaubte Gesamtverschiebung in Pixeln – schützt vor
    /// Fehlregistrierungen bei komplett veränderten Szenen.
    var maxShift: CGFloat = 80

    /// Registriert den Frame gegen den Vorgänger und liefert den
    /// akkumulierten Offset (in Pixeln des Quellbilds), der beim Zeichnen
    /// angewendet werden soll. Erster Frame → .zero.
    func register(_ image: CGImage) -> CGPoint {
        defer { previous = image }
        guard let previous else { return .zero }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image, options: [:])
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return accumulated
        }
        guard let observation = request.results?.first else {
            return accumulated
        }
        let t = observation.alignmentTransform
        // Verschiebung, die den neuen Frame auf den alten abbildet
        let shift = CGPoint(x: -t.tx, y: t.ty) // Vision-Y ist gespiegelt zu CoreGraphics
        let next = CGPoint(x: accumulated.x + shift.x, y: accumulated.y + shift.y)

        // Ausreißer verwerfen (Szenenwechsel, Fehlregistrierung)
        if abs(next.x) > maxShift || abs(next.y) > maxShift {
            return accumulated
        }
        accumulated = next
        return accumulated
    }

    func reset() {
        previous = nil
        accumulated = .zero
    }
}
