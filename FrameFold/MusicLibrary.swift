import AVFoundation
import Foundation

/// Kurze Musik für Trickfilme – wie die Geräusche im Code erzeugt, also
/// ohne Lizenzfragen. Jedes Stück wird so lang gerechnet, wie der Film
/// gerade ist, und blendet am Ende aus.
enum MusicStyle: String, CaseIterable, Identifiable {
    case happy, calm, suspense, chase, dream

    var id: String { rawValue }

    var label: String {
        switch self {
        case .happy: return String(localized: "Fröhlich")
        case .calm: return String(localized: "Ruhig")
        case .suspense: return String(localized: "Spannend")
        case .chase: return String(localized: "Verfolgung")
        case .dream: return String(localized: "Traum")
        }
    }

    var symbol: String {
        switch self {
        case .happy: return "sun.max"
        case .calm: return "leaf"
        case .suspense: return "eye"
        case .chase: return "hare"
        case .dream: return "moon.stars"
        }
    }
}

enum MusicLibrary {
    static let rate = 44_100.0

    /// Datei mit dem Stück in der gewünschten Länge (mindestens 4 s).
    static func file(for style: MusicStyle, seconds: Double) throws -> URL {
        let length = max(4, min(600, seconds.rounded(.up)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-musik-\(style.rawValue)-\(Int(length)).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let samples = render(style, seconds: length)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData?[0] else { throw PipelineError.exportFailed }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: partial)
        do {
            let file = try AVAudioFile(forWriting: partial, settings: format.settings)
            try file.write(from: buffer)
            if #available(iOS 18.0, macCatalyst 18.0, *) { file.close() }
        }
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    // MARK: Satz

    private enum Voice { case pluck, pad, bass, bell, kick, hat, snare }
    private struct Note { var start: Double; var length: Double; var midi: Int; var voice: Voice; var gain: Double }

    private struct Plan {
        var bpm: Double
        var key: Int                 // MIDI-Grundton
        var chords: [(Int, Bool)]    // Stufe in Halbtönen, Moll?
        var arpeggio: Bool
        var bell: Bool
        var drums: Int               // 0 keine, 1 leicht, 2 treibend
        var bassEighths: Bool
    }

    private static func plan(_ style: MusicStyle) -> Plan {
        switch style {
        case .happy:
            return Plan(bpm: 120, key: 60, chords: [(0, false), (7, false), (9, true), (5, false)],
                        arpeggio: true, bell: false, drums: 1, bassEighths: false)
        case .calm:
            return Plan(bpm: 72, key: 65, chords: [(0, false), (4, true), (5, false), (0, false)],
                        arpeggio: true, bell: false, drums: 0, bassEighths: false)
        case .suspense:
            return Plan(bpm: 92, key: 57, chords: [(0, true), (8, false), (0, true), (10, false)],
                        arpeggio: false, bell: false, drums: 1, bassEighths: true)
        case .chase:
            return Plan(bpm: 150, key: 62, chords: [(0, true), (10, false), (8, false), (10, false)],
                        arpeggio: true, bell: false, drums: 2, bassEighths: true)
        case .dream:
            return Plan(bpm: 78, key: 63, chords: [(0, false), (9, true), (5, false), (7, false)],
                        arpeggio: false, bell: true, drums: 0, bassEighths: false)
        }
    }

    private static func notes(for style: MusicStyle, seconds: Double) -> [Note] {
        let p = plan(style)
        let beat = 60 / p.bpm
        let bar = beat * 4
        var notes: [Note] = []
        var barIndex = 0
        while Double(barIndex) * bar < seconds {
            let t0 = Double(barIndex) * bar
            let (degree, minor) = p.chords[barIndex % p.chords.count]
            let root = p.key + degree
            let triad = [root, root + (minor ? 3 : 4), root + 7]
            // Flächenklang über den ganzen Takt
            for m in triad { notes.append(Note(start: t0, length: bar, midi: m, voice: .pad, gain: 0.10)) }
            // Bass: Viertel oder treibende Achtel
            let bassStep = p.bassEighths ? beat / 2 : beat
            var b = 0.0
            while b < bar - 0.001 {
                notes.append(Note(start: t0 + b, length: bassStep * 0.9, midi: root - 24, voice: .bass, gain: 0.32))
                b += bassStep
            }
            if p.arpeggio {
                let pattern = [0, 1, 2, 1, 0, 2, 1, 2]
                for (i, idx) in pattern.enumerated() {
                    let octave = (barIndex / p.chords.count) % 2 == 1 && i >= 4 ? 12 : 0
                    notes.append(Note(start: t0 + Double(i) * beat / 2, length: beat / 2,
                                      midi: triad[idx] + 12 + octave, voice: .pluck, gain: 0.16))
                }
            }
            if p.bell {
                for (i, idx) in [2, 0, 1, 2].enumerated() {
                    notes.append(Note(start: t0 + Double(i) * beat, length: beat * 2,
                                      midi: triad[idx] + 24, voice: .bell, gain: 0.12))
                }
            }
            if p.drums > 0 {
                for i in 0..<4 {
                    let t = t0 + Double(i) * beat
                    if i % 2 == 0 || p.drums == 2 { notes.append(Note(start: t, length: 0.3, midi: 0, voice: .kick, gain: 0.55)) }
                    if p.drums == 2 && i % 2 == 1 { notes.append(Note(start: t, length: 0.2, midi: 0, voice: .snare, gain: 0.25)) }
                    notes.append(Note(start: t + beat / 2, length: 0.05, midi: 0, voice: .hat, gain: 0.08))
                }
            }
            barIndex += 1
        }
        return notes
    }

    /// Die Samples eines Stücks (mono, 44,1 kHz, −2 dBFS Spitze).
    static func render(_ style: MusicStyle, seconds: Double) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Double](repeating: 0, count: count)
        var noise: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextNoise() -> Double {
            noise = noise &* 6364136223846793005 &+ 1442695040888963407
            return Double((noise >> 33) & 0xFFFFFF) / Double(0xFFFFFF) * 2 - 1
        }
        for note in notes(for: style, seconds: seconds) {
            let f = 440 * pow(2, Double(note.midi - 69) / 12)
            let release = note.voice == .pad ? 0.4 : note.voice == .bell ? 1.2 : 0.05
            let first = Int(note.start * rate)
            let last = min(count, Int((note.start + note.length + release) * rate))
            guard first < last else { continue }
            var previous = 0.0
            for i in first..<last {
                let t = Double(i - first) / rate
                let held = t < note.length ? 1 : max(0, 1 - (t - note.length) / release)
                let w = 2 * Double.pi * f * t
                let v: Double
                switch note.voice {
                case .pluck:
                    v = (sin(w) + sin(3 * w) / 3 + sin(5 * w) / 5) * exp(-t * 7) * min(1, t / 0.004)
                case .pad:
                    v = (sin(w) + sin(3 * w) / 9) * min(1, t / 0.35)
                case .bass:
                    v = (sin(w) + 0.3 * sin(2 * w)) * exp(-t * 3) * min(1, t / 0.006)
                case .bell:
                    v = (sin(w) + 0.4 * sin(2.76 * w) * exp(-t * 3)) * exp(-t * 1.6) * min(1, t / 0.002)
                case .kick:
                    let kf = 45 + 75 * exp(-t * 30)
                    v = sin(2 * .pi * kf * t) * exp(-t * 12)
                case .hat:
                    let n = nextNoise()
                    v = (n - previous) * exp(-t * 60)
                    previous = n
                case .snare:
                    v = (nextNoise() * 0.8 + sin(2 * .pi * 180 * t) * 0.4) * exp(-t * 18)
                }
                out[i] += v * note.gain * held
            }
        }
        // Am Ende ausblenden, damit der Film nicht mitten im Takt abreißt
        let fade = min(count, Int(1.5 * rate))
        for i in 0..<fade { out[count - 1 - i] *= Double(i) / Double(fade) }
        let peak = out.map(abs).max() ?? 1
        let gain = peak > 0 ? 0.8 / peak : 1
        return out.map { Float($0 * gain) }
    }
}
