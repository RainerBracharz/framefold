import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit
import StoreKit
import UIKit

/// Projektliste im Werkverzeichnis-Stil: nummerierte Einträge,
/// Haarlinien, gesperrte Versalien.
struct ProjectsView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var newProjectName = ""
    @State private var showNewProject = false
    @State private var showExhibition = false
    /// Werk, das per Wischen gelöscht werden soll – erst nach Rückfrage.
    @State private var pendingDelete: Project?
    @State private var renaming: Project?
    @State private var renameText = ""
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    @State private var path: [UUID] = []
    @State private var showWorkImporter = false
    @State private var workShare: ShareItem?
    @State private var workError: String?
    @State private var packing: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    // Leeres Blatt als Einladung – nicht bloß ein Hinweistext
                    VStack(spacing: 0) {
                        Spacer(minLength: 20)
                        FoldedPaperHero(seed: 21, accent: Theme.violet)
                            .frame(height: 190)
                            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                            .padding(.horizontal, 44)
                        Text("Ein Blatt pro Werk.")
                            .font(Theme.serifItalic(21))
                            .foregroundStyle(Theme.ink)
                            .padding(.top, 24)
                        Text("Bilder sammeln sich über beliebig viele\nAufnahmen – live oder aus Videos.")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.graphite)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.top, 8)
                        Button { showNewProject = true } label: {
                            Text("Werk anlegen")
                        }
                        .buttonStyle(InkButtonStyle(fullWidth: false))
                        .padding(.top, 24)
                        Button { showWorkImporter = true } label: {
                            Text("Werk aus Datei öffnen …")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.graphite)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                        Spacer(minLength: 20)
                    }
                } else {
                    List {
                        ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                            NavigationLink(value: project.id) {
                                projectRow(index: index, project: project)
                            }
                            // Rechtsklick am Mac, langes Drücken am iPhone
                            .contextMenu {
                                Button {
                                    renameText = project.name
                                    renaming = project
                                } label: { Label("Umbenennen …", systemImage: "pencil") }
                                Button { shareWork(project) } label: {
                                    Label("Als Datei teilen …", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    pendingDelete = project
                                } label: { Label("Werk löschen", systemImage: "trash") }
                            }
                            .listRowBackground(Theme.paper)
                            .listRowSeparatorTint(Theme.hairline)
                        }
                        // Wischen löscht endgültig – darum dieselbe
                        // Rückfrage wie in der Werkansicht.
                        .onDelete { offsets in
                            if let index = offsets.first, store.projects.indices.contains(index) {
                                pendingDelete = store.projects[index]
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .alert("Werk umbenennen", isPresented: Binding(get: { renaming != nil },
                                                                 set: { if !$0 { renaming = nil } })) {
                        TextField("Name", text: $renameText)
                        Button("Umbenennen") {
                            let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let project = renaming, !name.isEmpty { store.rename(project, to: name) }
                            renaming = nil
                        }
                        Button("Abbrechen", role: .cancel) { renaming = nil }
                    }
                    .confirmationDialog(
                        pendingDelete.map { Text("\($0.name) mit allen \($0.frameCount) Bildern löschen?") } ?? Text(verbatim: ""),
                        isPresented: Binding(get: { pendingDelete != nil },
                                             set: { if !$0 { pendingDelete = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Endgültig löschen", role: .destructive) {
                            if let project = pendingDelete { store.delete(project) }
                            pendingDelete = nil
                        }
                        Button("Abbrechen", role: .cancel) { pendingDelete = nil }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperStage()
            .onReceive(NotificationCenter.default.publisher(for: .ffNewWork)) { _ in
                showNewProject = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .ffOpenWork)) { note in
                if let id = note.object as? UUID { open(id) }
            }
            .onAppear {
                if let id = OpenWork.pending { open(id) }
                else if Platform.openFirstWork, path.isEmpty, let first = store.projects.first { open(first.id) }
            }
            .navigationDestination(for: UUID.self) { id in
                if let project = store.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    WorkTitle("Werke", size: 17)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if store.projects.count >= 2 && AppMode.current(modeRaw).showsTolino {
                        // Mit Wortmarke statt kryptischem Symbol – das Feature
                        // war sonst praktisch unauffindbar
                        Button { showExhibition = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "film.stack")
                                    .font(Theme.mono(12))
                                Text("Ausstellung")
                                    .font(Theme.caption(10))
                                    .tracking(1.2)
                                    .textCase(.uppercase)
                            }
                            .foregroundStyle(Theme.ink)
                        }
                        .accessibilityLabel("Ausstellung montieren")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showNewProject = true } label: { Label("Neues Werk", systemImage: "plus") }
                        Button { showWorkImporter = true } label: {
                            Label("Werk aus Datei öffnen …", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.ink)
                    } primaryAction: {
                        showNewProject = true
                    }
                    .accessibilityLabel("Neues Werk anlegen")
                }
            }
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .alert("Neues Werk", isPresented: $showNewProject) {
                TextField("Name (z. B. Faltung Nr. 12)", text: $newProjectName)
                Button("Anlegen") {
                    _ = store.createProject(name: newProjectName)
                    newProjectName = ""
                }
                Button("Abbrechen", role: .cancel) { newProjectName = "" }
            }
            .sheet(isPresented: $showExhibition) {
                ExhibitionSheet()
            }
            .sheet(item: $workShare) { item in
                ActivityView(items: [item.url])
            }
            .fileImporter(isPresented: $showWorkImporter, allowedContentTypes: [.frameFoldWork]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    do {
                        let project = try await store.importPackage(from: url)
                        open(project.id)
                    } catch {
                        workError = error.localizedDescription
                    }
                }
            }
            .alert("Werk konnte nicht übertragen werden",
                   isPresented: Binding(get: { workError != nil }, set: { if !$0 { workError = nil } })) {
                Button("OK", role: .cancel) { workError = nil }
            } message: {
                Text(workError ?? "")
            }
            .overlay {
                if packing != nil {
                    ProgressView("Werk wird verpackt …")
                        .font(Theme.mono(12))
                        .padding(20)
                        .background(Theme.paper)
                        .overlay(Rectangle().stroke(Theme.hairline))
                }
            }
        }
    }

    private func shareWork(_ project: Project) {
        guard packing == nil else { return }
        packing = project.id
        Task {
            defer { packing = nil }
            do {
                workShare = ShareItem(url: try await store.exportPackage(of: project))
            } catch {
                workError = error.localizedDescription
            }
        }
    }

    private func open(_ id: UUID) {
        OpenWork.pending = nil
        guard store.projects.contains(where: { $0.id == id }) else { return }
        path = [id]
    }

    private func projectRow(index: Int, project: Project) -> some View {
        HStack(spacing: 14) {
            CatalogLabel(verbatim: String(format: "%02d", index + 1), color: Theme.graphite)
                .frame(width: 26, alignment: .leading)

            // Akzent des Werks
            Rectangle()
                .fill(Theme.accent(for: project.id))
                .frame(width: 4, height: 52)

            // Das Werk als gefaltetes Blatt – wie auf dem Startscreen
            FoldedPaperHero(image: store.thumbnail(for: project),
                            seed: FoldSeed.make(project.id),
                            accent: Theme.accent(for: project.id),
                            animatesLight: false)
                .frame(width: 52, height: 52)
                .overlay(Rectangle().stroke(Theme.ink.opacity(0.5), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                WorkTitle(verbatim: project.name, size: 17)
                CatalogLabel("\(project.frameCount) Bilder")
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// Timeline eines Projekts: Frames als Kontaktbogen, Export-Presets.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var store: ProjectStore
    @State private var exportSettings = PipelineSettings.restored()
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var contactSheetURL: URL?
    @State private var isRenderingSheet = false
    @State private var flipbookURL: URL?
    @State private var isRenderingFlipbook = false
    @State private var foldTemplateURL: URL?
    @State private var isRenderingTemplate = false
    @State private var shareItem: ShareItem?
    @State private var isEditingFrames = false
    @State private var showDeleteProject = false
    @State private var showAudioImporter = false
    @State private var showVoice = false
    @State private var showBackgroundImporter = false
    @State private var showCameraMoves = false
    @State private var showRotoImporter = false
    @State private var rotoFPS = 12
    @State private var rotoProgress: Double?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var overlayFrame: Int?
    @State private var importingPhotos = 0
    @Environment(\.requestReview) private var requestReview
    @State private var sequenceFolder: ShareItem?
    @State private var isExportingSequence = false
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(modeRaw) }
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 2)]

    var body: some View {
        ScrollView {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Theme.accent(for: currentProject.id))
                    .frame(width: 22, height: 3)
                CatalogLabel("\(currentProject.frameCount) Bilder · Kontaktbogen")
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            LazyVGrid(columns: columns, spacing: 2) {
                // Identität über die Datei, nicht die Position: Sonst behält
                // eine Zelle nach dem Entfernen ihr altes Bild, und der nächste
                // Tipp löscht ein Bild, das gar nicht zu sehen war.
                ForEach(Array(store.frameURLs(for: currentProject).enumerated()), id: \.element) { index, url in
                    FrameThumbnail(url: url)
                        // Nummerierte Zelle wie im gedruckten Kontaktbogen
                        .overlay(alignment: .bottomLeading) {
                            Text(String(format: "%02d", index + 1))
                                .font(Theme.mono(9, .medium))
                                .foregroundStyle(Theme.paperOnDark)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Theme.ink.opacity(0.72))
                                .padding(4)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isEditingFrames {
                                Button {
                                    store.removeFrames(at: IndexSet(integer: index), from: currentProject)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.paper)
                                        .padding(8)
                                        .background(Theme.ink)
                                        // Größere Trefferfläche als das Symbol
                                        .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                                        .contentShape(Rectangle())
                                }
                                .padding(4)
                                .accessibilityLabel(Text("Bild \(index + 1) entfernen"))
                            }
                        }
                        .contextMenu {
                            // Genau dieses Bild noch einmal aufnehmen – es
                            // behält seinen Platz im Film.
                            Button {
                                RetakeFrame.pending = .init(project: currentProject.id,
                                                            filename: url.lastPathComponent)
                                ContinueWork.pending = currentProject.id
                                NotificationCenter.default.post(name: .ffContinueWork, object: currentProject.id)
                            } label: {
                                Label("Neu aufnehmen", systemImage: "camera.rotate")
                            }
                            Button {
                                overlayFrame = index
                            } label: {
                                Label("Text & Zeichnen …", systemImage: "pencil.and.scribble")
                            }
                            SoundEffectMenu(projectID: currentProject.id, frame: index) {
                                Label("Geräusch hier", systemImage: "speaker.wave.2")
                            }
                            Button {
                                store.duplicateFrame(named: url.lastPathComponent, in: currentProject)
                            } label: {
                                Label("Verdoppeln", systemImage: "plus.square.on.square")
                            }
                            Menu {
                                ForEach([2, 3, 4, 6], id: \.self) { n in
                                    Button("\(n) Bilder lang") {
                                        store.holdFrame(named: url.lastPathComponent, frames: n, in: currentProject)
                                    }
                                }
                            } label: { Label("Halten", systemImage: "pause.rectangle") }
                            if index > 0 {
                                Button {
                                    store.moveFrame(named: url.lastPathComponent, by: -1, in: currentProject)
                                } label: {
                                    Label("Nach vorn", systemImage: "arrow.left")
                                }
                            }
                            if index < currentProject.frameCount - 1 {
                                Button {
                                    store.moveFrame(named: url.lastPathComponent, by: 1, in: currentProject)
                                } label: {
                                    Label("Nach hinten", systemImage: "arrow.right")
                                }
                            }
                            Button(role: .destructive) {
                                store.removeFrames(at: IndexSet(integer: index), from: currentProject)
                            } label: {
                                Label("Bild entfernen", systemImage: "trash")
                            }
                        }
                        // Umordnen per Ziehen: Bild auf eine andere Zelle legen
                        .draggable(url.lastPathComponent) {
                            FrameThumbnail(url: url).frame(width: 80, height: 80)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let name = items.first,
                                  let from = currentProject.frameFilenames.firstIndex(of: name) else { return false }
                            store.moveFrame(named: name, by: index - from, in: currentProject)
                            return true
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Papierkorb: entfernte Frames sind 30 Tage wiederherstellbar
            if currentProject.trashCount > 0 {
                Button {
                    store.restoreTrash(in: currentProject)
                } label: {
                    Label("Zuletzt gelöscht: \(currentProject.trashCount) Bilder wiederherstellen",
                          systemImage: "arrow.uturn.backward")
                        .font(Theme.caption(11))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            exportSection
                .padding(20)

            // Projekt löschen – bewusst ganz unten, mit Rückfrage
            Button(role: .destructive) {
                showDeleteProject = true
            } label: {
                Text("Werk löschen")
                    .font(Theme.caption(12))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.oxblood)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(Theme.oxblood.opacity(0.45), lineWidth: 1))
            }
            // Ohne eigenen Stil legt Catalyst einen grauen, gerundeten
            // System-Hintergrund darunter – ein doppelter Rahmen.
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .paperStage()
        #if targetEnvironment(macCatalyst)
        // Am Mac erscheint ein `.principal`-Titel nicht – ohne diesen stünde
        // im Fenster nur „FrameFold" statt des Werks.
        .navigationTitle(currentProject.name)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                WorkTitle(verbatim: currentProject.name, size: 17)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                UndoRedoButtons(tint: Theme.ink)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Einzelne Frames entfernen ist Grundhygiene – in jedem Modus.
                Button {
                    isEditingFrames.toggle()
                } label: {
                    Text(isEditingFrames ? "Fertig" : "Bearbeiten")
                        .font(Theme.caption(11))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .confirmationDialog(
            "\(currentProject.name) mit allen \(currentProject.frameCount) Bildern löschen?",
            isPresented: $showDeleteProject, titleVisibility: .visible
        ) {
            Button("Endgültig löschen", role: .destructive) {
                store.delete(currentProject)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) { }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .onChange(of: exportSettings) { _, newValue in
            // Einstellungen geändert → das fertige Video passt nicht mehr dazu
            exportURL = nil
            // … und die Wahl wird zum neuen Standard für den nächsten Export.
            newValue.persist()
        }
        .onChange(of: currentProject.frameFilenames) { _, _ in
            // Frames entfernt, ergänzt oder umgestellt → dito
            exportURL = nil
        }
        .onChange(of: currentProject.audioFilename) { _, _ in
            exportURL = nil
        }
        .onChange(of: currentProject.audioTracks) { _, _ in
            exportURL = nil
        }
        .onChange(of: currentProject.greenScreen) { _, _ in exportURL = nil }
        .onChange(of: currentProject.overlays) { _, _ in exportURL = nil }
        .onChange(of: currentProject.titleText) { _, _ in exportURL = nil }
        .onChange(of: currentProject.creditsText) { _, _ in exportURL = nil }
    }

    /// Immer den frischen Stand aus dem Store verwenden.
    private var currentProject: Project {
        store.projects.first(where: { $0.id == project.id }) ?? project
    }

    /// Eine Einstellzeile: links wofür, rechts der Wert – sonst steht im
    /// Panel nur „Original" oder „Normal", ohne dass man weiß, was gemeint ist.
    // MARK: Export-Presets

    private var isStoryPreset: Bool {
        exportSettings.aspect == .reel && exportSettings.outputFPS == 12
    }
    private var isSquarePreset: Bool {
        exportSettings.aspect == .square && exportSettings.outputFPS == 10
    }
    private var isGalleryPreset: Bool {
        exportSettings.aspect == .original && exportSettings.outputFPS == 2
    }

    private func presetChip(_ label: LocalizedStringResource, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { action() }
        } label: {
            Text(label)
                .font(Theme.caption(10))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(active ? Theme.paper : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(active ? Theme.ink : Theme.paper)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preset \(label)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func optionRow<Content: View>(_ label: LocalizedStringResource,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            content()
                .labelsHidden()
                .tint(Theme.ink)
        }
        .padding(.vertical, 8)
    }

    /// Musik oder Ton unter dem Film – in jedem Modus, denn gerade Kinder
    /// wollen ihren Film mit Musik. Nur aus Dateien, kein Mikrofon.
    private var audioRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(Theme.ink)
            if currentProject.audioFilename == nil, let tracks = currentProject.audioTracks, !tracks.isEmpty {
                Text("\(tracks.count) Tonspuren")
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                Spacer()
            } else if currentProject.audioFilename != nil {
                Text("Mit Ton")
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Ersetzen") { showAudioImporter = true }
                    .font(Theme.caption(11))
                Button("Entfernen", role: .destructive) { store.removeAudio(from: currentProject) }
                    .font(Theme.caption(11))
            } else {
                Button("Musik oder Ton hinzufügen") { showAudioImporter = true }
                    .font(Theme.body)
                Spacer()
            }
            MusicMenu(projectID: currentProject.id, frame: 0, fps: exportSettings.outputFPS) {
                Image(systemName: "music.quarternote.3")
            }
            .accessibilityLabel(Text("Musik"))
            .disabled(currentProject.frameCount == 0)
            Button { showVoice = true } label: { Image(systemName: "mic") }
                .accessibilityLabel(Text("Stimme aufnehmen"))
                .disabled(currentProject.frameCount == 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 4)
        .sheet(isPresented: Binding(get: { overlayFrame != nil }, set: { if !$0 { overlayFrame = nil } })) {
            if let overlayFrame {
                OverlayEditorView(projectID: currentProject.id, frameIndex: overlayFrame) { self.overlayFrame = nil }
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showVoice) {
            VoiceRecordSheet(urls: store.frameURLs(for: currentProject), startFrame: 0,
                             fps: exportSettings.outputFPS) { url, frame in
                if let url {
                    store.addAudioTrack(from: url, startFrame: frame,
                                        name: String(localized: "Stimme \(currentProject.allAudioTracks.count + 1)"),
                                        to: currentProject)
                }
                showVoice = false
            }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result, !store.setAudio(from: url, for: currentProject) {
                errorMessage = String(localized: "Die Tondatei konnte nicht übernommen werden.")
            }
        }
    }

    /// Fotos aus der Mediathek als weitere Bilder anhängen – in der gewählten
    /// Reihenfolge.
    private var photoImportRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle").foregroundStyle(Theme.ink)
            PhotosPicker(selection: $photoItems, matching: .images, preferredItemEncoding: .compatible) {
                Text(importingPhotos > 0 ? "Fotos werden übernommen … \(importingPhotos)" : "Fotos als Bilder hinzufügen")
                    .font(Theme.body).foregroundStyle(Theme.ink)
            }
            .disabled(importingPhotos > 0 || rotoProgress != nil)
            Spacer()
            // Rotoskopie: Video Bild für Bild als Vorlage zum Nachzeichnen
            if let rotoProgress {
                Text("\(Int(rotoProgress * 100)) %").font(Theme.mono(11)).foregroundStyle(Theme.graphite)
            } else {
                Menu {
                    ForEach([6, 8, 12, 24], id: \.self) { rate in
                        Button("\(rate) Bilder pro Sekunde") { rotoFPS = rate; showRotoImporter = true }
                    }
                } label: {
                    Text("Video als Bilder …").font(Theme.caption(11))
                }
                .fixedSize()
            }
        }
        .fileImporter(isPresented: $showRotoImporter, allowedContentTypes: [.movie]) { result in
            guard case .success(let url) = result else { return }
            rotoProgress = 0
            Task {
                let saved = await store.importVideoFrames(from: url, fps: rotoFPS, into: currentProject) { p in rotoProgress = p }
                rotoProgress = nil
                if saved == 0 { errorMessage = String(localized: "Aus dem Video konnten keine Bilder übernommen werden.") }
            }
        }
        .padding(.horizontal, 4)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            importPhotos(items)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        importingPhotos = items.count
        let projectID = currentProject.id
        Task {
            for item in items {
                // HEIC, PNG, RAW … einheitlich als JPEG ins Werk
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = await Task.detached(priority: .userInitiated, operation: {
                       UIImage(data: data)?.jpegData(compressionQuality: 0.92)
                   }).value,
                   let current = store.projects.first(where: { $0.id == projectID }) {
                    store.appendFrame(jpegData: jpeg, to: current)
                }
                importingPhotos -= 1
            }
            photoItems = []
        }
    }

    /// Farblook des ganzen Films – in jedem Modus.
    private var lookRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.filters").foregroundStyle(Theme.ink)
            Text("Look").font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: $exportSettings.look) {
                ForEach(FilmLook.allCases) { Text(verbatim: $0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }

    /// Titelkarte und Abspann – leer lassen heißt: keiner.
    private var titleRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "textformat").foregroundStyle(Theme.ink)
                TextField("Titel (optional)", text: Binding(
                    get: { currentProject.titleText ?? "" },
                    set: { store.setTitles(title: $0.isEmpty ? nil : $0, credits: currentProject.creditsText,
                                           in: currentProject.id) }))
                    .font(Theme.body)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(Theme.ink)
                TextField("Abspann (optional, mehrere Zeilen)", text: Binding(
                    get: { currentProject.creditsText ?? "" },
                    set: { store.setTitles(title: currentProject.titleText, credits: $0.isEmpty ? nil : $0,
                                           in: currentProject.id) }), axis: .vertical)
                    .lineLimit(1...5)
                    .font(Theme.body)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Greenscreen: Farbe wählen, Hintergrund setzen.
    private var greenScreenRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack").foregroundStyle(Theme.ink)
            Text("Greenscreen").font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: Binding(
                get: { currentProject.greenScreen?.key ?? .none },
                set: { store.setGreenScreenKey($0, in: currentProject.id) })) {
                ForEach(ChromaKey.allCases) { Text(verbatim: $0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if (currentProject.greenScreen?.key ?? .none) != .none {
                Button(currentProject.greenScreen?.backgroundFilename == nil ? "Hintergrund …" : "Anderer Hintergrund …") {
                    showBackgroundImporter = true
                }
                .font(Theme.caption(11))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .fileImporter(isPresented: $showBackgroundImporter, allowedContentTypes: [.image, .movie]) { result in
            if case .success(let url) = result, !store.setGreenScreenBackground(from: url, in: currentProject.id) {
                errorMessage = String(localized: "Der Hintergrund konnte nicht übernommen werden.")
            }
        }
    }

    /// Schwenk und Zoom über Bildbereiche (Export).
    private var cameraMoveRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.metering.center.weighted").foregroundStyle(Theme.ink)
            Text("Kamerafahrt").font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            if let count = currentProject.cameraMoves?.count, count > 0 {
                Text("\(count)×").font(Theme.mono(11)).foregroundStyle(Theme.graphite)
            }
            Button(currentProject.cameraMoves?.isEmpty == false ? "Bearbeiten …" : "Hinzufügen …") { showCameraMoves = true }
                .font(Theme.caption(11))
                .disabled(currentProject.frameCount < 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .sheet(isPresented: $showCameraMoves) {
            CameraMoveEditor(projectID: currentProject.id) { showCameraMoves = false }
                .environmentObject(store)
        }
    }

    /// Einzelbilder in voller Auflösung für Schnitt und Compositing.
    private var sequenceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right").foregroundStyle(Theme.ink)
            Text(isExportingSequence ? "Bilder werden geschrieben…" : "Bildsequenz")
                .font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            ForEach(SequenceFormat.allCases) { format in
                Button(format.label) { exportSequence(format) }
                    .font(Theme.caption(11))
                    .disabled(isExportingSequence || currentProject.frameCount == 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .sheet(item: $sequenceFolder) { item in
            FolderExporter(url: item.url) { sequenceFolder = nil }
        }
    }

    private func exportSequence(_ format: SequenceFormat) {
        isExportingSequence = true
        let urls = store.frameURLs(for: currentProject)
        let name = currentProject.name
        Task.detached(priority: .userInitiated) {
            let folder = try? StopMotionAssembler.exportSequence(urls, name: name, format: format)
            await MainActor.run {
                isExportingSequence = false
                if let folder { sequenceFolder = ShareItem(url: folder) } else {
                    errorMessage = String(localized: "Die Bildsequenz konnte nicht geschrieben werden.")
                }
            }
        }
    }

    private var optionDivider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var exportSection: some View {
        VStack(spacing: 14) {
            if mode.showsAdvanced {
            VStack(spacing: 0) {
                CatalogLabel("Export", color: Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                // Schnellwahl: ein Tipp stellt alles ein. Die Regler darunter
                // bleiben für Feinarbeit – aber meistens reicht ein Preset.
                HStack(spacing: 8) {
                    presetChip("Story", active: isStoryPreset) {
                        exportSettings.aspect = .reel
                        exportSettings.outputFPS = 12
                        exportSettings.loopMode = .none
                        exportSettings.holdLastFrameSeconds = 1
                    }
                    presetChip("Quadrat", active: isSquarePreset) {
                        exportSettings.aspect = .square
                        exportSettings.outputFPS = 10
                        exportSettings.loopMode = .none
                        exportSettings.holdLastFrameSeconds = 1
                    }
                    presetChip("Galerie", active: isGalleryPreset) {
                        exportSettings.aspect = .original
                        exportSettings.outputFPS = 2
                        exportSettings.loopMode = .none
                        exportSettings.holdLastFrameSeconds = 2
                    }
                    Spacer()
                }
                .padding(.bottom, 12)

                // Beschriftete Zeilen: links wofür, rechts der Wert
                VStack(spacing: 0) {
                    optionRow("Format") {
                        Picker("", selection: $exportSettings.aspect) {
                            ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    optionDivider
                    optionRow("Abspielmodus") {
                        Picker("", selection: $exportSettings.loopMode) {
                            ForEach(LoopMode.allCases) { Text(verbatim: $0.label).tag($0) }
                        }
                    }
                    optionDivider
                    optionRow("Bildrate") {
                        Picker("", selection: $exportSettings.outputFPS) {
                            Text("2 fps").tag(Int32(2))
                            Text("3 fps").tag(Int32(3))
                            Text("4 fps").tag(Int32(4))
                            Text("6 fps").tag(Int32(6))
                            Text("8 fps").tag(Int32(8))
                            Text("10 fps").tag(Int32(10))
                            Text("12 fps").tag(Int32(12))
                            Text("15 fps").tag(Int32(15))
                            Text("24 fps").tag(Int32(24))
                            Text("25 fps").tag(Int32(25))
                            Text("30 fps").tag(Int32(30))
                        }
                    }
                    optionDivider
                    optionRow("Letztes Bild halten") {
                        Picker("", selection: $exportSettings.holdLastFrameSeconds) {
                            Text("Aus").tag(0.0)
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                            Text("3 s").tag(3.0)
                        }
                    }
                    optionDivider
                    optionRow("Verwacklung ausgleichen") {
                        Toggle("", isOn: $exportSettings.alignFrames)
                    }
                    optionDivider
                    optionRow("Flimmern ausgleichen") {
                        Toggle("", isOn: $exportSettings.deflicker)
                    }
                    optionDivider
                    optionRow("Codec") {
                        Picker("", selection: $exportSettings.videoCodec) {
                            ForEach(VideoCodec.allCases) { Text(verbatim: $0.label).tag($0) }
                        }
                    }
                    if mode.showsTolino {
                        optionDivider
                        optionRow("Bild-Echo (Nachbild)") {
                            Toggle("", isOn: $exportSettings.interferenzEcho)
                        }
                        optionDivider
                        optionRow("Überblendung") {
                            Picker("", selection: $exportSettings.transitionFrames) {
                                Text("Aus").tag(0)
                                Text("Kurz").tag(2)
                                Text("Weich").tag(4)
                            }
                        }
                        if exportSettings.transitionFrames > 0 {
                            optionDivider
                            optionRow("Übergangsstil") {
                                Picker("", selection: $exportSettings.transitionStyle) {
                                    ForEach(TransitionStyle.allCases) { Text(verbatim: $0.label).tag($0) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(Theme.paperShade.opacity(0.5))
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }

            audioRow
            photoImportRow
            lookRow
            titleRows
            if mode.showsAdvanced { greenScreenRow; cameraMoveRow; sequenceRow }

            if isExporting {
                VStack(spacing: 8) {
                    HairlineProgress(value: exportProgress)
                    CatalogLabel("Stopmotion wird montiert…", size: 10)
                }
            } else if let exportURL {
                // Fertig: erst ansehen (Endlos-Schleife), dann teilen
                LoopingVideoPreview(url: exportURL)
                    .editionPlate()

                Button {
                    shareItem = ShareItem(url: exportURL)
                } label: {
                    Text("Video teilen")
                }
                .buttonStyle(InkButtonStyle())
                GIFShareButton(videoURL: exportURL)
                // Kein „Neu exportieren": ändern sich Einstellungen oder
                // Frames, verfällt das Video ohnehin und der Export-Knopf
                // kehrt von selbst zurück.
            } else {
                Button("Stopmotion exportieren") { export() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(currentProject.frameCount == 0)
            }
            // Aus der Werkansicht direkt in die Kamera – sonst führt kein Weg
            // zurück zur Live-Aufnahme dieses Werks.
            Button {
                ContinueWork.pending = currentProject.id
                NotificationCenter.default.post(name: .ffContinueWork, object: currentProject.id)
            } label: {
                Label("Mit der Kamera weiterarbeiten", systemImage: "camera")
            }
            .buttonStyle(HairlineButtonStyle())
            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.oxblood)
            }

            // Drucksachen – bewusst leiser als der Export. Das Daumenkino gibt
            // es in jedem Modus: Es ist das, was Kinder und Kurse mitnehmen.
            VStack(alignment: .leading, spacing: 8) {
                // Vorlagen zum Ausdrucken – gedruckt wird erst nach dem
                // Teilen (am Mac: „Drucken …" im Teilen-Menü).
                CatalogLabel("Druckvorlagen", size: 9)
                HStack(spacing: 8) {
                    pdfButton(
                        title: flipbookURL == nil
                            ? (isRenderingFlipbook ? "Wird gesetzt…" : "Daumenkino")
                            : "Daumenkino teilen",
                        icon: "book.pages",
                        disabled: currentProject.frameCount == 0 || isRenderingFlipbook
                    ) {
                        if let flipbookURL {
                            shareItem = ShareItem(url: flipbookURL)
                        } else {
                            renderFlipbook()
                        }
                    }

                    if mode.showsAdvanced {
                        pdfButton(
                            title: contactSheetURL == nil
                                ? (isRenderingSheet ? "Wird gesetzt…" : "Kontaktbogen")
                                : "Kontaktbogen teilen",
                            icon: "square.grid.3x3",
                            disabled: currentProject.frameCount == 0 || isRenderingSheet
                        ) {
                            if let contactSheetURL {
                                shareItem = ShareItem(url: contactSheetURL)
                            } else {
                                renderContactSheet()
                            }
                        }
                    }

                    if mode.showsTolino {
                        pdfButton(
                            title: foldTemplateURL == nil
                                ? (isRenderingTemplate ? "Wird gesetzt…" : "Faltvorlage")
                                : "Faltvorlage teilen",
                            icon: "arrow.triangle.turn.up.right.diamond",
                            disabled: currentProject.frameCount == 0 || isRenderingTemplate
                        ) {
                            if let foldTemplateURL {
                                shareItem = ShareItem(url: foldTemplateURL)
                            } else {
                                renderFoldTemplate()
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            // Neue oder entfernte Bilder: fertige Drucksachen passen nicht mehr
            .onChange(of: currentProject.frameCount) { _, _ in
                flipbookURL = nil
                contactSheetURL = nil
                foldTemplateURL = nil
            }
        }
    }

    /// Drucksache: kleiner, ruhiger Knopf – ordnet sich dem Export unter.
    private func pdfButton(title: LocalizedStringResource, icon: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                Text(title)
                    .font(Theme.caption(10)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func renderFoldTemplate() {
        isRenderingTemplate = true
        let urls = store.frameURLs(for: currentProject)
        let title = currentProject.name
        Task.detached(priority: .userInitiated) {
            // Konstante statt veränderlicher Variable – eine im nebenläufigen
            // Kontext gefangene `var` ist ab Swift 6 ein Fehler.
            let result: URL? = {
                guard let first = urls.first, let data = try? Data(contentsOf: first),
                      let image = UIImage(data: data) else { return nil }
                return FoldTemplateRenderer.render(image: image, title: title)
            }()
            await MainActor.run {
                foldTemplateURL = result
                isRenderingTemplate = false
                if let result {
                    shareItem = ShareItem(url: result)   // Teilen-Sheet direkt öffnen
                } else {
                    errorMessage = String(localized: "Faltvorlage konnte nicht erstellt werden.")
                }
            }
        }
    }

    private func renderFlipbook() {
        isRenderingFlipbook = true
        let urls = store.frameURLs(for: currentProject)
        let title = currentProject.name
        let dateText = currentProject.createdDateText

        Task.detached(priority: .userInitiated) {
            let url = FlipbookRenderer.render(title: title, dateText: dateText, frameURLs: urls)
            await MainActor.run {
                flipbookURL = url
                isRenderingFlipbook = false
                if let url {
                    shareItem = ShareItem(url: url)   // Teilen-Sheet direkt öffnen
                } else {
                    errorMessage = String(localized: "Daumenkino konnte nicht erstellt werden.")
                }
            }
        }
    }

    private func renderContactSheet() {
        isRenderingSheet = true
        let urls = store.frameURLs(for: currentProject)
        let title = currentProject.name
        let dateText = currentProject.createdDateText

        Task.detached(priority: .userInitiated) {
            let url = ContactSheetRenderer.render(
                title: title, dateText: dateText, frameURLs: urls)
            await MainActor.run {
                contactSheetURL = url
                isRenderingSheet = false
                if let url {
                    shareItem = ShareItem(url: url)   // Teilen-Sheet direkt öffnen
                } else {
                    errorMessage = String(localized: "Kontaktbogen konnte nicht erstellt werden.")
                }
            }
        }
    }

    private func export() {
        isExporting = true
        exportProgress = 0
        exportURL = nil
        errorMessage = nil
        let urls = store.frameURLs(for: currentProject)
        let settings = exportSettings
        let project = currentProject
        let green = currentProject.greenScreen
        let compositor = green.flatMap {
            GreenScreenCompositor(key: $0.key, background: store.greenScreenBackgroundURL(for: currentProject),
                                  fps: settings.outputFPS)
        }
        let title = currentProject.titleText, credits = currentProject.creditsText
        let overlays = currentProject.overlays ?? []
        let moves = currentProject.cameraMoves ?? []
        let folder = store.folderURL(for: currentProject)
        let subtitle = currentProject.createdDateText

        Task {
            // Gekürzte und bearbeitete Spuren im Hintergrund fertig rechnen
            var audio = await project.renderedAudioSources(fps: settings.outputFPS, store: store)
            do {
                var url = try await StopMotionAssembler().assemble(
                    imageURLs: urls, settings: settings, greenScreen: compositor, overlays: overlays,
                    cameraMoves: moves, overlayFolder: folder
                ) { p in
                    Task { @MainActor in exportProgress = p }
                }
                // Titel davor, Abspann dahinter – der Ton rückt um den Vorspann nach hinten
                let wrapped = try await TitleSequence.wrap(film: url, title: title, subtitle: subtitle,
                                                           credits: credits, settings: settings)
                url = wrapped.url
                if wrapped.lead > 0 {
                    audio = audio.map { var a = $0; a.start += wrapped.lead; return a }
                }
                // Alle Tonspuren (Musik aus der Werkansicht und Studio-Spuren)
                // auf Filmlänge mischen und unterlegen
                if !audio.isEmpty {
                    let duration = try await AVURLAsset(url: url).load(.duration).seconds
                    // Offline-Mischung im Hintergrund – sonst steht die Oberfläche
                    let mix = try await Task.detached(priority: .userInitiated) {
                        try AudioMixer.mix(audio, duration: duration)
                    }.value
                    url = try await StopMotionAssembler.addAudio(mix, to: url)
                }
                await MainActor.run {
                    exportURL = url
                    if ReviewPrompt.noteFinishedFilm() { requestReview() }
                    isExporting = false
                    // Kein automatisches Teilen-Sheet mehr: das Ergebnis läuft
                    // jetzt direkt als Vorschau – teilen entscheidet der Nutzer.
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }
}

/// Kontaktbogen-Kachel: scharfkantig, Haarlinienrahmen.
struct FrameThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.paperShade)
            }
        }
        .frame(minWidth: 90, minHeight: 90)
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            // Abseits des Hauptthreads und nur so groß wie nötig dekodieren
            // (Kachel ≈ 90 pt × 3) – beim Zurückscrollen aus dem gemeinsamen
            // Zwischenspeicher statt erneut.
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage.thumbnail(at: url, maxPixelSize: 300)
            }.value
            if let loaded {
                let cost = loaded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                Self.cache.setObject(loaded, forKey: url as NSURL, cost: cost)
            }
            image = loaded
        }
    }

    /// Gemeinsam für Kontaktbogen und Studio-Zeitleiste, höchstens ~120 MB.
    static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 120 << 20
        return cache
    }()
}

/// Ausstellungsmodus: mehrere Werke auswählen und zu einem durchlaufenden
/// Reel mit Katalog-Titelkarten montieren.
struct ExhibitionSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var isBuilding = false
    @State private var progress = 0.0
    @State private var reelURL: URL?
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?

    private var chosen: [Project] { store.projects.filter { selected.contains($0.id) } }
    private var totalFrames: Int { chosen.reduce(0) { $0 + $1.frameCount } }

    /// Sagt jederzeit, wo man steht – statt eines stummen, grauen Knopfs.
    private var selectionHint: String {
        switch chosen.count {
        case 0: return String(localized: "Mindestens zwei Werke wählen.")
        case 1: return String(localized: "Ein Werk gewählt – noch mindestens eines.")
        default: return String(localized: "\(chosen.count) Werke · \(totalFrames) Bilder")
        }
    }

    /// Werkzeile mit gefalteter Kachel; Auswahl wird durch Inversion
    /// markiert (Tuschblock) statt durch ein System-Häkchen.
    private func exhibitionRow(_ project: Project) -> some View {
        let isOn = selected.contains(project.id)
        return HStack(spacing: 14) {
            FoldedPaperHero(image: store.thumbnail(for: project),
                            seed: FoldSeed.make(project.id),
                            accent: Theme.accent(for: project.id),
                            animatesLight: false)
                .frame(width: 54, height: 54)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.accent(for: project.id)).frame(width: 3)
                }
                .overlay(Rectangle().stroke(Theme.ink.opacity(0.45), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(Theme.serif(17, .regular))
                    .foregroundStyle(isOn ? Theme.paper : Theme.ink)
                    .lineLimit(1)
                CatalogLabel("\(project.frameCount) Bilder",
                             color: isOn ? Theme.paper.opacity(0.7) : Theme.graphite, size: 9)
            }
            Spacer()

            // Katalog-Marke statt Häkchen
            Rectangle()
                .fill(isOn ? Theme.paper : Color.clear)
                .frame(width: 11, height: 11)
                .overlay(Rectangle().stroke(isOn ? Theme.paper : Theme.graphite, lineWidth: 1.2))
        }
        .padding(12)
        .background(isOn ? Theme.ink : Theme.paper)
        .overlay(Rectangle().stroke(isOn ? Theme.ink : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.18), value: isOn)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Kopf im Katalogton – sagt, was hier entsteht
                VStack(alignment: .leading, spacing: 8) {
                    CatalogLabel("Ausstellung")
                    Text("Mehrere Werke,\nein durchlaufendes Reel.")
                        .font(Theme.serif(23, .regular))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(selectionHint)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.graphite)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.projects) { project in
                            Button { toggle(project.id) } label: {
                                exhibitionRow(project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                VStack(spacing: 10) {
                    if isBuilding {
                        HairlineProgress(value: progress)
                        CatalogLabel("Reel wird montiert…")
                    } else if let reelURL {
                        LoopingVideoPreview(url: reelURL)
                            .frame(maxHeight: 260)
                            .editionPlate()
                        Button {
                            shareItem = ShareItem(url: reelURL)
                        } label: {
                            Text("Ausstellung teilen")
                        }
                        .buttonStyle(InkButtonStyle())
                    } else {
                        Button(chosen.count >= 2
                               ? "\(chosen.count) Werke montieren"
                               : "Ausstellung erstellen") { build() }
                            .buttonStyle(InkButtonStyle())
                            .disabled(chosen.count < 2 || totalFrames == 0)
                            .opacity(chosen.count < 2 ? 0.45 : 1)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(Theme.mono(11)).foregroundStyle(Theme.oxblood)
                    }
                }
                .padding(20)
            }
            .background(Theme.paper)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CatalogLabel("Ausstellung", color: Theme.ink, size: 12)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.foregroundStyle(Theme.ink)
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        reelURL = nil
    }

    private func build() {
        isBuilding = true; progress = 0; errorMessage = nil; reelURL = nil
        let works = chosen.map { p in
            ExhibitionBuilder.Work(
                title: p.name,
                year: String(p.createdAtISO.prefix(4)),
                frames: store.frameURLs(for: p))
        }
        Task {
            do {
                let url = try await ExhibitionBuilder.build(
                    works: works, settings: PipelineSettings()
                ) { p in Task { @MainActor in progress = p } }
                await MainActor.run {
                    reelURL = url
                    isBuilding = false   // läuft direkt als Vorschau
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isBuilding = false
                }
            }
        }
    }
}

/// Endlos-Vorschau eines fertigen Videos – ansehen statt nur teilen.
/// Liest das Seitenverhältnis aus der Datei, damit nichts beschnitten wirkt.
/// Bild-für-Bild-Vorschau: liest die Frames aus dem fertigen Video und spielt
/// sie in Schleife. Mit dem Finger ziehen blättert frame-genau durch die
/// Sequenz – für Stopmotion das passende Werkzeug, und anders als ein
/// Video-Player bei sehr kurzen Clips absolut verlässlich.
struct LoopingVideoPreview: View {
    let url: URL

    @State private var frames: [UIImage] = []
    @State private var index = 0
    @State private var aspect: CGFloat = 9.0 / 16.0
    @State private var playFPS: Double = 10
    @State private var isScrubbing = false
    @State private var isLoading = true
    /// „Bewegung reduzieren": kein Endlos-Abspielen – das Bild steht, und
    /// man blättert selbst (Ziehen oder VoiceOver: auf/ab wischen).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = currentFrame {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle().fill(Theme.paperShade)
                    if isLoading { ProgressView().tint(Theme.ink) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                // Ziehen blättert frame-genau; loslassen spielt weiter
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !frames.isEmpty, geo.size.width > 0 else { return }
                        isScrubbing = true
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        index = min(frames.count - 1,
                                    max(0, Int(fraction * CGFloat(frames.count - 1))))
                    }
                    .onEnded { _ in isScrubbing = false }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay(alignment: .bottom) { scrubBar }
        .task(id: url) {
            await loadFrames()
            // Eine Task-Schleife statt Timer.publish im Modifier: der
            // Publisher wurde bei jedem Render neu aufgebaut.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / max(1, playFPS)))
                if !isScrubbing, !reduceMotion, frames.count > 1 { index = (index + 1) % frames.count }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Film-Vorschau"))
        .accessibilityValue(Text("Bild \(index + 1) von \(max(1, frames.count))"))
        .accessibilityAdjustableAction { direction in
            guard !frames.isEmpty else { return }
            switch direction {
            case .increment: index = min(frames.count - 1, index + 1)
            case .decrement: index = max(0, index - 1)
            @unknown default: break
            }
        }
    }

    private var currentFrame: UIImage? {
        frames.indices.contains(index) ? frames[index] : nil
    }

    /// Dünne Leiste: zeigt die Position und lädt zum Ziehen ein.
    private var scrubBar: some View {
        Group {
            if frames.count > 1 {
                VStack(spacing: 5) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.25))
                            Rectangle().fill(Theme.amber)
                                .frame(width: g.size.width * CGFloat(index + 1) / CGFloat(frames.count))
                        }
                    }
                    .frame(height: 3)
                    Text(isScrubbing
                         ? "Bild \(index + 1) von \(frames.count)"
                         : "Ziehen zum Durchblättern")
                        .font(Theme.mono(9))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 2)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func loadFrames() async {
        isLoading = true
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration) else {
            isLoading = false
            return
        }
        if let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let shown = size.applying(transform)
            let w = abs(shown.width), h = abs(shown.height)
            if w > 0, h > 0 { aspect = w / h }
        }
        let nominal = (try? await track.load(.nominalFrameRate)) ?? 10
        let rate = Double(nominal > 0 ? nominal : 10)
        playFPS = rate

        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0 else { isLoading = false; return }
        // Sehr lange Sequenzen ausdünnen – 300 Bilder à 720 px waren bis zu
        // ~350 MB Arbeitsspeicher; 180 à 480 px reichen für die Vorschau.
        let total = max(1, min(Int((seconds * rate).rounded()), 180))
        let step = seconds / Double(total)
        // Ausgedünnt muss auch langsamer laufen – sonst wirkte ein
        // 60-Sekunden-Film in der Vorschau wie 18 Sekunden.
        playFPS = Double(total) / seconds
        let times = (0..<total).map {
            CMTime(seconds: Double($0) * step + step / 2, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 480, height: 480)

        var loaded: [UIImage] = []
        for await result in generator.images(for: times) {
            if let cg = try? result.image { loaded.append(UIImage(cgImage: cg)) }
        }
        frames = loaded
        index = 0
        isLoading = false
    }
}

/// „Als GIF teilen“: macht aus dem fertigen Film ein endlos laufendes GIF
/// und öffnet das Teilen-Menü – leise als Textlink unter dem Film.
struct GIFShareButton: View {
    let videoURL: URL
    @State private var isMaking = false
    @State private var failed = false
    @State private var item: ShareItem?

    var body: some View {
        Button {
            isMaking = true
            failed = false
            Task {
                let url = try? await GIFMaker.make(from: videoURL)
                isMaking = false
                if let url { item = ShareItem(url: url) } else { failed = true }
            }
        } label: {
            Label(isMaking ? "GIF wird erstellt …"
                  : failed ? "GIF ließ sich nicht erstellen" : "Als GIF teilen",
                  systemImage: "rectangle.stack")
                .font(Theme.mono(12))
                .foregroundStyle(failed ? Theme.oxblood : Theme.graphite)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(isMaking)
        .accessibilityHint("Für Messenger und Präsentationen, die kein Video abspielen.")
        .sheet(item: $item) { item in
            ActivityView(items: [item.url])
        }
    }
}

/// Trägt eine fertige Datei (z. B. PDF) in den System-Teilen-Dialog,
/// damit er sich direkt nach dem Erzeugen öffnen lässt.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        #if targetEnvironment(macCatalyst)
        // Das Teilen-Menü am Mac kennt weder „Sichern" noch „Drucken" – für
        // ein druckfertiges Daumenkino und Filme, die in den Finder sollen,
        // sind das aber die naheliegenden Wege.
        let urls = items.compactMap { $0 as? URL }
        var extra: [UIActivity] = [SaveFileActivity(urls: urls)]
        if urls.contains(where: { $0.pathExtension.lowercased() == "pdf" }) {
            extra.append(PrintFileActivity(urls: urls))
        }
        return UIActivityViewController(activityItems: items, applicationActivities: extra)
        #else
        UIActivityViewController(activityItems: items, applicationActivities: nil)
        #endif
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#if targetEnvironment(macCatalyst)
/// „Sichern …": öffnet den Sichern-Dialog und legt eine Kopie ab.
///
/// Der Dialog hängt am Fenster, nicht am Teilen-Menü: Das Menü schließt sich
/// beim Antippen und nähme einen daran hängenden Dialog gleich mit.
final class SaveFileActivity: UIActivity {
    private let urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    override var activityTitle: String? { String(localized: "Sichern …") }
    override var activityImage: UIImage? { UIImage(systemName: "square.and.arrow.down") }
    override var activityType: UIActivity.ActivityType? { .init("com.bracharz.framefold.save") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { !urls.isEmpty }

    override func perform() {
        let urls = self.urls
        activityDidFinish(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
            UIApplication.shared.topViewController?.present(picker, animated: true)
        }
    }
}

extension UIApplication {
    /// Oberster sichtbarer Controller des aktiven Fensters.
    var topViewController: UIViewController? {
        let window = connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// „Drucken …" für die PDF-Vorlagen (Daumenkino, Kontaktbogen, Faltvorlage).
final class PrintFileActivity: UIActivity {
    private let urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    override var activityTitle: String? { String(localized: "Drucken …") }
    override var activityImage: UIImage? { UIImage(systemName: "printer") }
    override var activityType: UIActivity.ActivityType? { .init("com.bracharz.framefold.print") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        urls.contains { UIPrintInteractionController.canPrint($0) }
    }

    /// Wie bei „Sichern …": erst das Teilen-Menü schließen, dann drucken –
    /// sonst nimmt das Menü den Druckdialog beim Schließen mit.
    override func perform() {
        let items = urls.filter { UIPrintInteractionController.canPrint($0) }
        activityDidFinish(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let controller = UIPrintInteractionController.shared
            controller.printingItems = items
            controller.present(animated: true)
        }
    }
}
#endif


/// „Sichern unter …“ für einen ganzen Ordner (Bildsequenz).
struct FolderExporter: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onDone() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onDone() }
    }
}


/// Rückgängig / Wiederholen als Knöpfe – dieselbe Undo-Verwaltung wie ⌘Z
/// und Schütteln. Grau, solange es nichts zu tun gibt.
struct UndoRedoButtons: View {
    var tint: Color
    @Environment(\.undoManager) private var undoManager
    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        HStack(spacing: 4) {
            Button { undoManager?.undo(); refresh() } label: { Image(systemName: "arrow.uturn.backward").touchLabel(7, 8) }
                .touchButton(7, 8)
                .disabled(!canUndo)
                .help(Text(undoManager?.undoMenuItemTitle ?? String(localized: "Rückgängig")))
                .accessibilityLabel(Text("Rückgängig"))
            Button { undoManager?.redo(); refresh() } label: { Image(systemName: "arrow.uturn.forward").touchLabel(7, 8) }
                .touchButton(7, 8)
                .disabled(!canRedo)
                .help(Text(undoManager?.redoMenuItemTitle ?? String(localized: "Wiederholen")))
                .accessibilityLabel(Text("Wiederholen"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .frame(minWidth: 60, minHeight: 30)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refresh() }
    }

    private func refresh() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}
