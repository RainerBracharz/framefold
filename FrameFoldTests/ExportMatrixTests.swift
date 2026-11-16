//
//  ExportMatrixTests.swift
//  FrameFoldTests
//
//  Der Film-Export mit echtem Material in allen Varianten. Die Bilder und
//  Videos unter Fixtures/export stammen aus einem echten iPhone-Export und
//  einem Archivfilm; sie liegen so in der Datei, wie Kameras sie ablegen:
//  Pixel gedreht, die gemeinte Lage nur als Vermerk (EXIF bzw. Drehung der
//  Videospur). Jedes Bild trägt in der GEMEINTEN Ansicht vier Farbmarken –
//  rot oben links, grün oben rechts, gelb unten links, blau unten rechts –,
//  einmal in den Ecken und einmal nahe der Mitte (Mitte ± 14 % der kurzen
//  Kante), damit sie jeden Zuschnitt überleben.
//
//  Geprüft wird je Film: Bildzahl und Dauer, Maße und Seitenverhältnis,
//  Lage (Marken am erwarteten Ort, also weder gedreht noch gespiegelt noch
//  verschoben), keine schwarzen Ränder, derselbe Ausschnitt wie im
//  Kontaktbogen. Die Schleifen laufen über die Enum-Fälle – neue Formate,
//  Codecs oder Looks werden automatisch mitgeprüft.
//
//  Die Fixtures baut Fixtures/export/make_fixtures.py (ffmpeg + PIL, braucht
//  die Quellfilme auf Rainers Rechner); Namensschema: exq-<Satz>-o<Vermerk>-<Nr>.jpg, exq-video-r<Grad>-<Codec>.mp4.
//

import XCTest
import AVFoundation
import ImageIO
import UIKit
@testable import FrameFold

@MainActor
final class ExportMatrixTests: XCTestCase {

    // MARK: Fixtures

    /// Ein Quellbild: Datei, Größe der gemeinten Ansicht, mit Marken?
    struct Shot {
        let url: URL
        let size: CGSize
        var marked = true
    }

    /// Fotosätze: Kürzel → Größe der gemeinten Ansicht.
    static let shapes: [(key: String, size: CGSize)] = [
        ("p34", CGSize(width: 480, height: 640)),    // hochkant 3:4, Kopfhörerschachtel, mit echter (gemessener) Verwacklung
        ("l43", CGSize(width: 640, height: 480)),    // quer 4:3, ruhige Ansicht
        ("p916", CGSize(width: 360, height: 640)),   // hochkant 9:16
        ("l169", CGSize(width: 640, height: 360)),   // quer 16:9, drei verschiedene Szenen
    ]
    static let orientations = [1, 3, 6, 8]
    static let extraSizes: [String: CGSize] = [
        "big34": CGSize(width: 900, height: 1200), "small34": CGSize(width: 240, height: 320),
        "odd": CGSize(width: 443, height: 961), "gray43": CGSize(width: 640, height: 480),
    ]
    /// Videos: Drehung der Spur → Größe der gemeinten Ansicht.
    static let videoRotations: [(rotation: Int, size: CGSize)] = [
        (0, CGSize(width: 640, height: 480)), (180, CGSize(width: 640, height: 480)),
        (90, CGSize(width: 360, height: 640)), (270, CGSize(width: 360, height: 640)),
    ]
    static let videoCodecs = ["h264", "hevc"]

    nonisolated static func fixtureURL(_ name: String, file: String = #filePath) -> URL? {
        let bundle = Bundle(for: ExportMatrixTests.self)
        let ns = name as NSString
        for sub in [nil, "Fixtures/export", "export"] as [String?] {
            if let url = bundle.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension, subdirectory: sub) {
                return url
            }
        }
        // Läuft der Test auf dem Rechner, auf dem auch die Quellen liegen: direkt daneben
        let beside = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/export/\(name)")
        return FileManager.default.fileExists(atPath: beside.path) ? beside : nil
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Self.fixtureURL(name), "Fixture \(name) fehlt im Test-Bundle")
    }

    private func size(of key: String) -> CGSize {
        Self.shapes.first { $0.key == key }?.size ?? Self.extraSizes[key] ?? .zero
    }

    private func shot(_ key: String, _ orientation: Int, _ number: Int = 1, ext: String = "jpg") throws -> Shot {
        Shot(url: try fixture("exq-\(key)-o\(orientation)-\(number).\(ext)"), size: size(of: key),
             marked: key != "gray43")
    }

    private func photoSet(_ key: String, _ orientation: Int) throws -> [Shot] {
        try (1...3).map { try shot(key, orientation, $0) }
    }

    // MARK: Einstellungen

    /// Alles aus, was das Bild verändert – Ausgangspunkt für gezielte Varianten.
    private func plain(fps: Int32 = 4) -> PipelineSettings {
        var s = PipelineSettings()
        s.loopMode = .none
        s.transitionFrames = 0
        s.alignFrames = false
        s.deflicker = false
        s.interferenzEcho = false
        s.paperRelief = false
        s.printLook = false
        s.holdLastFrameSeconds = 0
        s.aspect = .original
        s.exportResolution = .p1080
        s.videoCodec = .hevc
        s.look = .original
        s.outputFPS = fps
        return s
    }

    /// Die Schnellwahl aus der Werkansicht (ProjectsView, „Export-Presets“).
    /// Dort stehen sie als Knöpfe in der Ansicht; hier dieselben Werte.
    static let presets: [(name: String, apply: (inout PipelineSettings) -> Void)] = [
        ("Story", { $0.aspect = .reel; $0.outputFPS = 12; $0.loopMode = .none; $0.holdLastFrameSeconds = 1 }),
        ("Quadrat", { $0.aspect = .square; $0.outputFPS = 10; $0.loopMode = .none; $0.holdLastFrameSeconds = 1 }),
        ("Galerie", { $0.aspect = .original; $0.outputFPS = 2; $0.loopMode = .none; $0.holdLastFrameSeconds = 2 }),
    ]

    // MARK: Bild lesen

    /// RGBA-Abbild eines Bilds, Zeile 0 oben.
    struct Bitmap {
        let w: Int, h: Int
        var px: [UInt8]

        init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
            w = width ?? image.width
            h = height ?? image.height
            px = [UInt8](repeating: 0, count: w * h * 4)
            let ok = px.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if !ok { return nil }
        }

        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))) * 4
            return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
        }

        /// Mittel über ein kleines Feld um (x, y).
        func patch(_ x: Int, _ y: Int, radius: Int = 1) -> (r: Double, g: Double, b: Double) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for yy in (y - radius)...(y + radius) { for xx in (x - radius)...(x + radius) {
                let c = rgb(xx, yy); r += c.r; g += c.g; b += c.b; n += 1
            } }
            return (r / n, g / n, b / n)
        }

        func luma(_ x: Int, _ y: Int) -> Double {
            let c = rgb(x, y)
            return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        }

        func image() -> CGImage? {
            var copy = px
            return copy.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }

        /// Helligkeit je Pixel – zum Vergleich zweier Ansichten.
        func gray() -> [Double] { (0..<(w * h)).map { luma($0 % w, $0 / w) } }
    }

    enum Tone: String, CaseIterable {
        case red, green, yellow, blue
        func matches(_ c: (r: Double, g: Double, b: Double)) -> Bool {
            switch self {
            case .red: return c.r - max(c.g, c.b) > 0.25
            case .green: return c.g - max(c.r, c.b) > 0.25
            case .blue: return c.b - max(c.r, c.g) > 0.25
            case .yellow: return min(c.r, c.g) - c.b > 0.25
            }
        }
        /// Richtung in der gemeinten Ansicht: (−1, −1) = oben links.
        var corner: (x: CGFloat, y: CGFloat) {
            switch self {
            case .red: return (-1, -1)
            case .green: return (1, -1)
            case .yellow: return (-1, 1)
            case .blue: return (1, 1)
            }
        }
    }

    /// Wo die Marken eines Quellbilds der Größe `source` in einer Ausgabe der
    /// Größe `out` liegen müssen, wenn das Bild den Rahmen mittig füllt.
    /// Liefert nur Marken, die ganz im Ausschnitt liegen.
    private func expectedMarks(source: CGSize, out: CGSize) -> [(tone: Tone, inner: Bool, point: CGPoint, half: CGFloat)] {
        let short = min(source.width, source.height)
        let m = (0.07 * short).rounded(), d = (0.14 * short).rounded()
        let fill = max(out.width / source.width, out.height / source.height)
        var result: [(Tone, Bool, CGPoint, CGFloat)] = []
        for tone in Tone.allCases {
            let c = tone.corner
            let inner = CGPoint(x: source.width / 2 + c.x * d, y: source.height / 2 + c.y * d)
            let outer = CGPoint(x: c.x < 0 ? m / 2 : source.width - m / 2, y: c.y < 0 ? m / 2 : source.height - m / 2)
            for (isInner, p) in [(true, inner), (false, outer)] {
                let q = CGPoint(x: (p.x - source.width / 2) * fill + out.width / 2,
                                y: (p.y - source.height / 2) * fill + out.height / 2)
                let half = m * fill / 2
                if q.x - half >= -0.5, q.y - half >= -0.5, q.x + half <= out.width + 0.5, q.y + half <= out.height + 0.5 {
                    result.append((tone, isInner, q, half))
                }
            }
        }
        return result
    }

    /// Marken prüfen. `colour` falsch (Schwarzweiß-Looks): nichts zu prüfen,
    /// die Lage klärt dann `orientationProblems`. `slack`: erlaubte Verschiebung
    /// als Anteil der kurzen Kante (für den Verwacklungsausgleich).
    private func markProblems(_ bitmap: Bitmap, source: CGSize, colour: Bool = true, slack: CGFloat = 0) -> [String] {
        let out = CGSize(width: bitmap.w, height: bitmap.h)
        let marks = expectedMarks(source: source, out: out)
        var problems: [String] = []
        guard marks.filter(\.inner).count == 4 else {
            return ["innere Marken liegen nicht im Ausschnitt (Quelle \(source), Ausgabe \(out))"]
        }
        if colour {
            let reach = Int((slack * min(out.width, out.height)).rounded())
            for mark in marks {
                let x = Int(mark.point.x), y = Int(mark.point.y)
                // Am Rand sitzt die Marke knapp: ein Stück nach innen messen
                let r = max(1, min(3, Int(mark.half / 3)))
                var found = mark.tone.matches(bitmap.patch(x, y, radius: r))
                if !found, reach > 0 {
                    search: for dy in stride(from: -reach, through: reach, by: 2) {
                        for dx in stride(from: -reach, through: reach, by: 2)
                        where mark.tone.matches(bitmap.patch(x + dx, y + dy, radius: r)) {
                            found = true
                            break search
                        }
                    }
                }
                if !found {
                    let c = bitmap.patch(x, y, radius: r)
                    problems.append(String(format: "Marke %@ (%@) fehlt bei (%d, %d): r %.2f g %.2f b %.2f",
                                           mark.tone.rawValue, mark.inner ? "Mitte" : "Ecke", x, y, c.r, c.g, c.b))
                }
            }
        }
        return problems
    }

    /// Schwarze Ränder: Der Film darf am Rand nicht schwarz sein, wo die
    /// Quelle es nicht ist. `references`: dieselbe Ansicht aus dem Kontaktbild,
    /// so groß wie der Film und schon mit dem Farblook des Films – bei Echo
    /// und Blenden alle Bilder, die an der Stelle durchscheinen können.
    /// Schwarz im Film (hellster Kanal unter 0,07) gilt als erklärt, wenn eine
    /// der Quellen an derselben Stelle dunkler ist als `limit`; `darkLimit`
    /// rechnet aus den Einstellungen, wie weit Flimmerausgleich, Papierrelief
    /// und Druckbild eine Stelle höchstens abdunkeln. `gray`: Das Druckbild
    /// macht Schwarzweiß, dann zählt die Helligkeit statt des hellsten Kanals.
    /// Geprüft werden je Kante zwei Linien, ganz außen und 3 % weiter innen:
    /// Liegt außen schon in der Quelle ein dunkler Streifen (Schatten,
    /// Kartonkante), verriete sich ein Balken darüber sonst nicht.
    /// Ohne Bezugsbild (Bilder aus Videos) gilt: höchstens 30 % der Kante schwarz.
    private func edgeProblems(_ bitmap: Bitmap, references: [Bitmap] = [], limit: Double = 0.22,
                              gray: Bool = false) -> [String] {
        let w = bitmap.w, h = bitmap.h
        let sources = references.filter { $0.w == w && $0.h == h }
        func black(_ x: Int, _ y: Int) -> Bool {
            let c = bitmap.rgb(x, y)
            return max(c.r, c.g, c.b) < 0.07
        }
        func darkInSource(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Bool {
            // drei Pixel tief ins Bild schauen: Kanten liegen nie auf den Pixel genau
            for source in sources { for k in 0..<3 {
                let c = source.rgb(x + dx * k, y + dy * k)
                let level = gray ? 0.299 * c.r + 0.587 * c.g + 0.114 * c.b : max(c.r, c.g, c.b)
                if level < limit { return true }
            } }
            return false
        }
        var problems: [String] = []
        let ix = max(1, Int(Double(w) * 0.03)), iy = max(1, Int(Double(h) * 0.03))
        let lines: [(String, [(Int, Int)], Int, Int)] = [
            ("oben", (0..<w).map { ($0, 0) }, 0, 1), ("unten", (0..<w).map { ($0, h - 1) }, 0, -1),
            ("links", (0..<h).map { (0, $0) }, 1, 0), ("rechts", (0..<h).map { (w - 1, $0) }, -1, 0),
            ("oben", (0..<w).map { ($0, iy) }, 0, 1), ("unten", (0..<w).map { ($0, h - 1 - iy) }, 0, -1),
            ("links", (0..<h).map { (ix, $0) }, 1, 0), ("rechts", (0..<h).map { (w - 1 - ix, $0) }, -1, 0),
        ]
        for (name, points, dx, dy) in lines where !problems.contains(where: { $0.contains("Rand \(name)") }) {
            let unexplained = points.filter { black($0.0, $0.1) && !darkInSource($0.0, $0.1, dx, dy) }.count
            let share = Double(unexplained) / Double(points.count)
            if share > (sources.isEmpty ? 0.3 : 0.2) {
                problems.append(String(format: "schwarzer Rand %@ (%.0f %% der Kante)", name, share * 100))
            }
        }
        return problems
    }

    /// Bis zu welcher Quellhelligkeit eine Stelle im Film schwarz werden darf.
    /// Grundwert 0,22 (Kodierung, Skalierung); darüber hinaus nur, soweit die
    /// Einstellungen abdunkeln: Flimmerausgleich höchstens auf 0,8, Papierrelief
    /// um seine Stärke, Druckbild mit dem Papierton (dunkelster Kanal 0,85).
    private func darkLimit(_ s: PipelineSettings) -> Double {
        var factor = 1.0
        if s.deflicker { factor *= 0.8 }
        if s.paperRelief { factor *= 1 - min(0.9, max(0, s.reliefStrength)) }
        if s.printLook { factor *= 0.85 }
        return max(0.22, 0.12 / factor)
    }

    /// Bezugsbild mit dem Farblook des Films (über die Look-Funktion der App –
    /// geprüft wird hier der Rand, nicht der Look).
    private func reference(for source: URL, width: Int, height: Int, look: FilmLook) -> Bitmap? {
        guard let plain = reference(for: source, width: width, height: height) else { return nil }
        guard look != .original, let image = plain.image(),
              let styled = StopMotionAssembler.apply(look: look, to: image) else { return plain }
        return Bitmap(styled, width: width, height: height)
    }

    /// Die gemeinte Ansicht der Quelle, mittig füllend auf `width` × `height`
    /// gebracht – über denselben Weg wie der Kontaktbogen (UIImage.thumbnail).
    private func reference(for source: URL, width: Int, height: Int) -> Bitmap? {
        guard let thumb = UIImage.thumbnail(at: source, maxPixelSize: 1280)?.cgImage else { return nil }
        let ratio = CGFloat(width) / CGFloat(height)
        let tw = CGFloat(thumb.width), th = CGFloat(thumb.height)
        let crop = tw / th > ratio
            ? CGRect(x: (tw - th * ratio) / 2, y: 0, width: th * ratio, height: th)
            : CGRect(x: 0, y: (th - tw / ratio) / 2, width: tw, height: tw / ratio)
        guard let cut = thumb.cropping(to: crop.integral) else { return nil }
        return Bitmap(cut, width: width, height: height)
    }

    /// Lage ohne Farbe (Schwarzweiß-Looks): Das Filmbild muss dem Bezugsbild
    /// in seiner eigenen Lage deutlich ähnlicher sein als in jeder der sieben
    /// gedrehten und gespiegelten Lagen.
    private func orientationProblems(_ frame: CGImage, source: URL) -> [String] {
        let n = 48
        guard let a = Bitmap(frame, width: n, height: n)?.gray(),
              let full = reference(for: source, width: frame.width, height: frame.height),
              let image = full.image(), let b = Bitmap(image, width: n, height: n)?.gray() else { return ["kein Bezugsbild"] }
        func correlation(_ map: (Int, Int) -> (Int, Int)) -> Double {
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            for y in 0..<n { for x in 0..<n {
                let (u, v) = map(x, y)
                let p = a[v * n + u], q = b[y * n + x]
                sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
            } }
            let count = Double(n * n)
            let cov = sab / count - sa / count * sb / count
            let va = saa / count - pow(sa / count, 2), vb = sbb / count - pow(sb / count, 2)
            return va > 0 && vb > 0 ? cov / (va * vb).squareRoot() : 0
        }
        let m = n - 1
        let upright = correlation { ($0, $1) }
        let others: [(String, (Int, Int) -> (Int, Int))] = [
            ("gespiegelt", { (m - $0, $1) }), ("kopfüber gespiegelt", { ($0, m - $1) }), ("um 180° gedreht", { (m - $0, m - $1) }),
            ("an der Diagonale gespiegelt", { ($1, $0) }), ("um 90° gedreht", { (m - $1, $0) }),
            ("um 270° gedreht", { ($1, m - $0) }), ("an der Gegendiagonale gespiegelt", { (m - $1, m - $0) }),
        ]
        var problems: [String] = []
        if upright < 0.6 { problems.append(String(format: "Filmbild gleicht der Quelle nicht (Korrelation %.2f)", upright)) }
        for (name, map) in others {
            let c = correlation(map)
            if c > upright - 0.1 { problems.append(String(format: "Filmbild passt %@ ebenso gut (%.2f gegen %.2f)", name, c, upright)) }
        }
        return problems
    }

    /// Mittlerer Helligkeitsunterschied (0…1) zwischen einem Filmbild und
    /// dem, was der Kontaktbogen von der Quelle zeigt (mittig füllend).
    private func differenceToContactSheet(_ frame: CGImage, source: URL) -> Double? {
        guard let thumb = UIImage.thumbnail(at: source, maxPixelSize: 640)?.cgImage else { return nil }
        let side = 48
        guard let a = Bitmap(frame, width: side, height: side) else { return nil }
        // Kontaktbild auf das Seitenverhältnis des Films zuschneiden
        let ratio = CGFloat(frame.width) / CGFloat(frame.height)
        let tw = CGFloat(thumb.width), th = CGFloat(thumb.height)
        let crop = tw / th > ratio
            ? CGRect(x: (tw - th * ratio) / 2, y: 0, width: th * ratio, height: th)
            : CGRect(x: 0, y: (th - tw / ratio) / 2, width: tw, height: tw / ratio)
        guard let cut = thumb.cropping(to: crop.integral), let b = Bitmap(cut, width: side, height: side) else { return nil }
        let ga = a.gray(), gb = b.gray()
        return zip(ga, gb).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(ga.count)
    }

    // MARK: Film prüfen

    private func frameOrder(_ mode: LoopMode, count n: Int) -> [Int] {
        let forward = Array(0..<n)
        switch mode {
        case .none: return forward
        case .reverse: return forward.reversed()
        case .boomerang: return n > 2 ? forward + Array(forward[1..<(n - 1)].reversed()) : forward
        }
    }

    private func videoTrack(_ asset: AVAsset) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first, "Film ohne Bildspur")
    }

    nonisolated private static func sampleCount(_ asset: AVAsset, _ track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var n = 0
        while let buffer = output.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(buffer) }
        return n
    }

    /// Prüft einen fertigen Film gegen die Quellen und Einstellungen.
    /// `sources`: je Quellbild Größe der gemeinten Ansicht und (für den
    /// Vergleich mit dem Kontaktbogen) die Datei.
    private func verify(_ film: URL, sources: [Shot], settings s: PipelineSettings,
                        colour: Bool = true, slack: CGFloat = 0, contactSheet: Bool = true) async -> [String] {
        var problems: [String] = []
        do {
            let asset = AVURLAsset(url: film)
            let track = try await videoTrack(asset)
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            if transform != .identity { problems.append("Film trägt selbst eine Drehung: \(transform)") }
            let ow = Int(natural.width), oh = Int(natural.height)
            if ow % 2 != 0 || oh % 2 != 0 { problems.append("Maße ungerade: \(ow) × \(oh)") }

            // Maße: mittiger Zuschnitt des ersten gezeigten Bilds, auf die Auflösungsgrenze verkleinert
            let order = frameOrder(s.loopMode, count: sources.count)
            let ref = sources[order[0]].size
            var cw = ref.width, ch = ref.height
            if let ratio = s.aspect.ratio.map({ CGFloat($0) }) {
                if cw / ch > ratio { cw = ch * ratio } else { ch = cw / ratio }
                if abs(CGFloat(ow) - CGFloat(oh) * ratio) > 2.5, abs(CGFloat(ow) / ratio - CGFloat(oh)) > 2.5 {
                    problems.append("Seitenverhältnis \(s.aspect.rawValue) verfehlt: \(ow) × \(oh)")
                }
            } else if (ref.width > ref.height) != (ow > oh) {
                problems.append("Original: Hoch-/Querformat vertauscht (\(ow) × \(oh) statt \(ref))")
            }
            let shrink = s.exportResolution.maxDimension.map { min(1, CGFloat($0) / max(cw, ch)) } ?? 1
            if abs(CGFloat(ow) - cw * shrink) > 2.5 || abs(CGFloat(oh) - ch * shrink) > 2.5 {
                problems.append("Maße \(ow) × \(oh), erwartet etwa \(Int(cw * shrink)) × \(Int(ch * shrink))")
            }

            // Bildzahl und Dauer
            let fps = Double(s.outputFPS)
            let step = s.transitionFrames + 1
            let steps = order.count + (order.count - 1) * s.transitionFrames
            let hold = Int((s.holdLastFrameSeconds * fps).rounded())
            let samples = try Self.sampleCount(asset, track)
            if samples != steps + hold { problems.append("\(samples) Bilder im Film, erwartet \(steps + hold)") }
            let duration = try await asset.load(.duration).seconds
            if abs(duration - Double(steps + hold) / fps) > 0.51 / fps {
                problems.append(String(format: "Dauer %.3f s, erwartet %.3f s", duration, Double(steps + hold) / fps))
            }

            // Bilder: jedes Hauptbild; Blenden nur, wenn alle Quellen gleich groß sind
            // (dann liegen die Marken beider Bilder aufeinander); dazu das gehaltene Schlussbild.
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let uniform = Set(sources.map { "\($0.size)" }).count == 1
            var checks: [(position: Int, index: Int, key: Bool)] = []
            for position in 0..<steps {
                let key = position % step == 0
                if key || uniform { checks.append((position, order[position / step], key)) }
            }
            if hold > 0, let last = order.last { checks.append((steps + hold - 1, last, true)) }
            let untouched = s.look == .original && !s.printLook && !s.paperRelief && !s.interferenzEcho
                && !s.deflicker && !s.alignFrames
            var styled: [Int: Bitmap] = [:]   // Bezugsbilder mit Look, je Quelle einmal
            for check in checks where check.position < samples {
                let time = CMTime(seconds: (Double(check.position) + 0.5) / fps, preferredTimescale: 600)
                let image = try await generator.image(at: time).image
                let bitmap = try XCTUnwrap(Bitmap(image))
                let source = sources[check.index]
                let isFile = source.url.pathExtension.lowercased() != "mp4"
                // Echo und Blenden lassen andere Bilder durchscheinen: dann zählen alle Quellen
                var references: [Bitmap] = []
                if isFile {
                    let visible = (s.interferenzEcho || !check.key) ? Array(sources.indices) : [check.index]
                    for index in visible {
                        if styled[index] == nil {
                            styled[index] = reference(for: sources[index].url, width: bitmap.w, height: bitmap.h, look: s.look)
                        }
                        if let reference = styled[index] { references.append(reference) }
                    }
                }
                var found = edgeProblems(bitmap, references: references, limit: darkLimit(s), gray: s.printLook)
                if source.marked { found += markProblems(bitmap, source: source.size, colour: colour, slack: slack) }
                if !colour, isFile, check.key { found += orientationProblems(image, source: source.url) }
                if contactSheet, untouched, check.key,
                   let difference = differenceToContactSheet(image, source: source.url), difference > 0.05 {
                    found.append(String(format: "anderer Ausschnitt als im Kontaktbogen (Abstand %.3f)", difference))
                }
                problems += found.map { "Bild \(check.position + 1) (Quelle \(check.index + 1)): \($0)" }
            }
        } catch {
            problems.append("Film nicht lesbar: \(error)")
        }
        return problems
    }

    /// Exportiert und prüft; liefert die Beanstandungen mit `label` davor.
    private func export(_ label: String, _ shots: [Shot], _ settings: PipelineSettings,
                        colour: Bool = true, slack: CGFloat? = nil, contactSheet: Bool = true) async -> [String] {
        do {
            let film = try await StopMotionAssembler().assemble(
                imageURLs: shots.map(\.url), settings: settings) { _ in }
            defer { try? FileManager.default.removeItem(at: film) }
            // Der Ausgleich darf dieselbe Ansicht zurechtrücken – aber nur wenig.
            let allowed = slack ?? (settings.alignFrames ? 0.06 : 0)
            return await verify(film, sources: shots, settings: settings, colour: colour, slack: allowed,
                                contactSheet: contactSheet).map { "\(label): \($0)" }
        } catch {
            return ["\(label): Export bricht ab (\(error))"]
        }
    }

    private func report(_ problems: [String], runs: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(problems.isEmpty,
                      "\(problems.count) Beanstandungen in \(runs) Exporten:\n" + problems.prefix(25).joined(separator: "\n"),
                      file: file, line: line)
    }

    private func describe(_ s: PipelineSettings) -> String {
        var parts = [s.aspect.rawValue, s.loopMode.rawValue, s.videoCodec.rawValue, s.exportResolution.rawValue,
                     "\(s.outputFPS) fps"]
        if s.alignFrames { parts.append("Ausgleich") }
        if s.deflicker { parts.append("Flimmern") }
        if s.transitionFrames > 0 { parts.append("\(s.transitionFrames)×\(s.transitionStyle.rawValue)") }
        if s.holdLastFrameSeconds > 0 { parts.append("halten \(s.holdLastFrameSeconds)") }
        if s.look != .original { parts.append(s.look.rawValue) }
        return parts.joined(separator: ", ")
    }

    // MARK: 1 – Dateien lesen

    /// Jedes Foto steht nach dem Laden aufrecht – für den Film (in jeder
    /// Dekodiergröße) wie für den Kontaktbogen. Auch gespiegelte Vermerke
    /// (2, 4, 5, 7), HEIC und ungerade Maße.
    func testEveryFixtureDecodesUpright() throws {
        var shots: [(String, Shot)] = []
        for shape in Self.shapes { for o in Self.orientations { for n in 1...3 {
            shots.append(("\(shape.key) o\(o) #\(n)", try shot(shape.key, o, n)))
        } } }
        for o in [2, 4, 5, 7] { shots.append(("p34 o\(o)", try shot("p34", o))) }
        for o in [1, 6] { shots.append(("p34 o\(o) heic", try shot("p34", o, ext: "heic"))) }
        shots.append(("big34 o6", try shot("big34", 6)))
        shots.append(("small34 o1", try shot("small34", 1)))
        for o in [1, 6] { shots.append(("odd o\(o)", try shot("odd", o))) }

        var problems: [String] = []
        for (label, shot) in shots {
            let long = max(shot.size.width, shot.size.height)
            for limit in [nil, 3840, 200, 64] as [Int?] {
                guard let image = StopMotionAssembler.decode(shot.url, maxPixelSize: limit) else {
                    problems.append("\(label): nicht lesbar (Grenze \(String(describing: limit)))")
                    continue
                }
                let scale = min(1, CGFloat(limit ?? Int(long)) / long)
                if abs(CGFloat(image.width) - shot.size.width * scale) > 1.5
                    || abs(CGFloat(image.height) - shot.size.height * scale) > 1.5 {
                    problems.append("\(label): \(image.width) × \(image.height) bei Grenze \(String(describing: limit)), gemeint \(shot.size)")
                    continue
                }
                if (limit ?? 9999) >= 200, let bitmap = Bitmap(image) {
                    problems += markProblems(bitmap, source: shot.size).map { "\(label), Grenze \(String(describing: limit)): \($0)" }
                }
            }
            if let thumb = UIImage.thumbnail(at: shot.url, maxPixelSize: 640)?.cgImage, let bitmap = Bitmap(thumb) {
                problems += markProblems(bitmap, source: shot.size).map { "\(label), Kontaktbogen: \($0)" }
            } else {
                problems.append("\(label): kein Kontaktbild")
            }
        }
        report(problems, runs: shots.count)
    }

    /// Die Randprüfung selbst: Ein Bild, das die Effekte abgedunkelt haben
    /// (hier auf 60 %, wie Relief und Druckbild zusammen), gilt nicht als
    /// Balken; ein echter schwarzer Balken wird an jeder Kante gefunden, hell
    /// wie abgedunkelt.
    func testEdgeCheckTellsDarkContentFromBlackBar() throws {
        var settings = plain()
        settings.paperRelief = true
        settings.reliefStrength = 0.3
        settings.printLook = true
        let limit = darkLimit(settings)
        for (key, o) in [("p34", 6), ("l43", 1), ("l169", 1), ("p916", 8)] {
            let shot = try shot(key, o)
            let w = Int(shot.size.width), h = Int(shot.size.height)
            let source = try XCTUnwrap(reference(for: shot.url, width: w, height: h))
            var dark = source
            for i in dark.px.indices where i % 4 != 3 { dark.px[i] = UInt8(Double(dark.px[i]) * 0.6) }
            XCTAssertEqual(edgeProblems(source, references: [source]), [], "\(key): die Quelle selbst")
            XCTAssertEqual(edgeProblems(dark, references: [source], limit: limit), [], "\(key): dunkler Inhalt ist kein Balken")

            for share in [0.05, 0.15] {
                for (name, inBar) in [
                    ("oben", { (x: Int, y: Int) in Double(y) < Double(h) * share }),
                    ("unten", { (x: Int, y: Int) in Double(y) >= Double(h) * (1 - share) }),
                    ("links", { (x: Int, y: Int) in Double(x) < Double(w) * share }),
                    ("rechts", { (x: Int, y: Int) in Double(x) >= Double(w) * (1 - share) }),
                ] as [(String, (Int, Int) -> Bool)] {
                    for (kind, base, allowed) in [("hell", source, 0.22), ("abgedunkelt", dark, limit)] {
                        var barred = base
                        for y in 0..<h { for x in 0..<w where inBar(x, y) {
                            let i = (y * w + x) * 4
                            barred.px[i] = 0; barred.px[i + 1] = 0; barred.px[i + 2] = 0
                        } }
                        let found = edgeProblems(barred, references: [source], limit: allowed)
                        XCTAssertTrue(found.contains { $0.contains("schwarzer Rand \(name)") },
                                      "\(key): Balken \(name) (\(share), \(kind)) nicht gefunden: \(found)")
                    }
                }
            }
        }
    }

    // MARK: 2 – Eingabe × Format × Ausgleich

    /// Alle Dreh-Vermerke × alle Bildformen × alle Seitenverhältnisse ×
    /// Verwacklungs- und Flimmerausgleich an/aus.
    func testPhotoMatrixOrientationShapeAspectAlignDeflicker() async throws {
        var problems: [String] = []
        var runs = 0
        for shape in Self.shapes {
            for o in Self.orientations {
                let shots = try photoSet(shape.key, o)
                for aspect in AspectPreset.allCases {
                    // an/an und aus/aus überall, die gemischten Paare bei den häufigsten Vermerken
                    var pairs = [(false, false), (true, true)]
                    if o == 6 || o == 1 { pairs += [(true, false), (false, true)] }
                    for (align, deflicker) in pairs {
                        var s = plain()
                        s.aspect = aspect
                        s.alignFrames = align
                        s.deflicker = deflicker
                        problems += await export("\(shape.key) o\(o), \(describe(s))", shots, s)
                        runs += 1
                    }
                }
            }
        }
        report(problems, runs: runs)
    }

    // MARK: 3 – Abspielmodus × Codec × Auflösung, dazu Blenden, Halten, Bildrate

    func testSettingsMatrixLoopCodecResolution() async throws {
        let inputs: [(String, [Shot])] = [("p34 o6", try photoSet("p34", 6)), ("l169 o1", try photoSet("l169", 1))]
        let styles = TransitionStyle.allCases
        let aspects = AspectPreset.allCases
        let rates: [Int32] = [2, 10, 12, 30]
        let holds = [0, 0.5, 1]
        var problems: [String] = []
        var runs = 0
        for (name, shots) in inputs {
            for loop in LoopMode.allCases {
                for codec in VideoCodec.allCases {
                    for resolution in ExportResolution.allCases {
                        var s = plain()
                        s.loopMode = loop
                        s.videoCodec = codec
                        s.exportResolution = resolution
                        // Die übrigen Regler laufen reihum mit, damit jede Paarung vorkommt
                        s.aspect = aspects[runs % aspects.count]
                        s.transitionFrames = runs % 3
                        s.transitionStyle = styles[(runs / 3) % styles.count]
                        s.outputFPS = rates[(runs / 2) % rates.count]
                        s.holdLastFrameSeconds = holds[(runs / 4) % holds.count]
                        s.alignFrames = runs % 5 == 0
                        s.deflicker = runs % 7 == 0
                        problems += await export("\(name), \(describe(s))", shots, s)
                        runs += 1
                    }
                }
            }
        }
        report(problems, runs: runs)
    }

    /// Jede Überblendung in jedem Abspielmodus: Auch die Zwischenbilder
    /// stehen richtig und haben keinen schwarzen Rand.
    func testTransitionsKeepOrientationInEveryFrame() async throws {
        let inputs: [(String, [Shot])] = [("p34 o6", try photoSet("p34", 6)), ("l43 o8", try photoSet("l43", 8))]
        var problems: [String] = []
        var runs = 0
        for (name, shots) in inputs {
            for style in TransitionStyle.allCases {
                for loop in LoopMode.allCases {
                    for (frames, align) in [(1, false), (3, true)] {
                        var s = plain(fps: 10)
                        s.transitionStyle = style
                        s.transitionFrames = frames
                        s.loopMode = loop
                        s.alignFrames = align
                        s.aspect = runs % 2 == 0 ? .reel : .wide
                        problems += await export("\(name), \(describe(s))", shots, s)
                        runs += 1
                    }
                }
            }
        }
        report(problems, runs: runs)
    }

    /// Bildzahl und Dauer über Bildrate × Halten × Abspielmodus × Blenden.
    func testFrameCountAndDuration() async throws {
        let shots = try photoSet("l43", 1)
        var problems: [String] = []
        var runs = 0
        for fps in [1, 2, 3, 10, 12, 24, 30] as [Int32] {
            for hold in [0, 0.4, 1, 2.5] {
                for loop in LoopMode.allCases {
                    var s = plain(fps: fps)
                    s.holdLastFrameSeconds = hold
                    s.loopMode = loop
                    s.transitionFrames = runs % 3
                    problems += await export(describe(s), shots, s)
                    runs += 1
                }
            }
        }
        // Ein und zwei Bilder: Boomerang hat dort nichts zum Umkehren
        for count in [1, 2] {
            for loop in LoopMode.allCases {
                var s = plain()
                s.loopMode = loop
                s.transitionFrames = 2
                s.holdLastFrameSeconds = 1
                problems += await export("\(count) Bild(er), \(describe(s))", Array(shots.prefix(count)), s)
                runs += 1
            }
        }
        report(problems, runs: runs)
    }

    // MARK: 4 – Looks und Effekte

    /// Jeder Look, dazu Druckbild, Papierrelief und Echo: Lage und Ränder
    /// stimmen weiter. Die Lage wird hier ohne Farbe geprüft (Vergleich mit der Quelle).
    func testLooksAndEffectsKeepGeometry() async throws {
        let inputs: [(String, [Shot])] = [("p34 o6", try photoSet("p34", 6)), ("l43 o8", try photoSet("l43", 8))]
        var variants: [(String, (inout PipelineSettings) -> Void)] = FilmLook.allCases.map { look in
            ("Look \(look.rawValue)", { $0.look = look })
        }
        variants.append(("Druckbild", { $0.printLook = true }))
        variants.append(("Papierrelief", { $0.paperRelief = true; $0.reliefStrength = 0.3 }))
        variants.append(("Echo", { $0.interferenzEcho = true; $0.echoStrength = 0.5 }))
        variants.append(("alles", { $0.look = .vivid; $0.printLook = true; $0.paperRelief = true
                                    $0.interferenzEcho = true; $0.transitionFrames = 1; $0.deflicker = true }))
        var problems: [String] = []
        var runs = 0
        for (name, shots) in inputs {
            for (label, apply) in variants {
                for aspect in [AspectPreset.original, .reel] {
                    var s = plain()
                    s.aspect = aspect
                    apply(&s)
                    problems += await export("\(name), \(label), \(aspect.rawValue)", shots, s, colour: false)
                    runs += 1
                }
            }
        }
        report(problems, runs: runs)
    }

    // MARK: 5 – Schnellwahl

    /// Story, Quadrat und Galerie mit den Standard-Einstellungen der App
    /// (Ausgleich und Flimmern an) auf jedem Fotosatz.
    func testPresetsOnEveryPhotoSet() async throws {
        var problems: [String] = []
        var runs = 0
        for shape in Self.shapes {
            for o in Self.orientations {
                let shots = try photoSet(shape.key, o)
                for preset in Self.presets {
                    var s = PipelineSettings()
                    preset.apply(&s)
                    problems += await export("\(shape.key) o\(o), \(preset.name)", shots, s)
                    runs += 1
                }
            }
        }
        report(problems, runs: runs)
    }

    // MARK: 6 – Gemischte Größen in einem Werk

    /// Hoch und quer, groß und klein, verschiedene Vermerke in einem Film:
    /// Jedes Bild füllt den Rahmen mittig, steht aufrecht, kein Schwarz –
    /// in jedem Format, vorwärts wie rückwärts (dann gibt das letzte Bild das Format vor),
    /// mit und ohne Ausgleich.
    func testMixedSizesFillFrameUpright() async throws {
        let mix: [Shot] = [try shot("p34", 6), try shot("l43", 1), try shot("big34", 6), try shot("small34", 1),
                           try shot("p916", 8), try shot("l169", 3), try shot("gray43", 1)]
        let rotated = Array(mix[1...] + mix[..<1])   // beginnt quer
        var problems: [String] = []
        var runs = 0
        for (name, shots) in [("hoch zuerst", mix), ("quer zuerst", rotated)] {
            for aspect in AspectPreset.allCases {
                for loop in [LoopMode.none, .reverse] {
                    for align in [false, true] {
                        var s = plain()
                        s.aspect = aspect
                        s.loopMode = loop
                        s.alignFrames = align
                        s.deflicker = align
                        s.transitionFrames = runs % 2
                        // Streng (gar kein Verschieben) prüft testAlignmentLeavesUnrelatedRealScenesAlone.
                        problems += await export("gemischt (\(name)), \(describe(s))", shots, s)
                        runs += 1
                    }
                }
            }
        }
        report(problems, runs: runs)
    }

    /// Ungerade Maße (Bildschirmfotos, zugeschnittene Bilder): gerade
    /// Ausgabe, kein schwarzer Strich am Rand.
    func testOddDimensionsLeaveNoBlackLine() async throws {
        var problems: [String] = []
        var runs = 0
        for o in [1, 6] {
            let shots = try photoSet("odd", o)
            for aspect in AspectPreset.allCases {
                for resolution in ExportResolution.allCases {
                    var s = plain()
                    s.aspect = aspect
                    s.exportResolution = resolution
                    problems += await export("443 × 961 o\(o), \(describe(s))", shots, s)
                    runs += 1
                }
            }
        }
        report(problems, runs: runs)
    }

    /// Drei verschiedene Szenen aus der Hand: Der Ausgleich lässt sie in
    /// Ruhe – keine Verschiebung, keine Verzerrung, derselbe Ausschnitt wie im Kontaktbogen.
    func testAlignmentLeavesUnrelatedRealScenesAlone() async throws {
        var problems: [String] = []
        var runs = 0
        for o in Self.orientations {
            let shots = try photoSet("l169", o)
            for aspect in AspectPreset.allCases {
                var s = plain()
                s.aspect = aspect
                s.alignFrames = true
                let film = try await StopMotionAssembler().assemble(imageURLs: shots.map(\.url), settings: s) { _ in }
                defer { try? FileManager.default.removeItem(at: film) }
                problems += await verify(film, sources: shots, settings: s, slack: 0).map { "o\(o) \(aspect.rawValue): \($0)" }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: film))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                for (i, shot) in shots.enumerated() {
                    let image = try await generator.image(at: CMTime(seconds: (Double(i) + 0.5) / 4, preferredTimescale: 600)).image
                    let own = try XCTUnwrap(differenceToContactSheet(image, source: shot.url))
                    if own > 0.05 { problems.append(String(format: "o%d %@ Bild %d: weicht vom Kontaktbogen ab (%.3f)", o, aspect.rawValue, i + 1, own)) }
                    // Reihenfolge: Das Bild gleicht seiner Quelle mehr als den anderen
                    for (j, other) in shots.enumerated() where j != i {
                        let foreign = try XCTUnwrap(differenceToContactSheet(image, source: other.url))
                        if foreign <= own { problems.append("o\(o) \(aspect.rawValue) Bild \(i + 1) zeigt eher Quelle \(j + 1)") }
                    }
                }
                runs += 1
            }
        }
        report(problems, runs: runs)
    }

    /// Gegenstück: Dieselbe Ansicht mit echter Verwacklung (Kopfhörerschachtel,
    /// bewegt mit der an Aufnahmen aus der Hand gemessenen Abbildung) rückt
    /// der Ausgleich weiterhin zurecht – die Bilder liegen danach deutlich
    /// besser aufeinander als ohne.
    func testAlignmentStillSteadiesRealShake() async throws {
        for o in Self.orientations {
            let shots = try photoSet("p34", o)
            var distance: [Bool: Double] = [:]
            for align in [false, true] {
                var s = plain()
                s.alignFrames = align
                let film = try await StopMotionAssembler().assemble(imageURLs: shots.map(\.url), settings: s) { _ in }
                defer { try? FileManager.default.removeItem(at: film) }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: film))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var grays: [[Double]] = []
                for i in shots.indices {
                    let image = try await generator.image(at: CMTime(seconds: (Double(i) + 0.5) / 4, preferredTimescale: 600)).image
                    grays.append(try XCTUnwrap(Bitmap(image, width: 120, height: 160)).gray())
                }
                distance[align] = (1..<grays.count).map { i in
                    zip(grays[0], grays[i]).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(grays[0].count)
                }.reduce(0, +) / Double(grays.count - 1)
            }
            let with = try XCTUnwrap(distance[true]), without = try XCTUnwrap(distance[false])
            XCTAssertLessThan(with, without * 0.8,
                              "o\(o): mit Ausgleich \(with), ohne \(without) – der Ausgleich greift bei echter Verwacklung nicht mehr")
        }
    }

    // MARK: 7 – Video-Tab: Bilder aus einem Video

    private func videoShots(rotation: Int, codec: String, count: Int) throws -> (url: URL, shots: [Shot]) {
        let url = try fixture("exq-video-r\(rotation)-\(codec).mp4")
        let size = try XCTUnwrap(Self.videoRotations.first { $0.rotation == rotation }).size
        return (url, Array(repeating: Shot(url: url, size: size), count: count))
    }

    /// Videos mit Dreh-Vermerk 0/90/180/270 in H.264 und HEVC: Der Film aus
    /// den gewählten Bildern steht aufrecht – in jedem Abspielmodus (Normal
    /// liest in einem Durchlauf, die anderen über Zwischenbilder) und Format.
    func testVideoKeyframesRespectTrackRotation() async throws {
        let times = [0.05, 0.25, 0.45, 0.65]   // 10 fps, acht Bilder
        var problems: [String] = []
        var runs = 0
        for (rotation, _) in Self.videoRotations {
            for codec in Self.videoCodecs {
                let (url, shots) = try videoShots(rotation: rotation, codec: codec, count: times.count)
                for loop in LoopMode.allCases {
                    for aspect in AspectPreset.allCases {
                        var s = plain()
                        s.loopMode = loop
                        s.aspect = aspect
                        // Standard im Video-Tab: beide Ausgleiche an; hier abwechselnd
                        s.alignFrames = runs % 2 == 0
                        s.deflicker = runs % 3 == 0
                        s.transitionFrames = runs % 4 == 0 ? 1 : 0
                        let label = "Video r\(rotation) \(codec), \(describe(s))"
                        do {
                            let film = try await StopMotionAssembler().assemble(
                                asset: AVURLAsset(url: url), keyframeTimes: times, settings: s) { _ in }
                            defer { try? FileManager.default.removeItem(at: film) }
                            problems += await verify(film, sources: shots, settings: s,
                                                     slack: s.alignFrames ? 0.06 : 0, contactSheet: false).map { "\(label): \($0)" }
                        } catch {
                            problems.append("\(label): Export bricht ab (\(error))")
                        }
                        runs += 1
                    }
                }
            }
        }
        report(problems, runs: runs)
    }

    // MARK: 8 – Import ins Werk

    private func makeStore() throws -> (ProjectStore, Project) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-export-matrix-\(UUID().uuidString)", isDirectory: true)
        let suite = "ff-export-matrix-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ProjectStore(root: root, defaults: defaults)
        return (store, store.createProject(name: "Export-Matrix"))
    }

    /// Bilder im Werk prüfen (Datei für Datei) und das Werk mit „Galerie“ exportieren.
    private func checkWork(_ label: String, store: ProjectStore, project: Project, sizes: [CGSize]) async -> [String] {
        guard let current = store.projects.first(where: { $0.id == project.id }) else { return ["\(label): Werk fehlt"] }
        let urls = store.frameURLs(for: current)
        guard urls.count == sizes.count else { return ["\(label): \(urls.count) Bilder im Werk, erwartet \(sizes.count)"] }
        var problems: [String] = []
        let shots = zip(urls, sizes).map { Shot(url: $0, size: $1) }
        for (i, shot) in shots.enumerated() {
            guard let image = StopMotionAssembler.decode(shot.url, maxPixelSize: nil), let bitmap = Bitmap(image) else {
                problems.append("\(label): Bild \(i + 1) nicht lesbar"); continue
            }
            if abs(CGFloat(image.width) - shot.size.width) > 1.5 || abs(CGFloat(image.height) - shot.size.height) > 1.5 {
                problems.append("\(label): Bild \(i + 1) ist \(image.width) × \(image.height), gemeint \(shot.size)")
                continue
            }
            problems += markProblems(bitmap, source: shot.size).map { "\(label): Bild \(i + 1) im Werk: \($0)" }
        }
        var s = PipelineSettings()
        Self.presets[2].apply(&s)
        return problems + (await export("\(label), Galerie", shots, s))
    }

    /// Rotoskopie-Import und „Keyframes als Werk sichern“: Bilder aus
    /// gedrehten Videos landen aufrecht im Werk, der Film daraus ebenso.
    func testVideoImportIntoWorkIsUpright() async throws {
        var problems: [String] = []
        var runs = 0
        for (rotation, size) in Self.videoRotations {
            for codec in Self.videoCodecs {
                let url = try fixture("exq-video-r\(rotation)-\(codec).mp4")
                let (store, project) = try makeStore()
                let saved = await store.importVideoFrames(from: url, fps: 5, into: project)
                XCTAssertEqual(saved, 4, "r\(rotation) \(codec): 0,8 s bei 5 Bildern/s")
                problems += await checkWork("Video-Import r\(rotation) \(codec)", store: store, project: project,
                                            sizes: Array(repeating: size, count: saved))

                let (store2, project2) = try makeStore()
                let kept = await store2.importKeyframes(from: url, times: [0.05, 0.35, 0.65], into: project2)
                XCTAssertEqual(kept, 3, "r\(rotation) \(codec)")
                problems += await checkWork("Keyframes r\(rotation) \(codec)", store: store2, project: project2,
                                            sizes: Array(repeating: size, count: kept))
                runs += 2
            }
        }
        report(problems, runs: runs)
    }

    /// Foto-Import (ProjectsView.importPhotos wandelt jedes Foto mit
    /// `UIImage(data:)?.jpegData` um – hier derselbe Schritt): JPEG mit jedem
    /// Vermerk, auch gespiegelt, und HEIC landen aufrecht im Werk.
    func testPhotoImportIntoWorkIsUpright() async throws {
        var inputs: [(String, Shot)] = []
        for o in [1, 2, 3, 4, 5, 6, 7, 8] { inputs.append(("JPEG o\(o)", try shot("p34", o))) }
        for o in [1, 6] { inputs.append(("HEIC o\(o)", try shot("p34", o, ext: "heic"))) }
        for o in Self.orientations { inputs.append(("JPEG quer o\(o)", try shot("l169", o))) }
        inputs.append(("JPEG groß o6", try shot("big34", 6)))

        var problems: [String] = []
        // jedes für sich …
        for (label, shot) in inputs {
            let (store, project) = try makeStore()
            let data = try Data(contentsOf: shot.url)
            let jpeg = try XCTUnwrap(UIImage(data: data)?.jpegData(compressionQuality: 0.92), label)
            XCTAssertNotNil(store.appendFrame(jpegData: jpeg, to: project), label)
            problems += await checkWork("Foto-Import \(label)", store: store, project: project, sizes: [shot.size])
        }
        // … und alle hochkant 3:4 zusammen in einem Werk
        let (store, project) = try makeStore()
        let together = inputs.filter { $0.1.size == size(of: "p34") }
        for (label, shot) in together {
            let jpeg = try XCTUnwrap(UIImage(data: try Data(contentsOf: shot.url))?.jpegData(compressionQuality: 0.92), label)
            let current = try XCTUnwrap(store.projects.first { $0.id == project.id })
            XCTAssertNotNil(store.appendFrame(jpegData: jpeg, to: current), label)
        }
        problems += await checkWork("Foto-Import, alle Vermerke in einem Werk", store: store, project: project,
                                    sizes: together.map(\.1.size))
        report(problems, runs: inputs.count + 1)
    }

    // MARK: 9 – GIF, Bildfolge, Titel und Abspann

    /// GIF aus dem fertigen Film: gleiche Lage, gleiches Seitenverhältnis,
    /// ein Bild je Filmbild (bis 15 Bilder/s), längste Seite höchstens 640 px.
    func testGIFKeepsOrientationAndCount() async throws {
        var problems: [String] = []
        var runs = 0
        for (key, o) in [("p34", 6), ("l169", 8), ("p916", 3), ("l43", 1)] {
            let shots = try photoSet(key, o)
            for aspect in AspectPreset.allCases {
                var s = plain(fps: runs % 2 == 0 ? 4 : 12)
                s.aspect = aspect
                s.holdLastFrameSeconds = 0.5
                let label = "GIF \(key) o\(o), \(describe(s))"
                let film = try await StopMotionAssembler().assemble(imageURLs: shots.map(\.url), settings: s) { _ in }
                defer { try? FileManager.default.removeItem(at: film) }
                let gif = try await GIFMaker.make(from: film)
                defer { try? FileManager.default.removeItem(at: gif) }
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
                let expected = shots.count + Int((0.5 * Double(s.outputFPS)).rounded())
                if CGImageSourceGetCount(source) != expected {
                    problems.append("\(label): \(CGImageSourceGetCount(source)) Bilder, erwartet \(expected)")
                }
                let track = try await videoTrack(AVURLAsset(url: film))
                let natural = try await track.load(.naturalSize)
                for i in [0, CGImageSourceGetCount(source) - 1] {
                    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, i, nil))
                    if max(image.width, image.height) > 640 { problems.append("\(label): GIF zu groß (\(image.width) × \(image.height))") }
                    let ratio = CGFloat(image.width) / CGFloat(image.height)
                    if abs(ratio - natural.width / natural.height) > 0.02 {
                        problems.append("\(label): GIF \(image.width) × \(image.height), Film \(natural)")
                    }
                    let bitmap = try XCTUnwrap(Bitmap(image))
                    let shown = i == 0 ? shots[0] : shots[shots.count - 1]
                    let ref = reference(for: shown.url, width: bitmap.w, height: bitmap.h)
                    problems += (edgeProblems(bitmap, references: [ref].compactMap { $0 }) + markProblems(bitmap, source: shown.size))
                        .map { "\(label), GIF-Bild \(i + 1): \($0)" }
                }
                runs += 1
            }
        }
        report(problems, runs: runs)
    }

    /// Bildfolge in jedem Format: Jedes Einzelbild zeigt, geöffnet wie in
    /// einem Bildbetrachter, die gemeinte Ansicht in voller Größe.
    func testSequenceExportShowsIntendedView() throws {
        var problems: [String] = []
        var runs = 0
        for format in SequenceFormat.allCases {
            for (key, o) in [("p34", 1), ("p34", 3), ("p34", 6), ("p34", 8), ("l169", 6), ("odd", 6)] {
                let shots = try photoSet(key, o)
                let label = "Bildfolge \(format.rawValue) \(key) o\(o)"
                let folder = try StopMotionAssembler.exportSequence(shots.map(\.url), name: "Matrix", format: format)
                defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
                let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                if files.count != shots.count { problems.append("\(label): \(files.count) Dateien") }
                for (file, shot) in zip(files, shots) {
                    // So zeigt ein Betrachter die Datei: mit angewandtem Vermerk
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                    kCGImageSourceThumbnailMaxPixelSize: 4096]
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                          let bitmap = Bitmap(image) else {
                        problems.append("\(label): \(file.lastPathComponent) nicht lesbar"); continue
                    }
                    if CGSize(width: image.width, height: image.height) != shot.size {
                        problems.append("\(label): \(file.lastPathComponent) ist \(image.width) × \(image.height), gemeint \(shot.size)")
                        continue
                    }
                    problems += markProblems(bitmap, source: shot.size).map { "\(label), \(file.lastPathComponent): \($0)" }
                }
                runs += 1
            }
        }
        report(problems, runs: runs)
    }

    /// Titel davor, Abspann oder Schlusskarte dahinter: Format und Lage des
    /// Films bleiben, die Dauer wächst um ganze Bilder.
    func testTitleAndCreditsKeepFormat() async throws {
        var problems: [String] = []
        var runs = 0
        for (key, o, aspect) in [("p34", 6, AspectPreset.reel), ("l169", 8, .original), ("odd", 6, .original)] {
            let shots = try photoSet(key, o)
            for codec in VideoCodec.allCases {
                for (title, credits, brand) in [("Titel", "Abspann", false), ("Titel", nil, true), (nil, nil, true)] as [(String?, String?, Bool)] {
                    var s = plain(fps: 4)
                    s.aspect = aspect
                    s.videoCodec = codec
                    let label = "Titel/Abspann \(key) o\(o) \(codec.rawValue) (\(title ?? "–")/\(credits ?? "–")/\(brand))"
                    let film = try await StopMotionAssembler().assemble(imageURLs: shots.map(\.url), settings: s) { _ in }
                    defer { try? FileManager.default.removeItem(at: film) }
                    let wrapped = try await TitleSequence.wrap(film: film, title: title, subtitle: "2026", credits: credits,
                                                               brandCard: brand, settings: s)
                    defer { if wrapped.url != film { try? FileManager.default.removeItem(at: wrapped.url) } }
                    let before = try await videoTrack(AVURLAsset(url: film))
                    let asset = AVURLAsset(url: wrapped.url)
                    let after = try await videoTrack(asset)
                    let sizeBefore = try await before.load(.naturalSize), sizeAfter = try await after.load(.naturalSize)
                    if sizeBefore != sizeAfter { problems.append("\(label): Format \(sizeAfter) statt \(sizeBefore)") }
                    if try await after.load(.preferredTransform) != .identity { problems.append("\(label): Film trägt eine Drehung") }
                    let fps = Double(s.outputFPS)
                    func whole(_ seconds: Double) -> Double { Double(max(1, Int((seconds * fps).rounded()))) / fps }
                    let lead = title == nil ? 0 : whole(TitleSequence.titleSeconds)
                    let tail = credits != nil ? whole(TitleSequence.creditsSeconds) : (brand ? whole(TitleSequence.brandSeconds) : 0)
                    if abs(wrapped.lead - lead) > 0.001 { problems.append("\(label): Vorspann \(wrapped.lead) s statt \(lead) s") }
                    let duration = try await asset.load(.duration).seconds
                    let expected = lead + Double(shots.count) / fps + tail
                    if abs(duration - expected) > 0.6 / fps { problems.append("\(label): Dauer \(duration) s statt \(expected) s") }
                    // Das erste Filmbild nach dem Vorspann steht richtig
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    for i in shots.indices {
                        let time = CMTime(seconds: lead + (Double(i) + 0.5) / fps, preferredTimescale: 600)
                        let image = try await generator.image(at: time).image
                        let bitmap = try XCTUnwrap(Bitmap(image))
                        let ref = reference(for: shots[i].url, width: bitmap.w, height: bitmap.h)
                        problems += (edgeProblems(bitmap, references: [ref].compactMap { $0 }) + markProblems(bitmap, source: shots[i].size))
                            .map { "\(label), Bild \(i + 1): \($0)" }
                    }
                    runs += 1
                }
            }
        }
        report(problems, runs: runs)
    }

    // MARK: 10 – Kontaktbilder zum Ansehen (nur auf Wunsch)

    /// Schreibt je Export ein Kontaktbild (alle Filmbilder nebeneinander) in
    /// einen Ordner – zum Ansehen mit eigenen Augen. Läuft nur mit
    /// `TEST_RUNNER_FF_QA_DUMP=<Ordner>` vor dem xcodebuild-Aufruf; mit
    /// `TEST_RUNNER_FF_QA_INPUT=<Ordner mit JPEGs>` zusätzlich für eigene Fotos.
    func testDumpContactSheetsForReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["FF_QA_DUMP"], !target.isEmpty else {
            throw XCTSkip("nur mit TEST_RUNNER_FF_QA_DUMP=<Ordner>")
        }
        // Die Mac-Fassung läuft in der Sandbox: Ist der Wunschordner nicht
        // beschreibbar, landen die Bilder im Zwischenspeicher der App (Pfad steht im Protokoll).
        var folder = URL(fileURLWithPath: target, isDirectory: true)
        if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) == nil
            || (try? Data().write(to: folder.appendingPathComponent(".probe"))) == nil {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("ff-export-qa-dump", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        print("KONTAKTBILDER: \(folder.path)")

        var jobs: [(String, [URL], PipelineSettings)] = []
        func presetJobs(_ name: String, _ urls: [URL]) {
            for preset in Self.presets {
                var s = PipelineSettings()
                preset.apply(&s)
                jobs.append(("\(name)-\(preset.name)", urls, s))
            }
        }
        if let input = env["FF_QA_INPUT"], !input.isEmpty {
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: input), includingPropertiesForKeys: nil)
                .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            presetJobs("eigene", urls)
        }
        presetJobs("p34-o6", try photoSet("p34", 6).map(\.url))
        presetJobs("l169-o1-drei-szenen", try photoSet("l169", 1).map(\.url))
        presetJobs("l169-o8-drei-szenen", try photoSet("l169", 8).map(\.url))
        presetJobs("odd-o6", try photoSet("odd", 6).map(\.url))
        let mix = [try shot("p34", 6), try shot("l43", 1), try shot("big34", 6), try shot("small34", 1),
                   try shot("p916", 8), try shot("l169", 3), try shot("gray43", 1)].map(\.url)
        presetJobs("gemischt", mix)
        var bare = plain()
        bare.aspect = .original
        jobs.append(("l169-o1-drei-szenen-ohne-ausgleich", try photoSet("l169", 1).map(\.url), bare))
        jobs.append(("gemischt-ohne-ausgleich", mix, bare))
        // Alle Effekte zusammen, mit Blende – und dasselbe ohne alles zum Vergleich
        var everything = plain()
        everything.look = .vivid; everything.printLook = true; everything.paperRelief = true
        everything.reliefStrength = 0.3
        everything.interferenzEcho = true; everything.echoStrength = 0.5
        everything.transitionFrames = 1; everything.deflicker = true
        jobs.append(("p34-o6-alle-effekte", try photoSet("p34", 6).map(\.url), everything))
        bare.transitionFrames = 1
        jobs.append(("p34-o6-ohne-effekte", try photoSet("p34", 6).map(\.url), bare))

        for (name, urls, settings) in jobs {
            let film = try await StopMotionAssembler().assemble(imageURLs: urls, settings: settings) { _ in }
            defer { try? FileManager.default.removeItem(at: film) }
            let asset = AVURLAsset(url: film)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var frames: [CGImage] = []
            // jedes Bild des Films, auch die Blenden (ohne das gehaltene Schlussbild)
            for i in 0..<(urls.count + (urls.count - 1) * settings.transitionFrames) {
                let time = CMTime(seconds: (Double(i) + 0.5) / Double(settings.outputFPS), preferredTimescale: 600)
                frames.append(try await generator.image(at: time).image)
            }
            let first = try XCTUnwrap(frames.first)
            let cellHeight: CGFloat = 480
            let cellWidth = (cellHeight * CGFloat(first.width) / CGFloat(first.height)).rounded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = CGSize(width: (cellWidth + 6) * CGFloat(frames.count) + 6, height: cellHeight + 12)
            let sheet = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.magenta.setFill()   // Grund in einer Farbe, die im Material nicht vorkommt
                ctx.fill(CGRect(origin: .zero, size: size))
                for (i, frame) in frames.enumerated() {
                    UIImage(cgImage: frame).draw(in: CGRect(x: 6 + (cellWidth + 6) * CGFloat(i), y: 6,
                                                            width: cellWidth, height: cellHeight))
                }
            }
            let out = folder.appendingPathComponent("\(name)-\(first.width)x\(first.height).jpg")
            try XCTUnwrap(sheet.jpegData(compressionQuality: 0.85)).write(to: out)
        }
    }
}
