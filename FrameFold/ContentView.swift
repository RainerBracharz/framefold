import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @StateObject private var viewModel = ProcessingViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.stage {
                case .idle:
                    startView
                case .done:
                    if let result = viewModel.result {
                        ResultView(
                            result: result,
                            sourceVideoURL: viewModel.lastVideoURL,
                            onReset: { viewModel.stage = .idle },
                            onReprocess: {
                                if let url = viewModel.lastVideoURL {
                                    viewModel.process(videoURL: url)
                                }
                            })
                    }
                case .failed(let message):
                    errorView(message)
                default:
                    ProcessingView(stage: viewModel.stage)
                }
            }
            .paperStage()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CatalogLabel("FrameFold", color: Theme.ink, size: 12)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: $viewModel.settings)
            }
        }
    }

    private var startView: some View {
        VStack(spacing: 0) {
            Spacer()
            FoldMark(size: 64)
                .padding(.bottom, 36)
            CatalogLabel("Video → Stopmotion", color: Theme.ink)
                .padding(.bottom, 14)
            Text("Die ruhigen Momente der Arbeit,\ngefunden und montiert.")
                .font(Theme.title)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)
            Text("Frames mit Händen werden entfernt. Alles bleibt auf diesem Gerät.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.graphite)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()

            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Text("Video auswählen")
                    .font(Theme.caption(12))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.paper)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ink)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            // Sofort Feedback zeigen – das Kopieren des Videos aus der
            // Mediathek kann bei langen Aufnahmen einige Sekunden dauern.
            viewModel.stage = .importing
            Task {
                if let movie = try? await newItem.loadTransferable(type: VideoPickerFile.self) {
                    viewModel.process(videoURL: movie.url)
                } else {
                    viewModel.stage = .failed("Das Video konnte nicht geladen werden.")
                }
                pickerItem = nil
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            FoldMark(size: 40, color: Theme.graphite)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Nochmal versuchen") { viewModel.stage = .idle }
                .buttonStyle(HairlineButtonStyle(fullWidth: false))
        }
    }
}

/// Transferable-Wrapper: kopiert das gewählte Video in eine temporäre Datei.
struct VideoPickerFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoPickerFile(url: dest)
        }
    }
}

struct ProcessingView: View {
    let stage: PipelineStage

    private var progress: Double? {
        switch stage {
        case .sampling(let p), .analyzing(let p), .checkingHands(let p), .assembling(let p):
            return p
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            FoldMark(size: 40)
            CatalogLabel(stage.label, color: Theme.ink)
            if let progress {
                HairlineProgress(value: progress)
                    .padding(.horizontal, 60)
            } else {
                ProgressView().tint(Theme.ink)
            }
            CatalogLabel("Lokal auf diesem Gerät")
            Spacer()
        }
    }
}

struct ResultView: View {
    let result: PipelineResult
    let sourceVideoURL: URL?
    let onReset: () -> Void
    let onReprocess: () -> Void
    @EnvironmentObject var store: ProjectStore
    @State private var player: AVPlayer?
    @State private var showSaveToProject = false
    @State private var saveProjectName = ""
    @State private var savedToProject = false

    var body: some View {
        VStack(spacing: 18) {
            VideoPlayer(player: player)
                .aspectRatio(9/16, contentMode: .fit)
                .passepartout()
                .onAppear {
                    let p = AVPlayer(url: result.outputURL)
                    p.play()
                    player = p
                }

            VStack(spacing: 6) {
                CatalogLabel("\(result.keyframeTimes.count) Keyframes · \(Int(result.sourceDuration)) s Quelle",
                             color: Theme.ink)
                CatalogLabel("\(result.discardedForHands) mit Händen entfernt · \(result.discardedAsDuplicates) Duplikate")
            }

            HStack(spacing: 12) {
                ShareLink(item: result.outputURL) {
                    Text("Teilen")
                        .font(Theme.caption(12))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.paper)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.ink)
                }
                Button("Verwerfen") { onReset() }
                    .buttonStyle(HairlineButtonStyle())
            }
            .padding(.horizontal, 24)

            if sourceVideoURL != nil {
                // Einstellungen (Zahnrad oben rechts) ändern und mit
                // demselben Video sofort neu verarbeiten
                Button("Mit aktuellen Einstellungen neu verarbeiten") {
                    onReprocess()
                }
                .buttonStyle(HairlineButtonStyle())
                .padding(.horizontal, 24)

                Button(savedToProject ? "Im Projekt gesichert ✓" : "Als Projekt sichern") {
                    showSaveToProject = true
                }
                .buttonStyle(HairlineButtonStyle())
                .padding(.horizontal, 24)
                .disabled(savedToProject)
            }
        }
        .padding(.vertical)
        .alert("Als Projekt sichern", isPresented: $showSaveToProject) {
            TextField("Projektname", text: $saveProjectName)
            Button("Sichern") {
                guard let url = sourceVideoURL, !saveProjectName.isEmpty else { return }
                let project = store.createProject(name: saveProjectName)
                saveProjectName = ""
                Task {
                    await store.importKeyframes(
                        from: url, times: result.keyframeTimes, into: project)
                    savedToProject = true
                }
            }
            Button("Abbrechen", role: .cancel) { saveProjectName = "" }
        } message: {
            Text("Die Keyframes wandern in ein Projekt und lassen sich dort mit weiteren Sessions ergänzen und neu exportieren.")
        }
    }
}

struct SettingsView: View {
    @Binding var settings: PipelineSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Empfindlichkeit: \(Int(settings.motionPercentile * 100)) %")
                            .font(Theme.body)
                        Slider(value: $settings.motionPercentile, in: 0.1...0.7, step: 0.05)
                        Text("Höher = mehr Frames werden als ruhig akzeptiert")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.graphite)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mindest-Ruhezeit: \(settings.minStillWindowSeconds, specifier: "%.1f") s")
                            .font(Theme.body)
                        Slider(value: $settings.minStillWindowSeconds, in: 0.2...2.0, step: 0.1)
                    }
                } header: {
                    CatalogLabel("Keyframe-Erkennung")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Toggle("Frames mit Händen entfernen", isOn: $settings.removeHands)
                        .font(Theme.body)
                } header: {
                    CatalogLabel("Hände")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Picker("Framerate", selection: $settings.outputFPS) {
                        Text("6 fps").tag(Int32(6))
                        Text("8 fps").tag(Int32(8))
                        Text("10 fps").tag(Int32(10))
                        Text("12 fps").tag(Int32(12))
                    }
                    Picker("Format", selection: $settings.aspect) {
                        ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Abspielmodus", selection: $settings.loopMode) {
                        ForEach(LoopMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Frames ausrichten", isOn: $settings.alignFrames)
                } header: {
                    CatalogLabel("Ausgabe")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Toggle("Interferenz-Echo", isOn: $settings.interferenzEcho)
                    if settings.interferenzEcho {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Echo-Stärke: \(Int(settings.echoStrength * 100)) %")
                                .font(Theme.body)
                            Slider(value: $settings.echoStrength, in: 0.1...0.5, step: 0.05)
                            Text("Der vorherige Frame schimmert im nächsten nach – Rekursion des eigenen Bildes.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.graphite)
                        }
                    }
                    Picker("Falz-Blende", selection: $settings.transitionFrames) {
                        Text("Aus").tag(0)
                        Text("Kurz").tag(2)
                        Text("Weich").tag(4)
                    }
                    Text("Übergänge decken den nächsten Frame entlang einer Diagonale auf – wie ein umgeschlagenes Blatt.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.graphite)
                } header: {
                    CatalogLabel("Interferenz")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
            }
            .font(Theme.body)
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .tint(Theme.ink)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CatalogLabel("Einstellungen", color: Theme.ink, size: 12)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(ProjectStore())
}
