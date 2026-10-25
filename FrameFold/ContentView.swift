import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import Combine   // Timer.publish(…).autoconnect() — ohne diesen Import warnt der Compiler

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var selectedTab: Int
    @StateObject private var viewModel = ProcessingViewModel()
    @EnvironmentObject var store: ProjectStore
    @State private var pickerItem: PhotosPickerItem?
    /// Mac: Videos liegen meist im Finder, nicht in Fotos.
    @State private var showFileImporter = false
    @State private var showSettings = false
    @State private var homeIn = false
    /// Neigungs-Licht: das Galerielicht folgt der Hand (CoreMotion).
    @StateObject private var lightTilt = LightTilt()
    /// Das Faltbild ist ein Spielzeug: antippen faltet es neu.
    @State private var foldNudge: UInt64 = 0
    @AppStorage("appMode") private var homeModeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(homeModeRaw) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    ProcessingView(stage: viewModel.stage, onCancel: { viewModel.cancel() })
                }
            }
            // Papier übers ganze Fenster, auch wenn der Inhalt schmaler ist (Mac)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .accessibilityLabel("Einstellungen")
                }
            }
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: $viewModel.settings)
            }
        }
    }

    private var recentProjects: [Project] { Array(store.projects.prefix(4)) }

    /// Breite Fläche (aufgeklapptes iPhone Duo): Die Seite wird wie ein
    /// aufgeschlagenes Heft gesetzt – links die Werk-Tafel, rechts Gruß,
    /// Zweitweg und die letzten Werke. Schmal bleibt alles untereinander.
    private var isSpread: Bool { horizontalSizeClass == .regular }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogLabel(verbatim: greetingLine)
            Text(mode == .basic ? "Was falten wir\nheute?" : "Woran arbeitest du\nheute?")
                .font(Theme.serifItalic(28))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var startView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isSpread {
                    HStack(alignment: .top, spacing: 0) {
                        PhotosPicker(selection: $pickerItem, matching: .videos) {
                            heroPlate
                        }
                        .padding(.leading, 24)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 0) {
                            greetingBlock
                            Button { selectedTab = 1 } label: {
                                secondaryAction
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)
                            if Platform.isMac { fileImportLink }
                            if !recentProjects.isEmpty { recentStrip }
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    // 1 – Begrüßung statt Ansage
                    greetingBlock

                    // 2 + 3 – die Werk-Tafel ist der Hauptgriff
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        heroPlate
                    }
                    .padding(.horizontal, 24)

                    // 4 – Zweitweg, leise
                    Button { selectedTab = 1 } label: {
                        secondaryAction
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    if Platform.isMac { fileImportLink }

                    // 5 – die Werke als gefaltete Kacheln
                    if !recentProjects.isEmpty { recentStrip }
                }

                Spacer(minLength: 26)
            }
            // Ruhiger Auftritt: der Inhalt steigt beim ersten Erscheinen sanft ein
            .opacity(homeIn ? 1 : 0)
            .offset(y: homeIn ? 0 : 12)
        }
        .onAppear {
            if !homeIn {
                if reduceMotion { homeIn = true }
                else { withAnimation(.smooth(duration: 0.55)) { homeIn = true } }
            }
            lightTilt.start()
            if let url = Platform.testVideo, viewModel.stage == .idle, viewModel.lastVideoURL == nil,
               let copy = Self.copyToTemporary(url) {
                viewModel.process(videoURL: copy)
            }
        }
        .onDisappear { lightTilt.stop() }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.movie, .video]) { result in
            if case .success(let url) = result { importVideoFile(url) }
        }
        // Mac: Video aus dem Finder aufs Fenster ziehen
        .onDrop(of: [.movie], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url, let copy = Self.copyToTemporary(url) else { return }
                Task { @MainActor in viewModel.process(videoURL: copy) }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffOpenVideoFile)) { _ in
            showFileImporter = true
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
                    viewModel.stage = .failed(String(localized: "Das Video konnte nicht geladen werden."))
                }
                pickerItem = nil
            }
        }
    }

    // MARK: Video aus einer Datei (Mac)

    private var fileImportLink: some View {
        Button { showFileImporter = true } label: {
            Label("Video aus einer Datei wählen …", systemImage: "folder")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.graphite)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func importVideoFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let copy = Self.copyToTemporary(url) else {
            viewModel.stage = .failed(String(localized: "Das Video konnte nicht geladen werden."))
            return
        }
        viewModel.process(videoURL: copy)
    }

    /// Eigene Kopie im temporären Ordner: Die Original-Datei darf die App
    /// nur kurz lesen (Sandbox), die Analyse braucht sie länger.
    nonisolated static func copyToTemporary(_ url: URL) -> URL? {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: Start-Bausteine

    /// Tageszeit-Gruß: die App begrüßt, statt anzusagen.
    private var greetingLine: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<11:  greeting = String(localized: "Guten Morgen")
        case 11..<14: greeting = String(localized: "Hallo")
        case 14..<18: greeting = String(localized: "Guten Tag")
        case 18..<23: greeting = String(localized: "Guten Abend")
        default:      greeting = String(localized: "Gute Nacht")
        }
        // Ohne Namen: Die App begrüßt jeden, der sie öffnet.
        return greeting
    }

    private var latestProject: Project? { store.projects.first }

    /// Die Werk-Tafel: gefaltetes Papier mit angeschlagener Bildunterschrift –
    /// die ganze Fläche ist der Griff. Ohne Projekt faltet sich ein leeres Blatt.
    private var heroPlate: some View {
        VStack(spacing: 0) {
            FoldedPaperHero(
                image: latestProject.flatMap { store.thumbnail(for: $0) },
                seed: FoldSeed.make(latestProject?.id) &+ foldNudge,
                accent: latestProject.map { Theme.accent(for: $0.id) } ?? Theme.violet,
                tilt: lightTilt.offset)
                // Am Mac ist das Fenster groß – eine iPhone-hohe Tafel ließe
                // die untere Hälfte leer.
                .frame(height: Platform.isMac ? 500 : isSpread ? 340 : 248)
                .overlay {
                    // Antippen faltet neu – ein kleines Spielzeug im Einfach-Modus
                    if mode == .basic {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if reduceMotion { foldNudge &+= 17 }
                                else { withAnimation(.smooth(duration: 0.45)) { foldNudge &+= 17 } }
                            }
                    }
                }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video wählen")
                        .font(Theme.caption(15)).tracking(1.8).textCase(.uppercase)
                        .foregroundStyle(Theme.paper)
                    Text("Die ruhigen Momente werden gefunden")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.paper.opacity(0.70))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.paper.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Theme.ink)
            .overlay(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 18))
                    p.addLine(to: CGPoint(x: 18, y: 0))
                }
                .stroke(Theme.crease, lineWidth: 2.2)
            }
        }
        .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
        .hung()   // hängt als Abzug an der Galeriewand
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CatalogLabel("Zuletzt im Atelier", color: Theme.ink)
                Spacer()
                Button { selectedTab = 2 } label: {
                    CatalogLabel("Alle →", color: Theme.graphite, size: 10)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentProjects) { project in
                        // Direkt in dieses Werk, nicht bloß in die Liste
                        Button {
                            OpenWork.pending = project.id
                            selectedTab = 2
                            NotificationCenter.default.post(name: .ffOpenWork, object: project.id)
                        } label: {
                            foldedTile(project)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.top, 32)
    }

    /// Ein Werk als gefaltete Kachel mit farbiger Werkkante.
    private func foldedTile(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldedPaperHero(image: store.thumbnail(for: project),
                            seed: FoldSeed.make(project.id),
                            accent: Theme.accent(for: project.id),
                            animatesLight: false)
                .frame(width: 126, height: 92)
                .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.accent(for: project.id)).frame(width: 3)
                }
                .shadow(color: Theme.ink.opacity(0.14), radius: 8, x: 0, y: 5)
            Text(project.name)
                .font(Theme.serif(14, .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.top, 8)
            CatalogLabel("\(project.frameCount) Bilder", size: 9)
                .padding(.top, 4)
        }
        .frame(width: 126)
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
                Text(Platform.isMac ? "Kamera über dem Tisch, automatisch auslösen" : "Kamera aufs Stativ, automatisch auslösen")
                    .font(Theme.mono(10)).foregroundStyle(Theme.graphite)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.graphite)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            FoldMark(size: 40, color: Theme.graphite)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Anderes Video wählen") { viewModel.stage = .idle }
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

    // Am Mac ist das Fenster breit: größere Kacheln statt einer langen Reihe Briefmarken
    private let columns = [GridItem(.adaptive(minimum: Platform.isMac ? 150 : 76), spacing: 2)]

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
                        // Der Regler „Mehr Bilder" erscheint erst ab „Erweitert" –
                        // im Einfach-Modus darf der Hinweis ihn nicht nennen.
                        Text(mode == .basic
                             ? (viewModel.reviewFrames.isEmpty
                                ? "Keine ruhigen Momente gefunden. Halte beim Filmen zwischendurch kurz still – oder nimm etwas länger auf."
                                : "Nur wenige Bilder gefunden. Halte beim Filmen öfter kurz still, dann werden es mehr.")
                             : viewModel.reviewFrames.isEmpty
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
                    ForEach(Array(viewModel.reviewFrames.enumerated()), id: \.element.id) { index, frame in
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
                        // VoiceOver: welches Bild, und ob es in den Film kommt
                        .accessibilityLabel(Text("Bild \(index + 1) von \(viewModel.reviewFrames.count)"))
                        .accessibilityAddTraits(frame.selected ? .isSelected : [])
                        .accessibilityHint(Text("Doppeltippen nimmt das Bild in den Film auf oder heraus."))
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
                    .padding(16)
                    .background(Theme.paperShade.opacity(0.5))
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }

            // Erstellen dominiert; Verwerfen ist destruktiv → Mistkübel,
            // kein gleichwertiger Balken direkt unterm Primärknopf.
            HStack(spacing: 10) {
                Button(mode == .basic ? "Zeig's mir!" : "Stopmotion erstellen") {
                    viewModel.createVideo()
                }
                .buttonStyle(InkButtonStyle())
                .disabled(viewModel.selectedCount == 0)

                IconSquare(icon: "trash", stage: .paper, destructive: true) {
                    viewModel.stage = .idle
                }
            }
            .frame(maxWidth: Platform.isMac ? 560 : .infinity)   // am Mac keine fensterbreiten Balken
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
    /// Lange Videos dauern – jederzeit abbrechen können.
    var onCancel: (() -> Void)? = nil
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                           value: pulse)
                .onAppear { if !reduceMotion { pulse = true } }
            CatalogLabel(verbatim: stage.label, color: Theme.ink)
            if let progress {
                HairlineProgress(value: progress)
                    .padding(.horizontal, 60)
            } else {
                ProgressView().tint(Theme.ink)
            }
            CatalogLabel("Lokal auf diesem Gerät")
            if let onCancel, stage != .importing {
                Button("Abbrechen", action: onCancel)
                    .buttonStyle(InkButtonStyle(fullWidth: false))
                    .padding(.top, 8)
            }
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
    @State private var showSaveToProject = false
    @State private var saveProjectName = ""
    @State private var savedProjectID: UUID?
    /// Läuft der Import noch? Erst danach gilt das Werk als gesichert.
    @State private var isSaving = false
    /// Auswahl „neues oder vorhandenes Werk"
    @State private var showSaveChoice = false
    /// Nicht alle Bilder ließen sich übernehmen – das soll man erfahren.
    @State private var saveWarning: String?

    /// Als „gesichert" gilt nur, solange das Zielprojekt noch existiert –
    /// so verschwindet der Haken, wenn das Projekt gelöscht wurde.
    private var savedToProject: Bool {
        guard let id = savedProjectID else { return false }
        return store.projects.contains { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 18) {
            // Bild-für-Bild statt Video-Player: läuft zuverlässig in Schleife
            // und lässt sich mit dem Finger frame-genau durchblättern.
            LoopingVideoPreview(url: result.outputURL)
                .editionPlate()   // wie seine Editionen: unter Acrylglas

            VStack(spacing: 6) {
                CatalogLabel("\(result.keyframeTimes.count) Bilder · aus \(Int(result.sourceDuration)) s Video",
                             color: Theme.ink)
                // „0 entfernt · 0 Duplikate" ist im Einfach-Modus nur Rauschen
                if mode != .basic || result.discardedForHands + result.discardedAsDuplicates > 0 {
                    CatalogLabel("\(result.discardedForHands) mit Händen entfernt · \(result.discardedAsDuplicates) Duplikate")
                }
                // Katalogsprache nur im Atelier – im Einfach-Modus ist sie Jargon.
                if mode.showsTolino {
                    CatalogLabel("Serie von \(result.keyframeTimes.count) · datiert \(String(Calendar.current.component(.year, from: Date())))", size: 9)
                }
            }

            if let saveWarning {
                Text(saveWarning)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.oxblood)
                    .multilineTextAlignment(.center)
            }

            // Primärzeile: Sichern schützt das Werk, Teilen trägt es hinaus –
            // beide stark. Verwerfen ist destruktiv → Mistkübel, nicht Balken.
            HStack(spacing: 10) {
                if sourceVideoURL != nil {
                    if isSaving {
                        Button("Wird gesichert …") {}
                            .buttonStyle(HairlineButtonStyle())
                            .disabled(true)
                    } else if savedToProject {
                        Button("Gesichert ✓") {}
                            .buttonStyle(HairlineButtonStyle())
                            .disabled(true)
                    } else {
                        Button("Sichern") {
                            if store.projects.isEmpty { showSaveToProject = true } else { showSaveChoice = true }
                        }
                            .buttonStyle(InkButtonStyle())
                    }
                }
                ShareLink(item: result.outputURL) {
                    Text("Teilen")
                }
                .buttonStyle(InkButtonStyle())

                IconSquare(icon: "trash", stage: .paper, destructive: true) {
                    onReset()
                }
            }
            .frame(maxWidth: Platform.isMac ? 560 : .infinity)
            .padding(.horizontal, 24)

            GIFShareButton(videoURL: result.outputURL)

            // Leise Extras je nach Modus
            if sourceVideoURL != nil {
                if mode.showsAdvanced {
                    // Zurück zur Bildauswahl – der Analyse-Cache bleibt,
                    // Regler und Auswahl wirken sofort
                    Button("Zurück zur Bildauswahl") {
                        onReprocess()
                    }
                    .buttonStyle(HairlineButtonStyle())
                    .padding(.horizontal, 24)
                } else {
                    // Auch im Einfach-Modus: ein Bild abwählen, ohne alles zu
                    // verwerfen und neu zu analysieren. Leise, als Textlink.
                    Button {
                        onReprocess()
                    } label: {
                        Label("Bilder noch einmal auswählen", systemImage: "square.grid.3x3")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.graphite)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }

                if mode.showsTolino {
                    // Rekursion: das Ergebnis erneut falten – Bild → Objekt → Bild
                    Button("Erneut falten (Rekursion)") {
                        onRecurse()
                    }
                    .buttonStyle(HairlineButtonStyle())
                    .padding(.horizontal, 24)
                }
            }
        }
        .padding(.vertical)
        // Wohin mit den Bildern? Neues Werk oder ein vorhandenes ergänzen –
        // so lassen sich Video und Live-Aufnahmen in einem Werk sammeln.
        .confirmationDialog("Bilder sichern", isPresented: $showSaveChoice, titleVisibility: .visible) {
            Button("Neues Werk anlegen …") { showSaveToProject = true }
            ForEach(store.projects.prefix(6)) { project in
                Button("Zu „\(project.name)“ hinzufügen") { save(into: project) }
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Die Bilder kommen ans Ende des Werks und lassen sich dort mit weiteren Aufnahmen ergänzen.")
        }
        .alert("Als Werk sichern", isPresented: $showSaveToProject) {
            TextField("Name des Werks", text: $saveProjectName)
            Button("Sichern") {
                let project = store.createProject(name: saveProjectName)
                saveProjectName = ""
                save(into: project)
            }
            Button("Abbrechen", role: .cancel) { saveProjectName = "" }
        } message: {
            Text("Die Bilder wandern in ein neues Werk und lassen sich dort mit weiteren Aufnahmen ergänzen und neu exportieren.")
        }
    }

    /// Bilder des Videos ans Ende von `project` – neu oder vorhanden.
    private func save(into project: Project) {
        guard let url = sourceVideoURL else { return }
        savedProjectID = project.id
        isSaving = true
        saveWarning = nil
        Task {
            let saved = await store.importKeyframes(
                from: url, times: result.keyframeTimes, into: project)
            isSaving = false
            let wanted = result.keyframeTimes.count
            if saved < wanted {
                saveWarning = String(localized: "\(saved) von \(wanted) Bildern gesichert – die übrigen ließen sich nicht lesen.")
            }
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
        case .basic: return String(localized: "Nur das Nötigste: Video wählen → Stopmotion.")
        case .advanced: return String(localized: "Klassische Einstellungen: Format, Bildrate, Abspielmodus, Stabilisierung.")
        case .tolino: return String(localized: "Alles dabei — plus die Spezialfeatures: Facetten, Echo, Faltvorlage, Rekursion, Ausstellung.")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Katalog-Reiter statt System-Segmentschalter
                    ModeTabs(modeRaw: $modeRaw)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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
                            Text("2 fps – sehr langsam").tag(Int32(2))
                            Text("3 fps").tag(Int32(3))
                            Text("4 fps").tag(Int32(4))
                            Text("6 fps").tag(Int32(6))
                            Text("8 fps").tag(Int32(8))
                            Text("10 fps").tag(Int32(10))
                            Text("12 fps").tag(Int32(12))
                            Text("15 fps").tag(Int32(15))
                            Text("24 fps – flüssig").tag(Int32(24))
                            Text("25 fps").tag(Int32(25))
                            Text("30 fps").tag(Int32(30))
                        }
                        Picker("Letztes Bild halten", selection: $settings.holdLastFrameSeconds) {
                            Text("Aus").tag(0.0)
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                            Text("3 s").tag(3.0)
                        }
                        Picker("Format", selection: $settings.aspect) {
                            ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Auflösung", selection: $settings.exportResolution) {
                            ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Abspielmodus", selection: $settings.loopMode) {
                            ForEach(LoopMode.allCases) { Text(verbatim: $0.label).tag($0) }
                        }
                        Toggle("Verwacklung ausgleichen", isOn: $settings.alignFrames)
                        Toggle("Flimmern ausgleichen", isOn: $settings.deflicker)
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
                            ForEach(TransitionStyle.allCases) { Text(verbatim: $0.label).tag($0) }
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

extension Notification.Name {
    /// Menübefehle am Mac (FrameFoldApp `.commands`) an die Ansichten.
    static let ffOpenVideoFile = Notification.Name("ffOpenVideoFile")
    static let ffNewWork = Notification.Name("ffNewWork")
    static let ffFinishSession = Notification.Name("ffFinishSession")
    static let ffUndoLastFrame = Notification.Name("ffUndoLastFrame")
    static let ffCaptureNow = Notification.Name("ffCaptureNow")
    /// Werk in der Kamera fortsetzen (object: die UUID des Werks).
    static let ffContinueWork = Notification.Name("ffContinueWork")
    /// Werk in der Projektliste öffnen (object: die UUID des Werks).
    static let ffOpenWork = Notification.Name("ffOpenWork")
}

/// Werk, das der Projekte-Tab öffnen soll – falls er die Nachricht verpasst,
/// weil er noch nie offen war.
@MainActor
enum OpenWork {
    static var pending: UUID?
}
