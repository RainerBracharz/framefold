import AVFoundation
import CoreImage
import UIKit

// MARK: Greenscreen

/// Greenscreen eines Werks: Diese Farbe wird beim Export durch den
/// Hintergrund (Bild oder Film im Werkordner) ersetzt.
struct GreenScreen: Codable, Equatable {
    var key: ChromaKey = .green
    var backgroundFilename: String?
}

/// Setzt Bilder vor einen Hintergrund. Ein Hintergrundfilm läuft Bild für
/// Bild mit (Bild n ↔ Zeit n ÷ Bildrate), ein Standbild bleibt stehen.
final class GreenScreenCompositor: @unchecked Sendable {
    private let hue: Double
    private let still: CIImage?
    private let generator: AVAssetImageGenerator?
    private let fps: Int32
    private let context = CIContext(options: [.cacheIntermediates: false])

    init?(key: ChromaKey, background: URL?, fps: Int32) {
        guard let hue = key.hue, let background else { return nil }
        self.hue = hue
        self.fps = max(1, fps)
        if let image = UIImage(contentsOfFile: background.path), let cg = image.cgImage {
            still = CIImage(cgImage: cg)
            generator = nil
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: background))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.maximumSize = CGSize(width: 3840, height: 3840)
            still = nil
            generator = gen
        }
    }

    /// Bild `index` des Films vor den passenden Hintergrund setzen.
    func composite(_ frame: CGImage, index: Int) async -> CGImage {
        var background = still
        if let generator {
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            if let cg = try? await generator.image(at: time).image { background = CIImage(cgImage: cg) }
        }
        guard let background, let keyed = StudioImaging.keyed(frame, hue: hue) else { return frame }
        return Self.compose(foreground: CIImage(cgImage: keyed), background: background,
                            size: CGSize(width: frame.width, height: frame.height), context: context) ?? frame
    }

    /// Vordergrund (mit Durchsicht) über den bildfüllend skalierten Hintergrund.
    static func compose(foreground: CIImage, background: CIImage, size: CGSize, context: CIContext) -> CGImage? {
        let scale = max(size.width / background.extent.width, size.height / background.extent.height)
        let scaled = background.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (size.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let result = foreground.composited(over: placed)
        return context.createCGImage(result, from: CGRect(origin: .zero, size: size))
    }
}

// MARK: Titel und Abspann

enum TitleCards {
    /// Titelkarte: Papier, Werktitel in Fraunces, Falzbalken, Unterzeile.
    static func title(_ text: String, subtitle: String, size: CGSize) -> UIImage {
        render(size: size) { ctx, size in
            UIColor.ffPaper.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let unit = min(size.width, size.height)
            draw(text, font: serif(unit * 0.09), color: .ffInk,
                 in: CGRect(x: size.width * 0.08, y: size.height * 0.5 - unit * 0.17,
                            width: size.width * 0.84, height: unit * 0.24))
            let bar = CGRect(x: size.width / 2 - unit * 0.08, y: size.height * 0.5 + unit * 0.1,
                             width: unit * 0.16, height: max(4, unit * 0.007))
            UIColor.ffAmber.setFill(); ctx.fill(bar)
            draw(subtitle.uppercased(), font: mono(unit * 0.028), color: .ffGraphite, kern: unit * 0.006,
                 in: CGRect(x: size.width * 0.08, y: bar.maxY + unit * 0.04,
                            width: size.width * 0.84, height: unit * 0.06))
        }
    }

    /// Abspann: dunkel, Zeilen zentriert, unten „Gemacht mit FrameFold“.
    static func credits(_ text: String, size: CGSize) -> UIImage {
        render(size: size) { ctx, size in
            UIColor.ffDarkroom.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let unit = min(size.width, size.height)
            draw(text, font: serif(unit * 0.05), color: .ffPaperOnDark,
                 in: CGRect(x: size.width * 0.1, y: size.height * 0.22,
                            width: size.width * 0.8, height: size.height * 0.56))
            draw(String(localized: "Gemacht mit FrameFold"), font: mono(unit * 0.024),
                 color: UIColor.ffPaperOnDark.withAlphaComponent(0.55), kern: unit * 0.005,
                 in: CGRect(x: 0, y: size.height - unit * 0.12, width: size.width, height: unit * 0.05))
        }
    }

    private static func render(size: CGSize, _ body: (CGContext, CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { body($0.cgContext, size) }
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor, kern: CGFloat = 0, in rect: CGRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern,
        ])
        // senkrecht mittig im Rahmen
        let bounds = attr.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], context: nil)
        let y = rect.minY + max(0, (rect.height - bounds.height) / 2)
        attr.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height),
                  options: [.usesLineFragmentOrigin], context: nil)
    }

    private static func serif(_ size: CGFloat) -> UIFont {
        UIFont(name: "Fraunces-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
    }

    private static func mono(_ size: CGFloat) -> UIFont {
        UIFont(name: "Inter-Medium", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }
}

enum TitleSequence {
    static let titleSeconds = 2.5
    static let creditsSeconds = 4.0

    /// Hängt Titel vor und Abspann hinter den fertigen Film – als eigene
    /// Stücke im selben Format, ohne den Film neu zu kodieren. Gibt den neuen
    /// Film und die Länge des Vorspanns zurück (um die der Ton verschoben wird).
    static func wrap(film: URL, title: String?, subtitle: String, credits: String?,
                     settings: PipelineSettings) async throws -> (url: URL, lead: Double) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let credits = credits?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard title != nil || credits != nil else { return (film, 0) }
        guard let track = try await AVURLAsset(url: film).loadTracks(withMediaType: .video).first else {
            throw PipelineError.exportFailed
        }
        let natural = try await track.load(.naturalSize)
        let size = CGSize(width: abs(natural.width), height: abs(natural.height))

        var parts: [URL] = []
        var lead = 0.0
        if let title {
            parts.append(try await segment(TitleCards.title(title, subtitle: subtitle, size: size),
                                           seconds: titleSeconds, settings: settings))
            lead = titleSeconds
        }
        parts.append(film)
        if let credits {
            parts.append(try await segment(TitleCards.credits(credits, size: size),
                                           seconds: creditsSeconds, settings: settings))
        }
        return (try await concatenate(parts, fileType: settings.videoCodec.fileType), lead)
    }

    /// Ein Standbild als kurzer Film im Format des Hauptfilms.
    private static func segment(_ image: UIImage, seconds: Double, settings: PipelineSettings) async throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw PipelineError.exportFailed }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("titlecard-\(UUID().uuidString).jpg")
        try data.write(to: url)
        var s = PipelineSettings()
        s.outputFPS = settings.outputFPS
        s.videoCodec = settings.videoCodec
        s.aspect = .original
        s.exportResolution = .original
        s.loopMode = .none
        s.alignFrames = false
        s.deflicker = false
        s.transitionFrames = 0
        s.interferenzEcho = false
        s.paperRelief = false
        s.printLook = false
        let count = max(1, Int((seconds * Double(s.outputFPS)).rounded()))
        // Das Bild nur einmal laden und rechnen, den Rest „halten“ – vorher
        // wurde die Karte für jedes einzelne Bild neu gelesen und dekodiert
        s.holdLastFrameSeconds = Double(count - 1) / Double(max(1, s.outputFPS))
        return try await StopMotionAssembler().assemble(imageURLs: [url], settings: s) { _ in }
    }

    /// Filme gleichen Formats hintereinander, nur umverpackt.
    static func concatenate(_ parts: [URL], fileType: AVFileType) async throws -> URL {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PipelineError.exportFailed
        }
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
            cursor = cursor + duration
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw PipelineError.exportFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("framefold-\(UUID().uuidString.prefix(8)).\(fileType == .mov ? "mov" : "mp4")")
        session.outputURL = url
        session.outputFileType = fileType
        await withCheckedContinuation { cont in session.exportAsynchronously { cont.resume() } }
        guard session.status == .completed else { throw PipelineError.exportFailed }
        return url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
