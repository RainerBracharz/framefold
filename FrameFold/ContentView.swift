import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @Binding var selectedTab: Int
    @StateObject private var viewModel = ProcessingViewModel()
    @EnvironmentObject var store: ProjectStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.stage {
                case .idle:
                    startView
                case .reviewing:
                    ReviewView(viewModel: viewModel)
                case .done:
                    if let result = viewModel.result {
                        ResultView(
                            result: result,
                            sourceVideoURL: viewModel.lastVideoURL,
                            onReset: { viewModel.stage = .idle },
                            onReprocess: { viewModel.backToReview() })
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
                    WorkTitle("FrameFold", size: 17)
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

    private var recentProjects: [Project] { Array(store.projects.prefix(4)) }

    private var startView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Kopfbereich mit Signet + Titel
                HStack(alignment: .center, spacing: 16) {
                    FoldMark(size: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        CatalogLabel("Video → Stopmotion")
                        Text("Dein Arbeitsvideo,\nautomatisch zur Stopmotion.")
                            .font(Theme.serif(19, .light))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 20)

                Rectangle().fill(Theme.hairline).frame(height: 1)
                    .padding(.horizontal, 22)

                // Zwei Einstiege – groß und eindeutig
                VStack(spacing: 10) {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        entryCard(icon: "triangle.fill",
                                  title: "Video auswählen",
                                  sub: "Aus einem fertigen Video",
                                  filled: true)
                    }
                    Button {
                        selectedTab = 1
                    } label: {
                        entryCard(icon: "circle.lefthalf.filled",
                                  title: "Direkt aufnehmen",
                                  sub: "Kamera aufs Stativ, automatisch auslösen",
                                  filled: false)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)

                // So funktioniert's – kompakte Dreierreihe
                HStack(alignment: .top, spacing: 0) {
                    stepCell(no: "1", text: "Aufnehmen\noder wählen")
                    stepDivider
                    stepCell(no: "2", text: "Bilder\nprüfen")
                    stepDivider
                    stepCell(no: "3", text: "Teilen\noder sichern")
                }
                .padding(.horizontal, 22)
                .padding(.top, 26)

                // Zuletzt bearbeitete Projekte
                if !recentProjects.isEmpty {
                    HStack {
                        CatalogLabel("Zuletzt bearbeitet", color: Theme.ink)
                        Spacer()
                        Button { selectedTab = 2 } label: {
                            CatalogLabel("Alle →", color: Theme.graphite, size: 10)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 30)
                    .padding(.bottom, 10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recentProjects) { project in
                                Button { selectedTab = 2 } label: {
                                    recentTile(project)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                }

                Text("Die ruhigen Momente werden gewählt, Bilder mit Händen verworfen. Alles bleibt auf diesem Gerät.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.graphite)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 34)
                    .padding(.top, 30)
                    .padding(.bottom, 24)
            }
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

    // MARK: Start-Bausteine

    private func entryCard(icon: String, title: String, sub: String, filled: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(filled ? Theme.paper : Theme.ink)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.caption(13))
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(filled ? Theme.paper : Theme.ink)
                Text(sub)
                    .font(Theme.mono(10))
                    .foregroundStyle(filled ? Theme.paper.opacity(0.7) : Theme.graphite)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 13))
                .foregroundStyle(filled ? Theme.paper.opacity(0.8) : Theme.graphite)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(filled ? Theme.ink : Theme.paper)
        .overlay(Rectangle().stroke(filled ? Color.clear : Theme.hairline, lineWidth: 1))
    }

    private func stepCell(no: String, text: String) -> some View {
        VStack(spacing: 8) {
            Text(no)
                .font(Theme.serif(22, .light))
                .foregroundStyle(Theme.ink)
            Text(text)
                .font(Theme.mono(9.5))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.graphite)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
    }

    private var stepDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 40)
    }

    private func recentTile(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let thumb = store.thumbnail(for: project) {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.paperShade)
                        .overlay(Image(systemName: "square.grid.2x2")
                            .foregroundStyle(Theme.hairline))
                }
            }
            .frame(width: 128, height: 128)
            .clipped()
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))

            Text(project.name)
                .font(Theme.serif(14, .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            CatalogLabel("\(project.frameCount) Bilder", size: 9)
        }
        .frame(width: 128)
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

/// Review vor dem Export: alle gefundenen Keyframes als Kontaktbogen,
/// Empfindlichkeit LIVE nachregelbar (Analyse-Cache – kein Neulesen des
/// Videos), einzelne Frames per Tipp abwählbar.
struct ReviewView: View {
    @ObservedObject var viewModel: ProcessingViewModel

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 2)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack {
                    CatalogLabel("\(viewModel.selectedCount) von \(viewModel.reviewFrames.count) Bildern gewählt",
                                 color: Theme.ink)
                    if viewModel.isRecomputing {
                        ProgressView().tint(Theme.ink).scaleEffect(0.7)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                CatalogLabel("Antippen zum Abwählen")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.reviewFrames) { frame in
                        Button {
                            viewModel.toggleFrame(frame.id)
                        } label: {
                            Group {
                                if let thumb = frame.thumbnail {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Rectangle().fill(Theme.paperShade)
                                }
                            }
                            .frame(minWidth: 76, minHeight: 76)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .opacity(frame.selected ? 1 : 0.3)
                            .overlay(Rectangle().stroke(
                                frame.selected ? Theme.ink : Theme.hairline,
                                lineWidth: frame.selected ? 1.5 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Optionale Feineinstellung – Standard erfasst bereits großzügig,
                // wirkt sofort mit Live-Vorschau (kein verstecktes Vertun möglich)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        CatalogLabel("Weniger Bilder", size: 9)
                        Spacer()
                        CatalogLabel("Mehr Bilder", size: 9)
                    }
                    Slider(value: $viewModel.settings.motionPercentile, in: 0.35...0.75, step: 0.05)
                        .tint(Theme.ink)
                        .onChange(of: viewModel.settings.motionPercentile) { _, _ in
                            viewModel.recomputeFromCache()
                        }
                    Text("Standard erfasst großzügig. Unerwünschte Bilder oben einfach abwählen.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                }
                .padding(14)
                .background(Theme.paperShade.opacity(0.5))
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            VStack(spacing: 10) {
                Button("Stopmotion erstellen") {
                    viewModel.createVideo()
                }
                .buttonStyle(InkButtonStyle())
                .disabled(viewModel.selectedCount == 0)
                Button("Verwerfen") {
                    viewModel.stage = .idle
                }
                .buttonStyle(HairlineButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
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
                CatalogLabel("\(result.keyframeTimes.count) Bilder · aus \(Int(result.sourceDuration)) s Video",
                             color: Theme.ink)
                CatalogLabel("\(result.discardedForHands) mit Händen entfernt · \(result.discardedAsDuplicates) Duplikate")
            }

            HStack(spacing: 12) {
                ShareLink(item: result.outputURL) {
                    Text("Teilen")
                        .font(Theme.caption(12))
                        .tracking(2.2)
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
                // Zurück zur Bildauswahl – der Analyse-Cache bleibt,
                // Regler und Auswahl wirken sofort
                Button("Zurück zur Bildauswahl") {
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
            Text("Die Bilder wandern in ein Projekt und lassen sich dort mit weiteren Aufnahmen ergänzen und neu exportieren.")
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
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(Theme.ink)
                        Text("Die Bildauswahl läuft automatisch: FrameFold erfasst alle ruhigen Momente und entfernt Bilder mit Händen. Feinschliff machst du danach in der Bildauswahl.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.graphite)
                            .lineSpacing(2)
                    }
                } header: {
                    CatalogLabel("Bildauswahl")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Picker("Bildrate", selection: $settings.outputFPS) {
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
                    Toggle("Bilder ausrichten", isOn: $settings.alignFrames)
                } header: {
                    CatalogLabel("Ausgabe")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Toggle("Bild-Echo (Nachbild)", isOn: $settings.interferenzEcho)
                    if settings.interferenzEcho {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Echo-Stärke: \(Int(settings.echoStrength * 100)) %")
                                .font(Theme.body)
                            Slider(value: $settings.echoStrength, in: 0.1...0.5, step: 0.05)
                            Text("Das vorherige Bild schimmert im nächsten leicht nach.")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.graphite)
                        }
                    }
                    Picker("Überblendung", selection: $settings.transitionFrames) {
                        Text("Aus").tag(0)
                        Text("Kurz").tag(2)
                        Text("Weich").tag(4)
                    }
                    Text("Blendet das nächste Bild diagonal ein, statt hart zu schneiden.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                } header: {
                    CatalogLabel("Effekte")
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
    ContentView(selectedTab: .constant(0)).environmentObject(ProjectStore())
}
