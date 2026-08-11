import SwiftUI
import AVFoundation
import PhotosUI
import UIKit

/// Live-Aufnahme als „Dunkelkammer": schwarze Bühne, Papierton-Typografie.
/// Kamerabild, Onion-Skin des letzten Frames, Auto-Shutter-Status.
struct LiveCaptureView: View {
    @EnvironmentObject var store: ProjectStore
    @StateObject private var controller = LiveCaptureController()
    @State private var targetProject: Project?
    @State private var onionSkin = true
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var showSettings = false
    @State private var recentThumbs: [UIImage] = []
    @StateObject private var level = MotionLevel()
    @AppStorage("liveShowGrid") private var showGrid = true
    @AppStorage("liveShowLevel") private var showLevel = true
    @AppStorage("didSeeCameraTip") private var didSeeCameraTip = false
    @AppStorage("liveOnionOpacity") private var onionOpacity: Double = 0.35
    @AppStorage("liveOnionFirst") private var onionFirst: Bool = false
    @State private var referenceImage: UIImage?
    @State private var refPickerItem: PhotosPickerItem?
    /// Im Einfach-Modus bleiben nur Auslöser und Fertig – alles andere
    /// (Raster, Wasserwaage, Pegel, Neu-Fixieren, Referenzbild) ab „Erweitert".
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(modeRaw) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kurzer weißer Blitz im Sucher bei jeder Aufnahme – sichtbar auch aus
    /// zwei Metern Entfernung, wenn man am Set steht statt am Display.
    @State private var flashOpacity = 0.0
    /// Jubel-Impuls des großen Zählers (Einfach): alle 10 Bilder = 1 s Film.
    @State private var celebratePulse = 1.0

    // Sofort-Ergebnis: nach „Fertig" wird direkt montiert und gezeigt,
    // statt den Nutzer in die Werkliste zurückzuwerfen.
    @State private var finishedProject: Project?
    @State private var isAssembling = false
    @State private var assembleProgress = 0.0
    @State private var resultURL: URL?
    @State private var resultError: String?
    @State private var resultShare: ShareItem?
    /// Wie viele Frames die letzte Session beigetragen hat – für „Verwerfen".
    @State private var lastSessionCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if controller.permissionDenied {
                    VStack(spacing: 16) {
                        FoldMark(size: 40, color: Theme.paperOnDark)
                        CatalogLabel("Kein Kamerazugriff", color: Theme.paperOnDark)
                        Text("Erlaube FrameFold den Kamerazugriff unter Einstellungen → FrameFold.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else if controller.cameraUnavailable {
                    cameraUnavailableView
                } else if let finishedProject {
                    // Direkt nach der Aufnahme: Ergebnis ansehen
                    resultView(project: finishedProject)
                } else if let project = targetProject {
                    captureView(project: project)
                } else {
                    projectChooser
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.darkroom.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    WorkTitle("Kamera", size: 17, color: Theme.paperOnDark)
                }
                // Ein Ausstieg reicht: der Fertig-Knopf unten. Oben bleibt
                // nur das Regler-Symbol – wie in allen anderen Tabs.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Theme.paperOnDark)
                    }
                }
            }
            .toolbarBackground(Theme.darkroom, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // Die App-weite Akzentfarbe ist auf diesem Tab hell (für die
            // dunkle Tab-Leiste) – System-Dialoge erben sie und wären hell
            // auf hell. Hier gilt für Dialoge wieder Tusche.
            .tint(Theme.ink)
            .sheet(isPresented: $showSettings) {
                LiveSettingsView(controller: controller,
                                 showGrid: $showGrid, showLevel: $showLevel)
            }
            .overlay {
                // Einmaliger, überspringbarer Tipp beim ersten Öffnen
                if !didSeeCameraTip && !controller.permissionDenied && !controller.cameraUnavailable {
                    cameraTip
                }
            }
        }
    }

    private var cameraTip: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 18) {
                FoldMark(size: 44, color: Theme.paperOnDark)
                CatalogLabel("So funktioniert die Kamera", color: Theme.paperOnDark)
                Text("iPhone aufs Stativ oder ruhig über die Arbeit halten. Arbeite einfach — FrameFold nimmt automatisch ein Bild auf, sobald deine Hände aus dem Bild sind und die Szene kurz ruht.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 34)
                Text("Der runde Knopf löst jederzeit von Hand aus.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.6))
                    .multilineTextAlignment(.center)
                Button {
                    didSeeCameraTip = true
                } label: {
                    Text("Verstanden")
                        .font(Theme.caption(12)).tracking(2.2).textCase(.uppercase)
                        .foregroundStyle(Theme.darkroom)
                        .padding(.vertical, 14).padding(.horizontal, 40)
                        .background(Theme.paperOnDark)
                }
                .padding(.top, 6)
            }
        }
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: 16) {
            FoldMark(size: 40, color: Theme.paperOnDark)
            CatalogLabel("Keine Kamera verfügbar", color: Theme.paperOnDark)
            Text("Auf diesem Gerät wurde keine Kamera gefunden (z. B. im Simulator). Die Live-Aufnahme braucht ein echtes iPhone. Videos kannst du im Video-Tab trotzdem verarbeiten.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 40)
        }
    }

    // MARK: Projektwahl

    private var projectChooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Dunkelkammer-Fassung der Begrüßung
                VStack(alignment: .leading, spacing: 10) {
                    CatalogLabel("Dunkelkammer", color: Theme.paperOnDark.opacity(0.55))
                    Text(mode == .basic ? "Was falten\nwir heute?" : "Welches Werk\nnimmst du auf?")
                        .font(Theme.serifItalic(26))
                        .foregroundStyle(Theme.paperOnDark)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("iPhone aufs Stativ. FrameFold löst aus, sobald deine Hände aus dem Bild sind.")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.paperOnDark.opacity(0.6))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 22)

                if store.projects.isEmpty {
                    VStack(spacing: 0) {
                        FoldedPaperHero(seed: 33, accent: Theme.violet, animatesLight: false)
                            .frame(height: 150)
                            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.3), lineWidth: 1))
                        Text("Noch kein Werk – leg eines an, dann kann die Kamera loslegen.")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.paperOnDark.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.projects.prefix(4)) { project in
                            Button { targetProject = project } label: {
                                darkProjectRow(project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Button {
                    showNewProject = true
                } label: {
                    Label("Neues Werk", systemImage: "plus")
                }
                .buttonStyle(DarkPrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer(minLength: 24)
            }
        }
        .alert("Neues Projekt", isPresented: $showNewProject) {
            TextField("Name", text: $newProjectName)
            Button("Anlegen & starten") {
                guard !newProjectName.isEmpty else { return }
                targetProject = store.createProject(name: newProjectName)
                newProjectName = ""
            }
            Button("Abbrechen", role: .cancel) { newProjectName = "" }
        }
    }

    // MARK: Sofort-Ergebnis

    /// Beendet die Session und montiert das Ergebnis gleich – der Lohn der
    /// Arbeit soll unmittelbar zu sehen sein, nicht drei Tipps entfernt.
    private func finishSession(project: Project) {
        controller.stop()
        level.stop()
        let captured = controller.capturedCount
        lastSessionCount = captured
        targetProject = nil
        guard captured > 0 else { return }   // Abbruch ohne Bilder

        finishedProject = project
        resultURL = nil
        resultError = nil
        isAssembling = true
        assembleProgress = 0

        let urls = store.frameURLs(for: store.projects.first(where: { $0.id == project.id }) ?? project)
        Task {
            do {
                let url = try await StopMotionAssembler().assemble(
                    imageURLs: urls, settings: PipelineSettings()
                ) { p in Task { @MainActor in assembleProgress = p } }
                await MainActor.run { resultURL = url; isAssembling = false }
            } catch {
                await MainActor.run {
                    resultError = "Das hat leider nicht geklappt."
                    isAssembling = false
                }
            }
        }
    }

    private func resultView(project: Project) -> some View {
        let count = store.projects.first(where: { $0.id == project.id })?.frameCount ?? 0
        let seconds = Double(count) / 10.0
        return VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 6) {
                // Tolino spricht Katalog: Blätter statt Bilder, Serie statt Zähler
                Text(mode == .basic ? "Fertig! \(count) Bilder"
                     : mode == .tolino
                        ? (count == 1 ? "Ein Blatt" : String(format: "Blatt 01 – %02d", count))
                        : "\(count) Bilder aufgenommen")
                    .font(Theme.serifItalic(24))
                    .foregroundStyle(Theme.paperOnDark)
                CatalogLabel(mode == .tolino
                    ? "Serie von \(count) · datiert \(String(Calendar.current.component(.year, from: Date()))) · Schleife"
                    : String(format: "%.1f Sekunden · läuft in Schleife", seconds),
                             color: Theme.paperOnDark.opacity(0.55), size: 9)
            }
            .padding(.bottom, 18)

            if isAssembling {
                VStack(spacing: 12) {
                    HairlineProgress(value: assembleProgress,
                                     trackColor: Theme.paperOnDark.opacity(0.25))
                        .frame(width: 180)
                    CatalogLabel(mode == .basic ? "Wird zusammengesetzt…"
                                 : mode == .tolino ? "Werk wird montiert…"
                                 : "Stopmotion wird montiert…",
                                 color: Theme.paperOnDark.opacity(0.6), size: 9)
                }
                .frame(maxHeight: .infinity)
            } else if let resultURL {
                LoopingVideoPreview(url: resultURL)
                    .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
            } else if let resultError {
                Text(resultError)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.amber)
                    .frame(maxHeight: .infinity)
            }

            VStack(spacing: 10) {
                if let resultURL {
                    Button("Teilen") { resultShare = ShareItem(url: resultURL) }
                        .buttonStyle(DarkPrimaryButtonStyle())
                }
                HStack(spacing: 10) {
                    // Verwerfen: Session löschen und von vorn – als Mistkübel
                    IconSquare(icon: "trash", stage: .dark) {
                        discardSession(project: project)
                    }

                    // Weiter aufnehmen = die produktive Aktion → gefüllt
                    Button(mode == .basic ? "Nochmal" : "Weiter aufnehmen") {
                        finishedProject = nil
                        targetProject = project
                    }
                    .buttonStyle(DarkPrimaryButtonStyle())

                    // Fertig = abschließen → bewusst leiser, nur Kontur
                    Button("Fertig") {
                        finishedProject = nil
                    }
                    .buttonStyle(DarkSecondaryButtonStyle())
                }
                CatalogLabel("gespeichert in \(project.name)",
                             color: Theme.paperOnDark.opacity(0.45), size: 8)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .sheet(item: $resultShare) { item in ActivityView(items: [item.url]) }
    }

    /// Entfernt die Frames der letzten Session aus dem Werk (wandern in den
    /// 30-Tage-Papierkorb) und startet direkt eine neue Aufnahme.
    private func discardSession(project: Project) {
        if let current = store.projects.first(where: { $0.id == project.id }),
           lastSessionCount > 0, current.frameCount >= lastSessionCount {
            let range = (current.frameCount - lastSessionCount)..<current.frameCount
            store.removeFrames(at: IndexSet(integersIn: range), from: current)
        }
        resultURL = nil
        lastSessionCount = 0
        finishedProject = nil
        targetProject = project   // ohne Umweg zurück in den Sucher
    }


    /// Werkzeile in der Dunkelkammer: gefaltetes Blatt + Werkkante.
    private func darkProjectRow(_ project: Project) -> some View {
        HStack(spacing: 14) {
            FoldedPaperHero(image: store.thumbnail(for: project),
                            seed: FoldSeed.make(project.id),
                            accent: Theme.accent(for: project.id),
                            animatesLight: false)
                .frame(width: 54, height: 54)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.accent(for: project.id)).frame(width: 3)
                }
                .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.3), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(Theme.serif(17, .regular))
                    .foregroundStyle(Theme.paperOnDark)
                    .lineLimit(1)
                CatalogLabel("\(project.frameCount) Bilder",
                             color: Theme.paperOnDark.opacity(0.55), size: 9)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.paperOnDark.opacity(0.5))
        }
        .padding(12)
        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.28), lineWidth: 1))
        .contentShape(Rectangle())   // ganze Zeile ist tippbar
    }

    // MARK: Aufnahme

    /// Sucher – bewusst flach aufgebaut: EIN ZStack, das Kamerabild füllt
    /// alles, darüber genau eine Spalte mit Status und Bedienung. Keine
    /// verschachtelten Stapel, keine Layout-Prioritäten: so kann die
    /// Bedienleiste strukturell nicht verschwinden.
    private func captureView(project: Project) -> some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            // Feste Größe: sonst macht scaledToFill das Bild breiter als den
            // Bildschirm – der ganze Stapel wird überbreit und die Bedienung
            // rutscht seitlich hinaus. Genau das war der alte Fehler.
            cameraLayer
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

            // Aufnahme-Blitz über dem Kamerabild, unter der Bedienung
            if flashOpacity > 0 {
                Color.white.opacity(flashOpacity)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                // Drei Gesichter derselben Kamera:
                //   Einfach     – Spielzeug: großer Zähler, sonst nichts
                //   Erweitert   – Werkzeug: Pegel + kompakter Stand
                //   Aldo Tolino – Messinstrument: Labor-HUD mit Zahlen
                switch mode {
                case .basic:    bigCounter
                case .advanced: advancedStatusRow
                case .tolino:   tolinoHUD
                }

                statusBadge

                if let hint = controller.hint {
                    // Im Einfach-Modus sind die Einstellungen unerreichbar –
                    // der Rat muss ohne sie auskommen.
                    Text(mode == .basic
                         ? "Zu viel Wackeln – leg das iPhone irgendwo auf oder lehne es an."
                         : hint)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.darkroom)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.amber)
                }

                if mode.showsAdvanced, !recentThumbs.isEmpty {
                    thumbStrip(project: project)
                }

                controlRow(project: project)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(width: geo.size.width)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        }
        .overlay(alignment: .topLeading) {
            // Werkzeuge erst ab „Erweitert"
            if mode.showsAdvanced {
                VStack(spacing: 8) {
                    sucherButton("camera.metering.center.weighted") {
                        controller.refixCamera()
                    }
                    if referenceImage == nil {
                        PhotosPicker(selection: $refPickerItem, matching: .images) {
                            sucherIcon("photo")
                        }
                    } else {
                        sucherButton("photo.fill") { referenceImage = nil }
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            recentThumbs = []
            level.start()
            controller.start { jpegData in
                if let current = store.projects.first(where: { $0.id == project.id }) {
                    store.appendFrame(jpegData: jpegData, to: current)
                }
                if let image = UIImage(data: jpegData) {
                    // Klein rechnen: Vollauflösung im Daumenkino zwingt SwiftUI,
                    // bei jedem Update sechs 1080p-Bilder zu skalieren.
                    let target = CGSize(width: 132, height: 176)
                    let thumb = UIGraphicsImageRenderer(size: target).image { _ in
                        image.draw(in: CGRect(origin: .zero, size: target))
                    }
                    recentThumbs.append(thumb)
                    if recentThumbs.count > 6 { recentThumbs.removeFirst() }
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stop()
            level.stop()
        }
        .onChange(of: refPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    referenceImage = img
                }
                refPickerItem = nil
            }
        }
        .onChange(of: controller.capturedCount) { old, new in
            guard new > old else { return }   // Undo blitzt nicht
            if !reduceMotion {
                flashOpacity = 0.5
                withAnimation(.easeOut(duration: 0.28)) { flashOpacity = 0 }
            }
            // Jubel im Einfach-Modus: jede volle Filmsekunde federt der Zähler
            if mode == .basic, new % 10 == 0, !reduceMotion {
                celebratePulse = 1.22
                withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) {
                    celebratePulse = 1.0
                }
            }
        }
    }

    /// Kamerabild samt Überblendungen (Zwiebelhaut, Referenz, Raster, Waage).
    @ViewBuilder
    private var cameraLayer: some View {
        ZStack {
            #if targetEnvironment(simulator)
            if let sim = controller.simulatedPreview {
                Image(uiImage: sim).resizable().scaledToFill()
            } else {
                Theme.darkroom
            }
            #else
            CameraPreview(session: controller.session) { devicePoint in
                controller.focus(atDevicePoint: devicePoint)
            }
            #endif

            if onionSkin,
               let ghost = onionFirst ? controller.firstCapturedImage : controller.lastCapturedImage {
                Image(uiImage: ghost).resizable().scaledToFill()
                    .opacity(onionOpacity).allowsHitTesting(false)
            }
            if let referenceImage {
                Image(uiImage: referenceImage).resizable().scaledToFill()
                    .opacity(onionOpacity * 0.9).allowsHitTesting(false)
            }
            if mode.showsAdvanced, showGrid { ThirdsGrid().allowsHitTesting(false) }
            if mode.showsAdvanced, showLevel {
                BubbleLevel(gx: level.gx, gy: level.gy, isLevel: level.isLevel)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Bedienung: Auslöser in der Mitte, Fertig rechts – wie in jeder Kamera-App.
    /// Einfach bekommt den größten Knopf (Kinderhände, Blick aufs Set);
    /// Tolino trägt den Falz-Countdown als Amber-Ring um den Auslöser.
    private func controlRow(project: Project) -> some View {
        // Auto-Shutter-Fortschritt (0..1), nur während „Ruhig halten…"
        let stabilizing: Double? = {
            if case .stabilizing(let p) = controller.status { return p }
            return nil
        }()
        let outer: CGFloat = mode == .basic ? 84 : 74
        let ring:  CGFloat = mode == .basic ? 78 : 68
        let core:  CGFloat = mode == .basic ? 62 : 54

        // ZStack statt HStack: der Auslöser ist absolut zentriert und kann
        // von unterschiedlich breiten Nachbarn nicht mehr verschoben werden.
        return ZStack {
            Button { controller.captureNow() } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.25)).frame(width: outer, height: outer)
                    Circle().stroke(Theme.paperOnDark, lineWidth: 3).frame(width: ring, height: ring)
                    // Tolino: der Countdown bis zum Auto-Shutter wandert als
                    // Falz in Amber um den Knopf – man sieht die Auslösung kommen.
                    if mode.showsTolino, let p = stabilizing {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(Theme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                            .frame(width: ring, height: ring)
                            .animation(.linear(duration: 0.1), value: p)
                    }
                    Circle().fill(Theme.paperOnDark).frame(width: core, height: core)
                }
            }

            HStack {
                if mode.showsAdvanced {
                    Button { onionSkin.toggle() } label: {
                        Image(systemName: "square.2.layers.3d")
                            .font(.system(size: 17))
                            .foregroundStyle(onionSkin ? Theme.darkroom : Theme.paperOnDark)
                            .frame(width: 48, height: 48)
                            .background(onionSkin ? Theme.paperOnDark : Color.black.opacity(0.35))
                            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.4), lineWidth: 1))
                    }
                }
                Spacer()
                // Fertig / Abbrechen – im Stil der Bildunterschriften:
                // Versalien, klare Fläche, Falz-Ecke in Amber
                Button { finishSession(project: project) } label: {
                    Text(controller.capturedCount == 0
                         ? "Abbrechen"
                         : "Fertig · \(controller.capturedCount)")
                        .font(Theme.caption(11))
                        .tracking(1.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.darkroom)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Theme.paperOnDark)
                        .overlay(alignment: .topLeading) {
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: 12))
                                p.addLine(to: CGPoint(x: 12, y: 0))
                            }
                            .stroke(Theme.amber, lineWidth: 2)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Erweitert: Pegel + kompakter Stand („12 · 1,2 s") in einer Zeile.
    private var advancedStatusRow: some View {
        let count = controller.capturedCount
        return HStack(spacing: 12) {
            MotionGauge(motion: controller.currentMotion,
                        threshold: controller.motionThreshold)
                .frame(width: 150, height: 10)
            Text(String(format: "%d · %.1f s", count, Double(count) / 10.0))
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.paperOnDark)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.darkroom.opacity(0.6))
        }
    }

    /// Tolino: das Labor-HUD. Blattnummer, Sitzungsuhr, fixierte Belichtung,
    /// darunter der Pegel mit Messwert gegen Schwelle – ein Instrument,
    /// kein Spielzeug. Alles in Katalog-Versalien auf Dunkelkammer-Grund.
    private var tolinoHUD: some View {
        let count = controller.capturedCount
        return VStack(spacing: 9) {
            HStack {
                CatalogLabel(String(format: "Blatt %02d · %.1f s", count, Double(count) / 10.0),
                             color: Theme.amberLight, size: 10)
                Spacer()
                if let start = controller.sessionStart {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        CatalogLabel(sessionClock(from: start, now: ctx.date),
                                     color: Theme.paperOnDark.opacity(0.8), size: 10)
                    }
                }
                Spacer()
                CatalogLabel(controller.exposureInfo ?? "—",
                             color: Theme.paperOnDark.opacity(0.8), size: 10)
            }
            HStack(spacing: 10) {
                MotionGauge(motion: controller.currentMotion,
                            threshold: controller.motionThreshold)
                    .frame(height: 10)
                Text(String(format: "%.1f / %.1f", controller.currentMotion,
                            controller.motionThreshold))
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.75))
                    .frame(width: 62, alignment: .trailing)
            }

            // Schnellzugriff: Auslöser direkt im Instrument umschalten –
            // der Gang in die Einstellungen unterbricht sonst die Arbeit.
            Button {
                controller.captureMode =
                    controller.captureMode == .motion ? .interval : .motion
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: controller.captureMode == .motion
                          ? "hand.raised" : "timer")
                        .font(.system(size: 10, weight: .medium))
                    Text(controller.captureMode == .motion
                         ? "Auslöser · Bewegung"
                         : String(format: "Auslöser · Intervall %.0f s",
                                  controller.intervalSeconds))
                        .font(Theme.caption(9))
                        .tracking(1.4)
                        .textCase(.uppercase)
                }
                .foregroundStyle(controller.captureMode == .interval
                                 ? Theme.darkroom : Theme.paperOnDark.opacity(0.85))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(controller.captureMode == .interval
                            ? Theme.amberLight : Color.clear)
                .overlay(Rectangle().stroke(
                    controller.captureMode == .interval
                    ? Theme.amberLight : Theme.paperOnDark.opacity(0.35),
                    lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.darkroom.opacity(0.75))
        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.25), lineWidth: 1))
    }

    /// „02:41" seit Sessionbeginn.
    private func sessionClock(from start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Daumenkino der letzten Aufnahmen + Zurücknehmen des letzten Bildes.
    /// Ein danebengegangener Frame ruiniert sonst die ganze Schleife.
    private func thumbStrip(project: Project) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(recentThumbs.enumerated()), id: \.offset) { _, img in
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 44, height: 33)
                    .clipped()
                    .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.4), lineWidth: 1))
            }
            Button { undoLastFrame(project: project) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.paperOnDark)
                    .frame(width: 36, height: 33)
                    .background(Color.black.opacity(0.35))
                    .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
            }
            .accessibilityLabel("Letztes Bild zurücknehmen")
        }
    }
    private func undoLastFrame(project: Project) {
        if let current = store.projects.first(where: { $0.id == project.id }),
           current.frameCount > 0 {
            store.removeFrames(at: IndexSet(integer: current.frameCount - 1), from: current)
        }
        if !recentThumbs.isEmpty { recentThumbs.removeLast() }
        controller.revertLastCapture(to: recentThumbs.last)
    }

    private var currentCount: Int {
        guard let project = targetProject else { return 0 }
        return store.projects.first(where: { $0.id == project.id })?.frameCount ?? 0
    }

    /// „48 Bilder · ~4,8 s bei 10 fps" – gibt ein Gefühl für die Werk-Länge.
    private var lengthHint: String {
        let secs = Double(currentCount) / 10.0
        return String(format: "%d Bilder · ~%.1f s bei 10 fps", currentCount, secs)
    }

    private func sucherIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(Theme.paperOnDark)
            .frame(width: 38, height: 38)
            .background(Theme.darkroom.opacity(0.6))
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
    }

    private func sucherButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { sucherIcon(name) }
    }

    /// Großer Zähler mit fühlbarem Fortschritt: 10 Bilder = 1 Sekunde Film.
    private var bigCounter: some View {
        let count = controller.capturedCount
        let toNext = (10 - (count % 10)) % 10
        return VStack(spacing: 4) {
            Text("\(count)")
                .font(Theme.serif(58, .regular))
                .foregroundStyle(Theme.amberLight)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: count)
                .scaleEffect(celebratePulse)   // federt bei jeder vollen Filmsekunde
            CatalogLabel("Bilder", color: Theme.paperOnDark.opacity(0.7), size: 9)

            if count > 0 {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.paperOnDark.opacity(0.2))
                        .frame(width: 130, height: 3)
                    Rectangle().fill(Theme.amber)
                        .frame(width: 130 * CGFloat(count % 10 == 0 ? 10 : count % 10) / 10, height: 3)
                }
                .animation(.snappy, value: count)
                Text(toNext == 0
                     ? "\(count / 10) Sekunde\(count / 10 == 1 ? "" : "n") Film!"
                     : "noch \(toNext) für eine Sekunde Film")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.65))
            }
        }
        .padding(.bottom, 6)
    }

    private var statusBadge: some View {
        HStack(spacing: 10) {
            switch controller.status {
            case .stabilizing(let progress):
                HairlineProgress(value: progress,
                                 trackColor: Theme.paperOnDark.opacity(0.3))
                    .frame(width: 56)
            case .captured:
                Image(systemName: "checkmark").foregroundStyle(Theme.paperOnDark)
            case .working:
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.paperOnDark.opacity(0.8))
            default:
                Image(systemName: "eye").foregroundStyle(Theme.paperOnDark.opacity(0.6))
            }
            // Einfach: einen Tick größer – wird oft aus Entfernung gelesen
            CatalogLabel(controller.status.label(playful: mode == .basic),
                         color: Theme.paperOnDark,
                         size: mode == .basic ? 12 : 11)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.darkroom.opacity(0.75))
        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.25), lineWidth: 1))
    }
}

/// Drittel-Raster (Rule of Thirds) als Haarlinien im Sucher.
struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Theme.paperOnDark.opacity(0.22), lineWidth: 0.5)
        }
    }
}

/// Wasserwaage: feste Fadenkreuz-Marke + Blase, die sich mit der Neigung
/// bewegt. Zentriert und spektral, wenn das iPhone ausgerichtet ist.
struct BubbleLevel: View {
    let gx: Double
    let gy: Double
    let isLevel: Bool

    var body: some View {
        ZStack {
            // feste Ziel-Marke
            Circle()
                .stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1)
                .frame(width: 46, height: 46)
            Path { p in
                p.move(to: CGPoint(x: -30, y: 0)); p.addLine(to: CGPoint(x: -10, y: 0))
                p.move(to: CGPoint(x: 10, y: 0)); p.addLine(to: CGPoint(x: 30, y: 0))
            }
            .stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1)
            .frame(width: 60, height: 1)

            // bewegliche Blase (Neigung skaliert)
            Circle()
                .fill(isLevel ? AnyShapeStyle(Theme.crease) : AnyShapeStyle(Theme.paperOnDark.opacity(0.85)))
                .frame(width: isLevel ? 18 : 14, height: isLevel ? 18 : 14)
                .offset(x: CGFloat(gx) * 220, y: CGFloat(gy) * 220)
                .animation(.easeOut(duration: 0.1), value: gx)
                .animation(.easeOut(duration: 0.1), value: gy)
        }
        .frame(width: 60, height: 60)
    }
}

/// Bewegungs-Pegel: Balken = aktuelle Bewegung, Strich in der Mitte = Schwelle.
/// Balken links vom Strich = Szene gilt als ruhig.
struct MotionGauge: View {
    let motion: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = min(1.0, motion / max(0.001, threshold * 2))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.paperOnDark.opacity(0.25))
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .center)
                Group {
                    if motion <= threshold {
                        Rectangle().fill(Theme.crease)   // ruhig → bereit (spektral)
                    } else {
                        Rectangle().fill(Theme.amber)     // Bewegung → warten
                    }
                }
                .frame(width: geo.size.width * fraction, height: 4)
                .frame(maxHeight: .infinity, alignment: .center)
                // Schwellen-Markierung (immer bei 50 %)
                Rectangle()
                    .fill(Theme.paperOnDark.opacity(0.8))
                    .frame(width: 1.5)
                    .offset(x: geo.size.width / 2)
            }
        }
        .animation(.linear(duration: 0.1), value: motion)
    }
}

/// Einstellungen des Auto-Shutters – vor UND während der Aufnahme änderbar
/// (der Controller liest die Werte bei jeder Analyse frisch).
struct LiveSettingsView: View {
    @ObservedObject var controller: LiveCaptureController
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("liveOnionOpacity") private var onionOpacity: Double = 0.35
    @AppStorage("liveOnionFirst") private var onionFirst: Bool = false
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(modeRaw) }

    var body: some View {
        NavigationStack {
            Form {
                // Der Modus steht oben – im Einfach-Modus ist er das Einzige,
                // was man hier überhaupt einstellen kann.
                Section {
                    ModeTabs(modeRaw: $modeRaw)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    Text(mode == .basic
                         ? "Einfach: nur Auslöser und Fertig. Alles Weitere erscheint ab \"Erweitert\"."
                         : mode.showsTolino
                         ? "Labor-Ansicht: Blattnummer, Sitzungsuhr, fixierte Belichtung, Messwerte – und der Falz-Countdown wandert in Amber um den Auslöser."
                         : "Alle Werkzeuge sichtbar: Raster, Wasserwaage, Pegel, Daumenkino mit Zurücknehmen, Neu-Fixieren, Referenzbild.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                        .lineSpacing(2)
                } header: {
                    CatalogLabel("Modus")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                if mode.showsAdvanced {
                Section {
                    Toggle("Drittel-Raster", isOn: $showGrid)
                        .font(Theme.body)
                    Toggle("Wasserwaage", isOn: $showLevel)
                        .font(Theme.body)
                } header: {
                    CatalogLabel("Sucher")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Auslöse-Wartezeit: \(controller.stableSeconds, specifier: "%.1f") s")
                            .font(Theme.body)
                        Slider(value: $controller.stableSeconds, in: 0.3...2.5, step: 0.1)
                        Text("So lange muss die Szene ruhig sein, bevor automatisch ausgelöst wird.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.graphite)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bewegungs-Toleranz: \(controller.motionThreshold, specifier: "%.1f")")
                            .font(Theme.body)
                        Slider(value: $controller.motionThreshold, in: 0.5...8.0, step: 0.5)
                        Text("Höher = kleine Wackler und Bildrauschen werden ignoriert. Wenn der Auslöser nie Ruhe findet, diesen Wert erhöhen.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.graphite)
                    }
                    Toggle("Nicht auslösen, solange Hände im Bild sind", isOn: $controller.checkHands)
                        .font(Theme.body)
                } header: {
                    CatalogLabel("Auto-Shutter")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Picker("Auslöser", selection: $controller.captureMode) {
                        ForEach(LiveCaptureController.CaptureMode.allCases) { Text($0.label).tag($0) }
                    }
                    .font(Theme.body)
                    if controller.captureMode == .interval {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Intervall: \(controller.intervalSeconds, specifier: "%.0f") s")
                                .font(Theme.body)
                            Slider(value: $controller.intervalSeconds, in: 1...30, step: 1)
                            Text("Im Intervall-Modus löst FrameFold in festem Takt aus – unabhängig von Bewegung.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.graphite)
                        }
                    }
                    // Netzfrequenz ist Labor-Wissen – erst im Tolino-Modus zeigen
                    if mode.showsTolino {
                        Picker("Netzfrequenz", selection: $controller.mainsHz) {
                            Text("50 Hz (EU)").tag(50)
                            Text("60 Hz (US)").tag(60)
                        }
                        .font(Theme.body)
                    }
                    Toggle("Auslöse-Ton", isOn: $controller.playShutterSound)
                        .font(Theme.body)
                } header: {
                    CatalogLabel("Auslöser & Belichtung")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Toggle("Gegen ersten Frame (Drift)", isOn: $onionFirst)
                        .font(Theme.body)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Deckkraft: \(Int(onionOpacity * 100)) %")
                            .font(Theme.body)
                        Slider(value: $onionOpacity, in: 0.1...0.8, step: 0.05)
                        Text("Zeigt ersten oder letzten Frame als Überblendung – zum Ausrichten und um Drift zu erkennen.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.graphite)
                    }
                } header: {
                    CatalogLabel("Zwiebelhaut")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
                } // Ende: nur ab „Erweitert"

                Section {
                    tipRow("lightbulb", "Licht konstant halten: Kunstlicht nutzen, Fenster abdunkeln. Billige LED-/Leuchtstofflampen flackern im Netztakt und streifen einzelne Frames.")
                    tipRow("hand.raised", "iPhone nicht berühren: aufs Stativ stellen und den Auto-Shutter arbeiten lassen (oder den runden Knopf).")
                    tipRow("lock", "Kamera bleibt fixiert: FrameFold sperrt Belichtung, Fokus und Weißabgleich nach der kurzen Kalibrierung – so driftet zwischen den Bildern nichts.")
                    tipRow("square.2.layers.3d", "Drift früh erkennen: Onion-Skin anlassen und die Aufnahme ab und zu mit dem ersten Frame vergleichen.")
                } header: {
                    CatalogLabel("Aufnahme-Tipps")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .tint(Theme.ink)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CatalogLabel("Live-Einstellungen", color: Theme.ink, size: 12)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private func tipRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// UIKit-Brücke für die Kamera-Vorschau. Tippen setzt Fokus-/Belichtungspunkt.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onFocusTap: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onFocusTap = onFocusTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFocusTap: onFocusTap) }

    final class Coordinator: NSObject {
        var onFocusTap: ((CGPoint) -> Void)?
        weak var view: PreviewView?
        init(onFocusTap: ((CGPoint) -> Void)?) { self.onFocusTap = onFocusTap }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onFocusTap?(devicePoint)
        }
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
