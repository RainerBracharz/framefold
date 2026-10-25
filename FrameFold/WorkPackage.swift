import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    /// Ein ganzes Werk als eine Datei („Faltung.framefold“).
    static let frameFoldWork = UTType(exportedAs: "com.bracharz.framefold.work", conformingTo: .data)
}

/// Ein Werk als einzelne Datei – zum Sichern und um es per AirDrop oder
/// über „Dateien“ auf ein anderes Gerät zu bringen. Ohne Netzwerk, ohne
/// Cloud: Die Datei wandert nur, wohin man sie selbst schickt.
///
/// Aufbau: Kennung „FFWORK1\n“, danach je Datei
/// Namenslänge (UInt32), Name (UTF-8), Größe (UInt64), Inhalt – Little Endian.
enum WorkPackage {
    static let magic = Data("FFWORK1\n".utf8)
    static let maxEntries = 20_000
    static let maxManifestBytes: UInt64 = 10 << 20
    static let fileExtension = "framefold"

    enum Failure: LocalizedError {
        case notAPackage, damaged, noManifest
        var errorDescription: String? {
            switch self {
            case .notAPackage: return String(localized: "Diese Datei ist kein FrameFold-Werk.")
            case .damaged: return String(localized: "Die Datei ist beschädigt oder unvollständig.")
            case .noManifest: return String(localized: "In der Datei fehlt die Beschreibung des Werks.")
            }
        }
    }

    /// Dateien eines Werkordners in ein Paket schreiben.
    static func write(files: [(name: String, url: URL)], to target: URL) throws {
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        try out.write(contentsOf: magic)
        for file in files {
            let name = Data(file.name.utf8)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            try out.write(contentsOf: le(UInt32(name.count)))
            try out.write(contentsOf: name)
            try out.write(contentsOf: le(size))
            // In Stücken kopieren – ein Werk mit hunderten Fotos passt nicht
            // auf einmal in den Speicher.
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            var remaining = size
            while remaining > 0 {
                let chunk = try input.read(upToCount: Int(min(remaining, 4 << 20))) ?? Data()
                guard !chunk.isEmpty else { throw Failure.damaged }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
    }

    /// Paket in einen (leeren) Ordner entpacken; liefert die Dateinamen.
    @discardableResult
    static func read(_ source: URL, into dir: URL) throws -> [String] {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.read(upToCount: magic.count) == magic else { throw Failure.notAPackage }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        var seen = Set<String>()
        while let lengthData = try input.read(upToCount: 4), !lengthData.isEmpty {
            guard names.count < maxEntries else { throw Failure.damaged }
            guard lengthData.count == 4 else { throw Failure.damaged }
            let length = Int(UInt32(littleEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard length > 0, length < 1024,
                  let nameData = try input.read(upToCount: length), nameData.count == length,
                  let name = String(data: nameData, encoding: .utf8), isSafe(name),
                  let sizeData = try input.read(upToCount: 8), sizeData.count == 8 else { throw Failure.damaged }
            var remaining = UInt64(littleEndian: sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            // Kein Name doppelt, kein Ordnername des Werks, Manifest klein
            guard !seen.contains(name), name != "trash",
                  name != "manifest.json" || remaining <= maxManifestBytes else { throw Failure.damaged }
            seen.insert(name)
            let target = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            while remaining > 0 {
                let chunk = try input.read(upToCount: Int(min(remaining, 4 << 20))) ?? Data()
                guard !chunk.isEmpty else { throw Failure.damaged }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            names.append(name)
        }
        return names
    }

    /// Nur flache, unauffällige Dateinamen – eine präparierte Datei darf
    /// nichts außerhalb des neuen Werkordners schreiben.
    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// Dateiname aus dem Werknamen, ohne Zeichen, die Dateisysteme stören.
    static func filename(for name: String) -> String {
        safeName(name) + "." + fileExtension
    }

    /// Werkname als Datei- oder Ordnername: keine Pfadzeichen, kein Punkt
    /// am Anfang (versteckt, „..“), höchstens 100 Zeichen.
    static func safeName(_ name: String) -> String {
        var cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|%\0")).joined(separator: "-")
            .components(separatedBy: .controlCharacters).joined()
        while let first = cleaned.first, first == "." || first.isWhitespace { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "FrameFold" : cleaned
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

// MARK: Prüfung beim Import


/// Ein fremdes Werk ist Eingabe von außen: Medien werden vor der Übernahme
/// geprüft, Zahlen auf vernünftige Bereiche begrenzt.
enum ImportCheck {
    enum Kind { case jpeg, image, audio, movie }

    /// Größte Bildkante und -fläche, die FrameFold annimmt (auch große
    /// Spiegelreflex- und Mittelformatbilder passen).
    static let maxSide = 16_384
    static let maxPixels = 250_000_000

    /// Welche Dateien taugen wofür – geprüft am Inhalt, nicht an der Endung,
    /// und ohne Bilder dafür zu dekodieren.
    static func usableFiles(_ names: Set<String>, in dir: URL) -> [String: Kind] {
        var result: [String: Kind] = [:]
        for name in names where WorkPackage.isSafe(name) && name != "manifest.json" {
            let url = dir.appendingPathComponent(name)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let type = CGImageSourceGetType(source) as String?,
               CGImageSourceGetCount(source) > 0,
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                if w > 0, h > 0, w <= maxSide, h <= maxSide, w * h <= maxPixels {
                    result[name] = type == "public.jpeg" ? .jpeg : .image
                }
                continue
            }
            if (try? AVAudioFile(forReading: url)) != nil {
                result[name] = .audio
                continue
            }
            if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
                result[name] = .movie
            }
        }
        return result
    }

    static func sanitized(_ project: Project, files: [String: Kind]) -> Project {
        var p = project
        p.name = String(project.name.prefix(200))
        p.frameFilenames = project.frameFilenames.filter { files[$0] == .jpeg }
        // Doppelte Einträge würden auf dieselbe Datei zeigen
        var seen = Set<String>()
        p.frameFilenames = p.frameFilenames.filter { seen.insert($0).inserted }
        p.trashFilenames = nil
        let numbers = p.frameFilenames.compactMap { Int($0.prefix(6)) }.filter { $0 >= 0 && $0 < 999_999 }
        p.nextFrameNumber = (numbers.max() ?? -1) + 1

        if let audio = p.audioFilename, files[audio] != .audio { p.audioFilename = nil }
        p.audioTracks = project.audioTracks?.filter { files[$0.filename] == .audio }.map { track in
            var t = track
            t.name = String(t.name.prefix(200))
            t.startFrame = min(max(0, t.startFrame), 100_000)
            t.volume = t.volume.isFinite ? min(max(0, t.volume), 2) : 1
            t.trimStart = t.trimStart.map(clampSeconds)
            t.maxLength = t.maxLength.map(clampSeconds)
            t.fadeIn = t.fadeIn.map(clampSeconds)
            t.fadeOut = t.fadeOut.map(clampSeconds)
            return t
        }
        if p.audioTracks?.isEmpty == true { p.audioTracks = nil }

        if let bg = p.greenScreen?.backgroundFilename, ![.jpeg, .image, .movie].contains(files[bg]) {
            p.greenScreen?.backgroundFilename = nil
        }
        p.titleText = p.titleText.map { String($0.prefix(2000)) }
        p.creditsText = p.creditsText.map { String($0.prefix(2000)) }
        p.notes = p.notes?.filter { Int($0.key).map { (0...100_000).contains($0) } ?? false }.mapValues { String($0.prefix(2000)) }
        p.dialogue = p.dialogue?.filter { (0...100_000).contains($0.frame) }

        let lastFrame = max(0, p.frameFilenames.count - 1)
        p.overlays = project.overlays?.prefix(10_000).map { overlay in
            var o = overlay
            o.firstFrame = min(max(0, o.firstFrame), lastFrame)
            o.lastFrame = min(max(o.firstFrame, o.lastFrame), lastFrame)
            o.x = clampUnit(o.x)
            o.y = clampUnit(o.y)
            o.size = o.size.isFinite ? min(max(0.01, o.size), 0.3) : 0.06
            o.text = String(o.text.prefix(2000))
            o.strokes = o.strokes.prefix(2000).map { stroke in
                var s = stroke
                s.points = s.points.prefix(20_000).map { CGPoint(x: clampUnit($0.x), y: clampUnit($0.y)) }
                s.width = s.width.isFinite ? min(max(0.001, s.width), 0.1) : 0.008
                return s
            }
            return o
        }
        return p
    }

    private static func clampSeconds(_ value: Double) -> Double {
        value.isFinite ? min(max(0, value), 3600) : 0
    }

    private static func clampUnit<T: BinaryFloatingPoint>(_ value: T) -> T {
        value.isFinite ? min(max(0, value), 1) : 0.5
    }
}
