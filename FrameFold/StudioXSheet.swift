import Speech
import SwiftUI

// MARK: Mundform

/// Schematische Mundstellung zu einer Lautgruppe – als Hilfe beim
/// Animieren, nicht als Figur.
struct MouthShape: View {
    let phoneme: Phoneme
    var color: Color = Theme.paperOnDark

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let (rw, rh): (Double, Double) = {
                switch phoneme {
                case .ai: return (0.9, 0.7)
                case .e: return (0.9, 0.35)
                case .o: return (0.55, 0.6)
                case .u: return (0.35, 0.35)
                case .etc: return (0.8, 0.25)
                case .fv: return (0.8, 0.18)
                case .l: return (0.7, 0.45)
                case .wq: return (0.25, 0.3)
                case .mbp, .rest: return (0.8, 0)
                }
            }()
            let rect = CGRect(x: w * (1 - rw) / 2, y: h * (1 - rh) / 2, width: w * rw, height: h * rh)
            if rh == 0 {
                var line = Path()
                line.move(to: CGPoint(x: rect.minX, y: h / 2))
                line.addQuadCurve(to: CGPoint(x: rect.maxX, y: h / 2),
                                  control: CGPoint(x: w / 2, y: h / 2 + (phoneme == .rest ? 3 : 0)))
                ctx.stroke(line, with: .color(color), lineWidth: 2)
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .color(.black))
                ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
                if phoneme == .fv {   // obere Zähne auf der Unterlippe
                    ctx.fill(Path(CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY, width: rect.width * 0.6, height: rect.height * 0.5)),
                             with: .color(color.opacity(0.8)))
                }
                if phoneme == .l {    // Zunge hinter den Zähnen
                    ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - rect.width * 0.15, y: rect.minY,
                                                    width: rect.width * 0.3, height: rect.height * 0.45)),
                             with: .color(color.opacity(0.6)))
                }
            }
        }
        .accessibilityLabel(Text(verbatim: phoneme.label))
    }
}

// MARK: Spracherkennung

/// Erkennt gesprochene Wörter samt Zeit – nur auf dem Gerät. Ist die
/// Erkennung ohne Netz nicht verfügbar, wird abgebrochen statt Audio an
/// einen Server zu schicken.
enum SpeechReader {
    enum Failure: LocalizedError {
        case notAllowed, unavailable, nothingFound
        var errorDescription: String? {
            switch self {
            case .notAllowed: return String(localized: "Spracherkennung ist nicht erlaubt (Systemeinstellungen → Datenschutz).")
            case .unavailable: return String(localized: "Für diese Sprache gibt es keine Spracherkennung auf dem Gerät.")
            case .nothingFound: return String(localized: "In der Spur wurden keine Wörter erkannt.")
            }
        }
    }

    static func words(in url: URL, locale: Locale) async throws -> [TimedWord] {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let words: [TimedWord] = try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error { finished = true; cont.resume(throwing: error); return }
                guard let result, result.isFinal else { return }
                finished = true
                cont.resume(returning: result.bestTranscription.segments.map {
                    TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                })
            }
        }
        guard !words.isEmpty else { throw Failure.nothingFound }
        return words
    }
}

// MARK: X-Sheet

/// Belichtungsblatt: eine Zeile je Bild mit Tonpegel, Mundform und Wort je
/// Figur und Notiz. Hier wird Dialog gelesen – von Hand oder per
/// Spracherkennung vorgeschlagen und dann korrigiert.
struct XSheetView: View {
    @EnvironmentObject var store: ProjectStore
    let projectID: UUID
    let fps: Int32
    /// Tonpegel auf der Film-Zeitachse (120 Werte je Sekunde)
    let peaks: [Float]
    var currentFrame: Int?
    let onClose: () -> Void

    @State private var showNewCharacter = false
    @State private var newCharacter = ""
    @State private var extraCharacters: [String] = []
    @State private var readTrack: UUID?
    @State private var readCharacter = ""
    @State private var readLanguage = Locale.current.language.languageCode?.identifier ?? "de"
    @State private var reading = false
    @State private var readError: String?

    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var characters: [String] {
        var all = project?.characters ?? []
        for c in extraCharacters where !all.contains(c) { all.append(c) }
        return all
    }
    private var rowCount: Int {
        let audioFrames = Int(Double(peaks.count) / 120 * Double(fps))
        let lastDialogue = project?.dialogue?.map(\.frame).max() ?? 0
        return max(project?.frameCount ?? 0, audioFrames, lastDialogue) + 24
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            readPanel
            columnTitles
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(1...max(1, rowCount), id: \.self) { frame in
                            row(frame).id(frame)
                        }
                    }
                }
                .onAppear { if let currentFrame { proxy.scrollTo(currentFrame, anchor: .center) } }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.darkroom)
        .preferredColorScheme(.dark)
        .alert("Neue Figur", isPresented: $showNewCharacter) {
            TextField("Name", text: $newCharacter)
            Button("Anlegen") {
                let name = newCharacter.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !characters.contains(name) { extraCharacters.append(name) }
                if readCharacter.isEmpty { readCharacter = name }
                newCharacter = ""
            }
            Button("Abbrechen", role: .cancel) { newCharacter = "" }
        }
    }

    private var header: some View {
        HStack {
            Text("X-Sheet").font(Theme.caption(12)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(Theme.paperOnDark)
            if let project {
                Text(verbatim: "· \(project.name) · \(fps) fps").font(Theme.mono(11))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.6))
            }
            Spacer()
            Button("Figur hinzufügen …") { showNewCharacter = true }
                .font(Theme.mono(11))
            Button("Fertig", action: onClose)
                .font(Theme.caption(12))
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.paperOnDark)
        .padding(14)
    }

    /// Automatisches Lesen: Spur und Figur wählen, Wörter erkennen lassen.
    @ViewBuilder
    private var readPanel: some View {
        if let project, !project.allAudioTracks.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic").foregroundStyle(Theme.amber)
                Picker("Spur", selection: $readTrack) {
                    ForEach(project.allAudioTracks) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                Picker("Figur", selection: $readCharacter) {
                    ForEach(characters, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .fixedSize()
                .disabled(characters.isEmpty)
                Picker("Sprache", selection: $readLanguage) {
                    Text("Deutsch").tag("de"); Text("English").tag("en"); Text("Français").tag("fr")
                    Text("Español").tag("es"); Text("Italiano").tag("it"); Text("Nederlands").tag("nl")
                }
                .fixedSize()
                Button(reading ? "Erkenne …" : "Wörter erkennen") { read() }
                    .disabled(reading || readTrack == nil || readCharacter.isEmpty)
                Spacer()
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.paperOnDark)
            .padding(.horizontal, 14).padding(.bottom, 8)
            .onAppear {
                if readTrack == nil { readTrack = project.allAudioTracks.first?.id }
                if readCharacter.isEmpty { readCharacter = characters.first ?? "" }
            }
            if let readError {
                Text(verbatim: readError).font(Theme.mono(11)).foregroundStyle(Theme.oxblood)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            cell(Text("Bild"), width: 56)
            cell(Text("Ton"), width: 90)
            ForEach(characters, id: \.self) { name in
                cell(Text(verbatim: name), width: 230)
            }
            cell(Text("Notiz"), width: nil)
        }
        .font(Theme.caption(10)).tracking(1.2).textCase(.uppercase)
        .foregroundStyle(Theme.paperOnDark.opacity(0.6))
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.4))
    }

    private func cell<V: View>(_ content: V, width: CGFloat?) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ frame: Int) -> some View {
        let captured = frame <= (project?.frameCount ?? 0)
        let isCurrent = frame == currentFrame
        return HStack(spacing: 0) {
            cell(Text(String(format: "%03d", frame))
                    .font(Theme.mono(11, isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? Theme.amber : Theme.paperOnDark.opacity(captured ? 0.9 : 0.45)),
                 width: 56)
            cell(levelBar(frame), width: 90)
            ForEach(characters, id: \.self) { name in
                cell(dialogueCell(frame: frame, character: name), width: 230)
            }
            cell(noteField(frame), width: nil)
        }
        .frame(height: 30)
        .background(frame % Int(max(1, fps)) == 1 ? Color.white.opacity(0.05) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    /// Pegel dieses Bilds als Balken – lauter Ton, breiter Balken.
    private func levelBar(_ frame: Int) -> some View {
        let level = Self.level(peaks: peaks, frame: frame - 1, fps: fps)
        return Rectangle().fill(Theme.amber.opacity(0.8))
            .frame(width: max(1, 74 * CGFloat(level)), height: 10)
            .frame(width: 74, alignment: .leading)
    }

    static func level(peaks: [Float], frame: Int, fps: Int32) -> Float {
        let perFrame = 120.0 / Double(max(1, fps))
        let a = Int(Double(frame) * perFrame), b = Int(Double(frame + 1) * perFrame)
        guard a < peaks.count, a < b else { return 0 }
        return peaks[a..<min(b, peaks.count)].max() ?? 0
    }

    private func dialogueCell(frame: Int, character: String) -> some View {
        let entry = project?.dialogue?.first { $0.frame == frame && $0.character == character }
        let inherited = entry == nil
            ? DialogueReading.current(in: project?.dialogue ?? [], frame: frame, character: character) : nil
        return HStack(spacing: 6) {
            MouthShape(phoneme: (entry ?? inherited)?.phoneme ?? .rest,
                       color: entry == nil ? Theme.paperOnDark.opacity(0.3) : Theme.paperOnDark)
                .frame(width: 26, height: 18)
            Picker("", selection: Binding<Phoneme?>(
                get: { entry?.phoneme },
                set: { new in
                    guard let project else { return }
                    store.setDialogue(frame: frame, character: character, phoneme: new, word: entry?.word, in: project)
                })) {
                Text("—").tag(Phoneme?.none)
                ForEach(Phoneme.allCases) { Text(verbatim: $0.label).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: 74)
            TextField("", text: Binding(
                get: { entry?.word ?? "" },
                set: { word in
                    guard let project else { return }
                    store.setDialogue(frame: frame, character: character,
                                      phoneme: entry?.phoneme ?? Phoneme.guess(for: word).first ?? .rest,
                                      word: word, in: project)
                }), prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.amber)
        }
    }

    private func noteField(_ frame: Int) -> some View {
        TextField("", text: Binding(
            get: { project?.note(forFrame: frame) ?? "" },
            set: { text in if let project { store.setNote(text, forFrame: frame, in: project) } }))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.paperOnDark)
    }

    private func read() {
        guard let project, let track = project.allAudioTracks.first(where: { $0.id == readTrack }) else { return }
        reading = true
        readError = nil
        let url = store.url(for: track, in: project)
        let character = readCharacter
        let fps = self.fps
        let locale = Locale(identifier: readLanguage)
        Task {
            do {
                let words = try await SpeechReader.words(in: url, locale: locale)
                let entries = DialogueReading.entries(for: words, character: character, fps: fps,
                                                      offsetFrames: track.startFrame)
                if let current = store.projects.first(where: { $0.id == projectID }) {
                    store.replaceDialogue(of: character, with: entries, in: current)
                }
            } catch {
                readError = error.localizedDescription
            }
            reading = false
        }
    }
}
