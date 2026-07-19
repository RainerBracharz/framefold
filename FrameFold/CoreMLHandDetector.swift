import Foundation
import Vision
import CoreML
import CoreGraphics

/// Stufe B der Handerkennung: RF-DETR (oder ein anderes Objektdetektions-
/// modell) als CoreML-Paket.
///
/// Integration:
/// 1. Auf https://app.roboflow.com ein Projekt anlegen, ~200 Bilder aus
///    Aldos Atelier annotieren (Klasse "hand", optional "arm", "tool").
/// 2. RF-DETR Nano trainieren und als CoreML (.mlpackage, FP16) exportieren.
/// 3. Die Datei als "HandDetector.mlpackage" per Drag & Drop ins
///    Xcode-Projekt ziehen (Target-Häkchen FrameFold).
/// 4. Fertig – dieser Detektor findet das Modell automatisch;
///    ohne Modell fällt die App auf Apples Vision-Handerkennung zurück.
final class CoreMLHandDetector: HandDetecting {

    /// Klassen, deren Fund einen Frame disqualifiziert.
    private let blockedLabels: Set<String> = ["hand", "hands", "arm", "person"]
    private let model: VNCoreMLModel

    /// Lädt das gebündelte Modell; nil, wenn keines im Bundle liegt.
    init?() {
        guard let url = Bundle.main.url(forResource: "HandDetector", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "HandDetector", withExtension: "mlpackage") else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all // Neural Engine bevorzugen
        guard let mlModel = try? MLModel(contentsOf: url, configuration: config),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        self.model = visionModel
    }

    func containsHands(cgImage: CGImage, confidence: Float) -> Bool {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return false // im Zweifel Frame behalten
        }
        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            return false
        }
        return observations.contains { observation in
            observation.confidence >= confidence &&
            observation.labels.contains { label in
                blockedLabels.contains(label.identifier.lowercased()) &&
                label.confidence >= confidence
            }
        }
    }
}

/// Fabrik: nimmt das CoreML-Modell, wenn vorhanden, sonst Apples Vision.
enum HandDetectorFactory {
    static func make() -> HandDetecting {
        if let coreML = CoreMLHandDetector() {
            return coreML
        }
        return VisionHandDetector()
    }
}
