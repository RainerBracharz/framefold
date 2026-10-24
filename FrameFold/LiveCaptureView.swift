import SwiftUI
import AVFoundation
import AVKit   // AVCaptureEventInteraction (Hardware-Fernauslöser)
import PhotosUI
import UIKit

/// Live-Aufnahme als „Dunkelkammer": schwarze Bühne, Papierton-Typografie.
/// Kamerabild, Onion-Skin des letzten Frames, Auto-Shutter-Status.
struct LiveCaptureView: View {
    @EnvironmentObject var store: ProjectStore
    @StateObject private var controller = LiveCaptureController()
    @State private var targetProject: Project?
    /// FF_AUTOSTART (Simulator/Mac-Debug) greift nur beim ersten Erscheinen.
    private static var autostarted = false
    @State private var onionSkin = true
    @State private var showNewProject = false
    @State private var showAllWorks = false
    @State private var newProjectName = ""
    @State private var showSettings = false
    @State private var recentThumbs: [UIImage] = []
    @StateObject private var level = MotionLevel()
    @AppStorage("liveShowGrid") private var showGrid = true
    @AppStorage("liveShowLevel") private var showLevel = true
    @AppStorage("didSeeCameraTip") private var didSeeCameraTip = false
    /// Live-Loop im Sucher groß oder klein
    @State private var loopLarge = false
    @AppStorage("liveOnionOpacity") private var onionOpacity: Double = 0.35
    @AppStorage("liveOnionFirst") private var onionFirst: Bool = false
    @State private var referenceImage: UIImage?
    @State private var refPickerItem: PhotosPickerItem?
    /// Im Einfach-Modus bleiben nur Auslöser und Fertig – alles andere
    /// (Raster, Wasserwaage, Pegel, Neu-Fixieren, Referenzbild) ab „Erweitert".
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    private var mode: AppMode { AppMode.current(modeRaw) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iPhone Duo: Film auf dem Außendisplay – vom Nutzer abschaltbar, und ob
    /// das System dort gerade etwas zeigen kann.
    @AppStorage("liveOuterDisplay") private var outerDisplayOn = true
    @State private var outerDisplayAvailable = false
    /// Steht die Film-Seite gerade neben der Kamera? Sonst zeigt der Sucher die Kachel.
    @State private var filmPageVisible = false
    /// Kurzer weißer Blitz im Sucher bei jeder Aufnahme – sichtbar auch aus
    /// zwei Metern Entfernung, wenn man am Set steht statt am Display.
    @State private var flashOpacity = 0.0
    /// Jubel-Impuls des großen Zählers (Einfach): alle 10 Bilder = 1 s Film.
    @State private var celebratePulse = 1.0
    /// Merkt einen langen Druck auf den Auslöser, damit das Loslassen nicht
    /// zusätzlich ein Bild macht (Selbstauslöser läuft dann schon).
    @State private var didLongPressShutter = false

    // Sofort-Ergebnis: nach „Fertig" wird direkt montiert und gezeigt,
    // statt den Nutzer in die Werkliste zurückzuwerfen.
    @State private var finishedProject: Project?
    @State private var isAssembling = false
    @State private var assembleProgress = 0.0
    @State private var resultURL: URL?
    @State private var resultError: String?
    @State private var resultShare: ShareItem?
    /// Wie viele Frames die letzte Session beigetragen hat – für „Verwerfen".
    /// Dateinamen der Bilder dieser Sitzung – Verwerfen und Zurücknehmen
    /// treffen genau diese, nie Bilder älterer Sitzungen.
    @State private var sessionFiles: [String] = []
    /// „Neu aufnehmen“: dieses Bild ersetzt das nächste ausgelöste; die
    /// Zwiebelhaut zeigt es zum Ausrichten.
    @State private var retake: RetakeFrame.Target?
    @State private var retakeGhost: UIImage?
    @State private var lastSessionFiles: [String] = []
    /// Laufende Montage des Sofort-Ergebnisses – eine neue ersetzt sie.
    @State private var assembleTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if controller.permissionDenied {
                    VStack(spacing: 16) {
                        FoldMark(size: 40, color: Theme.paperOnDark)
                        CatalogLabel("Kein Kamerazugriff", color: Theme.paperOnDark)
                        Text(Platform.isMac
                             ? "Erlaube FrameFold den Kamerazugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Kamera."
                             : "Erlaube FrameFold den Kamerazugriff unter Einstellungen → FrameFold.")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Einstellungen öffnen") { openCameraSettings() }
                            .buttonStyle(DarkSecondaryButtonStyle())
                            .padding(.top, 4)
                    }
                    // Zurück aus den Einstellungen: Ist der Zugriff jetzt da,
                    // geht es ohne Neustart weiter.
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                            controller.permissionDenied = false
                        }
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
            // Nur im Simulator und in der Mac-Testfassung: mit FF_AUTOSTART
            // direkt in die Aufnahme – für Layout-Prüfungen in Stellungen, in
            // denen sich der Simulator nicht bedienen lässt (aufgeklapptes
            // iPhone Duo), und für Store-Screenshots.
            .onAppear {
                if Platform.autostart, !Self.autostarted, targetProject == nil {
                    Self.autostarted = true   // nur einmal je Start (Test-Schalter)
                    didSeeCameraTip = true
                    targetProject = store.projects.first ?? store.createProject(name: "Faltung")
                }
                // „Mit der Kamera weiterarbeiten", bevor dieser Tab je offen war
                if let id = ContinueWork.pending { continueWork(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ffContinueWork)) { note in
                if let id = note.object as? UUID { continueWork(id) }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Im Sucher steht das Werk, in das gerade aufgenommen wird.
                    if let targetProject {
                        WorkTitle(verbatim: targetProject.name, size: 17, color: Theme.paperOnDark)
                    } else {
                        WorkTitle("Kamera", size: 17, color: Theme.paperOnDark)
                    }
                }
                // Ein Ausstieg reicht: der Fertig-Knopf unten. Oben bleibt
                // nur das Regler-Symbol – wie in allen anderen Tabs.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Theme.paperOnDark)
                    }
                    .accessibilityLabel("Aufnahme-Einstellungen")
                }
            }
            .toolbarBackground(Theme.darkroom, for: .navigationBar)
            // Sichtbarer Hintergrund: Erst dann folgt die Statusleiste dem
            // dunklen Schema – sonst stünden Uhrzeit und Akku dunkel auf dunkel.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // Die App-weite Akzentfarbe ist auf diesem Tab hell (für die
            // dunkle Tab-Leiste) – System-Dialoge erben sie und wären hell
            // auf hell. Hier gilt für Dialoge wieder Tusche.
            .tint(Theme.ink)
            .sheet(isPresented: $showSettings) {
                LiveSettingsView(controller: controller,
                                 showGrid: $showGrid, showLevel: $showLevel,
                                 outerDisplayAvailable: outerDisplayAvailable)
                    // Der Tab läuft im dunklen Modus (Statusleiste); die
                    // Einstellungen bleiben Papier wie überall sonst.
                    .preferredColorScheme(.light)
            }
            .overlay {
                // Einmaliger, überspringbarer Tipp beim ersten Öffnen
                if !didSeeCameraTip && !controller.permissionDenied && !controller.cameraUnavailable {
                    cameraTip
                }
            }
        }
    }

    private func continueWork(_ id: UUID) {
        ContinueWork.pending = nil
        adoptRetake(for: id)
        guard let project = store.projects.first(where: { $0.id == id }) else { return }
        // Auch wenn noch das Ergebnis desselben Werks offen ist: zurück in
        // den Sucher – sonst blieb „Weiterarbeiten“ bzw. „Neu aufnehmen“
        // auf dem Ergebnisbildschirm hängen.
        finishedProject = nil
        resultURL = nil
        if targetProject?.id != project.id { targetProject = project }
    }

    /// Übernimmt eine Bitte „Neu aufnehmen“ aus dem Kontaktbogen.
    private func adoptRetake(for id: UUID) {
        guard let target = RetakeFrame.pending, target.project == id,
              let project = store.projects.first(where: { $0.id == id }) else { return }
        RetakeFrame.pending = nil
        RetakeFrame.active = target
        retake = target
        retakeGhost = store.frameURLs(for: project)
            .first { $0.lastPathComponent == target.filename }
            .flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// Ersetzen-Modus beenden; nach dem Ersetzen zurück ins Werk – ohne
    /// Sitzungsende mit Montage: Das ersetzte Bild ist kein neues Bild.
    private func endRetake(openWork id: UUID?) {
        RetakeFrame.active = nil
        retake = nil
        retakeGhost = nil
        if let id {
            controller.stop()
            level.stop()
            targetProject = nil
            OpenWork.pending = id
            NotificationCenter.default.post(name: .ffOpenWork, object: id)
        }
    }

    /// Hinweis im Ersetzen-Modus: welches Bild, und wie man abbricht.
    private func retakeBanner(project: Project) -> some View {
        let number = (retake.flatMap { project.frameFilenames.firstIndex(of: $0.filename) } ?? 0) + 1
        return VStack(spacing: 0) {
            Text("Bild \(number) neu aufnehmen – das nächste Bild ersetzt es.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.darkroom)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.amber)
        .accessibilityElement(children: .contain)
    }

    private var cameraTip: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 18) {
                FoldMark(size: 44, color: Theme.paperOnDark)
                CatalogLabel("So funktioniert die Kamera", color: Theme.paperOnDark)
                Text(Platform.isMac
                     ? "Kamera fest über dem Tisch, etwa eine Dokumentenkamera. Arbeite einfach — FrameFold nimmt automatisch ein Bild auf, sobald deine Hände aus dem Bild sind und die Szene kurz ruht."
                     : "iPhone aufs Stativ oder ruhig über die Arbeit halten. Arbeite einfach — FrameFold nimmt automatisch ein Bild auf, sobald deine Hände aus dem Bild sind und die Szene kurz ruht.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
                Text(Platform.isMac
                     ? "Der runde Knopf oder die Leertaste löst jederzeit von Hand aus."
                     : "Der runde Knopf löst jederzeit von Hand aus.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.6))
                    .multilineTextAlignment(.center)
                Button {
                    didSeeCameraTip = true
                } label: {
                    Text("Verstanden")
                        .font(Theme.caption(12)).tracking(2.2).textCase(.uppercase)
                        .foregroundStyle(Theme.darkroom)
                        .padding(.vertical, 16).padding(.horizontal, 40)
                        .background(Theme.paperOnDark)
                }
                .padding(.top, 8)
            }
        }
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: 16) {
            FoldMark(size: 40, color: Theme.paperOnDark)
            CatalogLabel("Keine Kamera verfügbar", color: Theme.paperOnDark)
            Text(Platform.isMac
                 ? "Keine Kamera gefunden. Schließ eine USB-Kamera an – etwa eine Dokumentenkamera über dem Tisch – oder nimm dein iPhone als Kamera. Videos kannst du im Video-Tab trotzdem verarbeiten."
                 : "Auf diesem Gerät wurde keine Kamera gefunden (z. B. im Simulator). Die Live-Aufnahme braucht ein echtes iPhone. Videos kannst du im Video-Tab trotzdem verarbeiten.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 40)
            // Eine angesteckte Kamera wird am Mac von selbst erkannt; der
            // Knopf hilft, wenn das System sie nicht gemeldet hat.
            Button("Erneut suchen") { controller.cameraUnavailable = false }
                .buttonStyle(DarkSecondaryButtonStyle())
                .padding(.top, 4)
        }
    }

    private func openCameraSettings() {
        #if targetEnvironment(macCatalyst)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        #else
        let url = URL(string: UIApplication.openSettingsURLString)
        #endif
        if let url { UIApplication.shared.open(url) }
    }

    // MARK: Projektwahl

    private var projectChooser: some View {
        ScrollView {
            // Breit (aufgeklapptes iPhone Duo) als Doppelseite: links Frage
            // und „Neues Werk", rechts die Werke.
            let columns = horizontalSizeClass == .regular
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            columns {
              VStack(alignment: .leading, spacing: 0) {
                // Dunkelkammer-Fassung der Begrüßung
                VStack(alignment: .leading, spacing: 10) {
                    CatalogLabel("Dunkelkammer", color: Theme.paperOnDark.opacity(0.7))
                    Text(mode == .basic ? "Was falten\nwir heute?" : "Welches Werk\nnimmst du auf?")
                        .font(Theme.serifItalic(28))
                        .foregroundStyle(Theme.paperOnDark)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Platform.isMac
                         ? "Kamera über den Tisch. FrameFold löst aus, sobald deine Hände aus dem Bild sind."
                         : "iPhone aufs Stativ. FrameFold löst aus, sobald deine Hände aus dem Bild sind.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.paperOnDark.opacity(0.6))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)

                if horizontalSizeClass == .regular { newWorkButton }
              }
              .frame(maxWidth: .infinity, alignment: .leading)

              VStack(alignment: .leading, spacing: 0) {
                if store.projects.isEmpty {
                    VStack(spacing: 0) {
                        FoldedPaperHero(seed: 33, accent: Theme.violet, animatesLight: false)
                            .frame(height: horizontalSizeClass == .regular ? 260 : 150)
                            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.3), lineWidth: 1))
                        Text("Noch kein Werk – leg eines an, dann kann die Kamera loslegen.")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.paperOnDark.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 10) {
                        // Die vier jüngsten Werke, auf Wunsch alle – ältere
                        // Werke sollen sich live weiterführen lassen.
                        ForEach(showAllWorks ? store.projects : Array(store.projects.prefix(4))) { project in
                            Button { targetProject = project } label: {
                                darkProjectRow(project)
                            }
                            .buttonStyle(.plain)
                        }
                        if store.projects.count > 4 && !showAllWorks {
                            Button { showAllWorks = true } label: {
                                Text("Alle \(store.projects.count) Werke zeigen")
                                    .font(Theme.caption(11))
                                    .tracking(1.4)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Theme.paperOnDark.opacity(0.8))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                if horizontalSizeClass != .regular { newWorkButton }

                Spacer(minLength: 24)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, horizontalSizeClass == .regular ? 10 : 0)
            }
        }
        .alert("Neues Werk", isPresented: $showNewProject) {
            TextField("Name", text: $newProjectName)
            Button("Anlegen & starten") {
                targetProject = store.createProject(name: newProjectName)
                newProjectName = ""
            }
            Button("Abbrechen", role: .cancel) { newProjectName = "" }
        }
    }

    private var newWorkButton: some View {
        Button {
            showNewProject = true
        } label: {
            Label("Neues Werk", systemImage: "plus")
        }
        .buttonStyle(DarkPrimaryButtonStyle())
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    // MARK: Sofort-Ergebnis

    /// Beendet die Session und montiert das Ergebnis gleich – der Lohn der
    /// Arbeit soll unmittelbar zu sehen sein, nicht drei Tipps entfernt.
    private func finishSession(project: Project) {
        if retake != nil { endRetake(openWork: nil) }   // „Abbrechen“ im Ersetzen-Modus
        controller.stop()
        level.stop()
        let captured = controller.capturedCount
        lastSessionFiles = sessionFiles
        targetProject = nil
        guard captured > 0 else { return }   // Abbruch ohne Bilder

        finishedProject = project
        resultURL = nil
        resultError = nil
        isAssembling = true
        assembleProgress = 0

        // Eine noch laufende Montage (frühere Sitzung) ist überholt.
        assembleTask?.cancel()
        assembleTask = Task {
            // Erst alle ausgelösten Bilder ablegen lassen – sie werden im
            // Hintergrund kodiert, das letzte könnte sonst fehlen.
            await controller.flushCaptures()
            lastSessionFiles = sessionFiles
            let urls = store.frameURLs(for: store.projects.first(where: { $0.id == project.id }) ?? project)
            do {
                let url = try await StopMotionAssembler().assemble(
                    imageURLs: urls, settings: PipelineSettings.restored()
                ) { p in Task { @MainActor in assembleProgress = p } }
                guard !Task.isCancelled else { return }
                await MainActor.run { resultURL = url; isAssembling = false }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    resultError = String(localized: "Das hat leider nicht geklappt.")
                    isAssembling = false
                }
            }
        }
    }

    private func resultView(project: Project) -> some View {
        let count = store.projects.first(where: { $0.id == project.id })?.frameCount ?? 0
        let seconds = secondsText(count)
        return VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 6) {
                // Tolino spricht Katalog: Blätter statt Bilder, Serie statt Zähler
                // Alle drei Zweige ausdrücklich über String(localized:) —
                // mischt man hier String und Literal, wählt Swift den
                // nicht-lokalisierenden Text(String) und die Literale
                // verschwinden aus dem Katalog.
                Text(verbatim: mode == .basic
                        ? String(localized: "Fertig! \(count) Bilder")
                        : mode == .tolino
                            ? (count == 1 ? String(localized: "Ein Blatt")
                                          : String(format: String(localized: "Blatt 01 – %02d"), count))
                            : String(localized: "\(count) Bilder aufgenommen"))
                    .font(Theme.serifItalic(24))
                    .foregroundStyle(Theme.paperOnDark)
                CatalogLabel(verbatim: mode == .tolino
                    ? String(localized: "Serie von \(count) · datiert \(String(Calendar.current.component(.year, from: Date()))) · Schleife")
                    : String(localized: "\(seconds) Sekunden · läuft in Schleife"),
                             color: Theme.paperOnDark.opacity(0.7), size: 10)
            }
            .padding(.bottom, 16)

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
                             color: Theme.paperOnDark.opacity(0.65), size: 10)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .sheet(item: $resultShare) { item in ActivityView(items: [item.url]) }
    }

    /// Entfernt die Frames der letzten Session aus dem Werk (wandern in den
    /// 30-Tage-Papierkorb) und startet direkt eine neue Aufnahme.
    private func discardSession(project: Project) {
        if let current = store.projects.first(where: { $0.id == project.id }),
           !lastSessionFiles.isEmpty {
            store.removeFrames(named: lastSessionFiles, from: current)
        }
        resultURL = nil
        lastSessionFiles = []
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
                             color: Theme.paperOnDark.opacity(0.7), size: 10)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.paperOnDark.opacity(0.65))
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
        Group {
            if Platform.isMac, mode.showsAdvanced {
                // Profi-Arbeitsfläche: Betrachter, Zeitleiste, Inspektor
                StudioView(controller: controller, projectID: project.id,
                           onFinish: { finishSession(project: project) },
                           onUndo: { undoLastFrame(project: project) })
            } else if Platform.isMac {
                macCaptureView(project: project)
            } else if Duo.canArrange, horizontalSizeClass == .regular {
                // iPhone Duo aufgeklappt (iOS 27.1): Das System ordnet Kamera
                // und Film um den Falz an. Quer liegen sie nebeneinander wie
                // ein aufgeschlagenes Heft; hochkant steht die Kamera allein,
                // der Film läuft dann als Kachel im Sucher.
                FoldArrangement {
                    GeometryReader { stage in
                        captureStage(project: project, size: stage.size)
                            .overlay(alignment: .topLeading) { sucherTools }
                            .overlay(alignment: .topTrailing) { if !filmPageVisible { loopTile } }
                    }
                } secondary: {
                    filmPage
                        .onAppear { filmPageVisible = true }
                        .onDisappear { filmPageVisible = false }
                }
            } else {
                GeometryReader { geo in
                    // Ohne diese Schnittstelle (iPhone Mirroring, ältere
                    // Systeme) teilt die eigene Rechnung eine breite Fläche
                    // in der Mitte: links die Kamera, rechts der Film bisher.
                    let split = Self.splitsLikeABook(geo.size)
                    let windowWidth = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
                    let stageWidth = split
                        ? max(geo.size.width * 0.4, windowWidth / 2 - geo.safeAreaInsets.leading)
                        : geo.size.width
                    HStack(spacing: 0) {
                        captureStage(project: project, size: CGSize(width: stageWidth, height: geo.size.height),
                                     trailingBleed: split ? 0 : geo.safeAreaInsets.trailing)
                            .overlay(alignment: .topLeading) { sucherTools }
                            .overlay(alignment: .topTrailing) { if !split { loopTile } }
                        if split {
                            filmPage
                                .frame(width: geo.size.width - stageWidth, height: geo.size.height)
                        }
                    }
                }
            }
        }
        // Außendisplay des iPhone Duo: zeigt zum Tisch hin den bisherigen Film.
        .duoOuterDisplay(isOn: $outerDisplayOn, available: $outerDisplayAvailable) {
            OuterDisplayFilm(controller: controller, playful: mode == .basic)
        }
        #if targetEnvironment(simulator)
        // Der Simulator hat keine Kamera, das System zeigt dort nie etwas
        // außen. Mit FF_OUTER_PREVIEW lässt sich der Inhalt trotzdem ansehen.
        .overlay {
            if ProcessInfo.processInfo.environment["FF_OUTER_PREVIEW"] == "1" {
                OuterDisplayFilm(controller: controller, playful: mode == .basic)
            }
        }
        #endif
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Am Mac wirkt der Idle-Timer nicht – dort hält eine Aktivität
            // Bildschirm und Rechner während der Aufnahme wach.
            SessionWakeLock.shared.begin()
            recentThumbs = []
            sessionFiles = []
            level.start()
            // Startwert einspeisen: `onChange` feuert nur bei einem Wechsel,
            // ein von Anfang an gehaltenes iPhone bliebe sonst als „Stativ"
            // eingestuft.
            controller.noteDeviceIsMounted(level.looksMounted)
            // Studio-Monitor: externer Bildschirm zeigt ab jetzt dieses Werk
            StudioMonitorHub.shared.register(controller, projectName: project.name)
            // Watch als Fernauslöser: löst aus, ohne das Stativ zu berühren
            WatchLink.shared.onShutter = { controller.captureNow() }
            WatchLink.shared.onFinish = { finishSession(project: project) }
            WatchLink.shared.push(count: controller.capturedCount,
                                  projectName: project.name,
                                  status: controller.status.label(playful: mode == .basic))
            controller.start { jpegData in
                // „Neu aufnehmen“: ersetzen statt anhängen, dann zurück ins Werk
                if let target = RetakeFrame.active, target.project == project.id {
                    RetakeFrame.active = nil
                    guard let current = store.projects.first(where: { $0.id == project.id }),
                          store.replaceFrame(named: target.filename, jpegData: jpegData, in: current) != nil else {
                        controller.reportSaveFailure(previous: recentThumbs.last)
                        endRetake(openWork: nil)
                        return
                    }
                    endRetake(openWork: project.id)
                    return
                }
                guard let current = store.projects.first(where: { $0.id == project.id }),
                      let filename = store.appendFrame(jpegData: jpegData, to: current) else {
                    // Nicht gespeichert (Speicher voll?): Zähler und Film
                    // zurücknehmen und es sagen, statt still Bilder zu verlieren.
                    controller.reportSaveFailure(previous: recentThumbs.last)
                    return
                }
                sessionFiles.append(filename)
                if let image = UIImage(data: jpegData) {
                    // Klein rechnen: Vollauflösung im Daumenkino zwingt SwiftUI,
                    // bei jedem Update sechs 1080p-Bilder zu skalieren.
                    // Seitenverhältnis bleibt – der Streifen schneidet selbst zu.
                    let thumb = image.scaledToFit(maxSide: 176)
                    recentThumbs.append(thumb)
                    if recentThumbs.count > 6 { recentThumbs.removeFirst() }
                }
            }
        }
        // Der Bewegungssensor entscheidet, ob das iPhone steht oder gehalten
        // wird – und damit, ob der Fokus fixiert werden darf. Am Stativ ist
        // ein fester Fokus das Beste, aus der Hand wäre er nach ein paar
        // Sekunden zwangsläufig falsch.
        .onChange(of: level.looksMounted) { _, mounted in
            controller.noteDeviceIsMounted(mounted)
        }
.onChange(of: controller.capturedCount) { old, new in
            // VoiceOver: Wer nicht aufs Display schaut, hört die Auslösung.
            if new > old {
                AccessibilityNotification.Announcement(String(localized: "Bild \(new) aufgenommen")).post()
            }
        }
        .onChange(of: controller.focusHint) { _, hint in
            if let hint { AccessibilityNotification.Announcement(hint).post() }
        }
        .onChange(of: controller.hint) { _, hint in
            if let hint { AccessibilityNotification.Announcement(hint).post() }
        }
        .onChange(of: controller.cameraShifted) { _, shifted in
            if shifted {
                AccessibilityNotification.Announcement(String(localized: "Kamera verrutscht? Der Hintergrund liegt anders als beim ersten Bild.")).post()
            }
        }
                .onReceive(NotificationCenter.default.publisher(for: .ffFinishSession)) { _ in
            finishSession(project: project)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffUndoLastFrame)) { _ in
            undoLastFrame(project: project)
        }
        // Menü „Aufnahme → Auslösen“ bzw. „Bild ab“ einer Fernbedienung –
        // nur, solange der Sucher läuft.
        .onReceive(NotificationCenter.default.publisher(for: .ffCaptureNow)) { _ in
            if controller.isRunning { controller.captureNow() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            SessionWakeLock.shared.end()
            // Den Ersetzen-Modus hier NICHT beenden: Beim Wechsel in den Modus
            // tauscht SwiftUI die Ansicht aus und meldet dabei auch ein
            // Verschwinden. Er endet beim Ersetzen, bei „Abbrechen“/„Fertig“;
            // wer den Tab verlässt, findet beim Zurückkommen den Hinweis vor.
            // Tab gewechselt, während Bilder im Sucher stehen: die Sitzung
            // abschließen statt sie stillschweigend zurückzusetzen. Zurück im
            // Kamera-Tab wartet dann das Ergebnis mit „Weiter aufnehmen".
            if targetProject?.id == project.id, controller.capturedCount > 0 {
                finishSession(project: project)
            } else {
                controller.stop()
                level.stop()
            }
            StudioMonitorHub.shared.unregister(controller)
            WatchLink.shared.onShutter = nil
            WatchLink.shared.onFinish = nil
            WatchLink.shared.pushSessionEnded()
        }
        .onChange(of: controller.capturedCount) { _, count in
            WatchLink.shared.push(count: count, projectName: project.name,
                                  status: controller.status.label(playful: mode == .basic))
        }
        .onChange(of: controller.status) { _, status in
            // Ohne diesen Kanal stünde am Handgelenk dauerhaft „Bild
            // aufgenommen", weil der Zähler-Kanal immer denselben Moment trifft.
            WatchLink.shared.push(count: controller.capturedCount,
                                  projectName: project.name,
                                  status: status.label(playful: mode == .basic))
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
            if mode == .basic, new % filmFPS == 0, !reduceMotion {
                celebratePulse = 1.22
                withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) {
                    celebratePulse = 1.0
                }
            }
        }
    }

    /// Ab wann die Fläche geteilt wird: deutlich breiter als hoch und breit
    /// genug, dass beide Seiten ein Hochformat-Bild tragen.
    static func splitsLikeABook(_ size: CGSize) -> Bool {
        size.width >= 700 && size.width > size.height * 1.15
    }

    /// Die Kamera-Seite: Kamerabild, darüber Status und Bedienung.
    ///
    /// `trailingBleed`: so weit läuft das Kamerabild rechts über die Seite
    /// hinaus – unter die senkrechte Leiste des zugeklappten iPhone Duo. Die
    /// Bedienung bleibt innerhalb der Seite.
    private func captureStage(project: Project, size: CGSize, trailingBleed: CGFloat = 0) -> some View {
        // Liegt die Kamera-Seite quer (halb aufgeklapptes Duo, obere Hälfte),
        // würde das hochkante Kamerabild beim Füllen oben und unten mehr als
        // die Hälfte verlieren – man sähe nicht mehr, was aufgenommen wird.
        // Dann steht das Bild vollständig in der Mitte, im Verhältnis 3:4.
        // Am Mac zeigt die Vorschau ohnehin das ganze Bild (Querformat der
        // USB-Kamera) – dort keine 3:4-Box.
        let landscapePage = !Platform.isMac && size.width > size.height
        let cameraSize = landscapePage
            ? CGSize(width: size.height * 0.75, height: size.height)
            : CGSize(width: size.width + trailingBleed, height: size.height)
        return AnyView(ZStack(alignment: .bottom) {
            // Aufnahme-Blitz über dem Kamerabild, unter der Bedienung
            if flashOpacity > 0 {
                Color.white.opacity(flashOpacity)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }

            stageControls(project: project, width: size.width)
        }
        // Unten ausrichten: Seit das Kamerabild nicht mehr im Stapel liegt,
        // bestimmt allein die Bedienung seine Höhe.
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .clipped()
        // Das Kamerabild liegt als Hintergrund hinter der Seite statt in ihr:
        // So kann es über den Rand hinauslaufen, ohne dass die Bedienung
        // mitwandert. Feste Größe und eigener Beschnitt bleiben – sonst macht
        // scaledToFill das Bild breiter als den Bildschirm.
        .background(alignment: landscapePage ? .center : .leading) {
            cameraLayer
                .frame(width: cameraSize.width, height: cameraSize.height)
                .clipped()
                // Kopfhörer-/AirPods-Tasten und BT-Fernbedienungen lösen aus,
                // ohne das Stativ zu berühren.
                .background(HardwareShutterBridge { controller.captureNow() })
        })
    }

    /// Am Mac: oben Kamera und Film als zwei gleich hohe Seiten, darunter die
    /// Bedienung über die ganze Breite – ohne Leerfläche unter dem Film und
    /// ohne dass etwas über dem Werk liegt. Das Querformat der
    /// Dokumentenkamera passt ganz auf die Seite.
    private func macCaptureView(project: Project) -> some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width / 2
            let pageHeight = (pageWidth - 40) * 9 / 16 + 62   // Bild + Beschriftung + Ränder
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        CatalogLabel("Kamera", color: Theme.paperOnDark.opacity(0.7))
                        cameraLayer
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay {
                                if flashOpacity > 0 {
                                    Color.white.opacity(flashOpacity).allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .topLeading) { sucherTools }
                    }
                    .padding(20)
                    .frame(width: pageWidth, height: pageHeight, alignment: .top)
                    filmPage
                        .frame(width: pageWidth, height: pageHeight, alignment: .top)
                }
                // Bedienung als ruhige Mitte, „Fertig" nicht am Fensterrand
                stageControls(project: project, width: min(620, geo.size.width))
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    /// Status und Bedienung der Kamera-Seite.
    @ViewBuilder
    private func stageControls(project: Project, width: CGFloat) -> some View {
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

            HStack(spacing: 8) {
                statusBadge
                // Im Einfach-Modus nur zeigen, wenn die App tatsächlich
                // „aus der Hand" erkannt hat – dort ist jedes zusätzliche
                // Bedienelement eines zu viel, aber diese Abweichung
                // erklärt das Verhalten der Kamera.
                // Auch zeigen, sobald die Automatik abgeschaltet ist –
                // sonst verschwindet im Einfach-Modus genau der Knopf,
                // mit dem man gerade auf „Stativ" gestellt hat, und es
                // gibt keinen Weg zurück.
                // Am Mac gibt es keine Aufnahmeart: Die Kamera steht immer.
                if !Platform.isMac,
                   mode.showsAdvanced || controller.rig == .handheld
                    || !controller.rigIsAutomatic {
                    rigBadge
                }
            }

            if let focusHint = controller.focusHint {
                Text(focusHint)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.darkroom)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.amber)
            }

            if let hint = controller.hint {
                // Im Einfach-Modus sind die Einstellungen unerreichbar –
                // der Hinweis, der dorthin verweist, braucht eine einfache
                // Fassung. Alle anderen gelten wörtlich.
                //
                // Hier stand bis zur Lokalisierung `hint.contains("Einstellungen")`.
                // Das ist eine Prüfung auf ein deutsches Wort in einem Text,
                // der übersetzt wird — sie hätte auf Englisch nie mehr
                // gegriffen, ohne dass es auffällt. `hint` trägt ohnehin nur
                // die eine Unruhe-Meldung, die Prüfung war überflüssig.
                Text(verbatim: mode == .basic
                     ? (Platform.isMac
                        ? String(localized: "Zu viel Bewegung – steht die Kamera wirklich fest?")
                        : String(localized: "Zu viel Wackeln – leg das iPhone irgendwo auf oder lehne es an."))
                     : hint)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.darkroom)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.amber)
            }

            if retake != nil {
                retakeBanner(project: project)
            }

            if controller.cameraShifted {
                shiftBanner
            }

            if mode.showsAdvanced, !recentThumbs.isEmpty {
                thumbStrip(project: project)
            }

            controlRow(project: project)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(width: width)
    }

    /// „Kamera verrutscht?“ – der Rand liegt anders als beim ersten Bild.
    /// Das erste Bild einblenden hilft beim Zurückschieben; „Passt so“
    /// übernimmt die neue Position, wenn sie gewollt ist.
    private var shiftBanner: some View {
        VStack(spacing: 8) {
            Text(Platform.isMac
                 ? "Kamera verrutscht? Der Hintergrund liegt anders als beim ersten Bild."
                 : "Stativ verrutscht? Der Hintergrund liegt anders als beim ersten Bild.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.darkroom)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 16) {
                if !(onionSkin && onionFirst) {
                    Button("Erstes Bild einblenden") {
                        onionSkin = true
                        onionFirst = true
                    }
                }
                Button("Passt so") {
                    controller.acceptCameraPosition()
                }
            }
            .font(Theme.mono(11, .semibold))
            .foregroundStyle(Theme.darkroom)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.amber)
        .accessibilityElement(children: .contain)
    }

    /// Werkzeuge oben links im Sucher – erst ab „Erweitert".
    @ViewBuilder
    private var sucherTools: some View {
        // Werkzeuge erst ab „Erweitert"
        if mode.showsAdvanced {
            VStack(spacing: 8) {
                sucherButton("camera.metering.center.weighted",
                             label: Platform.isMac ? "Kamera neu einmessen" : "Kamera neu fixieren") {
                    controller.refixCamera()
                }
                if referenceImage == nil {
                    PhotosPicker(selection: $refPickerItem, matching: .images) {
                        sucherIcon("photo")
                    }
                } else {
                    sucherButton("photo.fill", label: "Vergleichsbild entfernen") { referenceImage = nil }
                }
            }
            .padding(16)
        }
    }

    /// Live-Loop als Kachel im Sucher: Der Film wächst mit jedem Bild – in
    /// jedem Modus, weil genau das der Lohn der Arbeit ist.
    @ViewBuilder
    private var loopTile: some View {
        // Live-Loop: Der Film wächst mit jedem Bild – in jedem Modus,
        // weil genau das der Lohn der Arbeit ist. Antippen vergrößert.
        if controller.loopFrames.count >= 2 {
            Button {
                withAnimation(.snappy(duration: 0.25)) { loopLarge.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    LiveLoopView(frames: controller.loopFrames)
                        .frame(width: loopLarge ? 200 : 88)
                        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.6), lineWidth: 1))
                    CatalogLabel("Der Film bisher", color: Theme.paperOnDark, size: 9)
                }
                .padding(8)
                .background(Theme.darkroom.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel(Text("Der Film bisher"))
            .accessibilityHint(Text("Antippen zum Vergrößern"))
        }
    }

    /// Die Film-Seite im geteilten Sucher: der bisherige Film groß, wie die
    /// rechte Seite eines aufgeschlagenen Hefts.
    private var filmPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogLabel("Der Film bisher", color: Theme.paperOnDark.opacity(0.7))
            if controller.loopFrames.isEmpty {
                Rectangle()
                    .stroke(Theme.paperOnDark.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .aspectRatio(Platform.isMac ? 16.0 / 9.0 : 3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        FoldMark(size: 34, color: Theme.paperOnDark.opacity(0.35))
                    }
            } else {
                LiveLoopView(frames: controller.loopFrames)
                    .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.6), lineWidth: 1))
            }
            if mode.showsAdvanced {
                Text(verbatim: lengthHint)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.6))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Platform.isMac ? .top : .center)
        .background(Theme.darkroom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Der Film bisher"))
    }


    /// Kamerabild samt Überblendungen (Zwiebelhaut, Referenz, Raster, Waage).
    @ViewBuilder
    private var cameraLayer: some View {
        ZStack {
            if Platform.simulatedCamera {
                if let sim = controller.simulatedPreview {
                    Image(uiImage: sim).resizable()
                        .aspectRatio(contentMode: Platform.isMac ? .fit : .fill)
                } else {
                    Theme.darkroom
                }
            } else {
                #if !targetEnvironment(simulator)
                CameraPreview(session: controller.session) { devicePoint in
                    controller.focus(atDevicePoint: devicePoint)
                }
                #endif
            }

            if onionSkin || retakeGhost != nil,
               let ghost = retakeGhost ?? (onionFirst ? controller.firstCapturedImage : controller.lastCapturedImage) {
                Image(uiImage: ghost).resizable().aspectRatio(contentMode: Platform.isMac ? .fit : .fill)
                    .opacity(onionOpacity).allowsHitTesting(false)
            }
            if let referenceImage {
                Image(uiImage: referenceImage).resizable().aspectRatio(contentMode: Platform.isMac ? .fit : .fill)
                    .opacity(onionOpacity * 0.9).allowsHitTesting(false)
            }
            if mode.showsAdvanced, showGrid { ThirdsGrid().allowsHitTesting(false) }
            if mode.showsAdvanced, showLevel, !Platform.isMac {
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
            Button {
                // Nach einem langen Druck läuft der Selbstauslöser – der
                // Tipp beim Loslassen darf dann nicht zusätzlich auslösen.
                if didLongPressShutter { didLongPressShutter = false; return }
                controller.captureNow()
            } label: {
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
                    if let n = controller.selfTimerCount {
                        Text("\(n)")
                            .font(Theme.serif(30, .regular))
                            .foregroundStyle(Theme.darkroom)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy(duration: 0.2), value: n)
                    }
                }
            }
            .simultaneousGesture(
                // Gedrückt halten = Selbstauslöser: das Wackeln vom Antippen
                // des Stativs klingt ab, bevor ausgelöst wird.
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    didLongPressShutter = true
                    controller.startSelfTimer()
                }
            )
            #if targetEnvironment(macCatalyst)
            // Am Mac löst auch die Leertaste aus – ohne die Kamera zu berühren.
            .keyboardShortcut(.space, modifiers: [])
            #endif
            .accessibilityLabel("Auslöser")
            .accessibilityHint("Nimmt sofort ein Bild auf. Sonst löst die Kamera von selbst aus, sobald die Hände aus dem Bild sind.")

            HStack {
                // Einfach-Modus: großes „Ups, weg damit" – das Daumenkino mit
                // dem Zurücknehmen-Knopf gibt es dort nicht.
                if mode == .basic, !sessionFiles.isEmpty {
                    Button { undoLastFrame(project: project) } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Theme.paperOnDark)
                            .frame(width: 48, height: 48)
                            .background(Color.black.opacity(0.35))
                            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.4), lineWidth: 1))
                    }
                    .accessibilityLabel("Letztes Bild zurücknehmen")
                }
                if mode.showsAdvanced {
                    Button { onionSkin.toggle() } label: {
                        Image(systemName: "square.2.layers.3d")
                            .font(.system(size: 17))
                            .foregroundStyle(onionSkin ? Theme.darkroom : Theme.paperOnDark)
                            .frame(width: 48, height: 48)
                            .background(onionSkin ? Theme.paperOnDark : Color.black.opacity(0.35))
                            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.4), lineWidth: 1))
                    }
                    .accessibilityLabel("Zwiebelhaut")
                    .accessibilityValue(onionSkin ? "an" : "aus")
                    .accessibilityHint("Blendet das vorherige Bild halbtransparent über den Sucher.")
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
                        .padding(.horizontal, 16)
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
            Text(verbatim: "\(count) · \(secondsText(count)) s")
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.paperOnDark)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
                CatalogLabel(verbatim: String(format: String(localized: "Blatt %02d · %@ s"), count, secondsText(count)),
                             color: Theme.amberLight, size: 10)
                Spacer()
                if let start = controller.sessionStart {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        CatalogLabel(verbatim: sessionClock(from: start, now: ctx.date),
                                     color: Theme.paperOnDark.opacity(0.8), size: 10)
                    }
                }
                Spacer()
                CatalogLabel(verbatim: controller.exposureInfo ?? "—",
                             color: Theme.paperOnDark.opacity(0.8), size: 10)
            }
            HStack(spacing: 10) {
                MotionGauge(motion: controller.currentMotion,
                            threshold: controller.motionThreshold)
                    .frame(height: 10)
                    .accessibilityHidden(true)
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
                    Text(verbatim: controller.captureMode == .motion
                         ? String(localized: "Auslöser · Bewegung")
                         : String(format: String(localized: "Auslöser · Intervall %.0f s"),
                                  controller.intervalSeconds))
                        .font(Theme.caption(9))
                        .tracking(1.4)
                        .textCase(.uppercase)
                }
                .foregroundStyle(controller.captureMode == .interval
                                 ? Theme.darkroom : Theme.paperOnDark.opacity(0.85))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(controller.captureMode == .interval
                            ? Theme.amberLight : Color.clear)
                .overlay(Rectangle().stroke(
                    controller.captureMode == .interval
                    ? Theme.amberLight : Theme.paperOnDark.opacity(0.35),
                    lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Auslöser umschalten")
                .accessibilityValue(controller.captureMode == .motion
                                    ? String(localized: "Bewegung")
                                    : String(localized: "Intervall, alle \(Int(controller.intervalSeconds.rounded())) Sekunden"))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        // Erst warten, bis das zuletzt ausgelöste Bild abgelegt ist – es wird
        // im Hintergrund kodiert. Sonst träfe das Zurücknehmen das vorletzte.
        Task {
            await controller.flushCaptures()
            removeLastSessionFrame(project: project)
        }
    }

    private func removeLastSessionFrame(project: Project) {
        // Nur Bilder dieser Sitzung – nie eins aus einer früheren.
        guard let filename = sessionFiles.popLast() else { return }
        if let current = store.projects.first(where: { $0.id == project.id }) {
            store.removeFrames(named: [filename], from: current)
        }
        if !recentThumbs.isEmpty { recentThumbs.removeLast() }
        // Zwiebelhaut wieder auf das vorige Bild in voller Größe – vorher
        // zeigte sie danach nur das Briefmarken-Vorschaubild.
        var previous: UIImage? = recentThumbs.last
        if let name = sessionFiles.last,
           let current = store.projects.first(where: { $0.id == project.id }),
           let url = store.frameURLs(for: current).first(where: { $0.lastPathComponent == name }),
           let full = UIImage(contentsOfFile: url.path) {
            previous = full
        }
        controller.revertLastCapture(to: previous)
    }

    private var currentCount: Int {
        guard let project = targetProject else { return 0 }
        return store.projects.first(where: { $0.id == project.id })?.frameCount ?? 0
    }

    /// „48 Bilder · ~4,8 s bei 10 fps" – gibt ein Gefühl für die Werk-Länge.
    private var lengthHint: String {
        // Über den Katalog und mit dem Dezimalzeichen der Sprache – die
        // frühere `String(format:)`-Fassung blieb in jeder Sprache deutsch.
        let seconds = secondsText(currentCount)
        return String(localized: "\(currentCount) Bilder · ~\(seconds) s bei \(filmFPS) fps")
    }

    /// Bilder pro Sekunde des fertigen Films – eingestellt im Video-Tab,
    /// gilt auch für das Ergebnis der Kamera. Der Sucher rechnete früher
    /// fest mit 10 und lag bei anderer Einstellung daneben.
    private var filmFPS: Int { max(1, Int(PipelineSettings.restored().outputFPS)) }

    /// Filmlänge mit dem Dezimalzeichen der Sprache („4,8").
    private func secondsText(_ count: Int) -> String {
        (Double(count) / Double(filmFPS)).formatted(.number.precision(.fractionLength(1)))
    }

    private func sucherIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(Theme.paperOnDark)
            .frame(width: 38, height: 38)
            .background(Theme.darkroom.opacity(0.6))
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
    }

    private func sucherButton(_ name: String, label: LocalizedStringResource,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { sucherIcon(name) }
            .accessibilityLabel(label)
    }

    /// Großer Zähler mit fühlbarem Fortschritt: 10 Bilder = 1 Sekunde Film.
    private var bigCounter: some View {
        let count = controller.capturedCount
        let fps = filmFPS
        let toNext = (fps - (count % fps)) % fps
        return VStack(spacing: 4) {
            Text("\(count)")
                .font(Theme.serif(58, .regular))
                .foregroundStyle(Theme.amberLight)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: count)
                .scaleEffect(celebratePulse)   // federt bei jeder vollen Filmsekunde
            CatalogLabel("Bilder", color: Theme.paperOnDark.opacity(0.85), size: 10)

            if count > 0 {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.paperOnDark.opacity(0.2))
                        .frame(width: 130, height: 3)
                    Rectangle().fill(Theme.amber)
                        .frame(width: 130 * CGFloat(count % fps == 0 ? fps : count % fps) / CGFloat(fps), height: 3)
                }
                .animation(.snappy, value: count)
                Text(toNext == 0
                     ? "\(count / fps) Sekunden Film!"
                     : "noch \(toNext) für eine Sekunde Film")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.85))
            }
        }
        .padding(.bottom, 8)
        // Am iPhone liegt der Zähler auf dem Kamerabild – über hellem Papier
        // wäre Amber unlesbar. Eine dunkle Platte wie beim Status hält ihn
        // lesbar. Am Mac steht er unter dem Bild und braucht sie nicht.
        .padding(.horizontal, Platform.isMac ? 0 : 18)
        .padding(.top, Platform.isMac ? 0 : 8)
        .background(Platform.isMac ? Color.clear : Theme.darkroom.opacity(0.72))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aufgenommene Bilder")
        .accessibilityValue("\(count)")
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
            case .focusing:
                // Amber, weil hier gerade bewusst NICHT ausgelöst wird –
                // das ist der einzige Zustand, der den Nutzer aufhält.
                Image(systemName: "camera.metering.spot").foregroundStyle(Theme.amber)
            default:
                Image(systemName: "eye").foregroundStyle(Theme.paperOnDark.opacity(0.6))
            }
            // Einfach: einen Tick größer – wird oft aus Entfernung gelesen
            CatalogLabel(verbatim: controller.status.label(playful: mode == .basic),
                         color: Theme.paperOnDark,
                         size: mode == .basic ? 12 : 11)
                // Neben dem Aufnahmeart-Feld wird es auf kleinen Geräten eng.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.darkroom.opacity(0.75))
        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.25), lineWidth: 1))
    }

    /// Aufnahmeart – die App erkennt sie am Bewegungssensor, ein Tipp
    /// schaltet um. Steht bewusst neben dem Zustand: Sie entscheidet, ob der
    /// Fokus eingefroren wird, und das erklärt das Verhalten der Kamera.
    private var rigBadge: some View {
        Button {
            controller.setRig(controller.rig == .tripod ? .handheld : .tripod)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: controller.rig == .tripod
                      ? "camera.on.rectangle" : "hand.raised")
                    .font(.system(size: 10, weight: .semibold))
                CatalogLabel(verbatim: controller.rig.shortLabel,
                             color: Theme.paperOnDark, size: 10)
            }
            .foregroundStyle(Theme.paperOnDark.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Theme.darkroom.opacity(0.75))
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.rig == .tripod
                            ? "Aufnahmeart: Stativ. Tippen für aus der Hand."
                            : "Aufnahmeart: aus der Hand. Tippen für Stativ.")
        .accessibilityHint("Am Stativ wird der Fokus fixiert, aus der Hand läuft er mit.")
    }
}
