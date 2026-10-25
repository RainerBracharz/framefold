import AVFoundation
import Foundation

/// Erkennt ein Klatschen im Mikrofon – ein kurzer, lauter Ausschlag deutlich
/// über dem Raumgeräusch. Nichts wird aufgezeichnet oder gespeichert.
final class ClapListener: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var noiseFloor: Float = -50
    private var lastClap = Date.distantPast
    private let onClap: @Sendable () -> Void
    private(set) var isRunning = false

    init(onClap: @escaping @Sendable () -> Void) { self.onClap = onClap }

    func start() -> Bool {
        guard !isRunning else { return true }
        #if !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let v = abs(data[i])
            peak = max(peak, v)
            sum += v * v
        }
        let rms = sqrt(sum / Float(max(1, buffer.frameLength)))
        let peakDB = 20 * log10(max(peak, 1e-6))
        let rmsDB = 20 * log10(max(rms, 1e-6))
        if Self.isClap(peakDB: peakDB, noiseFloor: noiseFloor),
           Date().timeIntervalSince(lastClap) > 1.2 {
            lastClap = Date()
            onClap()
        } else {
            // Raumgeräusch langsam nachführen, Spitzen nicht mitzählen
            noiseFloor = noiseFloor * 0.97 + min(rmsDB, noiseFloor + 6) * 0.03
        }
    }

    /// Klatschen: laut (über −14 dBFS) und deutlich (25 dB) über dem Raum.
    static func isClap(peakDB: Float, noiseFloor: Float) -> Bool {
        peakDB > -14 && peakDB > noiseFloor + 25
    }
}
