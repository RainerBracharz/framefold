import SwiftUI
import AVKit

/// Projektliste im Werkverzeichnis-Stil: nummerierte Einträge,
/// Haarlinien, gesperrte Versalien.
struct ProjectsView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var newProjectName = ""
    @State private var showNewProject = false

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    VStack(spacing: 18) {
                        FoldMark(size: 48, color: Theme.graphite)
                        CatalogLabel("Noch keine Projekte", color: Theme.ink)
                        Text("Ein Projekt pro Werk. Frames sammeln sich\nüber beliebig viele Sessions – live oder aus Videos.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.graphite)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                                NavigationLink(value: project.id) {
                                    projectRow(index: index, project: project)
                                }
                                .buttonStyle(.plain)
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                            }
                        }
                        .overlay(alignment: .top) {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
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
                    CatalogLabel("Werkverzeichnis", color: Theme.ink, size: 12)
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
        }
    }

    private func projectRow(index: Int, project: Project) -> some View {
        HStack(spacing: 16) {
            CatalogLabel(String(format: "%02d", index + 1), color: Theme.graphite)
                .frame(width: 28, alignment: .leading)

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
                Text(project.name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                CatalogLabel("\(project.frameCount) Frames")
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Theme.graphite)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                store.delete(project)
            } label: {
                Label("Projekt löschen", systemImage: "trash")
            }
        }
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

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 2)]

    var body: some View {
        ScrollView {
            CatalogLabel("\(currentProject.frameCount) Frames · Kontaktbogen")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(store.frameURLs(for: currentProject).enumerated()), id: \.offset) { index, url in
                    FrameThumbnail(url: url)
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

            exportSection
                .padding(20)
        }
        .paperStage()
        .toolbar {
            ToolbarItem(placement: .principal) {
                CatalogLabel(currentProject.name, color: Theme.ink, size: 12)
            }
        }
        .toolbarBackground(Theme.paper, for: .navigationBar)
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
                    Toggle("Frames ausrichten", isOn: $exportSettings.alignFrames)
                    Toggle("Interferenz-Echo", isOn: $exportSettings.interferenzEcho)
                    Picker("Falz-Blende", selection: $exportSettings.transitionFrames) {
                        Text("Aus").tag(0)
                        Text("Kurz").tag(2)
                        Text("Weich").tag(4)
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
