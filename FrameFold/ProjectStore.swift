import Foundation
import AVFoundation
import UIKit

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

    var frameCount: Int { frameFilenames.count }
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
            frameFilenames: frames, trashFilenames: nil, nextFrameNumber: nil)
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
            nextFrameNumber: 0)
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
              let data = try? Data(contentsOf: first),
              let full = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 320
        let scale = min(1, maxSide / max(full.size.width, full.size.height))
        let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            full.draw(in: CGRect(origin: .zero, size: size))
        }
        thumbnailCache[project.id] = small
        return small
    }

    /// Sichert die Keyframes eines verarbeiteten Videos als Projekt-Session
    /// (volle Auflösung, nacheinander – speicherschonend).
    func importKeyframes(
        from videoURL: URL, times: [Double],
        into project: Project
    ) async {
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
                if let current = projects.first(where: { $0.id == project.id }) {
                    appendFrame(jpegData: data, to: current)
                }
            }
        }
    }
}

extension UIImage {
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
