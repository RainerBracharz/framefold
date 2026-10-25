import Foundation

/// Eine Tonspur des Werks: Datei im Werkordner, ab welchem Bild sie
/// einsetzt, wie laut und ob sie stumm ist.
struct AudioTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var filename: String
    /// Einsatz: bei diesem Bild (0-basiert) beginnt der Ton
    var startFrame: Int = 0
    var volume: Double = 1
    var muted = false
    /// Kürzen und Blenden, alles in Sekunden. Optional, damit ältere Werke
    /// ohne diese Felder weiter lesbar bleiben.
    var trimStart: Double?
    /// Höchstens so lang spielen (nil = bis zum Ende der Datei)
    var maxLength: Double?
    var fadeIn: Double?
    var fadeOut: Double?

    var isShaped: Bool {
        (trimStart ?? 0) > 0 || (maxLength ?? 0) > 0 || (fadeIn ?? 0) > 0 || (fadeOut ?? 0) > 0
    }
}

/// Mundformen nach Preston Blair – der Standardsatz im Trickfilm. Jede
/// Lautgruppe hat eine Mundstellung, die die Figur in diesem Bild zeigt.
enum Phoneme: String, Codable, CaseIterable, Identifiable {
    case ai = "AI", e = "E", o = "O", u = "U", etc = "etc", fv = "FV", l = "L", mbp = "MBP", wq = "WQ", rest

    var id: String { rawValue }
    var label: String { self == .rest ? String(localized: "Ruhe") : rawValue }

    /// Kurze Hilfe, welche Laute dazugehören.
    var sounds: String {
        switch self {
        case .ai: return "a, ai, ei"
        case .e: return "e, ä, i"
        case .o: return "o, ö"
        case .u: return "u, ü, oo"
        case .etc: return "c, d, g, k, n, r, s, t, z"
        case .fv: return "f, v, w (de)"
        case .l: return "l, th"
        case .mbp: return "m, b, p"
        case .wq: return "w (en), q, ou"
        case .rest: return "–"
        }
    }

    /// Grobe Zuordnung von Buchstaben zu Mundformen für das automatische
    /// Lesen. Kein echtes Lautlexikon – ein Vorschlag, den man im X-Sheet
    /// korrigiert, wie Animatoren es auch mit Dragonframe tun.
    static func guess(for word: String) -> [Phoneme] {
        let w = word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var result: [Phoneme] = []
        var i = w.startIndex
        while i < w.endIndex {
            let rest = w[i...]
            let two = String(rest.prefix(2))
            var step = 1
            var p: Phoneme?
            switch two {
            case "ai", "ei", "ay": p = .ai; step = 2
            case "oo", "ou", "ow": p = .wq; step = 2
            case "th": p = .l; step = 2
            case "ch", "sh": p = .etc; step = 2
            case "qu": p = .wq; step = 2
            default:
                switch w[i] {
                case "a": p = .ai
                case "e", "i", "y": p = .e
                case "o": p = .o
                case "u": p = .u
                case "f", "v": p = .fv
                case "w": p = .wq
                case "l": p = .l
                case "m", "b", "p": p = .mbp
                case "c", "d", "g", "k", "n", "r", "s", "t", "z", "x", "j", "h": p = .etc
                default: p = nil
                }
            }
            if let p, result.last != p { result.append(p) }
            i = w.index(i, offsetBy: step, limitedBy: w.endIndex) ?? w.endIndex
        }
        return result.isEmpty ? [.rest] : result
    }

    /// Verteilt die Mundformen eines Worts gleichmäßig auf `frames` Bilder.
    static func spread(_ phonemes: [Phoneme], over frames: Int) -> [Phoneme] {
        guard frames > 0, !phonemes.isEmpty else { return [] }
        return (0..<frames).map { phonemes[min(phonemes.count - 1, $0 * phonemes.count / frames)] }
    }
}

/// Ein Eintrag im Dialog-Lesen: In Bild `frame` (1-basiert, wie im X-Sheet)
/// zeigt `character` die Mundform `phoneme`; beim ersten Bild eines Worts
/// steht das Wort dabei.
struct DialogueEntry: Codable, Equatable, Identifiable {
    var frame: Int
    var character: String
    var phoneme: Phoneme
    var word: String?

    var id: String { "\(frame)-\(character)" }
}

/// Erkanntes Wort mit Zeit (aus der Spracherkennung oder von Hand).
struct TimedWord: Equatable {
    var text: String
    var start: Double
    var duration: Double
}

enum DialogueReading {
    /// Wörter mit Zeiten → Einträge je Bild. Pausen dazwischen bekommen
    /// „Ruhe“, damit der Mund sich schließt.
    static func entries(for words: [TimedWord], character: String, fps: Int32, offsetFrames: Int = 0) -> [DialogueEntry] {
        let rate = Double(max(1, fps))
        var result: [DialogueEntry] = []
        var lastEnd: Int?
        for word in words {
            let first = Int((word.start * rate).rounded()) + offsetFrames
            let last = max(first, Int(((word.start + word.duration) * rate).rounded()) - 1 + offsetFrames)
            if let lastEnd, first > lastEnd + 1 {
                result.append(DialogueEntry(frame: lastEnd + 2, character: character, phoneme: .rest, word: nil))
            }
            let shapes = Phoneme.spread(Phoneme.guess(for: word.text), over: last - first + 1)
            for (i, shape) in shapes.enumerated() {
                result.append(DialogueEntry(frame: first + i + 1, character: character, phoneme: shape,
                                            word: i == 0 ? word.text : nil))
            }
            lastEnd = last
        }
        if let lastEnd {
            result.append(DialogueEntry(frame: lastEnd + 2, character: character, phoneme: .rest, word: nil))
        }
        // Doppelte Bildnummern (sehr kurze Wörter): das spätere gewinnt
        var byFrame: [Int: DialogueEntry] = [:]
        for entry in result { byFrame[entry.frame] = entry }
        return byFrame.values.sorted { $0.frame < $1.frame }
    }

    /// Welche Mundform gilt in Bild `frame`? Die letzte gesetzte davor gilt
    /// weiter – so muss man nur Wechsel eintragen, wie im X-Sheet üblich.
    static func current(in entries: [DialogueEntry], frame: Int, character: String) -> DialogueEntry? {
        entries.filter { $0.character == character && $0.frame <= frame }.max { $0.frame < $1.frame }
    }
}
