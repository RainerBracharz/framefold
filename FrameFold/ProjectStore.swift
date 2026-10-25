import Foundation
import AVFoundation
import UIKit
import ImageIO

/// Ein Projekt = ein Werk von Aldo, dokumentiert über beliebig viele
/// Sessions (Live-Capture oder Video-Import). Frames liegen als JPEGs
/// im Documents-Verzeichnis, Metadaten in manifest.json.
struct Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var createdAtISO: String
    var frameFilenames: [String]
    /// Papierkorb: entfernte Frames, 30 Tage wiederherstellbar (optional
    /// für Abwärtskompatibilität mit älteren Manifesten)
    var trashFilenames: [String]?
    /// Fortlaufende Frame-Nummer – verhindert Dateinamens-Kollisionen
    /// nach dem Löschen einzelner Frames
    var nextFrameNumber: Int?
    /// Musik- oder Tonspur für den Export (Datei im Werkordner, optional)
    var audioFilename: String?
    /// Notizen zu Bildnummern (1-basiert, wie im X-Sheet) – erscheinen im
    /// Studio, wenn genau dieses Bild als nächstes aufgenommen wird.
    var notes: [String: String]?
    /// Weitere Tonspuren (Studio) mit Einsatzbild und Lautstärke
    var audioTracks: [AudioTrack]?
    /// Dialog-Lesen: Mundformen je Bild und Figur
    var dialogue: [DialogueEntry]?
    /// Greenscreen: Farbe und Hintergrund für den Export
    var greenScreen: GreenScreen?
    /// Titelkarte vor und Abspann nach dem Film (leer = keiner)
    var titleText: String?
    var creditsText: String?
    /// Text, Sprechblasen und Zeichnungen über Bildbereichen
    var overlays: [FrameOverlay]?

    /// Alle Tonspuren – die einfache Musikspur aus der Werkansicht zählt
    /// als erste, mit Einsatz bei Bild 1.
    var allAudioTracks: [AudioTrack] {
        var tracks = audioTracks ?? []
        if let audioFilename {
            tracks.insert(AudioTrack(id: Self.legacyTrackID, name: String(localized: "Musik"),
                                     filename: audioFilename), at: 0)
        }
        return tracks
    }
    static let legacyTrackID = UUID(uuidString: "00000000-0000-0000-0000-00000000F01D")!

    /// Figuren, für die es Dialog-Einträge gibt, in der Reihenfolge des Auftretens.
    var characters: [String] {
        var seen: [String] = []
        for entry in (dialogue ?? []).sorted(by: { $0.frame < $1.frame }) where !seen.contains(entry.character) {
            seen.append(entry.character)
        }
        return seen
    }

    func note(forFrame number: Int) -> String? { notes?[String(number)] }

    var frameCount: Int { frameFilenames.count }

    /// Anlagedatum im Format der Sprache und in der eigenen Zeitzone
    /// („18. Okt. 2026") – vorher das rohe ISO-Datum in UTC, das nachts einen
    /// Tag danebenlag.
    var createdDateText: String {
        guard let date = ISO8601DateFormatter().date(from: createdAtISO) else {
            return String(createdAtISO.prefix(10))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    var trashCount: Int { trashFilenames?.count ?? 0 }
}

@MainActor
final class ProjectStore: ObservableObject {

    @Published private(set) var projects: [Project] = []

    private let root: URL
    private let defaults: UserDefaults

    convenience init() {
        #if targetEnvironment(macCatalyst)
        // Am Mac ist „Dokumente" der Ordner des Nutzers, nicht der der App –
        // dort hat ein Ordner namens „Projects" nichts verloren.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameFold", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        #if DEBUG
        // Tests und Screenshots: eigener Ordner statt der echten Werke.
        if let custom = ProcessInfo.processInfo.environment["FF_STORE_ROOT"], !custom.isEmpty {
            self.init(root: URL(fileURLWithPath: custom, isDirectory: true))
            return
        }
        #endif
        self.init(root: base.appendingPathComponent("Projects", isDirectory: true))
    }

    /// Eigener Ordner – für Tests, die nicht an echte Werke dürfen.
    init(root: URL, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        stampLegacyTrashOnce()
        purgeOldTrash()
        Self.cleanTemporaryFiles()
    }

    /// Zwischendateien der App (Video-Importe, Exporte, PDFs, Titelkarten)
    /// räumt niemand sonst zeitnah weg – importierte Videos sind ganze
    /// Kopien, das wuchs auf Gigabyte. Beim Start fliegt alles, was älter
    /// als einen Tag ist; frische Dateien (etwa ein gerade geteilter Film)
    /// bleiben. Nur eigene Präfixe, im Hintergrund.
    nonisolated static func cleanTemporaryFiles(olderThan age: TimeInterval = 24 * 3600) {
        let prefixes = ["import-", "framefold-", "daumenkino-", "kontaktbogen-",
                        "faltvorlage-", "titlecard-", "ff-"]
        Task.detached(priority: .utility) {
            removeOldFiles(in: FileManager.default.temporaryDirectory, prefixes: prefixes, olderThan: age)
        }
    }

    /// Kern des Aufräumens, eigenständig testbar: entfernt in `dir` nur
    /// Einträge mit einem der Präfixe, die älter als `age` sind.
    nonisolated static func removeOldFiles(in dir: URL, prefixes: [String], olderThan age: TimeInterval) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? fm.removeItem(at: url) }
        }
    }

    /// Bis 2.2 behielten Bilder im Papierkorb ihr Aufnahmedatum – die
    /// 30-Tage-Frist wäre für ältere Werke sofort abgelaufen. Einmalig
    /// beginnt sie für alles, was schon im Papierkorb liegt, jetzt.
    private func stampLegacyTrashOnce() {
        let key = "trashStampedOnce"
        guard !defaults.bool(forKey: key) else { return }
        for project in projects {
            let trashDir = directory(for: project).appendingPathComponent("trash", isDirectory: true)
            for filename in project.trashFilenames ?? [] {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: trashDir.appendingPathComponent(filename).path)
            }
        }
        defaults.set(true, forKey: key)
    }

    // MARK: Laden & Speichern

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let project = try? JSONDecoder().decode(Project.self, from: data) else {
                return Self.recoverProject(in: dir)
            }
            return project
        }
        .sorted { $0.createdAtISO > $1.createdAtISO }
    }

    /// Fehlt das Manifest oder ist es unlesbar, liegen die Bilder trotzdem
    /// noch im Ordner. Statt das Werk stillschweigend zu verlieren, wird es
    /// aus den Bilddateien wieder zusammengesetzt.
    private static func recoverProject(in dir: URL) -> Project? {
        guard let id = UUID(uuidString: dir.lastPathComponent),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let frames = names.filter { $0.hasSuffix(".jpg") }.sorted()
        guard !frames.isEmpty else { return nil }
        let created = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.creationDate] as? Date) ?? Date()
        let project = Project(
            id: id, name: String(localized: "Wiederhergestelltes Werk"),
            createdAtISO: ISO8601DateFormatter().string(from: created),
            frameFilenames: frames, trashFilenames: nil, nextFrameNumber: nil, audioFilename: nil, notes: nil, audioTracks: nil, dialogue: nil,
            greenScreen: nil, titleText: nil, creditsText: nil, overlays: nil)
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
        return project
    }

    private func directory(for project: Project) -> URL {
        root.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    private func save(_ project: Project) {
        let dir = directory(for: project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(project) {
            // Atomar: Bricht die App mitten im Schreiben ab (Akku, Absturz),
            // bleibt das alte Manifest stehen statt eines halben.
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
        // Nur das eine Projekt im Speicher aktualisieren. Das frühere
        // reload() las nach JEDEM aufgenommenen Bild sämtliche Manifeste
        // von der Platte – auf dem Hauptthread, mitten in der Aufnahme.
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.append(project)
            projects.sort { $0.createdAtISO > $1.createdAtISO }
        }
        thumbnailCache[project.id] = nil
    }

    // MARK: API

    /// Leerer Name: Statt still nichts zu tun, bekommt das Werk eine Nummer.
    func createProject(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            id: UUID(),
            name: trimmed.isEmpty ? String(localized: "Werk \(projects.count + 1)") : trimmed,
            createdAtISO: ISO8601DateFormatter().string(from: Date()),
            frameFilenames: [],
            trashFilenames: nil,
            nextFrameNumber: 0,
            audioFilename: nil,
            notes: nil,
            audioTracks: nil,
            dialogue: nil,
            greenScreen: nil,
            titleText: nil,
            creditsText: nil,
            overlays: nil)
        save(project)
        return project
    }

    /// Fortlaufende Nummer für neue Frames – bei alten Manifesten aus dem
    /// höchsten vorhandenen Dateinamen abgeleitet.
    private func nextNumber(for project: Project) -> Int {
        if let n = project.nextFrameNumber { return n }
        let all = project.frameFilenames + (project.trashFilenames ?? [])
        let maxExisting = all.compactMap { Int($0.prefix(6)) }.max() ?? -1
        return maxExisting + 1
    }

    func delete(_ project: Project) {
        try? FileManager.default.removeItem(at: directory(for: project))
        projects.removeAll { $0.id == project.id }
        thumbnailCache[project.id] = nil
    }

    func rename(_ project: Project, to name: String) {
        var updated = project
        updated.name = name
        save(updated)
    }

    // MARK: Werk als Datei

    /// Schreibt das Werk als eine `.framefold`-Datei in einen temporären
    /// Ordner – ohne Papierkorb, der bleibt auf diesem Gerät.
    func exportPackage(of project: Project) async throws -> URL {
        var clean = project
        clean.trashFilenames = nil
        let manifest = try JSONEncoder().encode(clean)
        let dir = directory(for: project)
        let skip = Set(project.trashFilenames ?? []).union(["manifest.json"])
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-werk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let target = outDir.appendingPathComponent(WorkPackage.filename(for: project.name))
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let manifestURL = outDir.appendingPathComponent("manifest.json")
            try manifest.write(to: manifestURL)
            let names = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
                .filter { WorkPackage.isSafe($0) && !skip.contains($0) }
                // Nur Dateien – der Papierkorb liegt als Unterordner daneben
                .filter { (try? dir.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted()
            let files = [("manifest.json", manifestURL)] + names.map { ($0, dir.appendingPathComponent($0)) }
            try WorkPackage.write(files: files.map { (name: $0.0, url: $0.1) }, to: target)
            try? FileManager.default.removeItem(at: manifestURL)
        }.value
        return target
    }

    /// Liest eine `.framefold`-Datei als neues Werk ein. Es bekommt eine
    /// neue Kennung – zweimal importiert ergibt zwei Werke, nichts wird
    /// überschrieben.
    @discardableResult
    func importPackage(from source: URL) async throws -> Project {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-import-\(id.uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Task.detached(priority: .userInitiated) {
            try WorkPackage.read(source, into: staging)
        }.value
        guard let data = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkPackage.Failure.noManifest
        }
        json["id"] = id.uuidString
        json["createdAtISO"] = ISO8601DateFormatter().string(from: Date())
        json["trashFilenames"] = nil
        guard let project = try? JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)) else {
            throw WorkPackage.Failure.noManifest
        }
        // Nur Bilder übernehmen, die wirklich in der Datei lagen
        var checked = project
        checked.frameFilenames = project.frameFilenames.filter {
            FileManager.default.fileExists(atPath: staging.appendingPathComponent($0).path)
        }
        let target = directory(for: checked)
        try FileManager.default.moveItem(at: staging, to: target)
        save(checked)
        return checked
    }

    /// Hängt ein Bild als neuen Frame an (Live-Capture). Gibt den
    /// Dateinamen zurück – oder nil, wenn das Bild nicht gespeichert werden
    /// konnte (etwa weil der Speicher voll ist).
    @discardableResult
    func appendFrame(jpegData: Data, to project: Project) -> String? {
        var updated = project
        let number = nextNumber(for: updated)
        let filename = String(format: "%06d.jpg", number)
        let dir = directory(for: updated)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try jpegData.write(to: dir.appendingPathComponent(filename))
            updated.frameFilenames.append(filename)
            updated.nextFrameNumber = number + 1
            save(updated)
            return filename
        } catch {
            return nil
        }
    }

    /// Ersetzt ein Bild an seiner Stelle („Neu aufnehmen“). Das alte wandert
    /// in den Papierkorb (30 Tage wiederherstellbar). Gibt den neuen
    /// Dateinamen zurück – oder nil, wenn das alte Bild nicht mehr im Werk
    /// ist oder das neue nicht gespeichert werden konnte.
    @discardableResult
    func replaceFrame(named old: String, jpegData: Data, in project: Project) -> String? {
        guard let index = project.frameFilenames.firstIndex(of: old) else { return nil }
        recordUndo(project.id, String(localized: "Neu aufnehmen"))
        var updated = project
        let number = nextNumber(for: updated)
        let filename = String(format: "%06d.jpg", number)
        let dir = directory(for: updated)
        do {
            try jpegData.write(to: dir.appendingPathComponent(filename))
        } catch {
            return nil
        }
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let target = trashDir.appendingPathComponent(old)
        try? FileManager.default.moveItem(at: dir.appendingPathComponent(old), to: target)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        updated.trashFilenames = (updated.trashFilenames ?? []) + [old]
        updated.frameFilenames[index] = filename
        updated.nextFrameNumber = number + 1
        save(updated)
        return filename
    }

    /// Übernimmt eine Audiodatei als Tonspur des Werks (Kopie im Werkordner;
    /// die Quelle darf danach verschwinden). Eine vorige Spur wird ersetzt.
    @discardableResult
    func setAudio(from source: URL, for project: Project) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let filename = "ton-\(UUID().uuidString.prefix(8)).\(ext)"
        let dir = directory(for: project)
        do {
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(filename))
        } catch {
            return false
        }
        removeAudioFile(of: project)
        var updated = project
        updated.audioFilename = filename
        save(updated)
        return true
    }

    func removeAudio(from project: Project) {
        removeAudioFile(of: project)
        var updated = project
        updated.audioFilename = nil
        save(updated)
    }

    private func removeAudioFile(of project: Project) {
        guard let name = project.audioFilename else { return }
        try? FileManager.default.removeItem(at: directory(for: project).appendingPathComponent(name))
    }

    /// Notiz zu Bild `number` setzen; leerer Text entfernt sie.
    func setNote(_ text: String, forFrame number: Int, in project: Project) {
        recordUndo(project.id, String(localized: "Notiz"))
        var updated = project
        var notes = updated.notes ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[String(number)] = trimmed.isEmpty ? nil : trimmed
        updated.notes = notes.isEmpty ? nil : notes
        save(updated)
    }

    // MARK: Tonspuren (Studio)

    /// Nimmt eine Audiodatei als weitere Tonspur auf (Kopie im Werkordner).
    @discardableResult
    func addAudioTrack(from source: URL, startFrame: Int = 0, name: String? = nil, to project: Project) -> AudioTrack? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let filename = "spur-\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try FileManager.default.copyItem(at: source, to: directory(for: project).appendingPathComponent(filename))
        } catch {
            return nil
        }
        let track = AudioTrack(name: name ?? source.deletingPathExtension().lastPathComponent,
                               filename: filename, startFrame: startFrame)
        var updated = project
        updated.audioTracks = (updated.audioTracks ?? []) + [track]
        save(updated)
        return track
    }

    /// Einsatz, Lautstärke oder Stumm einer Spur ändern – immer am aktuellen
    /// Stand des Werks, nie an einer veralteten Kopie aus der Ansicht. Die
    /// einfache Musikspur wird dabei zur gewöhnlichen Spur und behält ihre
    /// Kennung; ein zweiter Aufruf mit derselben Kennung ändert sie nur.
    func updateAudioTrack(id: UUID, in projectID: UUID, _ change: (inout AudioTrack) -> Void) {
        guard var updated = projects.first(where: { $0.id == projectID }) else { return }
        if let i = updated.audioTracks?.firstIndex(where: { $0.id == id }) {
            change(&updated.audioTracks![i])
        } else if id == Project.legacyTrackID, let legacy = updated.allAudioTracks.first(where: { $0.id == id }) {
            var promoted = legacy
            change(&promoted)
            updated.audioFilename = nil
            updated.audioTracks = [promoted] + (updated.audioTracks ?? [])
        } else {
            return
        }
        save(updated)
    }

    func updateAudioTrack(_ track: AudioTrack, in project: Project) {
        updateAudioTrack(id: track.id, in: project.id) { $0 = track }
    }

    func removeAudioTrack(_ track: AudioTrack, from project: Project) {
        guard var updated = projects.first(where: { $0.id == project.id }) else { return }
        guard let stored = updated.audioTracks?.first(where: { $0.id == track.id }) else {
            if track.id == Project.legacyTrackID { removeAudio(from: updated) }
            return
        }
        updated.audioTracks?.removeAll { $0.id == track.id }
        if updated.audioTracks?.isEmpty == true { updated.audioTracks = nil }
        // Die Datei nur löschen, wenn keine andere Spur sie noch nutzt
        if !(updated.allAudioTracks.contains { $0.filename == stored.filename }) {
            try? FileManager.default.removeItem(at: directory(for: updated).appendingPathComponent(stored.filename))
        }
        save(updated)
    }

    func url(for track: AudioTrack, in project: Project) -> URL {
        directory(for: project).appendingPathComponent(track.filename)
    }

    // MARK: Rückgängig

    /// Die Undo-Verwaltung des Fensters (⌘Z, Bearbeiten-Menü, Schütteln am
    /// iPhone). Gesetzt von der Oberfläche; ohne sie wird nichts vermerkt.
    weak var undoManager: UndoManager?
    private var lastUndoKey: (String, Date)?

    /// Stand des Werks vor einer Änderung vermerken. Mehrere schnelle
    /// Änderungen am selben Ding (Text tippen, Sprechblase ziehen) werden zu
    /// einem Schritt zusammengefasst.
    private func recordUndo(_ projectID: UUID, _ name: String, coalesce key: String? = nil) {
        guard let undoManager, let before = projects.first(where: { $0.id == projectID }) else { return }
        if let key, let last = lastUndoKey, last.0 == key, Date().timeIntervalSince(last.1) < 1.5 {
            lastUndoKey = (key, Date())
            return
        }
        lastUndoKey = key.map { ($0, Date()) }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.applyUndo(before) }
        }
        undoManager.setActionName(name)
    }

    /// Einen vermerkten Stand wiederherstellen – und den jetzigen für
    /// „Wiederholen“ vermerken. Bilddateien wandern dabei zwischen Werk und
    /// Papierkorb, damit Liste und Ordner zusammenpassen.
    private func applyUndo(_ snapshot: Project) {
        guard let current = projects.first(where: { $0.id == snapshot.id }) else { return }
        lastUndoKey = nil
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.applyUndo(current) }
        }
        let dir = directory(for: snapshot)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        for name in snapshot.frameFilenames where !fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try? fm.moveItem(at: trashDir.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        for name in snapshot.trashFilenames ?? [] where !snapshot.frameFilenames.contains(name)
            && fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try? fm.moveItem(at: dir.appendingPathComponent(name), to: trashDir.appendingPathComponent(name))
        }
        var restored = snapshot
        // Fortlaufende Nummer nie zurückdrehen – sonst überschriebe das
        // nächste Bild eine Datei, die noch im Papierkorb liegt.
        restored.nextFrameNumber = max(snapshot.nextFrameNumber ?? 0, current.nextFrameNumber ?? 0)
        save(restored)
    }

    // MARK: Beispielwerk

    /// Beim allerersten Start ein kleines Beispielwerk anlegen (die Faltung
    /// aus dem Spot, 22 Bilder): So gibt es sofort etwas zum Abspielen,
    /// Exportieren und Ausprobieren. Nur einmal je Installation und nur, wenn
    /// noch kein Werk existiert.
    func createSampleIfNeeded() {
        let key = "didCreateSample"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard projects.isEmpty else { return }
        var project = createProject(name: String(localized: "Beispiel: Faltung"))
        for n in 1...22 {
            guard let image = UIImage(named: String(format: "sample-%02d", n)),
                  let data = image.jpegData(compressionQuality: 0.85),
                  let current = projects.first(where: { $0.id == project.id }) else { continue }
            appendFrame(jpegData: data, to: current)
        }
        if let current = projects.first(where: { $0.id == project.id }) { project = current }
        if project.frameCount == 0 { delete(project) }
    }

    // MARK: Text, Sprechblasen, Zeichnungen

    /// Einblendung anlegen oder ändern (gleiche Kennung = ersetzen).
    func upsertOverlay(_ overlay: FrameOverlay, in projectID: UUID) {
        recordUndo(projectID, String(localized: "Text & Zeichnen"), coalesce: "overlay-\(overlay.id)")
        guard var updated = projects.first(where: { $0.id == projectID }) else { return }
        var all = updated.overlays ?? []
        if let i = all.firstIndex(where: { $0.id == overlay.id }) { all[i] = overlay } else { all.append(overlay) }
        updated.overlays = all
        save(updated)
    }

    func removeOverlay(id: UUID, in projectID: UUID) {
        recordUndo(projectID, String(localized: "Text & Zeichnen"))
        guard var updated = projects.first(where: { $0.id == projectID }) else { return }
        updated.overlays?.removeAll { $0.id == id }
        if updated.overlays?.isEmpty == true { updated.overlays = nil }
        save(updated)
    }

    // MARK: Greenscreen, Titel

    /// Greenscreen-Farbe setzen (`.none` schaltet ab, der Hintergrund bleibt gemerkt).
    func setGreenScreenKey(_ key: ChromaKey, in projectID: UUID) {
        recordUndo(projectID, String(localized: "Greenscreen"))
        guard var updated = projects.first(where: { $0.id == projectID }) else { return }
        var green = updated.greenScreen ?? GreenScreen()
        green.key = key
        updated.greenScreen = green
        save(updated)
    }

    /// Hintergrundbild oder -film übernehmen (Kopie im Werkordner).
    @discardableResult
    func setGreenScreenBackground(from source: URL, in projectID: UUID) -> Bool {
        guard var updated = projects.first(where: { $0.id == projectID }) else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let filename = "hintergrund-\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try FileManager.default.copyItem(at: source, to: directory(for: updated).appendingPathComponent(filename))
        } catch {
            return false
        }
        var green = updated.greenScreen ?? GreenScreen()
        if let old = green.backgroundFilename {
            try? FileManager.default.removeItem(at: directory(for: updated).appendingPathComponent(old))
        }
        green.backgroundFilename = filename
        updated.greenScreen = green
        save(updated)
        return true
    }

    func greenScreenBackgroundURL(for project: Project) -> URL? {
        project.greenScreen?.backgroundFilename.map { directory(for: project).appendingPathComponent($0) }
    }

    func setTitles(title: String?, credits: String?, in projectID: UUID) {
        guard var updated = projects.first(where: { $0.id == projectID }) else { return }
        updated.titleText = title
        updated.creditsText = credits
        save(updated)
    }

    // MARK: Dialog-Lesen

    /// Setzt (oder löscht mit `phoneme == nil`) den Eintrag einer Figur in einem Bild.
    func setDialogue(frame: Int, character: String, phoneme: Phoneme?, word: String?, in project: Project) {
        var updated = project
        var entries = updated.dialogue ?? []
        entries.removeAll { $0.frame == frame && $0.character == character }
        if let phoneme {
            let trimmed = word?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(DialogueEntry(frame: frame, character: character, phoneme: phoneme,
                                         word: trimmed?.isEmpty == false ? trimmed : nil))
        }
        updated.dialogue = entries.isEmpty ? nil : entries.sorted { ($0.frame, $0.character) < ($1.frame, $1.character) }
        save(updated)
    }

    /// Ersetzt alle Einträge einer Figur (automatisches Lesen).
    func replaceDialogue(of character: String, with entries: [DialogueEntry], in project: Project) {
        var updated = project
        var all = (updated.dialogue ?? []).filter { $0.character != character }
        all += entries
        updated.dialogue = all.isEmpty ? nil : all.sorted { ($0.frame, $0.character) < ($1.frame, $1.character) }
        save(updated)
    }

    /// Ordner mit den Bildern des Werks (für „Im Finder zeigen“).
    func folderURL(for project: Project) -> URL { directory(for: project) }

    func audioURL(for project: Project) -> URL? {
        project.audioFilename.map { directory(for: project).appendingPathComponent($0) }
    }

    /// Verdoppelt ein Bild direkt hinter sich – so steht eine Pose länger im
    /// Film. Eine eigene Datei statt eines Verweises, damit Papierkorb und
    /// „Neu aufnehmen“ jedes Exemplar einzeln behandeln können.
    @discardableResult
    func duplicateFrame(named name: String, in project: Project) -> String? {
        guard let index = project.frameFilenames.firstIndex(of: name) else { return nil }
        recordUndo(project.id, String(localized: "Verdoppeln"))
        var updated = project
        let number = nextNumber(for: updated)
        let filename = String(format: "%06d.jpg", number)
        let dir = directory(for: updated)
        do {
            try FileManager.default.copyItem(at: dir.appendingPathComponent(name),
                                             to: dir.appendingPathComponent(filename))
        } catch {
            return nil
        }
        updated.frameFilenames.insert(filename, at: index + 1)
        updated.nextFrameNumber = number + 1
        save(updated)
        return filename
    }

    /// Verschiebt ein Bild um `offset` Plätze (negativ = nach vorn).
    func moveFrame(named name: String, by offset: Int, in project: Project) {
        guard let index = project.frameFilenames.firstIndex(of: name) else { return }
        let target = min(max(index + offset, 0), project.frameFilenames.count - 1)
        guard target != index else { return }
        recordUndo(project.id, String(localized: "Verschieben"))
        var updated = project
        updated.frameFilenames.remove(at: index)
        updated.frameFilenames.insert(name, at: target)
        save(updated)
    }

    /// Verschiebt genau diese Frames in den Papierkorb – für Verwerfen und
    /// Zurücknehmen einer Sitzung, damit nie Bilder älterer Sitzungen
    /// mitgehen.
    func removeFrames(named filenames: [String], from project: Project) {
        let offsets = IndexSet(project.frameFilenames.indices.filter { filenames.contains(project.frameFilenames[$0]) })
        guard !offsets.isEmpty else { return }
        removeFrames(at: offsets, from: project)
    }

    /// Verschiebt Frames in den Papierkorb (30 Tage wiederherstellbar).
    func removeFrames(at offsets: IndexSet, from project: Project) {
        recordUndo(project.id, String(localized: "Bild entfernen"))
        var updated = project
        let dir = directory(for: updated)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        var trash = updated.trashFilenames ?? []
        for index in offsets {
            guard updated.frameFilenames.indices.contains(index) else { continue }
            let filename = updated.frameFilenames[index]
            let target = trashDir.appendingPathComponent(filename)
            try? FileManager.default.moveItem(
                at: dir.appendingPathComponent(filename), to: target)
            // Die 30 Tage zählen ab dem Entfernen. Verschieben behält das
            // Aufnahmedatum der Datei – ohne neuen Zeitstempel wären Bilder
            // älterer Werke beim nächsten Start endgültig gelöscht.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            trash.append(filename)
        }
        updated.frameFilenames.remove(atOffsets: offsets)
        updated.trashFilenames = trash
        updated.nextFrameNumber = nextNumber(for: updated) // für alte Manifeste fixieren
        save(updated)
    }

    /// Holt alle Frames aus dem Papierkorb zurück (ans Ende der Timeline,
    /// in ursprünglicher Reihenfolge).
    func restoreTrash(in project: Project) {
        recordUndo(project.id, String(localized: "Wiederherstellen"))
        var updated = project
        guard let trash = updated.trashFilenames, !trash.isEmpty else { return }
        let dir = directory(for: updated)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)

        for filename in trash.sorted() {
            let source = trashDir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.moveItem(
                at: source, to: dir.appendingPathComponent(filename))
            updated.frameFilenames.append(filename)
        }
        // Timeline in Aufnahme-Reihenfolge halten
        updated.frameFilenames.sort()
        updated.trashFilenames = nil
        save(updated)
    }

    /// Entfernt Papierkorb-Dateien, die älter als 30 Tage sind.
    func purgeOldTrash() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for project in projects {
            guard var trash = project.trashFilenames, !trash.isEmpty else { continue }
            let trashDir = directory(for: project).appendingPathComponent("trash", isDirectory: true)
            var changed = false
            for filename in trash {
                let url = trashDir.appendingPathComponent(filename)
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
                if let modified, modified < cutoff {
                    try? FileManager.default.removeItem(at: url)
                    trash.removeAll { $0 == filename }
                    changed = true
                }
            }
            if changed {
                var updated = project
                updated.trashFilenames = trash.isEmpty ? nil : trash
                save(updated)
            }
        }
    }

    func frameURLs(for project: Project) -> [URL] {
        let dir = directory(for: project)
        return project.frameFilenames.map { dir.appendingPathComponent($0) }
    }

    /// Klein gerechnete Vorschaubilder, gecacht pro Projekt – vorher wurde
    /// bei jedem Listen-Render das volle 1080p-JPEG neu dekodiert.
    private var thumbnailCache: [UUID: UIImage] = [:]

    func thumbnail(for project: Project) -> UIImage? {
        if let cached = thumbnailCache[project.id] { return cached }
        guard let first = frameURLs(for: project).first,
              let small = UIImage.thumbnail(at: first, maxPixelSize: 640) else { return nil }
        thumbnailCache[project.id] = small
        return small
    }

    /// Sichert die Keyframes eines verarbeiteten Videos als Projekt-Session
    /// (volle Auflösung, nacheinander – speicherschonend).
    /// Gibt zurück, wie viele Bilder tatsächlich im Werk gelandet sind.
    @discardableResult
    func importKeyframes(
        from videoURL: URL, times: [Double],
        into project: Project
    ) async -> Int {
        var saved = 0
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        for seconds in times {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else { continue }
            if let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) {
                // save() in appendFrame aktualisiert das Projekt im Speicher;
                // Projekt-Objekt jeweils frisch holen:
                if let current = projects.first(where: { $0.id == project.id }),
                   appendFrame(jpegData: data, to: current) != nil {
                    saved += 1
                }
            }
        }
        return saved
    }
}

extension UIImage {
    /// Liest eine kleine Vorschau direkt aus der Bilddatei, ohne das volle
    /// Foto zu dekodieren – deutlich schneller und sparsamer, wenn ein
    /// Kontaktbogen Hunderte Kacheln zeigt. Thread-sicher.
    nonisolated static func thumbnail(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Verkleinert, ohne zu verzerren: Die längere Seite wird `maxSide`.
    func scaledToFit(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Füllt `target` und schneidet den Überstand mittig ab – für Kacheln
    /// mit festem Format. Vorher wurde das Bild hineingestaucht: Querformat-
    /// Bilder der Mac-Kamera wirkten im quadratischen Kontaktbogen platt.
    func filled(to target: CGSize) -> UIImage {
        let fill = max(target.width / max(size.width, 1), target.height / max(size.height, 1))
        let drawn = CGSize(width: size.width * fill, height: size.height * fill)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2,
                            width: drawn.width, height: drawn.height))
        }
    }
}
