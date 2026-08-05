import SwiftUI
import AVKit
import UIKit

/// Projektliste im Werkverzeichnis-Stil: nummerierte Einträge,
/// Haarlinien, gesperrte Versalien.
struct ProjectsView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var newProjectName = ""
    @State private var showNewProject = false
    @State private var showExhibition = false
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue

    var body: some View {
        NavigationStack {
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
                        .padding(.top, 22)
                        Spacer(minLength: 20)
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
                    if store.projects.count >= 2 && AppMode.current(modeRaw).showsTolino {
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

            // Das Werk als gefaltetes Blatt – wie auf dem Startscreen
            FoldedPaperHero(image: store.thumbnail(for: project),
                            seed: FoldSeed.make(project.id),
                            accent: Theme.accent(for: project.id),
                            animatesLight: false)
                .frame(width: 52, height: 52)
                .overlay(Rectangle().stroke(Theme.ink.opacity(0.5), lineWidth: 1))

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
    @State private var shareItem: ShareItem?
    @State private var isEditingFrames = false
    @State private var showDeleteProject = false
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
                ForEach(Array(store.frameURLs(for: currentProject).enumerated()), id: \.offset) { index, url in
                    FrameThumbnail(url: url)
                        // Nummerierte Zelle wie im gedruckten Kontaktbogen
                        .overlay(alignment: .bottomLeading) {
                            Text(String(format: "%02d", index + 1))
                                .font(Theme.mono(8.5, .medium))
                                .foregroundStyle(Theme.paperOnDark)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Theme.ink.opacity(0.72))
                                .padding(5)
                        }
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
                    .foregroundStyle(Theme.oxblood)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(Theme.oxblood.opacity(0.45), lineWidth: 1))
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
                // Frame-Bearbeitung erst ab „Erweitert" – im Einfach-Modus
                // reicht: ansehen, exportieren, teilen.
                if mode.showsAdvanced {
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
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .onChange(of: exportSettings) { _, _ in
            // Einstellungen geändert → das fertige Video passt nicht mehr dazu
            exportURL = nil
        }
    }

    /// Immer den frischen Stand aus dem Store verwenden.
    private var currentProject: Project {
        store.projects.first(where: { $0.id == project.id }) ?? project
    }

    /// Eine Einstellzeile: links wofür, rechts der Wert – sonst steht im
    /// Panel nur „Original" oder „Normal", ohne dass man weiß, was gemeint ist.
    private func optionRow<Content: View>(_ label: String,
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
                            ForEach(LoopMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    optionDivider
                    optionRow("Bildrate") {
                        Picker("", selection: $exportSettings.outputFPS) {
                            Text("6 fps").tag(Int32(6))
                            Text("8 fps").tag(Int32(8))
                            Text("10 fps").tag(Int32(10))
                            Text("12 fps").tag(Int32(12))
                        }
                    }
                    optionDivider
                    optionRow("Verwacklung ausgleichen") {
                        Toggle("", isOn: $exportSettings.alignFrames)
                    }
                    if mode.showsTolino {
                        optionDivider
                        optionRow("Interferenz-Echo") {
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
                                    ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(Theme.paperShade.opacity(0.5))
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }

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

                Button("Neu exportieren") { export() }
                    .buttonStyle(HairlineButtonStyle())
            } else {
                Button("Stopmotion exportieren") { export() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(currentProject.frameCount == 0)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.oxblood)
            }

            // Drucksachen – bewusst leiser als der Export, als Paar
            if mode.showsAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    CatalogLabel("Drucken", size: 9)
                    HStack(spacing: 8) {
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
                .padding(.top, 6)
            }
        }
    }

    /// Drucksache: kleiner, ruhiger Knopf – ordnet sich dem Export unter.
    private func pdfButton(title: String, icon: String, disabled: Bool,
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
            .padding(.vertical, 14)
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
                    errorMessage = "Faltvorlage konnte nicht erstellt werden."
                }
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
                if let url {
                    shareItem = ShareItem(url: url)   // Teilen-Sheet direkt öffnen
                } else {
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
    @State private var shareItem: ShareItem?

    private var chosen: [Project] { store.projects.filter { selected.contains($0.id) } }
    private var totalFrames: Int { chosen.reduce(0) { $0 + $1.frameCount } }

    /// Sagt jederzeit, wo man steht – statt eines stummen, grauen Knopfs.
    private var selectionHint: String {
        switch chosen.count {
        case 0: return "Mindestens zwei Werke wählen."
        case 1: return "Ein Werk gewählt – noch mindestens eines."
        default: return "\(chosen.count) Werke · \(totalFrames) Bilder"
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
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.graphite)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 18)

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
        .task(id: url) { await loadFrames() }
        .onReceive(Timer.publish(every: 1.0 / max(1, playFPS), on: .main, in: .common).autoconnect()) { _ in
            guard !isScrubbing, frames.count > 1 else { return }
            index = (index + 1) % frames.count
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
                .padding(.bottom, 7)
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
        // Sehr lange Sequenzen ausdünnen – der Speicher soll ruhig bleiben
        let total = max(1, min(Int((seconds * rate).rounded()), 300))
        let step = seconds / Double(total)
        let times = (0..<total).map {
            CMTime(seconds: Double($0) * step + step / 2, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 720, height: 720)

        var loaded: [UIImage] = []
        for await result in generator.images(for: times) {
            if let cg = try? result.image { loaded.append(UIImage(cgImage: cg)) }
        }
        frames = loaded
        index = 0
        isLoading = false
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
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
