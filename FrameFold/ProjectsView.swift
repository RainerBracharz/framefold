import SwiftUI
import AVKit

/// Projektliste im Werkverzeichnis-Stil: nummerierte Einträge,
/// Haarlinien, gesperrte Versalien.
struct ProjectsView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var newProjectName = ""
    @State private var showNewProject = false
    @State private var showExhibition = false

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    VStack(spacing: 18) {
                        FoldMark(size: 48, color: Theme.graphite)
                        CatalogLabel("Noch keine Projekte", color: Theme.ink)
                        Text("Ein Projekt pro Werk. Bilder sammeln sich\nüber beliebig viele Aufnahmen – live oder aus Videos.")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.graphite)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }
                } else {
                    List {
                        ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                            NavigationLink(value: project.id) {
                                projectRow(index: index, project: project)
                            }
                            .listRowBackground(Theme.paper)
                            .listRowSeparatorTint(Theme.hairline)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                store.delete(store.projects[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperStage()
            .navigationDestination(for: UUID.self) { id in
                if let project = store.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    WorkTitle("Projekte", size: 17)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if store.projects.count >= 2 {
                        Button { showExhibition = true } label: {
                            Image(systemName: "film.stack")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .alert("Neues Projekt", isPresented: $showNewProject) {
                TextField("Name (z. B. Faltung Nr. 12)", text: $newProjectName)
                Button("Anlegen") {
                    guard !newProjectName.isEmpty else { return }
                    _ = store.createProject(name: newProjectName)
                    newProjectName = ""
                }
                Button("Abbrechen", role: .cancel) { newProjectName = "" }
            }
            .sheet(isPresented: $showExhibition) {
                ExhibitionSheet()
            }
        }
    }

    private func projectRow(index: Int, project: Project) -> some View {
        HStack(spacing: 14) {
            CatalogLabel(String(format: "%02d", index + 1), color: Theme.graphite)
                .frame(width: 26, alignment: .leading)

            // Akzent des Werks
            Rectangle()
                .fill(Theme.accent(for: project.id))
                .frame(width: 4, height: 52)

            if let thumb = store.thumbnail(for: project) {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipped()
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            } else {
                Rectangle()
                    .fill(Theme.paperShade)
                    .frame(width: 52, height: 52)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                WorkTitle(project.name, size: 17)
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
    @State private var exportSettings = PipelineSettings()
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var contactSheetURL: URL?
    @State private var isRenderingSheet = false
    @State private var foldTemplateURL: URL?
    @State private var isRenderingTemplate = false
    @State private var isEditingFrames = false
    @State private var showDeleteProject = false
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
                ForEach(Array(store.frameURLs(for: currentProject).enumerated()), id: \.offset) { index, url in
                    FrameThumbnail(url: url)
                        .overlay(alignment: .topTrailing) {
                            if isEditingFrames {
                                Button {
                                    store.removeFrames(at: IndexSet(integer: index), from: currentProject)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.paper)
                                        .padding(6)
                                        .background(Theme.ink)
                                }
                                .padding(4)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeFrames(at: IndexSet(integer: index), from: currentProject)
                            } label: {
                                Label("Frame entfernen", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Papierkorb: entfernte Frames sind 30 Tage wiederherstellbar
            if currentProject.trashCount > 0 {
                Button {
                    store.restoreTrash(in: currentProject)
                } label: {
                    Label("Zuletzt gelöscht: \(currentProject.trashCount) Frames wiederherstellen",
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
                .padding(.top, 10)
            }

            exportSection
                .padding(20)

            // Projekt löschen – bewusst ganz unten, mit Rückfrage
            Button(role: .destructive) {
                showDeleteProject = true
            } label: {
                Text("Projekt löschen")
                    .font(Theme.caption(12))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.red)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(.red.opacity(0.4), lineWidth: 1))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .paperStage()
        .toolbar {
            ToolbarItem(placement: .principal) {
                WorkTitle(currentProject.name, size: 17)
            }
            ToolbarItem(placement: .topBarTrailing) {
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
            "\(currentProject.name) mit allen \(currentProject.frameCount) Frames löschen?",
            isPresented: $showDeleteProject, titleVisibility: .visible
        ) {
            Button("Endgültig löschen", role: .destructive) {
                store.delete(currentProject)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) { }
        }
    }

    /// Immer den frischen Stand aus dem Store verwenden.
    private var currentProject: Project {
        store.projects.first(where: { $0.id == project.id }) ?? project
    }

    private var exportSection: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                CatalogLabel("Export", color: Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                Group {
                    Picker("Format", selection: $exportSettings.aspect) {
                        ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Abspielmodus", selection: $exportSettings.loopMode) {
                        ForEach(LoopMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Framerate", selection: $exportSettings.outputFPS) {
                        Text("6 fps").tag(Int32(6))
                        Text("8 fps").tag(Int32(8))
                        Text("10 fps").tag(Int32(10))
                        Text("12 fps").tag(Int32(12))
                    }
                    Toggle("Verwacklung ausgleichen", isOn: $exportSettings.alignFrames)
                    Toggle("Interferenz-Echo", isOn: $exportSettings.interferenzEcho)
                    Picker("Überblendung", selection: $exportSettings.transitionFrames) {
                        Text("Aus").tag(0)
                        Text("Kurz").tag(2)
                        Text("Weich").tag(4)
                    }
                    if exportSettings.transitionFrames > 0 {
                        Picker("Übergangsstil", selection: $exportSettings.transitionStyle) {
                            ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
                .font(Theme.body)
                .tint(Theme.ink)
                .padding(.vertical, 6)
            }
            .padding(14)
            .background(Theme.paperShade.opacity(0.5))
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))

            if isExporting {
                HairlineProgress(value: exportProgress)
            } else {
                Button("Stopmotion exportieren") { export() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(currentProject.frameCount == 0)
            }

            if let exportURL {
                ShareLink(item: exportURL) {
                    Text("Video teilen")
                        .font(Theme.caption(12))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            // Kontaktbogen: druckfertiges PDF aller Frames –
            // zum Ausdrucken und Wiederfalten (Bild → Objekt → Bild)
            if let contactSheetURL {
                ShareLink(item: contactSheetURL) {
                    Text("Kontaktbogen teilen (PDF)")
                        .font(Theme.caption(12))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
            } else {
                Button(isRenderingSheet ? "Bogen wird gesetzt…" : "Kontaktbogen (PDF)") {
                    renderContactSheet()
                }
                .buttonStyle(HairlineButtonStyle())
                .disabled(currentProject.frameCount == 0 || isRenderingSheet)
            }

            // Faltvorlage: ein Bild als druckbare Seite mit Falzlinien –
            // zum Ausdrucken und physischen Nachfalten
            if let foldTemplateURL {
                ShareLink(item: foldTemplateURL) {
                    Text("Faltvorlage teilen (PDF)")
                        .font(Theme.caption(12)).tracking(1.6).textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .padding(.vertical, 14).frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
            } else {
                Button(isRenderingTemplate ? "Vorlage wird gesetzt…" : "Faltvorlage (PDF)") {
                    renderFoldTemplate()
                }
                .buttonStyle(HairlineButtonStyle())
                .disabled(currentProject.frameCount == 0 || isRenderingTemplate)
            }
        }
    }

    private func renderFoldTemplate() {
        isRenderingTemplate = true
        let urls = store.frameURLs(for: currentProject)
        let title = currentProject.name
        Task.detached(priority: .userInitiated) {
            var result: URL? = nil
            if let first = urls.first, let data = try? Data(contentsOf: first),
               let image = UIImage(data: data) {
                result = FoldTemplateRenderer.render(image: image, title: title)
            }
            await MainActor.run {
                foldTemplateURL = result
                isRenderingTemplate = false
                if result == nil { errorMessage = "Faltvorlage konnte nicht erstellt werden." }
            }
        }
    }

    private func renderContactSheet() {
        isRenderingSheet = true
        let urls = store.frameURLs(for: currentProject)
        let title = currentProject.name
        let dateText = String(currentProject.createdAtISO.prefix(10))

        Task.detached(priority: .userInitiated) {
            let url = ContactSheetRenderer.render(
                title: title, dateText: dateText, frameURLs: urls)
            await MainActor.run {
                contactSheetURL = url
                isRenderingSheet = false
                if url == nil {
                    errorMessage = "Kontaktbogen konnte nicht erstellt werden."
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

        Task {
            do {
                let url = try await StopMotionAssembler().assemble(
                    imageURLs: urls, settings: settings
                ) { p in
                    Task { @MainActor in exportProgress = p }
                }
                await MainActor.run {
                    exportURL = url
                    isExporting = false
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
        .task {
            if image == nil, let data = try? Data(contentsOf: url),
               let full = UIImage(data: data) {
                let size = CGSize(width: 180, height: 180)
                let renderer = UIGraphicsImageRenderer(size: size)
                image = renderer.image { _ in
                    full.draw(in: CGRect(origin: .zero, size: size))
                }
            }
        }
    }
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

    private var chosen: [Project] { store.projects.filter { selected.contains($0.id) } }
    private var totalFrames: Int { chosen.reduce(0) { $0 + $1.frameCount } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CatalogLabel("Werke für die Ausstellung wählen", color: Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 14)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.projects) { project in
                            Button { toggle(project.id) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: selected.contains(project.id)
                                          ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(Theme.ink)
                                    Rectangle().fill(Theme.accent(for: project.id))
                                        .frame(width: 4, height: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        WorkTitle(project.name, size: 16)
                                        CatalogLabel("\(project.frameCount) Bilder")
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 12).padding(.horizontal, 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }

                VStack(spacing: 10) {
                    if isBuilding {
                        HairlineProgress(value: progress)
                        CatalogLabel("Reel wird montiert…")
                    } else if let reelURL {
                        ShareLink(item: reelURL) {
                            Text("Ausstellung teilen")
                                .font(Theme.caption(12)).tracking(2.2).textCase(.uppercase)
                                .foregroundStyle(Theme.paper)
                                .padding(.vertical, 15).frame(maxWidth: .infinity)
                                .background(Theme.ink)
                        }
                    } else {
                        Button("Ausstellung erstellen") { build() }
                            .buttonStyle(InkButtonStyle())
                            .disabled(chosen.count < 2 || totalFrames == 0)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(Theme.mono(11)).foregroundStyle(.red)
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
                await MainActor.run { reelURL = url; isBuilding = false }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isBuilding = false
                }
            }
        }
    }
}
