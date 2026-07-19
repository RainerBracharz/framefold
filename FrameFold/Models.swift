import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Einstellungen der Stopmotion-Pipeline.
/// Alle Werte sind bewusst als Regler exponiert, damit sie sich
/// an Aldos Arbeitsweise anpassen lassen.
struct PipelineSettings {
    /// Abtastrate aus dem Quellvideo (Frames pro Sekunde der Analyse)
    var samplingFPS: Double = 6.0
    /// Analyse-Breite in Pixeln (downgesampelt für Geschwindigkeit)
    var analysisWidth: CGFloat = 160
    /// Untergrenze der adaptiven Schwelle als Perzentil der Bewegungsverteilung.
    /// Die eigentliche Schwelle wird per Otsu-Split bestimmt (siehe KeyframeSelector);
    /// dieses Perzentil dient als Fallback/Untergrenze und ist der "Empfindlichkeit"-Regler.
    var motionPercentile: Double = 0.35
    /// Mindestlänge eines Ruhefensters in Sekunden
    var minStillWindowSeconds: Double = 0.5
    /// Hände erkennen und Frames mit Händen verwerfen
    var removeHands: Bool = true
    /// Konfidenz-Schwelle der Vision-Handerkennung
    var handConfidence: Float = 0.3
    /// Hamming-Distanz-Schwelle für dHash-Deduplizierung (0–64).
    /// In Tests mit der Referenzpipeline lagen echte Szenenwechsel bei Distanz 5–8,
    /// echte Duplikate bei 0–2 → 3 trennt sauber.
    var dedupHashThreshold: Int = 3
    /// Framerate des ausgegebenen Stopmotion-Videos
    var outputFPS: Int32 = 10
    /// Seitenverhältnis des Exports (Center-Crop)
    var aspect: AspectPreset = .original
    /// Abspielmodus des Exports
    var loopMode: LoopMode = .none
    /// Frames gegeneinander ausrichten (gleicht kleine Stativ-Verschiebungen aus)
    var alignFrames: Bool = false
    /// Interferenz-Echo: der vorherige Output-Frame schimmert im nächsten nach
    /// (Rekursion des eigenen Bildes – Bild → Objekt → Bild)
    var interferenzEcho: Bool = false
    /// Stärke des Echos (Anteil des vorherigen Frames, 0..0.5)
    var echoStrength: Double = 0.3
    /// Falz-Blende: Zwischenframes pro Übergang, die den nächsten Frame
    /// entlang einer Diagonale aufdecken (0 = harte Schnitte)
    var transitionFrames: Int = 0
}

/// Export-Seitenverhältnisse (Center-Crop auf das Zielformat).
enum AspectPreset: String, CaseIterable, Identifiable {
    case original = "Original"
    case reel = "9:16 Reel"
    case square = "1:1"
    case wide = "16:9"

    var id: String { rawValue }

    /// Breite/Höhe-Verhältnis; nil = unverändert lassen
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .reel: return 9.0 / 16.0
        case .square: return 1.0
        case .wide: return 16.0 / 9.0
        }
    }
}

/// Abspielmodus: normal, Boomerang (vor + zurück) oder rückwärts
/// ("das Werk faltet sich selbst auseinander").
enum LoopMode: String, CaseIterable, Identifiable {
    case none = "Normal"
    case boomerang = "Boomerang"
    case reverse = "Rückwärts"

    var id: String { rawValue }

    /// Wandelt eine Index-Folge 0..<n in die Abspielreihenfolge um.
    func frameOrder(count: Int) -> [Int] {
        let forward = Array(0..<count)
        switch self {
        case .none: return forward
        case .reverse: return forward.reversed()
        case .boomerang:
            guard count > 2 else { return forward }
            return forward + forward.dropFirst().dropLast().reversed()
        }
    }
}

/// Ein Kandidaten-Frame aus der Analysephase.
struct FrameSample {
    let time: CMTimeValueBox
    let motionScore: Double
    var sharpness: Double = 0
}

/// CMTime lässt sich nicht direkt in Structs ohne CoreMedia-Import verwenden;
/// kleine Box für Zeitwerte in Sekunden.
struct CMTimeValueBox: Hashable {
    let seconds: Double
}

/// Ergebnis der Verarbeitung.
struct PipelineResult {
    let keyframeTimes: [Double]
    let outputURL: URL
    let sourceDuration: Double
    let discardedForHands: Int
    let discardedAsDuplicates: Int
}

/// Fortschritt der Verarbeitung für die UI.
enum PipelineStage: Equatable {
    case idle
    case sampling(progress: Double)
    case analyzing(progress: Double)
    case selectingKeyframes
    case checkingHands(progress: Double)
    case assembling(progress: Double)
    case done
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Bereit"
        case .sampling: return "Lese Frames…"
        case .analyzing: return "Analysiere Bewegung…"
        case .selectingKeyframes: return "Wähle Keyframes…"
        case .checkingHands: return "Prüfe auf Hände…"
        case .assembling: return "Baue Stopmotion…"
        case .done: return "Fertig"
        case .failed(let msg): return "Fehler: \(msg)"
        }
    }
}
