import Foundation
import SwiftUI

/// Einstellungen der Studio-Arbeitsfläche (Mac). Bleiben über Neustarts
/// erhalten – wer einmal mit 2,39:1-Maske und drei Zwiebelhaut-Bildern
/// arbeitet, will das morgen wieder so.
struct StudioSettings: Codable, Equatable {
    // Ansicht
    var viewMode: StudioViewMode = .normal
    var onionFrames = 1
    var onionOpacity = 0.35
    /// Auto-Umschalten Live ↔ letztes Bild: Wechsel pro Sekunde
    var toggleRate = 2.0
    var shortPlayFrames = 12

    /// Lupe: vergrößerter Ausschnitt des Live-Bilds zum Prüfen der Schärfe
    var loupe = false
    var loupeZoom = 4
    var loupeX = 0.5
    var loupeY = 0.5

    // Hilfen
    var mask: MaskAspect = .none
    var maskOpacity = 0.7
    var safeFrames = false
    var gridColumns = 0
    var gridRows = 0

    // Referenz
    var referenceOpacity = 0.5
    var referenceScale = 1.0
    var referenceOffsetX = 0.0
    var referenceOffsetY = 0.0
    var referenceKey: ChromaKey = .none

    // Aufnahme
    var autoShutter = true
    var averageFrames = 1
    var captureBlackout = false

    // Ton
    /// Beim Blättern den Ton genau dieses Bilds anspielen
    var scrubAudio = true
    /// Mundformen der Figuren im Betrachter einblenden
    var dialogueHUD = true

    // Zeitraffer
    var intervalSeconds = 5.0
    var useStartTime = false
    /// Start so viele Minuten nach dem Druck auf „Zeitraffer starten“
    var startDelayMinutes = 60.0
    var useEndTime = false
    /// Dauer in Minuten ab Start
    var durationMinutes = 60.0
    var useFrameLimit = false
    var frameLimit = 100

    init() {}

    /// Feldweise dekodieren: Kommt eine Einstellung dazu, gilt nur für sie
    /// der Standard – die übrige gespeicherte Wahl bleibt.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudioSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        viewMode = v(.viewMode, d.viewMode)
        onionFrames = v(.onionFrames, d.onionFrames)
        onionOpacity = v(.onionOpacity, d.onionOpacity)
        toggleRate = v(.toggleRate, d.toggleRate)
        shortPlayFrames = v(.shortPlayFrames, d.shortPlayFrames)
        loupe = v(.loupe, d.loupe)
        loupeZoom = v(.loupeZoom, d.loupeZoom)
        loupeX = v(.loupeX, d.loupeX)
        loupeY = v(.loupeY, d.loupeY)
        mask = v(.mask, d.mask)
        maskOpacity = v(.maskOpacity, d.maskOpacity)
        safeFrames = v(.safeFrames, d.safeFrames)
        gridColumns = v(.gridColumns, d.gridColumns)
        gridRows = v(.gridRows, d.gridRows)
        referenceOpacity = v(.referenceOpacity, d.referenceOpacity)
        referenceScale = v(.referenceScale, d.referenceScale)
        referenceOffsetX = v(.referenceOffsetX, d.referenceOffsetX)
        referenceOffsetY = v(.referenceOffsetY, d.referenceOffsetY)
        referenceKey = v(.referenceKey, d.referenceKey)
        autoShutter = v(.autoShutter, d.autoShutter)
        averageFrames = v(.averageFrames, d.averageFrames)
        captureBlackout = v(.captureBlackout, d.captureBlackout)
        scrubAudio = v(.scrubAudio, d.scrubAudio)
        dialogueHUD = v(.dialogueHUD, d.dialogueHUD)
        intervalSeconds = v(.intervalSeconds, d.intervalSeconds)
        useStartTime = v(.useStartTime, d.useStartTime)
        startDelayMinutes = v(.startDelayMinutes, d.startDelayMinutes)
        useEndTime = v(.useEndTime, d.useEndTime)
        durationMinutes = v(.durationMinutes, d.durationMinutes)
        useFrameLimit = v(.useFrameLimit, d.useFrameLimit)
        frameLimit = v(.frameLimit, d.frameLimit)
    }

    private static let key = "studioSettings"

    static func restored() -> StudioSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(StudioSettings.self, from: data) else {
            return StudioSettings()
        }
        return settings
    }

    func persist() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Was der Betrachter zeigt.
enum StudioViewMode: String, Codable, CaseIterable, Identifiable {
    case normal, difference, clipping
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .difference: return String(localized: "Differenz")
        case .clipping: return String(localized: "Belichtung")
        }
    }
}

/// Formatmasken – Bildformate aus Kino, Fernsehen und Netz.
enum MaskAspect: String, Codable, CaseIterable, Identifiable {
    case none, scope, flat, hd, academy, square, vertical
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .none: return nil
        case .scope: return 2.39
        case .flat: return 1.85
        case .hd: return 16.0 / 9.0
        case .academy: return 4.0 / 3.0
        case .square: return 1
        case .vertical: return 9.0 / 16.0
        }
    }
    var label: String {
        switch self {
        case .none: return String(localized: "Keine")
        case .scope: return "2,39:1"
        case .flat: return "1,85:1"
        case .hd: return "16:9"
        case .academy: return "4:3"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }
}

/// Chroma-Key der Referenzebene: diese Farbe wird durchsichtig.
enum ChromaKey: String, Codable, CaseIterable, Identifiable {
    case none, green, blue
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return String(localized: "Aus")
        case .green: return String(localized: "Grün")
        case .blue: return String(localized: "Blau")
        }
    }
    /// Farbton-Mitte in Grad
    var hue: Double? {
        switch self {
        case .none: return nil
        case .green: return 120
        case .blue: return 225
        }
    }
}

/// Tastaturbefehle der Arbeitsfläche – kommen über das Menü „Studio“, damit
/// sie am Mac in der Menüleiste stehen und sich nachschlagen lassen.
enum StudioCommand: String {
    case capture, stepBack, stepForward, live, play, shortPlay
    case toggle, autoToggle, loopIn, loopOut, loopClear
    case duplicate, delete, onionMore, onionLess, cycleView, note, testShot, xsheet, loupe, loupeZoom
}

/// Ob gerade eine Studio-Arbeitsfläche offen ist – nur dann sind die
/// Menübefehle aktiv. Sonst würden einfache Tasten wie „P“ oder „L“ jedes
/// Textfeld der App kapern.
@MainActor
final class StudioHub: ObservableObject {
    static let shared = StudioHub()
    @Published var isActive = false

    func send(_ command: StudioCommand) {
        NotificationCenter.default.post(name: .ffStudio, object: command.rawValue)
    }
}

extension Notification.Name {
    /// Studio-Befehl (object: `StudioCommand.rawValue`)
    static let ffStudio = Notification.Name("ffStudio")
}

/// Schleifen- und Wiedergabelogik, getrennt von der Ansicht und testbar.
enum StudioPlayback {
    /// Bilder, die „Abspielen“ zeigt: mit gesetzten Marken nur der Bereich
    /// dazwischen, sonst alle.
    static func range(count: Int, loopIn: Int?, loopOut: Int?) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let lower = min(max(loopIn ?? 0, 0), count - 1)
        let upper = min(max(loopOut ?? count - 1, lower), count - 1)
        return lower...upper
    }

    /// „Kurz abspielen“: die letzten `frames` Bilder vor dem Live-Bild.
    static func shortRange(count: Int, frames: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        return max(0, count - frames)...(count - 1)
    }

    /// Schritt durch die Bilder: `nil` steht für das Live-Bild hinter dem
    /// letzten Bild. Vor dem ersten Bild bleibt es beim ersten.
    static func step(from index: Int?, by delta: Int, count: Int) -> Int? {
        let current = index ?? count
        let next = min(max(current + delta, 0), count)
        return next == count ? nil : next
    }
}

/// Ausschnitt der Lupe im Kamerabild: um `center` (0…1), `zoom`-fach
/// vergrößert, im Seitenverhältnis `aspect` des Lupenfensters, am Rand
/// angehalten statt abgeschnitten.
func studioLoupeRect(imageSize: CGSize, center: CGPoint, zoom: Int, aspect: Double) -> CGRect {
    let w = imageSize.width / CGFloat(max(1, zoom))
    let h = min(imageSize.height, w / CGFloat(max(0.1, aspect)))
    let x = min(max(0, center.x * imageSize.width - w / 2), imageSize.width - w)
    let y = min(max(0, center.y * imageSize.height - h / 2), imageSize.height - h)
    return CGRect(x: x, y: y, width: w, height: h).integral
}
