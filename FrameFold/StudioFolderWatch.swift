import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// „Ordner beobachten“ wie bei Dragonframe: Jedes neue Foto, das die
/// Software einer Kamera (EOS Utility, Nikon Webcam/Tether, Capture One …)
/// in einen Ordner legt, wird das nächste Bild im Werk – in voller
/// Auflösung. So wird jede Kamera nutzbar, die FrameFold nicht selbst steuert.
@MainActor
final class StudioFolderWatch: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var isWatching = false
    @Published private(set) var imported = 0
    @Published var lastError: String?

    private var folder: URL?
    private var scoped = false
    private var known: Set<String> = []
    /// Größe beim letzten Blick – eine Datei gilt erst als fertig, wenn sie
    /// zweimal hintereinander gleich groß ist (die Kamera schreibt noch).
    private var pendingSizes: [String: Int] = [:]
    private var timer: Timer?
    private var onImage: ((CGImage, Data) -> Void)?
    private var loadChain: Task<Void, Never>?

    private static let bookmarkKey = "studioWatchFolder"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
                                               "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "pef"]

    init() { restoreBookmark() }

    /// Ordner wählen (aus dem Dateidialog) und merken.
    func choose(_ url: URL) {
        stop()
        releaseFolder()
        scoped = url.startAccessingSecurityScopedResource()
        folder = url
        folderName = url.lastPathComponent
        #if targetEnvironment(macCatalyst)
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            StudioDefaults.store.set(data, forKey: Self.bookmarkKey)
        }
        #endif
    }

    func forget() {
        stop()
        releaseFolder()
        folder = nil
        folderName = nil
        StudioDefaults.store.removeObject(forKey: Self.bookmarkKey)
    }

    /// Beobachten beginnen: Was schon im Ordner liegt, bleibt draußen.
    func start(onImage: @escaping (CGImage, Data) -> Void) {
        guard let folder else { return }
        self.onImage = onImage
        known = Set(Self.imageFiles(in: folder))
        pendingSizes = [:]
        imported = 0
        lastError = nil
        isWatching = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        loadChain?.cancel()
        loadChain = nil
        timer?.invalidate()
        timer = nil
        isWatching = false
        onImage = nil
    }

    private func poll() {
        guard let folder else { return }
        for name in Self.imageFiles(in: folder) where !known.contains(name) {
            let url = folder.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, pendingSizes[name] == size else {
                pendingSizes[name] = size   // erst beim nächsten Blick, wenn unverändert
                continue
            }
            pendingSizes[name] = nil
            known.insert(name)
            // Lesen und Umwandeln (RAW: einige Sekunden) im Hintergrund, aber
            // der Reihe nach – die Bilder kommen in Kamera-Reihenfolge ins Werk.
            let previous = loadChain
            loadChain = Task { [weak self] in
                await previous?.value
                let loaded = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
                guard let self, self.isWatching else { return }
                if let (image, data) = loaded {
                    self.imported += 1
                    self.onImage?(image, data)
                } else {
                    self.lastError = String(localized: "„\(name)“ ließ sich nicht lesen.")
                }
            }
        }
    }

    /// Bilddateien im Ordner, nach Namen sortiert (Kameras nummerieren fortlaufend).
    nonisolated static func imageFiles(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Foto lesen. JPEG bleibt Byte für Byte erhalten; alles andere (RAW,
    /// HEIC, TIFF, PNG) wird als hochwertiges JPEG abgelegt, damit das Werk
    /// einheitlich bleibt.
    nonisolated static func load(_ url: URL) -> (CGImage, Data)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 8192]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg", let data = try? Data(contentsOf: url) {
            return (image, data)
        }
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.95) else { return nil }
        return (image, data)
    }

    private func restoreBookmark() {
        #if targetEnvironment(macCatalyst)
        guard let data = StudioDefaults.store.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        scoped = url.startAccessingSecurityScopedResource()
        folder = url
        folderName = url.lastPathComponent
        #endif
    }

    private func releaseFolder() {
        if scoped { folder?.stopAccessingSecurityScopedResource() }
        scoped = false
    }
}
