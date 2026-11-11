import AppIntents
import SwiftUI

/// Befehle für Siri und die Kurzbefehle-App. Beim Stop-Motion sind die Hände
/// am Objekt – auslösen, zurücknehmen und beenden gehen damit auf Zuruf.
///
/// Die Befehle tun nichts Eigenes: Sie schicken dieselben Nachrichten wie die
/// Menüleiste am Mac (`.ffCaptureNow`, `.ffFinishSession`, …). Was die
/// Ansichten daraus machen, bleibt an einer Stelle.

/// Was die Befehle von der laufenden App wissen müssen.
@MainActor
enum SiriBridge {
    /// Der Werke-Speicher der App (gesetzt beim Start in `FrameFoldApp.init`).
    static var store: ProjectStore?
    /// Die Kamera-Steuerung des Kamera-Tabs, solange es ihn gibt.
    static weak var controller: LiveCaptureController?
    /// Werk, das die Werkansicht gleich nach dem Öffnen exportieren soll.
    static var pendingExport: UUID?

    static var isCapturing: Bool { controller?.isRunning == true }
}

extension Notification.Name {
    /// Werk exportieren (object: die UUID des Werks) – die Werkansicht prüft
    /// zusätzlich `SiriBridge.pendingExport`, damit der Export nur einmal läuft.
    static let ffExportWork = Notification.Name("ffExportWork")
}

/// Ohne laufende Aufnahme gibt es nichts auszulösen oder zurückzunehmen.
enum SiriIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notCapturing
    case workMissing
    case workEmpty

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notCapturing: return "Gerade läuft keine Aufnahme."
        case .workMissing: return "Dieses Werk gibt es nicht mehr."
        case .workEmpty: return "Dieses Werk hat noch keine Bilder."
        }
    }
}

// MARK: Werke

/// Ein Werk, wie Siri und Kurzbefehle es sehen: Name und Bildzahl.
struct WorkEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Werk"
    static let defaultQuery = WorkQuery()

    let id: UUID
    let name: String
    let frameCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(frameCount) Bilder")
    }

    init(_ project: Project) {
        id = project.id
        name = project.name
        frameCount = project.frameCount
    }
}

struct WorkQuery: EntityStringQuery {
    @MainActor
    private var all: [WorkEntity] { (SiriBridge.store?.projects ?? []).map(WorkEntity.init) }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WorkEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [WorkEntity] {
        all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WorkEntity] { all }
}

// MARK: Aufnahme

/// Öffnet die Kamera mit einem Werk. Ohne Angabe entsteht ein neues Werk –
/// wie „Neues Werk“ im Kamera-Tab.
struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Aufnahme starten"
    static let description = IntentDescription("Öffnet die Kamera und nimmt in ein Werk auf. Ohne Angabe entsteht ein neues Werk.")
    static let openAppWhenRun = true

    @Parameter(title: "Werk", description: "Das Werk, in das aufgenommen wird.")
    var work: WorkEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = SiriBridge.store else { return .result() }
        let id: UUID
        if let work {
            guard store.projects.contains(where: { $0.id == work.id }) else { throw SiriIntentError.workMissing }
            id = work.id
        } else {
            id = store.createProject(name: "").id
        }
        ContinueWork.pending = id
        NotificationCenter.default.post(name: .ffContinueWork, object: id)
        return .result()
    }
}

/// Löst ein Bild aus – nur, solange der Sucher läuft.
struct CaptureFrameIntent: AppIntent {
    static let title: LocalizedStringResource = "Auslösen"
    static let description = IntentDescription("Nimmt in der laufenden Aufnahme ein Bild auf.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard SiriBridge.isCapturing else { throw SiriIntentError.notCapturing }
        NotificationCenter.default.post(name: .ffCaptureNow, object: nil)
        return .result()
    }
}

/// Nimmt das zuletzt aufgenommene Bild dieser Sitzung zurück.
struct UndoLastFrameIntent: AppIntent {
    static let title: LocalizedStringResource = "Letztes Bild zurücknehmen"
    static let description = IntentDescription("Nimmt in der laufenden Aufnahme das letzte Bild zurück.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard SiriBridge.isCapturing else { throw SiriIntentError.notCapturing }
        NotificationCenter.default.post(name: .ffUndoLastFrame, object: nil)
        return .result()
    }
}

/// Beendet die Aufnahme; die App zeigt danach den Film.
struct FinishCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Aufnahme beenden"
    static let description = IntentDescription("Beendet die laufende Aufnahme und zeigt den Film.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard SiriBridge.isCapturing else { throw SiriIntentError.notCapturing }
        NotificationCenter.default.post(name: .ffFinishSession, object: nil)
        return .result()
    }
}

// MARK: Film

/// Öffnet ein Werk und exportiert es mit den zuletzt gewählten Einstellungen.
/// Der fertige Film erscheint in der Werkansicht und lässt sich dort abspielen.
struct ExportFilmIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop-Motion exportieren"
    static let description = IntentDescription("Öffnet ein Werk und exportiert es als Film.")
    static let openAppWhenRun = true

    @Parameter(title: "Werk", description: "Das Werk, das zum Film wird.")
    var work: WorkEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let project = SiriBridge.store?.projects.first(where: { $0.id == work.id }) else {
            throw SiriIntentError.workMissing
        }
        guard project.frameCount > 0 else { throw SiriIntentError.workEmpty }
        let id = project.id
        SiriBridge.pendingExport = id
        OpenWork.pending = id
        NotificationCenter.default.post(name: .ffOpenWork, object: id)
        // War das Werk schon offen, erscheint die Ansicht nicht neu – dann
        // trifft diese zweite Nachricht. Sonst erledigt es ihr `onAppear`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .ffExportWork, object: id)
        }
        return .result()
    }
}

// MARK: Sprachbefehle

/// Feste Sätze, die Siri ohne Einrichtung versteht. Jeder Satz braucht den
/// App-Namen; die Übersetzungen stehen in `AppShortcuts.xcstrings`.
struct FrameFoldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureFrameIntent(),
                    phrases: ["Auslösen in \(.applicationName)"],
                    shortTitle: "Auslösen", systemImageName: "camera.shutter.button")
        AppShortcut(intent: UndoLastFrameIntent(),
                    phrases: ["Letztes Bild zurücknehmen in \(.applicationName)"],
                    shortTitle: "Letztes Bild zurücknehmen", systemImageName: "arrow.uturn.backward")
        AppShortcut(intent: FinishCaptureIntent(),
                    phrases: ["Aufnahme beenden in \(.applicationName)"],
                    shortTitle: "Aufnahme beenden", systemImageName: "checkmark.circle")
        AppShortcut(intent: StartCaptureIntent(),
                    phrases: ["Aufnahme starten in \(.applicationName)"],
                    shortTitle: "Aufnahme starten", systemImageName: "camera")
        AppShortcut(intent: ExportFilmIntent(),
                    phrases: ["Stop-Motion exportieren in \(.applicationName)"],
                    shortTitle: "Stop-Motion exportieren", systemImageName: "film")
    }
}
