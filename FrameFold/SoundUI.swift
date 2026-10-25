import AVFoundation
import SwiftUI

/// Menü „Geräusch“: legt das gewählte Geräusch als Tonspur ab Bild `frame` an.
struct SoundEffectMenu<Label: View>: View {
    @EnvironmentObject var store: ProjectStore
    let projectID: UUID
    let frame: Int
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(SoundEffect.allCases) { effect in
                Button { add(effect) } label: { SwiftUI.Label(effect.label, systemImage: effect.symbol) }
            }
        } label: { label() }
    }

    private func add(_ effect: SoundEffect) {
        guard let project = store.projects.first(where: { $0.id == projectID }),
              let url = try? SoundLibrary.file(for: effect) else { return }
        store.addAudioTrack(from: url, startFrame: frame, name: effect.label, to: project)
    }
}

/// Menü „Musik“: legt ein Stück ab Bild `frame` an, so lang wie der Rest
/// des Films (mindestens 4 s).
struct MusicMenu<Label: View>: View {
    @EnvironmentObject var store: ProjectStore
    let projectID: UUID
    let frame: Int
    let fps: Int32
    @ViewBuilder let label: () -> Label
    @State private var working = false

    var body: some View {
        Menu {
            ForEach(MusicStyle.allCases) { style in
                Button { add(style) } label: { SwiftUI.Label(style.label, systemImage: style.symbol) }
            }
        } label: { label() }
        .disabled(working)
    }

    private func add(_ style: MusicStyle) {
        guard let project = store.projects.first(where: { $0.id == projectID }) else { return }
        let seconds = Double(max(1, project.frameCount - frame)) / Double(max(1, fps)) + 1
        working = true
        Task {
            let url = try? await Task.detached(priority: .userInitiated) {
                try MusicLibrary.file(for: style, seconds: seconds)
            }.value
            working = false
            guard let url, let current = store.projects.first(where: { $0.id == projectID }) else { return }
            store.addAudioTrack(from: url, startFrame: frame, name: style.label, to: current)
        }
    }
}

/// Text vorlesen lassen (auf dem Gerät) und als Tonspur anlegen.
struct SpeechSheet: View {
    @EnvironmentObject var store: ProjectStore
    let projectID: UUID
    let frame: Int
    let onClose: () -> Void

    @StateObject private var holder = SpeechHolder()
    @State private var text = ""
    @State private var voiceID = SpeechMaker.voices.first(where: { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "de") })?.identifier
        ?? SpeechMaker.voices.first?.identifier ?? ""
    @State private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @State private var working = false
    @State private var failed = false

    private var voice: AVSpeechSynthesisVoice? { AVSpeechSynthesisVoice(identifier: voiceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sprechen lassen").font(Theme.caption(12)).tracking(1.4).textCase(.uppercase)
                Spacer()
                Text("ab Bild \(frame + 1)").font(Theme.mono(11))
            }
            TextField("Was soll gesagt werden?", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .font(Theme.body)
            HStack {
                Text("Stimme").font(Theme.mono(11))
                Spacer()
                Picker("", selection: $voiceID) {
                    ForEach(SpeechMaker.voices, id: \.identifier) { v in
                        Text(verbatim: "\(v.name) · \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)").tag(v.identifier)
                    }
                }
                .labelsHidden()
            }
            HStack {
                Text("Tempo").font(Theme.mono(11))
                Slider(value: $rate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
            }
            if failed {
                Text("Die Stimme konnte nichts erzeugen. Andere Stimme wählen?").font(Theme.mono(11)).foregroundStyle(Theme.oxblood)
            }
            HStack(spacing: 10) {
                Button("Anhören") { holder.maker.preview(text, voice: voice, rate: rate) }
                    .buttonStyle(DarkSecondaryButtonStyle())
                    .disabled(text.isEmpty)
                Button(working ? "…" : "Als Tonspur hinzufügen") { add() }
                    .buttonStyle(DarkPrimaryButtonStyle())
                    .disabled(text.isEmpty || working)
                Button("Abbrechen", role: .cancel, action: onClose)
                    .buttonStyle(DarkSecondaryButtonStyle())
            }
            Text("Die Sprachausgabe läuft auf dem Gerät – nichts wird übertragen.")
                .font(Theme.mono(10)).opacity(0.55)
        }
        .foregroundStyle(Theme.paperOnDark)
        .padding(20)
        .frame(minWidth: 480)
        .background(Theme.darkroom)
        .preferredColorScheme(.dark)
    }

    private func add() {
        working = true
        failed = false
        Task {
            let url = await holder.maker.render(text, voice: voice, rate: rate)
            working = false
            guard let url, let project = store.projects.first(where: { $0.id == projectID }) else { failed = true; return }
            let name = String(text.prefix(24))
            store.addAudioTrack(from: url, startFrame: frame, name: name, to: project)
            onClose()
        }
    }
}

@MainActor
private final class SpeechHolder: ObservableObject {
    let maker = SpeechMaker()
}
