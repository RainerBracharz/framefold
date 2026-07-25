import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @Binding var selectedTab: Int
    @StateObject private var viewModel = ProcessingViewModel()
    @EnvironmentObject var store: ProjectStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var homeIn = false

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
                            onReprocess: { viewModel.backToReview() },
                            onRecurse: { viewModel.process(videoURL: result.outputURL) })
                    }
                case .failed(let message):
                    errorView(message)
                default:
                    ProcessingView(stage: viewModel.stage)
                }
            }
            .paperStage()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    LogoTile(size: 26)
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
                // Hero – trägt die Stimme, füllt den oberen Raum
                VStack(alignment: .leading, spacing: 14) {
                    CatalogLabel("Video → Stopmotion")
                    Text("Vom Video zur\nStopmotion.")
                        .font(Theme.serif(31, .regular))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Die ruhigen Momente werden gewählt, Bilder mit Händen verworfen — alles bleibt auf deinem Gerät.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.graphite)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)

                // Primäraktion – groß, eindeutig, klarer Tap
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    primaryAction
                }
                .padding(.horizontal, 24)

                // Sekundäraktion – klar untergeordnet
                Button { selectedTab = 1 } label: {
                    secondaryAction
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 12)

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

                Spacer(minLength: 28)
            }
            // Ruhiger Auftritt: der Inhalt steigt beim ersten Erscheinen sanft ein
            .opacity(homeIn ? 1 : 0)
            .offset(y: homeIn ? 0 : 12)
        }
        .onAppear {
            if !homeIn { withAnimation(.smooth(duration: 0.55)) { homeIn = true } }
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

    /// Primäraktion: großer warmer Ink-Block, Film-Icon (wie der Video-Tab),
    /// feiner Marine-Falz in der Ecke – der eindeutige erste Griff.
    private var primaryAction: some View {
        HStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 22))
                .foregroundStyle(Theme.paper)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Video auswählen")
                    .font(Theme.caption(15)).tracking(1.6).textCase(.uppercase)
                    .foregroundStyle(Theme.paper)
                Text("Aus einem fertigen Video")
                    .font(Theme.mono(11)).foregroundStyle(Theme.paper.opacity(0.72))
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.paper.opacity(0.85))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Theme.ink)
        .overlay(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 20))
                p.addLine(to: CGPoint(x: 20, y: 0))
            }
            .stroke(Theme.crease, lineWidth: 2)
        }
    }

    /// Sekundäraktion: klar untergeordnet, Kamera-Icon (wie der Kamera-Tab).
    private var secondaryAction: some View {
        HStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 19))
                .foregroundStyle(Theme.ink)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Direkt aufnehmen")
                    .font(Theme.caption(13)).tracking(1.6).textCase(.uppercase)
                    .foregroundStyle(Theme.ink)
                Text("Kamera aufs Stativ, automatisch auslösen")
                    .font(Theme.mono(10)).foregroundStyle(Theme.graphite)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.graphite)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 0) {
            // Akzentkante des Werks
            Rectangle()
                .fill(Theme.accent(for: project.id))
                .frame(width: 128, height: 3)
            Group {
                if let thumb = store.thumbnail(for: project) {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.paperShade)
                        .overlay(Image(systemName: "square.grid.2x2")
                            .foregroundStyle(Theme.hairline))
                }
            }
            .frame(width: 128, height: 125)
            .clipped()
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))

            Text(project.name)
                .font(Theme.serif(14, .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.top, 8)
            CatalogLabel("\(project.frameCount) Bilder", size: 9)
                .padding(.top, 4)
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
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(modeRaw) }
    @State private var isPreviewing = false
    @State private var previewIndex = 0
    private let previewTimer = Timer.publish(every: 1.0/8.0, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 2)]

    private var selectedThumbs: [UIImage] {
        viewModel.reviewFrames.filter(\.selected).compactMap(\.thumbnail)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack {
                    CatalogLabel("\(viewModel.selectedCount) von \(viewModel.reviewFrames.count) Bildern gewählt",
                                 color: Theme.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: viewModel.selectedCount)
                    if viewModel.isRecomputing {
                        ProgressView().tint(Theme.ink).scaleEffect(0.7)
                    }
                    Spacer()
                    Button {
                        previewIndex = 0
                        isPreviewing.toggle()
                    } label: {
                        Label(isPreviewing ? "Anhalten" : "Vorschau",
                              systemImage: isPreviewing ? "pause.fill" : "play.fill")
                            .font(Theme.caption(11))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.ink)
                    }
                    .disabled(selectedThumbs.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Ergebnis-Wächter: bei sehr wenigen Bildern klar sagen, warum
                if !viewModel.isRecomputing && viewModel.reviewFrames.count < 3 {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.amber)
                        Text(viewModel.reviewFrames.isEmpty
                             ? "Keine ruhigen Momente gefunden. Das Video ist evtl. sehr kurz oder durchgehend in Bewegung — schiebe den Regler unten Richtung Mehr Bilder oder nimm etwas länger auf."
                             : "Nur wenige Bilder gefunden. Für eine flüssigere Stopmotion den Regler unten Richtung Mehr Bilder schieben oder länger aufnehmen.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(2)
                    }
                    .padding(12)
                    .background(Theme.amber.opacity(0.12))
                    .overlay(Rectangle().stroke(Theme.amber.opacity(0.5), lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Endlos-Vorschau der gewählten Bilder – vor dem Rendern
                if isPreviewing, !selectedThumbs.isEmpty {
                    Image(uiImage: selectedThumbs[previewIndex % selectedThumbs.count])
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .plate()
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .onReceive(previewTimer) { _ in
                            if isPreviewing { previewIndex += 1 }
                        }
                }

                CatalogLabel("Antippen zum Abwählen")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

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
                            .opacity(frame.selected ? 1 : 0.28)
                            .overlay {
                                if frame.selected {
                                    Rectangle().strokeBorder(Theme.crease, lineWidth: 2.5)
                                } else {
                                    Rectangle().stroke(Theme.hairline, lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Optionale Feineinstellung (ab „Erweitert") – Standard erfasst
                // bereits großzügig, wirkt sofort mit Live-Vorschau
                if mode.showsAdvanced {
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
    @State private var pulse = false

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
            // Das Falz-Signet „atmet", während gebaut wird
            FoldMark(size: 40)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .opacity(pulse ? 1 : 0.7)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
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
    let onRecurse: () -> Void
    @EnvironmentObject var store: ProjectStore
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(modeRaw) }
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var showSaveToProject = false
    @State private var saveProjectName = ""
    @State private var savedProjectID: UUID?

    /// Als „gesichert" gilt nur, solange das Zielprojekt noch existiert –
    /// so verschwindet der Haken, wenn das Projekt gelöscht wurde.
    private var savedToProject: Bool {
        guard let id = savedProjectID else { return false }
        return store.projects.contains { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 18) {
            VideoPlayer(player: player)
                .aspectRatio(9/16, contentMode: .fit)
                .passepartout()
                .onAppear {
                    // Endlos-Loop, damit sich die Animation – und besonders die
                    // Übergänge (Verwebung/Falz/Facetten) – in Ruhe ansehen lassen.
                    let queue = AVQueuePlayer()
                    looper = AVPlayerLooper(
                        player: queue,
                        templateItem: AVPlayerItem(url: result.outputURL))
                    queue.play()
                    player = queue
                }
                .onDisappear { player?.pause() }

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
                if mode.showsAdvanced {
                    // Zurück zur Bildauswahl – der Analyse-Cache bleibt,
                    // Regler und Auswahl wirken sofort
                    Button("Zurück zur Bildauswahl") {
                        onReprocess()
                    }
                    .buttonStyle(HairlineButtonStyle())
                    .padding(.horizontal, 24)
                }

                if mode.showsTolino {
                    // Rekursion: das Ergebnis erneut falten – Bild → Objekt → Bild
                    Button("Erneut falten (Rekursion)") {
                        onRecurse()
                    }
                    .buttonStyle(HairlineButtonStyle())
                    .padding(.horizontal, 24)
                }

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
                savedProjectID = project.id
                saveProjectName = ""
                Task {
                    await store.importKeyframes(
                        from: url, times: result.keyframeTimes, into: project)
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
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    @Environment(\.dismiss) private var dismiss

    private var mode: AppMode { AppMode.current(modeRaw) }
    private var modeHint: String {
        switch mode {
        case .basic: return "Nur das Nötigste: Video wählen → Stopmotion."
        case .advanced: return "Klassische Einstellungen: Format, Framerate, Abspielmodus, Stabilisierung."
        case .tolino: return "Alles dabei — plus die Spezialfeatures: Facetten, Echo, Faltvorlage, Rekursion, Ausstellung."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Modus", selection: $modeRaw) {
                        ForEach(AppMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text(modeHint)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                        .lineSpacing(2)
                } header: {
                    CatalogLabel("Modus")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

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

                if mode.showsAdvanced {
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
                        Picker("Auflösung", selection: $settings.exportResolution) {
                            ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Abspielmodus", selection: $settings.loopMode) {
                            ForEach(LoopMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Verwacklung ausgleichen", isOn: $settings.alignFrames)
                    } header: {
                        CatalogLabel("Ausgabe")
                    }
                    .listRowBackground(Theme.paperShade.opacity(0.5))
                }

                if mode.showsTolino {
                Section {
                    Toggle("Druckbild (Schwarzweiß)", isOn: $settings.printLook)
                    if settings.printLook {
                        Text("Schwarzweiß mit warmem Papierton — wie ein abfotografierter Druck.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.graphite)
                    }
                    Toggle("Papierrelief", isOn: $settings.paperRelief)
                    if settings.paperRelief {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Relief-Stärke: \(Int(settings.reliefStrength * 100)) %")
                                .font(Theme.body)
                            Slider(value: $settings.reliefStrength, in: 0.05...0.3, step: 0.01)
                            Text("Jede Facette liegt anders im Licht — als wäre das Bild gefaltet und wieder abfotografiert worden.")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.graphite)
                        }
                    }
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
                    if settings.transitionFrames > 0 {
                        Picker("Übergangsstil", selection: $settings.transitionStyle) {
                            ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Text("Blendet das nächste Bild ein — als Falzkante, als triangulierte Facetten oder als eingewobene Bildstreifen.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                } header: {
                    CatalogLabel("Effekte")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
                }
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
