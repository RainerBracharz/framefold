import AVFoundation
import CoreGraphics
import UIKit

// Simulierte Kamera für Simulator und Mac-Debug (Tests, Bildschirmfotos, App-Vorschau).
#if targetEnvironment(simulator) || (targetEnvironment(macCatalyst) && DEBUG)
extension LiveCaptureController {
    /// Erzeugt 10 Frames/s: ein Papierquadrat wandert in Schritten über den
    /// Tisch, dazwischen fährt eine „Hand" ins Bild. Dieselbe Struktur wie das
    /// Referenz-Testvideo – der Auto-Shutter sollte pro Ruhephase auslösen.
    func startSimulatedCamera() {
        simulatorTask?.cancel()
        // Aufnahmen für die App-Vorschau im Store: Statt der Testszene spielt
        // der Simulator eine vorbereitete Bildfolge ab (JPEGs in FF_SIM_FRAMES,
        // 10 Bilder/s, in Schleife). Nur im Simulator, nur mit gesetzter Variable.
        if let dir = ProcessInfo.processInfo.environment["FF_SIM_FRAMES"], !dir.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            let files = names.filter { $0.hasSuffix(".jpg") }.sorted()
                .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
            if !files.isEmpty {
                simulatorTask = Task { [weak self] in
                    var tick = 0
                    while !Task.isCancelled {
                        guard let self else { return }
                        if let img = UIImage(contentsOfFile: files[tick % files.count].path),
                           let cg = img.cgImage {
                            self.simulatedPreview = img
                            let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(cg, targetWidth: 160)
                            self.analyze(gray: gray, w: w, h: h, fullFrame: cg)
                        }
                        tick += 1
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                return
            }
        }
        simulatorTask = Task { [weak self] in
            var tick = 0
            let stillFrames = 14        // ~1,4 s Ruhe
            let moveFrames = 6          // ~0,6 s Bewegung
            let cycle = stillFrames + moveFrames
            while !Task.isCancelled {
                guard let self else { return }
                let step = tick / cycle
                let inCycle = tick % cycle
                let moving = inCycle >= stillFrames
                let progress = moving ? Double(inCycle - stillFrames) / Double(moveFrames) : 0
                if let cg = Self.makeSimulatedFrame(step: step, moving: moving, progress: progress) {
                    self.simulatedPreview = UIImage(cgImage: cg)
                    let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(cg, targetWidth: 160)
                    self.analyze(gray: gray, w: w, h: h, fullFrame: cg)
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Zeichnet einen synthetischen Atelier-Frame (640×360).
    static func makeSimulatedFrame(step: Int, moving: Bool, progress: Double) -> CGImage? {
        let w = 640, h = 360
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }

        // Tisch
        ctx.setFillColor(red: 0.91, green: 0.86, blue: 0.78, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.69, green: 0.63, blue: 0.55, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 60))

        // Papierquadrat wandert in 8 Schritten
        let positions = (0..<8).map { 40.0 + Double($0) * 70.0 }
        let from = positions[step % positions.count]
        let to = positions[(step + 1) % positions.count]
        let x = moving ? from + (to - from) * progress : from

        ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        ctx.fill(CGRect(x: x, y: 150, width: 80, height: 80))
        ctx.setStrokeColor(red: 0.35, green: 0.33, blue: 0.30, alpha: 1)
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: x, y: 150, width: 80, height: 80))
        ctx.move(to: CGPoint(x: x, y: 150))
        ctx.addLine(to: CGPoint(x: x + 80, y: 230))
        ctx.strokePath()

        // „Hand" nur während der Bewegung
        if moving {
            let hy = 60 + 150 * sin(Double.pi * progress)
            ctx.setFillColor(red: 0.85, green: 0.66, blue: 0.55, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: x + 10, y: hy, width: 70, height: 70))
            ctx.fill(CGRect(x: x + 30, y: 0, width: 34, height: hy))
        }

        // Sensorrauschen, damit die Bewegung nie exakt null ist
        for _ in 0..<220 {
            ctx.setFillColor(red: .random(in: 0...1), green: .random(in: 0...1),
                             blue: .random(in: 0...1), alpha: 0.05)
            ctx.fill(CGRect(x: .random(in: 0...Double(w)), y: .random(in: 0...Double(h)),
                            width: 2, height: 2))
        }
        return ctx.makeImage()
    }
}
#endif
