import Foundation
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
        while let lengthData = try input.read(upToCount: 4), !lengthData.isEmpty {
            guard lengthData.count == 4 else { throw Failure.damaged }
            let length = Int(UInt32(littleEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard length > 0, length < 1024,
                  let nameData = try input.read(upToCount: length), nameData.count == length,
                  let name = String(data: nameData, encoding: .utf8), isSafe(name),
                  let sizeData = try input.read(upToCount: 8), sizeData.count == 8 else { throw Failure.damaged }
            var remaining = UInt64(littleEndian: sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
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
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "FrameFold" : cleaned) + "." + fileExtension
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
