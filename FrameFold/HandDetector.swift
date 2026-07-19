import Foundation
import Vision
import CoreGraphics

/// Stufe A der Handerkennung: Apples eingebaute Hand-Pose-Erkennung.
/// Läuft auf der Neural Engine, braucht kein externes Modell.
///
/// Stufe B (später): RF-DETR Nano als CoreML-Modell – gleiche Schnittstelle,
/// einfach dieses Protokoll implementieren und im ViewModel austauschen.
protocol HandDetecting {
    func containsHands(cgImage: CGImage, confidence: Float) -> Bool
}

final class VisionHandDetector: HandDetecting {

    func containsHands(cgImage: CGImage, confidence: Float) -> Bool {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Im Zweifel Frame behalten – lieber ein Frame mit Handschatten
            // als eine Lücke in der Animation.
            return false
        }
        guard let observations = request.results, !observations.isEmpty else {
            return false
        }
        return observations.contains { $0.confidence >= confidence }
    }
}
