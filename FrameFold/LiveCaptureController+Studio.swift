import Accelerate
import CoreGraphics
import Foundation

/// Studio-Auslösung: Bildschirm abdunkeln und Kamerabilder mitteln, bevor ein
/// Bild ins Werk geht – wie bei Dragonframe „Capture Blackout“ und
/// „Video Frame Averaging“.
extension LiveCaptureController {

    /// Dunkelt ab (falls gewünscht), sammelt danach `averageFrames` frische
    /// Kamerabilder, mittelt sie und legt das Ergebnis ab. Kommen keine
    /// neuen Bilder (Kamera hängt), wird das auslösende Bild genommen.
    func prepareCapture(fallback: CGImage) {
        isPreparingCapture = true
        let count = max(1, averageFrames)
        let blackout = captureBlackout
        // Bild gehört zu genau dieser Sitzung – endet sie vorher, verfällt es.
        let session = sessionStart
        prepareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if blackout {
                self.setBlackout(true)
                // Das Licht des Bildschirms muss aus dem Set sein, bevor das
                // erste Bild für die Aufnahme kommt.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            var frames: [CGImage] = []
            var last = self.currentLatestFrame
            let deadline = Date().addingTimeInterval(Double(count) * 0.25 + 1)
            while frames.count < count, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                if let frame = self.currentLatestFrame, frame !== last {
                    frames.append(frame)
                    last = frame
                }
            }
            // Abgebrochen (Sitzung beendet): `stop()` hat schon aufgeräumt, und
            // eine neue Auslösung darf ihr Abdunkeln behalten.
            guard !Task.isCancelled else { return }
            if blackout { self.setBlackout(false) }
            self.isPreparingCapture = false
            self.prepareTask = nil
            guard self.isRunning, self.sessionStart == session else { return }
            // Gemittelt ist das Ergebnis selbst das Bild fürs Werk – kein Foto
            self.commit(frame: Self.average(frames) ?? fallback, allowPhoto: count == 1)
        }
    }

    /// Mittelwert mehrerer gleich großer Bilder (Rauschminderung bei wenig
    /// Licht). Bilder anderer Größe werden übergangen.
    nonisolated static func average(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        if frames.count == 1 { return first }
        let width = first.width, height = first.height
        let count = width * height * 4
        var sum = [Float](repeating: 0, count: count)
        var bytes = [UInt8](repeating: 0, count: count)
        var used = 0
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        for frame in frames where frame.width == width && frame.height == height {
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: info) else { return false }
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { continue }
            var floats = [Float](repeating: 0, count: count)
            vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(count))
            vDSP_vadd(sum, 1, floats, 1, &sum, 1, vDSP_Length(count))
            used += 1
        }
        guard used > 0 else { return first }
        var scale = 1 / Float(used)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(count))
        // Runden statt abschneiden, sonst wird das Mittel um ein halbes Bit dunkler
        var half: Float = 0.5
        vDSP_vsadd(sum, 1, &half, &sum, 1, vDSP_Length(count))
        vDSP_vfixu8(sum, 1, &bytes, 1, vDSP_Length(count))
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: info)?.makeImage()
        }
    }

    /// Endet der Zeitraffer? Nach `limit` Bildern oder ab `end`.
    nonisolated static func intervalFinished(taken: Int, limit: Int?, end: Date?, now: Date) -> Bool {
        if let limit, taken >= limit { return true }
        if let end, now >= end { return true }
        return false
    }
}
