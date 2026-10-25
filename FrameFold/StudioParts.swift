import AVFoundation
import CoreImage
import SwiftUI
import UIKit

// MARK: Bildverarbeitung

/// Analyse-Ansichten und Chroma-Key auf Core Image.
enum StudioImaging {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Differenz zwischen Live-Bild und einem aufgenommenen Bild: Wo nichts
    /// verrutscht ist, bleibt es schwarz. Hilft, ein angestoßenes Set wieder
    /// auszurichten.
    static func difference(live: CGImage, against frame: CGImage) -> CGImage? {
        let a = CIImage(cgImage: live)
        var b = CIImage(cgImage: frame)
        // Auf dieselbe Größe bringen (Aufnahme hat volle Auflösung)
        let sx = a.extent.width / b.extent.width, sy = a.extent.height / b.extent.height
        b = b.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
            // verstärken, damit kleine Verschiebungen sichtbar werden
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.5, kCIInputBrightnessKey: 0])
        return context.createCGImage(diff, from: a.extent)
    }

    /// Belichtungsansicht: ausgefressene Lichter rot, abgesoffene Schatten
    /// blau, der Rest leicht abgedunkelt in Graustufen.
    static func clipping(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": clippingCube.dimension,
            "inputCubeData": clippingCube.data,
            "inputColorSpace": CGColorSpaceCreateDeviceRGB(),
        ])
        return context.createCGImage(output, from: input.extent)
    }

    /// Chroma-Key: Farbton um `hue` (± 35°) mit genug Sättigung wird durchsichtig.
    static func keyed(_ image: CGImage, hue: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let cube = keyCube(hue: hue)
        let output = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cube.dimension,
            "inputCubeData": cube.data,
            "inputColorSpace": CGColorSpaceCreateDeviceRGB(),
        ])
        return context.createCGImage(output, from: input.extent)
    }

    private struct Cube { let dimension: Int; let data: Data }

    private static let clippingCube: Cube = makeCube(size: 32) { r, g, b in
        let peak = max(r, g, b)
        if peak >= 0.98 { return (1, 0.1, 0.1, 1) }   // ein Kanal ausgefressen
        if peak <= 0.02 { return (0.1, 0.3, 1, 1) }    // alle Kanäle abgesoffen
        let y = (0.299 * r + 0.587 * g + 0.114 * b) * 0.8
        return (y, y, y, 1)
    }

    private static var keyCubes: [Double: Cube] = [:]
    private static func keyCube(hue: Double) -> Cube {
        if let cached = keyCubes[hue] { return cached }
        let cube = makeCube(size: 32) { r, g, b in
            let (h, s, v) = hsv(r, g, b)
            var distance = abs(h - hue)
            distance = min(distance, 360 - distance)
            let keyed = distance < 35 && s > 0.3 && v > 0.15
            // vormultipliziert: durchsichtig heißt alle Kanäle 0
            return keyed ? (0, 0, 0, 0) : (r, g, b, 1)
        }
        keyCubes[hue] = cube
        return cube
    }

    private static func makeCube(size: Int,
                                 _ map: (Double, Double, Double) -> (Double, Double, Double, Double)) -> Cube {
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        let step = 1.0 / Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = map(Double(r) * step, Double(g) * step, Double(b) * step)
                    values += [Float(c.0), Float(c.1), Float(c.2), Float(c.3)]
                }
            }
        }
        return Cube(dimension: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        return (h, maxV == 0 ? 0 : delta / maxV, maxV)
    }
}

// MARK: Bilder des Werks

/// Verkleinerte Bilder des Werks für Betrachter und Wiedergabe. Volle
/// Auflösung wäre beim Abspielen mit 24 fps zu schwer.
@MainActor
final class StudioFrameCache: ObservableObject {
    private let cache = NSCache<NSURL, UIImage>()
    private var loading: Set<URL> = []
    /// Wartende Bilder – höchstens zwei werden gleichzeitig dekodiert, damit
    /// Abspielen nicht alle Kerne und den Speicher auf einmal belegt.
    private var queue: [URL] = []
    private var queued: Set<URL> = []
    private var active = 0
    private let maxActive = 2
    /// Zählt hoch, wenn ein Bild fertig geladen ist – die Ansicht zeichnet neu.
    @Published private(set) var generation = 0

    init() {
        cache.countLimit = 400
        cache.totalCostLimit = 400 << 20   // ~400 MB, Kosten = Pixelbytes
    }

    func image(_ url: URL) -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        enqueue([url], front: true)
        return nil
    }

    /// Bilder vorab laden. Mit `replacing` ersetzt die Liste alle noch
    /// wartenden (beim Abspielen: nur das nächste Stück vorladen).
    func preload(_ urls: [URL], replacing: Bool = false) {
        if replacing { queue = []; queued = [] }
        enqueue(urls, front: false)
    }

    private func enqueue(_ urls: [URL], front: Bool) {
        let fresh = urls.filter { cache.object(forKey: $0 as NSURL) == nil && !loading.contains($0) && !queued.contains($0) }
        guard !fresh.isEmpty else { return }
        queued.formUnion(fresh)
        if front { queue.insert(contentsOf: fresh, at: 0) } else { queue.append(contentsOf: fresh) }
        pump()
    }

    private func pump() {
        while active < maxActive, !queue.isEmpty {
            let url = queue.removeFirst()
            queued.remove(url)
            guard cache.object(forKey: url as NSURL) == nil, !loading.contains(url) else { continue }
            loading.insert(url)
            active += 1
            Task.detached(priority: .userInitiated) {
                let image = UIImage.thumbnail(at: url, maxPixelSize: 1600)
                await MainActor.run {
                    if let image {
                        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                        self.cache.setObject(image, forKey: url as NSURL, cost: cost)
                    }
                    self.loading.remove(url)
                    self.active -= 1
                    self.generation += 1
                    self.pump()
                }
            }
        }
    }
}

// MARK: Referenzebene

/// Referenz: ein Standbild oder ein Film, dessen Bild zur jeweiligen
/// Bildnummer passt (Bild n ↔ Zeit n / Bildrate).
@MainActor
final class StudioReference: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var name: String?
    private var still: CGImage?
    private var generator: AVAssetImageGenerator?
    private var key: ChromaKey = .none
    private var lastRequest: (Int, Int32)?

    var isMovie: Bool { generator != nil }

    func load(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Kopie im Zwischenordner: Die Freigabe der Originaldatei endet hier.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-ref-\(UUID().uuidString.prefix(6))-\(source.lastPathComponent)")
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { return }
        name = source.lastPathComponent
        lastRequest = nil
        if let ui = UIImage(contentsOfFile: copy.path), let cg = ui.cgImage {
            still = cg
            generator = nil
            render(cg)
        } else {
            still = nil
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: copy))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1600, height: 1600)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            generator = gen
            show(frame: 0, fps: 12)
        }
    }

    func clear() {
        still = nil; generator = nil; image = nil; name = nil; lastRequest = nil
    }

    func setKey(_ newKey: ChromaKey) {
        guard newKey != key else { return }
        key = newKey
        if let still { render(still) } else if let (frame, fps) = lastRequest { lastRequest = nil; show(frame: frame, fps: fps) }
    }

    /// Filmreferenz auf die Bildnummer stellen.
    func show(frame: Int, fps: Int32) {
        guard let generator, lastRequest.map({ $0 != (frame, fps) }) ?? true else { return }
        lastRequest = (frame, fps)
        let time = CMTime(value: CMTimeValue(frame), timescale: max(1, fps))
        Task {
            guard let cg = try? await generator.image(at: time).image else { return }
            render(cg)
        }
    }

    private func render(_ cg: CGImage) {
        if let hue = key.hue, let keyed = StudioImaging.keyed(cg, hue: hue) {
            image = UIImage(cgImage: keyed)
        } else {
            image = UIImage(cgImage: cg)
        }
    }
}

// MARK: Hilfslinien

/// Rechteck des Formats `ratio`, mittig in `size`.
func studioMaskRect(in size: CGSize, ratio: Double?) -> CGRect {
    guard let ratio, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
    let canvas = size.width / size.height
    if ratio > canvas {
        let h = size.width / ratio
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    } else {
        let w = size.height * ratio
        return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
    }
}

/// Formatmaske, Sicherheitsrahmen und Raster über dem Bild.
struct StudioGuides: View {
    let settings: StudioSettings

    var body: some View {
        Canvas { ctx, size in
            let rect = studioMaskRect(in: size, ratio: settings.mask.ratio)
            if settings.mask != .none {
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRect(rect)
                ctx.fill(outside, with: .color(.black.opacity(settings.maskOpacity)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(rect), with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
            if settings.safeFrames {
                // Aktionsbereich 93 %, Titelbereich 90 % (EBU R 95)
                for (inset, alpha) in [(0.035, 0.55), (0.05, 0.35)] {
                    let r = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
                    ctx.stroke(Path(r), with: .color(.white.opacity(alpha)),
                               style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                }
            }
            var grid = Path()
            if settings.gridColumns > 1 {
                for i in 1..<settings.gridColumns {
                    let x = rect.minX + rect.width * CGFloat(i) / CGFloat(settings.gridColumns)
                    grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
            }
            if settings.gridRows > 1 {
                for i in 1..<settings.gridRows {
                    let y = rect.minY + rect.height * CGFloat(i) / CGFloat(settings.gridRows)
                    grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
