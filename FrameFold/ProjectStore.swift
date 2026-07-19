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

    var frameCount: Int { frameFilenames.count }
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
            frameFilenames: [])
        save(project)
        return project
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
        let filename = String(format: "%06d.jpg", updated.frameFilenames.count)
        let dir = directory(for: updated)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try jpegData.write(to: dir.appendingPathComponent(filename))
            updated.frameFilenames.append(filename)
            save(updated)
        } catch { }
    }

    /// Entfernt einzelne Frames (manueller Override in der Timeline).
    func removeFrames(at offsets: IndexSet, from project: Project) {
        var updated = project
        let dir = directory(for: updated)
        for index in offsets {
            guard updated.frameFilenames.indices.contains(index) else { continue }
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(updated.frameFilenames[index]))
        }
        updated.frameFilenames.remove(atOffsets: offsets)
        save(updated)
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
