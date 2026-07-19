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

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        purgeOldTrash()
    }

    // MARK: Laden & Speichern

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let project = try? JSONDecoder().decode(Project.self, from: data) else {
                return nil
            }
            return project
        }
        .sorted { $0.createdAtISO > $1.createdAtISO }
    }

    private func directory(for project: Project) -> URL {
        root.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    private func save(_ project: Project) {
        let dir = directory(for: project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
        reload()
    }

    // MARK: API

    func createProject(name: String) -> Project {
        let project = Project(
            id: UUID(), name: name,
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
        reload()
    }

    func rename(_ project: Project, to name: String) {
        var updated = project
        updated.name = name
        save(updated)
    }

    /// Hängt ein Bild als neuen Frame an (Live-Capture).
    func appendFrame(jpegData: Data, to project: Project) {
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
        } catch { }
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
            try? FileManager.default.moveItem(
                at: dir.appendingPathComponent(filename),
                to: trashDir.appendingPathComponent(filename))
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

    func thumbnail(for project: Project) -> UIImage? {
        guard let first = frameURLs(for: project).first,
              let data = try? Data(contentsOf: first) else { return nil }
        return UIImage(data: data)
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
                // reload() in appendFrame hält das Manifest aktuell;
                // Projekt-Objekt jeweils frisch holen:
                if let current = projects.first(where: { $0.id == project.id }) {
                    appendFrame(jpegData: data, to: current)
                }
            }
        }
    }
}
