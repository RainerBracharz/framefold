import AVFoundation
import Foundation

/// Geräusche für Trickfilme – nicht aufgenommen, sondern hier im Code
/// erzeugt. Damit gibt es keine Lizenzfragen, und die App bleibt klein.
enum SoundEffect: String, CaseIterable, Identifiable {
    case pop, whoosh, click, boing, ding, drumroll, steps, splash, zap, tada

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pop: return String(localized: "Plopp")
        case .whoosh: return String(localized: "Wusch")
        case .click: return String(localized: "Klick")
        case .boing: return String(localized: "Boing")
        case .ding: return String(localized: "Ding")
        case .drumroll: return String(localized: "Trommelwirbel")
        case .steps: return String(localized: "Schritte")
        case .splash: return String(localized: "Platsch")
        case .zap: return String(localized: "Zisch")
        case .tada: return String(localized: "Tadaa")
        }
    }

    var symbol: String {
        switch self {
        case .pop: return "circle.dotted"
        case .whoosh: return "wind"
        case .click: return "cursorarrow.click"
        case .boing: return "arrow.up.and.down"
        case .ding: return "bell"
        case .drumroll: return "music.note"
        case .steps: return "figure.walk"
        case .splash: return "drop"
        case .zap: return "bolt"
        case .tada: return "sparkles"
        }
    }
}

enum SoundLibrary {
    static let rate = 44_100.0

    /// Datei mit dem Geräusch (einmal erzeugt, danach wiederverwendet).
    static func file(for effect: SoundEffect) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ff-sfx-\(effect.rawValue).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let samples = render(effect)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData?[0] else { throw PipelineError.exportFailed }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { data[i] = s }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Die Samples eines Geräuschs (−1…1, mono, 44,1 kHz).
    static func render(_ effect: SoundEffect) -> [Float] {
        var rng = SeededNoise(seed: effect.rawValue.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) })
        func n(_ seconds: Double) -> Int { Int(seconds * rate) }
        func env(_ i: Int, _ count: Int, attack: Double = 0.005, curve: Double = 4) -> Double {
            let t = Double(i) / rate
            let a = min(1, t / attack)
            return a * pow(1 - Double(i) / Double(count), curve)
        }
        var out: [Float]
        switch effect {
        case .pop:
            let c = n(0.12); out = (0..<c).map { i in
                let t = Double(i) / rate
                let f = 900 * exp(-t * 30) + 180
                return Float(sin(2 * .pi * f * t) * env(i, c, curve: 3))
            }
        case .whoosh:
            let c = n(0.7); var lp = 0.0
            out = (0..<c).map { i in
                let x = Double(i) / Double(c)
                let cutoff = 0.02 + 0.25 * sin(.pi * x)          // Filter öffnet und schließt
                lp += cutoff * (rng.next() - lp)
                return Float(lp * sin(.pi * x) * 2.2)
            }
        case .click:
            let c = n(0.03); out = (0..<c).map { i in
                Float((rng.next() * 0.6 + sin(2 * .pi * 2500 * Double(i) / rate) * 0.5) * env(i, c, attack: 0.0005, curve: 6))
            }
        case .boing:
            let c = n(0.6); var phase = 0.0
            out = (0..<c).map { i in
                let t = Double(i) / rate
                let f = 220 + 160 * exp(-t * 4) * sin(2 * .pi * 11 * t) + 120 * t
                phase += 2 * .pi * f / rate
                return Float(sin(phase) * env(i, c, curve: 1.5) * 0.8)
            }
        case .ding:
            let c = n(1.4); out = (0..<c).map { i in
                let t = Double(i) / rate
                let partials = [(1.0, 1.0), (2.76, 0.5), (5.4, 0.25), (8.93, 0.12)]
                let v = partials.reduce(0.0) { $0 + sin(2 * .pi * 880 * $1.0 * t) * $1.1 * exp(-t * (2 + $1.0)) }
                return Float(v * 0.5 * min(1, t / 0.002))
            }
        case .drumroll:
            let c = n(1.6); out = [Float](repeating: 0, count: c)
            var start = 0, k = 0
            while start < c {
                let hit = n(0.05)
                for j in 0..<min(hit, c - start) {
                    let swell = 0.35 + 0.65 * Double(start) / Double(c)
                    out[start + j] += Float(rng.next() * env(j, hit, attack: 0.001, curve: 3) * swell)
                }
                k += 1; start += n(0.045 + (k % 2 == 0 ? 0.004 : 0))
            }
        case .steps:
            let c = n(1.6); out = [Float](repeating: 0, count: c)
            for s in 0..<4 {
                let start = n(0.1 + Double(s) * 0.38), hit = n(0.12)
                var lp = 0.0
                for j in 0..<min(hit, c - start) {
                    lp += 0.08 * (rng.next() - lp)
                    let thump = sin(2 * .pi * 90 * Double(j) / rate)
                    out[start + j] += Float((lp * 3 + thump * 0.6) * env(j, hit, attack: 0.002, curve: 4))
                }
            }
        case .splash:
            let c = n(0.9); var lp = 0.0
            out = (0..<c).map { i in
                lp += 0.35 * (rng.next() - lp)
                let t = Double(i) / rate
                let bubble = sin(2 * .pi * (400 + 300 * sin(t * 40)) * t) * 0.15
                return Float((lp + bubble) * env(i, c, attack: 0.003, curve: 2.5))
            }
        case .zap:
            let c = n(0.35); var phase = 0.0
            out = (0..<c).map { i in
                let t = Double(i) / rate
                let f = 2400 * exp(-t * 9) + 120
                phase += 2 * .pi * f / rate
                let square: Double = sin(phase) > 0 ? 0.6 : -0.6
                return Float(square * env(i, c, curve: 1.5) * 0.6)
            }
        case .tada:
            let c = n(1.3); out = (0..<c).map { i in
                let t = Double(i) / rate
                // „Ta“ (kurz) und „daa“ (Dur-Akkord, lang)
                let ta = t < 0.15 ? sin(2 * .pi * 523 * t) * (1 - t / 0.15) : 0
                let chordT = t - 0.18
                let daa = chordT > 0
                    ? [523.25, 659.25, 783.99, 1046.5].reduce(0.0) { $0 + sin(2 * .pi * $1 * chordT) } / 4 * exp(-chordT * 1.6)
                    : 0
                return Float((ta + daa) * 0.7)
            }
        }
        // Auf −1 dBFS normalisieren
        let peak = out.map { abs($0) }.max() ?? 1
        let gain = peak > 0 ? 0.89 / peak : 1
        return out.map { $0 * gain }
    }
}

/// Reproduzierbares Rauschen – gleiche Datei bei jedem Erzeugen.
private struct SeededNoise {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF) * 2 - 1
    }
}

// MARK: Sprachausgabe

/// Getippten Text auf dem Gerät vorlesen lassen und als Tonspur speichern.
@MainActor
final class SpeechMaker {
    private let synthesizer = AVSpeechSynthesizer()

    /// Stimmen in den Sprachen der App, die beste Qualität zuerst.
    static var voices: [AVSpeechSynthesisVoice] {
        let wanted = ["de", "en", "fr", "es", "it", "nl", "ja", "pt"]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in wanted.contains { voice.language.hasPrefix($0) } }
            .sorted { ($0.language, -$0.quality.rawValue, $0.name) < ($1.language, -$1.quality.rawValue, $1.name) }
    }

    /// Text in eine Audiodatei sprechen (nil, wenn nichts entstand).
    func render(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) async -> URL? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ff-sprache-\(UUID().uuidString.prefix(8)).caf")
        var file: AVAudioFile?
        var wrote = false
        return await withCheckedContinuation { cont in
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finished = true
                    cont.resume(returning: wrote ? url : nil)
                    return
                }
                if file == nil { file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                if (try? file?.write(from: pcm)) != nil { wrote = true }
            }
        }
    }

    func preview(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        synthesizer.speak(utterance)
    }
}
