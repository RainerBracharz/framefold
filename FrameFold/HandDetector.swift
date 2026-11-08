import Foundation
import Vision
import CoreGraphics

/// Stufe A der Handerkennung: Apples eingebaute Hand-Pose-Erkennung.
/// Läuft auf der Neural Engine, braucht kein externes Modell.
///
/// Stufe B: ein eigenes CoreML-Modell (CoreMLHandDetector) – greift nur,
/// wenn eines gebündelt ist; die Auswahl trifft `HandDetectorFactory`.
/// Derzeit ist keins dabei, es läuft Stufe A.
protocol HandDetecting {
    func containsHands(cgImage: CGImage, confidence: Float) -> Bool
}

final class VisionHandDetector: HandDetecting {

    /// Mindestanteil der Bildfläche, den die Personen-Segmentierung als
    /// Mensch sehen muss, und Mindestanteil des Bildrands, den diese Fläche
    /// berühren muss. Gemessen an eval/hands: Lehrfilm 1959 (621 Bilder von
    /// Hand beschriftet) und Puppenfilm „Round and Round“ 1939 (355 Bilder,
    /// nur Holzfiguren). Hand-Pose allein: 77 % erkannt, 64 Puppenbilder als
    /// Hand. Diese Regel: 91 % erkannt, 9 Puppenbilder.
    static let personArea = 0.05
    static let personEdge = 0.03
    /// Eine Hand aus der Hand-Pose zählt nur, wenn die Personenmaske in ihrer
    /// Nähe anschlägt. Figurenhände (Holz, Knete, LEGO) erkennt die Hand-Pose
    /// oft als Hand, die Personen-Segmentierung aber nicht als Mensch.
    static let maskNearHand = 0.1

    func containsHands(cgImage: CGImage, confidence: Float) -> Bool {
        let pose = VNDetectHumanHandPoseRequest()
        pose.maximumHandCount = 2
        // Schnelle Stufe mit Absicht: Ihre gröbere Maske erfasst angeschnittene
        // Hände, Arme und Nahaufnahmen, die die Hand-Pose nicht findet, und
        // schlug im Eval anders als „balanced“/„accurate“ nicht auf Grafiken an.
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .fast
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([pose, person])
        } catch {
            // Im Zweifel Frame behalten – lieber ein Frame mit Handschatten
            // als eine Lücke in der Animation.
            return false
        }
        guard let mask = person.results?.first?.pixelBuffer else { return false }
        for hand in pose.results ?? [] where hand.confidence >= confidence {
            let points = ((try? hand.recognizedPoints(.all)) ?? [:]).values.map(\.location)
            if Self.maskPeak(mask, near: points) >= Self.maskNearHand { return true }
        }
        let (area, edge) = Self.coverage(mask)
        // Hände und Arme kommen beim Animieren vom Bildrand herein; eine Figur
        // mitten im Bild berührt den Rand nicht und bleibt erhalten.
        return area >= Self.personArea && edge >= Self.personEdge
    }

    /// Höchster Maskenwert (0…1) im Umkreis von 4 % der Breite um die Punkte
    /// (Vision-Koordinaten, Ursprung unten links).
    static func maskPeak(_ mask: CVPixelBuffer, near points: [CGPoint]) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return 0 }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let r = max(1, w / 25)
        var peak: UInt8 = 0
        for pt in points {
            let cx = Int(pt.x * CGFloat(w)), cy = Int((1 - pt.y) * CGFloat(h))
            for y in max(0, cy - r)..<min(h, cy + r + 1) {
                for x in max(0, cx - r)..<min(w, cx + r + 1) { peak = max(peak, p[y * rowBytes + x]) }
            }
        }
        return Double(peak) / 255
    }

    /// Anteil der Maske an der ganzen Fläche und am äußeren Rand (8 % je Seite).
    static func coverage(_ mask: CVPixelBuffer) -> (area: Double, edge: Double) {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return (0, 0) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let mx = max(1, w * 8 / 100), my = max(1, h * 8 / 100)
        var on = 0, edge = 0, edgeOn = 0
        for y in 0..<h {
            let row = p + y * rowBytes
            let edgeRow = y < my || y >= h - my
            for x in 0..<w {
                let v = row[x] > 127
                if v { on += 1 }
                if edgeRow || x < mx || x >= w - mx {
                    edge += 1
                    if v { edgeOn += 1 }
                }
            }
        }
        return (Double(on) / Double(max(1, w * h)), Double(edgeOn) / Double(max(1, edge)))
    }
}
