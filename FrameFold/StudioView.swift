import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Die Profi-Arbeitsfläche am Mac (ab „Erweitert“): großer Betrachter,
/// Zeitleiste mit allen Bildern des Werks, Transport und ein Inspektor für
/// Ansicht, Hilfslinien, Referenz, Aufnahme und Zeitraffer. Die Aufnahme
/// selbst – Automatik, Speichern, Watch, Fernbedienung – bleibt bei
/// `LiveCaptureView`; hier wird nur anders gezeigt und gesteuert.
struct StudioView: View {
    @EnvironmentObject var store: ProjectStore
    @ObservedObject private var shapes = AudioShapeCenter.shared
    @ObservedObject var controller: LiveCaptureController
    let projectID: UUID
    let onFinish: () -> Void
    let onUndo: () -> Void

    @State private var settings = StudioSettings.restored()
    @StateObject private var cache = StudioFrameCache()
    @StateObject private var reference = StudioReference()
    @ObservedObject private var hub = StudioHub.shared

    /// Gezeigtes Bild der Zeitleiste; nil = Live-Bild
    @State private var selected: Int?
    @State private var playing = false
    @State private var playIndex = 0
    @State private var playTask: Task<Void, Never>?
    @State private var loopIn: Int?
    @State private var loopOut: Int?
    /// „Umschalten“: zeigt statt des Live-Bilds das letzte aufgenommene
    @State private var showCaptured = false
    @State private var autoToggle = false
    @State private var autoPhase = false
    @State private var toggleTask: Task<Void, Never>?
    @State private var processed: UIImage?
    @State private var testShots: [UIImage] = []
    @State private var testShown: Int?
    @State private var showReferenceImporter = false
    @State private var noteDraft = ""
    @State private var noteFrame: Int?
    @State private var flash = 0.0
    @State private var audioPlayer = StudioAudioPlayer()
    /// Tonpegel auf der Film-Zeitachse (120 Werte je Sekunde)
    @State private var peaks: [Float] = []
    @State private var showXSheet = false
    @State private var showVoice = false
    @State private var overlayFrame: Int?
    @State private var showInspector = false
    @State private var showSpeech = false
    @State private var importKind: ImportKind = .reference
    @StateObject private var folderWatch = StudioFolderWatch()
    @StateObject private var tether = TetherCamera()
    @StateObject private var lights = LightController()
    /// Gerade verstellte Lichtwerte fürs nächste Bild (nil = aus den Stimmungen)
    @State private var lightDraft: [Int]?
    /// Auslösen (Leertaste, Knopf) löst die per USB verbundene Kamera aus
    @State private var useTether = false
    @State private var volumeDraft: [UUID: Double] = [:]
    /// Bildrate des Films – einmal beim Öffnen gelesen statt bei jedem Zugriff
    @State private var fps: Int32 = max(1, PipelineSettings.restored().outputFPS)

    private enum ImportKind { case reference, audio, folder, background }
    @State private var greenCompositor: GreenScreenCompositor?

    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var urls: [URL] { project.map { store.frameURLs(for: $0) } ?? [] }
    private var audioSources: [AudioSource] { project?.audioSources(fps: fps, store: store) ?? [] }

    // Der Körper ist bewusst in Stücke geteilt: Als eine lange Kette
    // überfordert er den Typprüfer älterer Xcode-Versionen (CI).
    var body: some View {
        withDialogs(withImporter(withLifecycle(layout)))
    }

    /// iPhone: alles untereinander, der Inspektor als eigenes Blatt.
    private var compact: Bool { !Platform.isMac && !Platform.isPad }

    @ViewBuilder
    private var layout: some View {
        if compact {
            VStack(spacing: 0) {
                viewer
                compactTransport
                timeline
            }
            .background(Color.black)
            .background { HardwareShutterBridge { handle(.capture) } }
            .sheet(isPresented: $showInspector) {
                NavigationStack {
                    inspector
                        .background(Theme.darkroom)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { showInspector = false }
                            }
                        }
                }
                .preferredColorScheme(.dark)
                .presentationDetents([.medium, .large])
            }
        } else {
            wideLayout
        }
    }

    /// Transport fürs iPhone: Werkzeuge zum Wischen, darunter groß Auslösen.
    private var compactTransport: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    transportButton("backward.frame", "Bild zurück (←)") { handle(.stepBack) }
                    transportButton(playing ? "stop.fill" : "play.fill", "Abspielen (P)") { handle(.play) }
                    transportButton("goforward", "Kurz abspielen (K)") { handle(.shortPlay) }
                    transportButton("forward.frame", "Bild vor (→)") { handle(.stepForward) }
                    transportButton("record.circle", "Live-Bild (L)", active: showsLive) { handle(.live) }
                    transportButton("arrow.left.arrow.right", "Umschalten (T)", active: showCaptured) { handle(.toggle) }
                    transportButton("repeat", "Auto-Umschalten (⇧T)", active: autoToggle) { handle(.autoToggle) }
                    transportButton("chevron.left.to.line", "Schleifenanfang (I)", active: loopIn != nil) { handle(.loopIn) }
                    transportButton("chevron.right.to.line", "Schleifenende (O)", active: loopOut != nil) { handle(.loopOut) }
                    UndoRedoButtons(tint: Theme.paperOnDark)
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 10) {
                Button { showInspector = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.paperOnDark)
                .accessibilityLabel(Text("Einstellungen"))
                Button { handle(.capture) } label: {
                    Label("Auslösen", systemImage: "circle.inset.filled")
                        .font(Theme.caption(13))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.amber)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Auslöser"))
                Button("Fertig · \(controller.capturedCount)", action: onFinish)
                    .buttonStyle(.plain)
                    .font(Theme.caption(12))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(Theme.paperOnDark)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Theme.darkroom)
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                viewer
                transport
                timeline
            }
            inspector
                .frame(width: Platform.isPad ? 300 : 290)
                .background(Theme.darkroom.opacity(0.92))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.paperOnDark.opacity(0.12)).frame(width: 1)
                }
        }
        .background(Color.black)
        // iPad: Lautstärketasten, Kopfhörer und Bluetooth-Auslöser lösen aus
        .background { if Platform.isPad { HardwareShutterBridge { handle(.capture) } } }
    }

    private func withLifecycle<V: View>(_ content: V) -> some View {
        content
            .onAppear(perform: activate)
            .onDisappear(perform: deactivate)
            .onChange(of: settings) { _, new in
                new.persist()
                apply(new)
            }
            .onChange(of: controller.liveFrame) { _, _ in updateProcessed() }
            .onChange(of: controller.capturedCount) { old, new in
                guard new > old else { return }
                selected = nil
                flash = 0.6
                withAnimation(.easeOut(duration: 0.3)) { flash = 0 }
            }
            .onChange(of: controller.blackoutActive) { _, on in StudioBlackout.set(on) }
            .onChange(of: urls.count) { _, _ in referenceFollow() }
            .onChange(of: selected) { _, _ in referenceFollow() }
            .onChange(of: project?.allAudioTracks) { _, _ in reloadAudio() }
            .onChange(of: shapes.revision) { _, _ in reloadAudio() }
            .onChange(of: project?.frameCount) { _, _ in applyLight() }
            .onChange(of: project?.greenScreen) { _, _ in rebuildGreenScreen() }
            .onReceive(NotificationCenter.default.publisher(for: .ffStudio)) { note in
                if let raw = note.object as? String, let command = StudioCommand(rawValue: raw) { handle(command) }
            }
    }

    private var importTypes: [UTType] {
        switch importKind {
        case .audio: return [.audio]
        case .folder: return [.folder]
        case .reference, .background: return [.image, .movie]
        }
    }

    private func withImporter<V: View>(_ content: V) -> some View {
        content.fileImporter(isPresented: $showReferenceImporter, allowedContentTypes: importTypes) { result in
            guard case .success(let url) = result else { return }
            imported(url)
        }
    }

    private func imported(_ url: URL) {
        switch importKind {
        case .audio:
            if let project { store.addAudioTrack(from: url, startFrame: frameOnViewer ?? 0, to: project) }
        case .folder:
            folderWatch.choose(url)
        case .background:
            store.setGreenScreenBackground(from: url, in: projectID)
        case .reference:
            reference.load(url)
            reference.setKey(settings.referenceKey)
            referenceFollow()
        }
    }

    private var overlayEditorShown: Binding<Bool> {
        Binding(get: { overlayFrame != nil }, set: { if !$0 { overlayFrame = nil } })
    }
    private var noteShown: Binding<Bool> {
        Binding(get: { noteFrame != nil }, set: { if !$0 { noteFrame = nil } })
    }

    private func withDialogs<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $showXSheet) { xSheet }
            .sheet(isPresented: $showVoice) { voiceSheet }
            .sheet(isPresented: overlayEditorShown) { overlayEditor }
            .sheet(isPresented: $showSpeech) {
                SpeechSheet(projectID: projectID, frame: frameOnViewer ?? urls.count) { showSpeech = false }
                    .environmentObject(store)
            }
            .onChange(of: showSpeech) { _, _ in updateHub() }
            .alert(noteTitle, isPresented: noteShown) { noteAlert }
            // Solange ein Dialog offen ist, dürfen einfache Tasten nicht als
            // Befehle gelten.
            .onChange(of: showXSheet) { _, _ in updateHub() }
            .onChange(of: showVoice) { _, _ in updateHub() }
            .onChange(of: overlayFrame) { _, _ in updateHub() }
            .onChange(of: noteFrame) { _, _ in updateHub() }
    }

    private func updateHub() {
        hub.isActive = !showXSheet && !showVoice && !showSpeech && overlayFrame == nil && noteFrame == nil
    }

    private var xSheet: some View {
        XSheetView(projectID: projectID, fps: fps, peaks: peaks,
                   currentFrame: (frameOnViewer ?? urls.count) + 1) { showXSheet = false }
            .environmentObject(store)
    }

    private var voiceSheet: some View {
        VoiceRecordSheet(urls: urls, startFrame: frameOnViewer ?? 0, fps: fps) { url, frame in
            if let url, let project {
                store.addAudioTrack(from: url, startFrame: frame,
                                    name: String(localized: "Stimme \(project.allAudioTracks.count + 1)"), to: project)
            }
            showVoice = false
        }
    }

    @ViewBuilder
    private var overlayEditor: some View {
        if let overlayFrame {
            OverlayEditorView(projectID: projectID, frameIndex: overlayFrame) { self.overlayFrame = nil }
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private var noteAlert: some View {
        TextField("Notiz", text: $noteDraft)
        Button("Sichern") {
            if let noteFrame, let project { store.setNote(noteDraft, forFrame: noteFrame, in: project) }
            noteFrame = nil
        }
        Button("Abbrechen", role: .cancel) { noteFrame = nil }
    }

    private var noteTitle: String {
        String(localized: "Notiz zu Bild \(noteFrame ?? 0)")
    }

    // MARK: Betrachter

    private var viewer: some View {
        GeometryReader { geo in
            let canvas = fit(aspect: controller.frameAspect, in: geo.size)
            ZStack {
                base
                if showsLive { onionLayers }
                if let image = reference.image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(settings.referenceScale)
                        .offset(x: settings.referenceOffsetX * canvas.width,
                                y: settings.referenceOffsetY * canvas.height)
                        .opacity(settings.referenceOpacity)
                        .allowsHitTesting(false)
                }
                // Text, Sprechblasen, Zeichnungen – live für das nächste Bild
                if let overlays = project?.overlays {
                    let index = frameOnViewer ?? urls.count
                    OverlayLayer(overlays: overlays.filter { $0.covers(index) }, folder: project.map { store.folderURL(for: $0) })
                }
                StudioGuides(settings: settings)
                if flash > 0 { Color.white.opacity(flash).allowsHitTesting(false) }
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipped()
            .overlay(alignment: .topLeading) { viewerBadge }
            .overlay(alignment: .top) { noteBanner }
            .overlay(alignment: .bottomLeading) { dialogueHUD }
            .overlay { loupeMarker(canvas: canvas) }
            .overlay(alignment: .topTrailing) { loupeInset }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard settings.loupe, showsLive else { return }
                settings.loupeX = min(1, max(0, value.location.x / canvas.width))
                settings.loupeY = min(1, max(0, value.location.y / canvas.height))
            }.onEnded { _ in
                // Die Lupe zeigt, wo scharfgestellt werden soll – also dort fokussieren
                if settings.loupe, showsLive {
                    controller.focus(atDevicePoint: CGPoint(x: settings.loupeX, y: settings.loupeY))
                }
            }, including: settings.loupe ? .all : .subviews)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color(white: 0.08))
    }

    /// Größtes Rechteck mit `aspect` in `size`.
    private func fit(aspect: Double, in size: CGSize) -> CGSize {
        let a = max(0.1, aspect)
        let inset = CGSize(width: max(1, size.width - 24), height: max(1, size.height - 24))
        return inset.width / inset.height > a
            ? CGSize(width: inset.height * a, height: inset.height)
            : CGSize(width: inset.width, height: inset.width / a)
    }

    /// Greenscreen im Sucher: eingeschaltet, Farbe und Hintergrund gesetzt.
    private var greenPreviewActive: Bool { settings.greenPreview && greenCompositor != nil }

    /// Zeigt der Betrachter gerade das Live-Bild?
    private var showsLive: Bool { frameOnViewer == nil && testShown == nil }

    /// Index des aufgenommenen Bilds, das gerade groß steht (nil = live).
    private var frameOnViewer: Int? {
        if playing { return playIndex }
        if let selected { return selected }
        if (showCaptured || (autoToggle && autoPhase)), !urls.isEmpty { return urls.count - 1 }
        return nil
    }

    @ViewBuilder
    private var base: some View {
        if let testShown, testShots.indices.contains(testShown) {
            Image(uiImage: testShots[testShown]).resizable().scaledToFill()
        } else if let index = frameOnViewer, urls.indices.contains(index) {
            if let image = cache.image(urls[index]) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.black
            }
        } else if settings.viewMode != .normal || greenPreviewActive, let processed {
            Image(uiImage: processed).resizable().scaledToFill()
        } else {
            livePreview
        }
    }

    @ViewBuilder
    private var livePreview: some View {
        if Platform.simulatedCamera {
            if let sim = controller.simulatedPreview {
                Image(uiImage: sim).resizable().scaledToFill()
            } else {
                Color.black
            }
        } else {
            #if !targetEnvironment(simulator)
            CameraPreview(session: controller.session) { point in controller.focus(atDevicePoint: point) }
            #endif
        }
    }

    /// Zwiebelhaut über mehrere Bilder: das jüngste am deutlichsten.
    @ViewBuilder
    private var onionLayers: some View {
        let count = min(settings.onionFrames, urls.count)
        if count > 0, settings.viewMode == .normal {
            ForEach(0..<count, id: \.self) { i in
                let url = urls[urls.count - count + i]
                if let image = cache.image(url) {
                    let weight = Double(i + 1) / Double(count)
                    Image(uiImage: image).resizable().scaledToFill()
                        .opacity(settings.onionOpacity * weight)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var viewerBadge: some View {
        HStack(spacing: 8) {
            Text(verbatim: badgeText)
                .font(Theme.mono(11, .medium))
                .foregroundStyle(showsLive ? Color.black : Theme.paperOnDark)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(showsLive ? Theme.amber : Color.black.opacity(0.6))
            if showsLive {
                Text(verbatim: controller.status.label)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.paperOnDark)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55))
            }
        }
        .padding(10)
    }

    private var badgeText: String {
        if let testShown { return String(localized: "TEST \(testShown + 1)") }
        if let index = frameOnViewer { return String(localized: "BILD \(index + 1) / \(urls.count)") }
        return String(localized: "LIVE · BILD \(urls.count + 1)")
    }

    /// Vergrößerter Ausschnitt des Live-Bilds (aus dem vollen Kamerabild,
    /// nicht hochgerechnet) – zum Prüfen der Schärfe.
    @ViewBuilder
    private var loupeInset: some View {
        if settings.loupe, showsLive, let frame = controller.liveFrame {
            let rect = studioLoupeRect(imageSize: CGSize(width: frame.width, height: frame.height),
                                       center: CGPoint(x: settings.loupeX, y: settings.loupeY),
                                       zoom: settings.loupeZoom, aspect: 16.0 / 10.0)
            if let crop = frame.cropping(to: rect) {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(uiImage: UIImage(cgImage: crop)).resizable().interpolation(.none)
                        .frame(width: 320, height: 200)
                        .overlay(Rectangle().stroke(Theme.amber, lineWidth: 2))
                    Text(verbatim: "LUPE \(settings.loupeZoom)×").font(Theme.mono(10, .bold))
                        .foregroundStyle(Theme.amber)
                }
                .padding(10)
                .allowsHitTesting(false)
            }
        }
    }

    /// Rahmen im Betrachter, wo die Lupe hinschaut.
    @ViewBuilder
    private func loupeMarker(canvas: CGSize) -> some View {
        if settings.loupe, showsLive {
            let w = canvas.width / CGFloat(settings.loupeZoom)
            let h = w / 1.6
            Rectangle().stroke(Theme.amber, lineWidth: 1.5)
                .frame(width: w, height: h)
                .position(x: min(max(w / 2, settings.loupeX * canvas.width), canvas.width - w / 2),
                          y: min(max(h / 2, settings.loupeY * canvas.height), canvas.height - h / 2))
                .allowsHitTesting(false)
        }
    }

    /// Mundformen aller Figuren für das gezeigte Bild – beim Animieren
    /// sieht man, welche Stellung jetzt dran ist.
    @ViewBuilder
    private var dialogueHUD: some View {
        let frame = (frameOnViewer ?? urls.count) + 1
        let current: [(String, DialogueEntry)] = settings.dialogueHUD
            ? (project?.characters ?? []).compactMap { name in
                DialogueReading.current(in: project?.dialogue ?? [], frame: frame, character: name).map { (name, $0) }
            }
            : []
        // Erst zeigen, wenn mindestens eine Figur hier schon eine Mundform hat
        if !current.isEmpty {
            HStack(spacing: 12) {
                ForEach(current, id: \.0) { name, entry in
                    HStack(spacing: 6) {
                        MouthShape(phoneme: entry.phoneme).frame(width: 34, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: name.uppercased()).font(Theme.mono(9, .medium))
                                .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                            Text(verbatim: entry.phoneme.label + (entry.frame == frame ? (entry.word.map { " »\($0)«" } ?? "") : ""))
                                .font(Theme.mono(12, .bold)).foregroundStyle(Theme.amber)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.65))
            .padding(10)
        }
    }

    @ViewBuilder
    private var noteBanner: some View {
        if showsLive, let note = project?.note(forFrame: urls.count + 1) {
            Text(verbatim: note)
                .font(Theme.mono(13, .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.amber)
                .padding(.top, 44)
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Platform.isPad ? 6 : 14) {
            transportButton("backward.frame", "Bild zurück (←)") { handle(.stepBack) }
            transportButton(playing ? "stop.fill" : "play.fill", "Abspielen (P)") { handle(.play) }
            transportButton("goforward", "Kurz abspielen (K)") { handle(.shortPlay) }
            transportButton("forward.frame", "Bild vor (→)") { handle(.stepForward) }
            transportButton("record.circle", "Live-Bild (L)", active: showsLive) { handle(.live) }
            Divider().frame(height: 22).overlay(Theme.paperOnDark.opacity(0.2))
            transportButton("arrow.left.arrow.right", "Umschalten (T)", active: showCaptured) { handle(.toggle) }
            transportButton("repeat", "Auto-Umschalten (⇧T)", active: autoToggle) { handle(.autoToggle) }
            transportButton("chevron.left.to.line", "Schleifenanfang (I)", active: loopIn != nil) { handle(.loopIn) }
            transportButton("chevron.right.to.line", "Schleifenende (O)", active: loopOut != nil) { handle(.loopOut) }
            Divider().frame(height: 22).overlay(Theme.paperOnDark.opacity(0.2))
            UndoRedoButtons(tint: Theme.paperOnDark)
            Spacer()
            Button {
                handle(.capture)
            } label: {
                Label("Auslösen", systemImage: "circle.inset.filled")
                    .font(Theme.caption(12))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.amber)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .help("Auslösen (Leertaste oder ⏎)")
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(Text("Auslöser"))
            // Wie im einfachen Sucher: „Fertig · 3“ zeigt, wie viele Bilder
            // diese Sitzung dazukommen.
            Button("Fertig · \(controller.capturedCount)", action: onFinish)
                .buttonStyle(.plain)
                .font(Theme.caption(12))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.5), lineWidth: 1))
                .foregroundStyle(Theme.paperOnDark)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.darkroom)
    }

    private func transportButton(_ symbol: String, _ help: LocalizedStringKey, active: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Platform.isPad ? 19 : 15, weight: .medium))
                .frame(width: Platform.isPad ? 44 : 30, height: Platform.isPad ? 44 : 26)
                .foregroundStyle(active ? Theme.amber : Theme.paperOnDark)
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }

    // MARK: Zeitleiste

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 3) {
                    ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                        timelineCell(index: index, url: url).id(index)
                    }
                    liveCell.id(-1)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: peaks.isEmpty ? 104 : 120)
            .background(Color(white: 0.06))
            .onChange(of: frameOnViewer) { _, index in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index ?? -1, anchor: .center) }
            }
            .onChange(of: urls.count) { _, _ in proxy.scrollTo(-1, anchor: .trailing) }
            .onAppear { proxy.scrollTo(-1, anchor: .trailing) }
        }
    }

    /// Kacheln im Seitenverhältnis der Kamera – hochkant wie quer.
    private var cellWidth: CGFloat { min(140, max(36, 63 * controller.frameAspect)) }

    private func timelineCell(index: Int, url: URL) -> some View {
        let isShown = frameOnViewer == index
        let inLoop = (loopIn ?? 0) <= index && index <= (loopOut ?? Int.max) && (loopIn != nil || loopOut != nil)
        return VStack(spacing: 3) {
            FrameThumbnail(url: url)
                .frame(width: cellWidth, height: 63)
                .clipped()
                .overlay(Rectangle().stroke(isShown ? Theme.amber : Color.clear, lineWidth: 2))
            if !peaks.isEmpty { waveSlice(index).frame(width: cellWidth, height: 14) }
            HStack(spacing: 4) {
                Text(String(format: "%03d", index + 1))
                    .font(Theme.mono(9, isShown ? .bold : .regular))
                    .foregroundStyle(isShown ? Theme.amber : Theme.paperOnDark.opacity(0.7))
                if project?.note(forFrame: index + 1) != nil {
                    Image(systemName: "text.bubble.fill").font(.system(size: 8)).foregroundStyle(Theme.amber)
                }
            }
            Rectangle().fill(inLoop ? Theme.amber.opacity(0.8) : Color.clear).frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { stopPlayback(); testShown = nil; selected = index }
        .contextMenu {
            Button { stopPlayback(); overlayFrame = index } label: { Label("Text & Zeichnen …", systemImage: "pencil.and.scribble") }
            SoundEffectMenu(projectID: projectID, frame: index) { Label("Geräusch hier", systemImage: "speaker.wave.2") }
            Button { duplicate(index) } label: { Label("Verdoppeln", systemImage: "plus.square.on.square") }
            Menu {
                ForEach([2, 3, 4, 6], id: \.self) { n in
                    Button("\(n) Bilder lang") { hold(index, frames: n) }
                }
            } label: { Label("Halten", systemImage: "pause.rectangle") }
            Button { editNote(index + 1) } label: { Label("Notiz …", systemImage: "text.bubble") }
            Button { loopIn = index } label: { Label("Als Schleifenanfang", systemImage: "chevron.left.to.line") }
            Button { loopOut = index } label: { Label("Als Schleifenende", systemImage: "chevron.right.to.line") }
            Button(role: .destructive) { delete(index) } label: { Label("Bild entfernen", systemImage: "trash") }
        }
        .draggable(url.lastPathComponent) {
            FrameThumbnail(url: url).frame(width: 80, height: 45)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let name = items.first, let project,
                  let from = project.frameFilenames.firstIndex(of: name) else { return false }
            store.moveFrame(named: name, by: index - from, in: project)
            return true
        }
    }

    /// Wellenform genau dieses Bilds (bei der Bildrate des Films).
    private func waveSlice(_ index: Int) -> some View {
        let perFrame = 120.0 / Double(fps)
        let a = Int(Double(index) * perFrame), b = Int(Double(index + 1) * perFrame)
        let slice = a < peaks.count ? Array(peaks[a..<min(max(a, b), peaks.count)]) : []
        return Canvas { ctx, size in
            guard !slice.isEmpty else { return }
            let step = size.width / CGFloat(slice.count)
            var path = Path()
            for (i, v) in slice.enumerated() {
                let h = max(1, CGFloat(v) * size.height)
                path.addRect(CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: max(1, step - 1), height: h))
            }
            ctx.fill(path, with: .color(Theme.amber.opacity(0.75)))
        }
    }

    private var liveCell: some View {
        VStack(spacing: 3) {
            ZStack {
                Rectangle().fill(Color.black)
                Text("LIVE").font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
            }
            .frame(width: cellWidth, height: 63)
            .overlay(Rectangle().stroke(showsLive ? Theme.amber : Theme.paperOnDark.opacity(0.3), lineWidth: 2))
            Text(String(format: "%03d", urls.count + 1))
                .font(Theme.mono(9)).foregroundStyle(Theme.paperOnDark.opacity(0.7))
            Rectangle().fill(Color.clear).frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { handle(.live) }
        .contextMenu {
            Button { editNote(urls.count + 1) } label: { Label("Notiz …", systemImage: "text.bubble") }
        }
    }

    // MARK: Inspektor

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Ansicht") {
                    picker("Modus", $settings.viewMode, StudioViewMode.allCases) { $0.label }
                    stepper("Zwiebelhaut", value: $settings.onionFrames, in: 0...6) { $0 == 0 ? String(localized: "aus") : String(localized: "\($0) Bilder") }
                    slider("Deckkraft", $settings.onionOpacity, 0.1...0.8)
                    toggle("Lupe (Z)", $settings.loupe)
                    if settings.loupe {
                        picker("Vergrößerung", Binding(get: { LoupeZoom(id: settings.loupeZoom) },
                                                      set: { settings.loupeZoom = $0.id }),
                               [2, 4, 8].map(LoupeZoom.init)) { "\($0.id)×" }
                        Text("Im Bild klicken oder ziehen: Lupe setzen und dort scharfstellen.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
                    }
                    stepper("Kurz abspielen", value: $settings.shortPlayFrames, in: 4...48, step: 4) { String(localized: "\($0) Bilder") }
                    stepper("Auto-Umschalten", value: $settings.toggleRate, in: 1...8) { String(localized: "\(Int($0))× pro s") }
                }
                section("Hilfslinien") {
                    picker("Format", $settings.mask, MaskAspect.allCases) { $0.label }
                    if settings.mask != .none { slider("Maske", $settings.maskOpacity, 0.2...1) }
                    toggle("Sicherheitsrahmen", $settings.safeFrames)
                    stepper("Raster Spalten", value: $settings.gridColumns, in: 0...12) { $0 < 2 ? String(localized: "aus") : "\($0)" }
                    stepper("Raster Zeilen", value: $settings.gridRows, in: 0...12) { $0 < 2 ? String(localized: "aus") : "\($0)" }
                }
                section("Referenz") {
                    if let name = reference.name {
                        Text(verbatim: name).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark).lineLimit(1)
                        slider("Deckkraft", $settings.referenceOpacity, 0.05...1)
                        slider("Größe", $settings.referenceScale, 0.2...3)
                        slider("Versatz X", $settings.referenceOffsetX, -0.5...0.5)
                        slider("Versatz Y", $settings.referenceOffsetY, -0.5...0.5)
                        picker("Chroma-Key", $settings.referenceKey, ChromaKey.allCases) { $0.label }
                        HStack {
                            smallButton("Ersetzen …") { importKind = .reference; showReferenceImporter = true }
                            smallButton("Entfernen") { reference.clear() }
                        }
                    } else {
                        smallButton("Bild oder Film laden …") { importKind = .reference; showReferenceImporter = true }
                        Text("Ein Film läuft Bild für Bild mit: Bild n zeigt die Stelle n ÷ Bildrate.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
                    }
                }
                if CameraOptionsPanel.isAvailable || controller.manualCapabilities.any {
                    section("Kamera") { CameraOptionsPanel(controller: controller, dark: true) }
                }
                section("Greenscreen") {
                    picker("Farbe", Binding(get: { project?.greenScreen?.key ?? .none },
                                            set: { store.setGreenScreenKey($0, in: projectID) }),
                           ChromaKey.allCases) { $0.label }
                    if (project?.greenScreen?.key ?? .none) != .none {
                        smallButton(project?.greenScreen?.backgroundFilename == nil ? "Hintergrund …" : "Anderer Hintergrund …") {
                            importKind = .background; showReferenceImporter = true
                        }
                        toggle("Im Sucher zeigen", $settings.greenPreview)
                    }
                    Text("Die Farbe wird beim Export durch den Hintergrund ersetzt – ein Bild oder ein Film, der Bild für Bild mitläuft.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
                }
                if TetherCamera.isSupported { tetherSection }
                lightSection
                section("Kamera-Ordner") {
                    if let name = folderWatch.folderName {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(Theme.amber)
                            Text(verbatim: name).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark).lineLimit(1)
                        }
                        toggle("Beobachten", Binding(get: { folderWatch.isWatching }, set: { on in
                            if on {
                                folderWatch.start { image, data in controller.commit(frame: image, originalData: data) }
                            } else {
                                folderWatch.stop()
                            }
                        }))
                        if folderWatch.isWatching {
                            Text("\(folderWatch.imported) Fotos übernommen").font(Theme.mono(10))
                                .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                        }
                        if let error = folderWatch.lastError {
                            Text(verbatim: error).font(Theme.mono(10)).foregroundStyle(Theme.oxblood)
                        }
                        HStack {
                            smallButton("Anderer Ordner …") { importKind = .folder; showReferenceImporter = true }
                            smallButton("Vergessen") { folderWatch.forget() }
                        }
                    } else {
                        smallButton("Ordner wählen …") { importKind = .folder; showReferenceImporter = true }
                    }
                    Text("Fotos, die die Software deiner Kamera in diesen Ordner legt, werden in voller Auflösung das nächste Bild – auch RAW. Die Automatik am besten ausschalten.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
                }
                section("Aufnahme") {
                    toggle("Automatik (Hände weg)", $settings.autoShutter)
                    ClapTriggerToggle(controller: controller, dark: true)
                    stepper("Mitteln", value: $settings.averageFrames, in: 1...16) { $0 == 1 ? String(localized: "aus") : String(localized: "\($0) Bilder") }
                    toggle("Beim Auslösen abdunkeln", $settings.captureBlackout)
                    HStack {
                        smallButton("Testaufnahme") { handle(.testShot) }
                        if !testShots.isEmpty {
                            smallButton(testShown == nil ? "Test zeigen" : "Live") {
                                testShown = testShown == nil ? testShots.count - 1 : nil
                            }
                        }
                    }
                }
                section("Ton") {
                    if let project {
                        ForEach(project.allAudioTracks) { track in trackRow(track, in: project) }
                    }
                    HStack {
                        smallButton("Tonspur hinzufügen …") { importKind = .audio; showReferenceImporter = true }
                        smallButton("Aufnehmen … (R)") { handle(.record) }
                    }
                    HStack {
                        SoundEffectMenu(projectID: projectID, frame: frameOnViewer ?? urls.count) {
                            Text("Geräusch …").font(Theme.mono(11))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
                                .foregroundStyle(Theme.paperOnDark)
                        }
                        smallButton("Sprechen lassen …") { stopPlayback(); showSpeech = true }
                    }
                    HStack {
                        MusicMenu(projectID: projectID, frame: frameOnViewer ?? 0, fps: fps) {
                            Text("Musik …").font(Theme.mono(11))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
                                .foregroundStyle(Theme.paperOnDark)
                        }
                        smallButton("X-Sheet …") { handle(.xsheet) }
                    }
                    toggle("Ton beim Blättern", $settings.scrubAudio)
                    toggle("Mundformen einblenden", $settings.dialogueHUD)
                }
                section("Zeitraffer") {
                    stepper("Intervall", value: $settings.intervalSeconds, in: 1...3600, step: intervalStep) { Self.durationText($0) }
                    // Bewusst ohne Datumsfelder: In einem Textfeld würden ⌫ und
                    // die Pfeiltasten die Studio-Befehle auslösen.
                    toggle("Später starten", $settings.useStartTime)
                    if settings.useStartTime {
                        stepper("Start in", value: $settings.startDelayMinutes, in: 1...1440,
                                step: settings.startDelayMinutes < 60 ? 1 : 30) { Self.durationText($0 * 60) }
                    }
                    toggle("Begrenzte Dauer", $settings.useEndTime)
                    if settings.useEndTime {
                        stepper("Dauer", value: $settings.durationMinutes, in: 1...10080,
                                step: settings.durationMinutes < 60 ? 5 : 60) { Self.durationText($0 * 60) }
                    }
                    toggle("Höchstzahl", $settings.useFrameLimit)
                    if settings.useFrameLimit {
                        stepper("Bilder", value: $settings.frameLimit, in: 1...10000, step: 10) { "\($0)" }
                    }
                    smallButton(controller.captureMode == .interval ? "Zeitraffer stoppen" : "Zeitraffer starten") {
                        toggleTimelapse()
                    }
                }
                section("Werk") {
                    if let project {
                        Text(verbatim: "\(project.frameCount) · \(project.name)")
                            .font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
                        smallButton("Notiz zum nächsten Bild …") { editNote(urls.count + 1) }
                        if Platform.isMac {
                            smallButton("Bilder im Finder zeigen") {
                                UIApplication.shared.open(store.folderURL(for: project))
                            }
                        }
                        smallButton("Letztes Bild zurücknehmen", action: onUndo)
                    }
                }
            }
            .padding(16)
        }
        .tint(Theme.amber)
    }

    /// Eine Tonspur im Inspektor: Einsatzbild, Lautstärke, stumm, entfernen.
    private func trackRow(_ track: AudioTrack, in project: Project) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: track.muted ? "speaker.slash" : "waveform")
                    .foregroundStyle(track.muted ? Theme.paperOnDark.opacity(0.4) : Theme.amber)
                Text(verbatim: track.name).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark).lineLimit(1)
                Spacer()
                Button { store.updateAudioTrack(id: track.id, in: projectID) { $0.muted.toggle() } } label: {
                    Image(systemName: track.muted ? "speaker.wave.2" : "speaker.slash")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.paperOnDark)
                .help(Text(track.muted ? "Ton an" : "Stumm"))
                Button { store.removeAudioTrack(track, from: project) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.paperOnDark)
                    .help(Text("Spur entfernen"))
            }
            stepper("Ab Bild", value: Binding(get: { track.startFrame + 1 },
                                              set: { frame in store.updateAudioTrack(id: track.id, in: projectID) { $0.startFrame = frame - 1 } }),
                    in: 1...100_000) { "\($0)" }
            // Beim Ziehen nur die Anzeige ändern; gespeichert (und der Ton neu
            // geladen) wird erst beim Loslassen.
            Slider(value: Binding(get: { volumeDraft[track.id] ?? track.volume },
                                  set: { volumeDraft[track.id] = $0 }),
                   in: 0...1.5) { editing in
                guard !editing, let volume = volumeDraft[track.id] else { return }
                store.updateAudioTrack(id: track.id, in: projectID) { $0.volume = volume }
                volumeDraft[track.id] = nil
            }
            clipControls(track)
        }
        .padding(8)
        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.15), lineWidth: 1))
    }

    // MARK: Licht (DMX über Art-Net)

    private var nextFrame: Int { project?.frameCount ?? 0 }

    private var plannedLight: [Int] {
        guard let project else { return [] }
        return ArtNet.values(project.lightCues ?? [], at: nextFrame, channels: lights.channels,
                             fade: project.lightFade == true).map(Int.init)
    }

    private var lightValues: [Int] {
        let base = lightDraft ?? plannedLight
        return (0..<lights.channels).map { $0 < base.count ? base[$0] : 0 }
    }

    /// Licht für das nächste Bild stellen – nach jeder Aufnahme und beim Einschalten.
    private func applyLight() {
        guard lights.enabled else { return }
        lightDraft = nil
        lights.send(plannedLight.map { UInt8($0) })
    }

    private var lightSection: some View {
        section("Licht (DMX)") {
            toggle("Licht über Art-Net steuern", Binding(get: { lights.enabled }, set: { on in
                lights.enabled = on
                if on { applyLight() }
            }))
            if lights.enabled {
                TextField("IP-Adresse des Art-Net-Knotens", text: $lights.host)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                    .autocorrectionDisabled()
                    .onSubmit { applyLight() }
                stepper("Universum", value: $lights.universe, in: 0...32767) { "\($0)" }
                stepper("Kanäle", value: $lights.channels, in: 1...32) { "\($0)" }
                Text("Stimmung für Bild \(nextFrame + 1)").font(Theme.mono(11)).foregroundStyle(Theme.amber)
                ForEach(0..<lights.channels, id: \.self) { channel in
                    HStack {
                        Text("Kanal \(channel + 1)").font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark).frame(width: 64, alignment: .leading)
                        Slider(value: Binding(get: { Double(lightValues[channel]) }, set: { v in
                            var values = lightValues
                            values[channel] = Int(v.rounded())
                            lightDraft = values
                            lights.send(values.map { UInt8($0) })
                        }), in: 0...255)
                        Text(verbatim: "\(lightValues[channel])").font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark).frame(width: 30)
                    }
                }
                HStack {
                    smallButton("Ab diesem Bild speichern") { saveLightCue() }
                    if lightDraft != nil { smallButton("Verwerfen") { applyLight() } }
                }
                if let project {
                    toggle("Zwischen Stimmungen überblenden", Binding(get: { project.lightFade == true }, set: { on in
                        store.setLightCues(project.lightCues ?? [], fade: on, in: projectID)
                    }))
                    ForEach(project.lightCues ?? []) { cue in
                        HStack {
                            Text("Ab Bild \(cue.frame + 1)").font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark)
                            Text(verbatim: cue.values.prefix(8).map(String.init).joined(separator: " "))
                                .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.6)).lineLimit(1)
                            Spacer()
                            Button {
                                store.setLightCues((project.lightCues ?? []).filter { $0.id != cue.id },
                                                   fade: project.lightFade == true, in: projectID)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(Theme.paperOnDark)
                        }
                    }
                }
                if let error = lights.lastError {
                    Text(verbatim: error).font(Theme.mono(10)).foregroundStyle(Theme.oxblood)
                }
            }
            Text("Nur im lokalen Netz und nur, wenn eingeschaltet. Nach jeder Aufnahme stellt FrameFold das Licht für das nächste Bild.")
                .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
        }
    }

    private func saveLightCue() {
        guard let project else { return }
        var cues = (project.lightCues ?? []).filter { $0.frame != nextFrame }
        cues.append(LightCue(frame: nextFrame, values: lightValues))
        store.setLightCues(cues, fade: project.lightFade == true, in: projectID)
        lightDraft = nil
    }

    /// Spiegelreflex per USB: verbinden, dann löst „Auslösen“ die Kamera aus.
    private var tetherSection: some View {
        section("Spiegelreflex (USB)") {
            toggle("Kamera verbinden", Binding(get: { tether.isSearching || tether.isReady }, set: { on in
                if on {
                    tether.start { image, data in controller.commit(frame: image, originalData: data) }
                } else {
                    tether.stop(); useTether = false
                }
            }))
            if let name = tether.cameraName {
                HStack {
                    Image(systemName: "camera").foregroundStyle(Theme.amber)
                    Text(verbatim: name).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark).lineLimit(1)
                }
                if tether.isReady {
                    toggle("Auslösen mit dieser Kamera", $useTether)
                    if !tether.canTakePicture {
                        Text("Diese Kamera meldet kein Auslösen über USB – den Kamera-Ordner nutzen.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.oxblood)
                    }
                    if tether.captured > 0 {
                        Text("\(tether.captured) Fotos übernommen").font(Theme.mono(10))
                            .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                    }
                }
            } else if tether.isSearching {
                Text("Suche Kamera … per USB anschließen und einschalten.").font(Theme.mono(10))
                    .foregroundStyle(Theme.paperOnDark.opacity(0.7))
            }
            if let error = tether.lastError {
                Text(verbatim: error).font(Theme.mono(10)).foregroundStyle(Theme.oxblood)
            }
            Text("Löst die Kamera aus und holt das Foto in voller Auflösung (auch RAW). Ein Livebild liefert macOS dafür nicht – zum Ausrichten das Livebild einer zweiten Kamera oder den Sucher nutzen.")
                .font(Theme.mono(10)).foregroundStyle(Theme.paperOnDark.opacity(0.55))
        }
    }

    /// Kürzen und Blenden einer Spur, in Zehntelsekunden.
    private func clipControls(_ track: AudioTrack) -> some View {
        DisclosureGroup {
            VStack(spacing: 2) {
                stepper("Anfang weglassen", value: clipBinding(track, \.trimStart), in: 0...600, step: 0.1) { Self.seconds($0) }
                stepper("Länge", value: clipBinding(track, \.maxLength), in: 0...600, step: 0.1) {
                    $0 == 0 ? String(localized: "ganz") : Self.seconds($0)
                }
                stepper("Einblenden", value: clipBinding(track, \.fadeIn), in: 0...10, step: 0.1) { Self.seconds($0) }
                stepper("Ausblenden", value: clipBinding(track, \.fadeOut), in: 0...10, step: 0.1) { Self.seconds($0) }
                Picker(selection: Binding(get: { track.voiceEffect?.rawValue ?? "" },
                                          set: { raw in store.updateAudioTrack(id: track.id, in: projectID) { $0.voiceEffect = VoiceEffect(rawValue: raw) } })) {
                    Text("Ohne Effekt").tag("")
                    ForEach(VoiceEffect.allCases) { Text(verbatim: $0.label).tag($0.rawValue) }
                } label: {
                    Text("Stimmeffekt").font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
                }
                .font(Theme.mono(11))
                .id(track.voiceEffect?.rawValue ?? "")
            }
            .padding(.top, 4)
        } label: {
            Text("Kürzen, Blenden, Effekt").font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
        }
        .tint(Theme.paperOnDark)
    }

    private func clipBinding(_ track: AudioTrack, _ key: WritableKeyPath<AudioTrack, Double?>) -> Binding<Double> {
        Binding(get: { track[keyPath: key] ?? 0 },
                set: { value in
                    let rounded = (value * 10).rounded() / 10
                    store.updateAudioTrack(id: track.id, in: projectID) { $0[keyPath: key] = rounded > 0 ? rounded : nil }
                })
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    private var intervalStep: Double {
        settings.intervalSeconds < 10 ? 1 : settings.intervalSeconds < 60 ? 5 : 60
    }

    static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.caption(10)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(Theme.paperOnDark.opacity(0.55))
            content()
        }
    }

    private func picker<T: Hashable & Identifiable>(_ title: LocalizedStringKey, _ value: Binding<T>, _ all: [T],
                                                    label: @escaping (T) -> String) -> some View {
        HStack {
            Text(title).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
            Spacer()
            Picker("", selection: value) {
                ForEach(all) { Text(verbatim: label($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            // Am Mac zeichnet das Auswahlmenü einen von außen gesetzten Wert
            // sonst nicht neu – es bliebe beim Startwert stehen.
            .id(label(value.wrappedValue))
        }
    }

    private func stepper<V: Strideable & Comparable>(_ title: LocalizedStringKey, value: Binding<V>,
                                                     in range: ClosedRange<V>, step: V.Stride = 1,
                                                     text: @escaping (V) -> String) -> some View {
        HStack {
            Text(title).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
            Spacer()
            Text(verbatim: text(value.wrappedValue)).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark.opacity(0.8))
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
            Slider(value: value, in: range)
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title).font(Theme.mono(11)).foregroundStyle(Theme.paperOnDark)
        }
    }

    private func smallButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.mono(11))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
                .foregroundStyle(Theme.paperOnDark)
        }
        .buttonStyle(.plain)
    }

    // MARK: Befehle

    private func handle(_ command: StudioCommand) {
        switch command {
        case .capture:
            stopPlayback()
            selected = nil; testShown = nil
            if useTether, tether.isReady { tether.shoot() } else { controller.captureNow() }
        case .stepBack:
            stopPlayback(); testShown = nil
            selected = StudioPlayback.step(from: frameOnViewer, by: -1, count: urls.count)
            scrub()
        case .stepForward:
            stopPlayback(); testShown = nil
            selected = StudioPlayback.step(from: frameOnViewer, by: 1, count: urls.count)
            scrub()
        case .live:
            stopPlayback(); selected = nil; showCaptured = false; testShown = nil
        case .play:
            if playing { stopPlayback() } else {
                play(StudioPlayback.range(count: urls.count, loopIn: loopIn, loopOut: loopOut), loop: true)
            }
        case .shortPlay:
            play(StudioPlayback.shortRange(count: urls.count, frames: settings.shortPlayFrames), loop: false)
        case .toggle:
            showCaptured.toggle()
        case .autoToggle:
            setAutoToggle(!autoToggle)
        case .loopIn:
            loopIn = frameOnViewer ?? max(0, urls.count - 1)
        case .loopOut:
            loopOut = frameOnViewer ?? max(0, urls.count - 1)
        case .loopClear:
            loopIn = nil; loopOut = nil
        case .duplicate:
            if let index = frameOnViewer { duplicate(index) }
        case .delete:
            if let index = frameOnViewer { delete(index) }
        case .onionMore:
            settings.onionFrames = min(6, settings.onionFrames + 1)
        case .onionLess:
            settings.onionFrames = max(0, settings.onionFrames - 1)
        case .cycleView:
            let all = StudioViewMode.allCases
            settings.viewMode = all[(all.firstIndex(of: settings.viewMode)! + 1) % all.count]
        case .note:
            editNote((frameOnViewer ?? urls.count) + 1)
        case .loupe:
            settings.loupe.toggle()
        case .loupeZoom:
            settings.loupe = true
            settings.loupeZoom = settings.loupeZoom >= 8 ? 2 : settings.loupeZoom * 2
        case .record:
            stopPlayback()
            showVoice = true
        case .xsheet:
            stopPlayback()
            showXSheet = true
        case .testShot:
            if let frame = controller.currentLatestFrame {
                testShots.append(UIImage(cgImage: frame))
                testShown = testShots.count - 1
            }
        }
    }

    private func play(_ range: ClosedRange<Int>?, loop: Bool) {
        stopPlayback()
        guard let range else { return }
        let all = urls
        // Nur das nächste Stück vorladen – das ganze Werk auf einmal
        // belegte alle Kerne und Gigabytes Speicher
        func window(from start: Int) -> [URL] {
            let count = min(range.count, Int(fps) + 4)
            return (0..<count).map { all[range.lowerBound + (start - range.lowerBound + $0) % range.count] }
        }
        cache.preload(window(from: range.lowerBound), replacing: true)
        playing = true
        playIndex = range.lowerBound
        let rate = Double(fps)
        audioPlayer.play(from: Double(range.lowerBound) / rate)
        let interval = UInt64(1_000_000_000 / Double(fps))
        playTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                if playIndex < range.upperBound {
                    playIndex += 1
                    cache.preload(window(from: playIndex))
                } else if loop {
                    playIndex = range.lowerBound
                    audioPlayer.play(from: Double(range.lowerBound) / rate)
                } else {
                    break
                }
            }
            if !Task.isCancelled { playing = false; audioPlayer.stop() }
        }
    }

    private func stopPlayback() {
        playTask?.cancel(); playTask = nil
        playing = false
        audioPlayer.stop()
    }

    /// Ton genau des gezeigten Bilds anspielen.
    private func scrub() {
        guard settings.scrubAudio, !audioSources.isEmpty else { return }
        let frame = frameOnViewer ?? urls.count
        audioPlayer.play(from: Double(frame) / Double(fps), duration: 1 / Double(fps))
    }

    private func reloadAudio() {
        let sources = audioSources
        audioPlayer.load(sources)
        Task.detached(priority: .utility) {
            let combined = Waveform.combined(sources)
            await MainActor.run { peaks = combined }
        }
    }

    private func setAutoToggle(_ on: Bool) {
        autoToggle = on
        toggleTask?.cancel(); toggleTask = nil
        autoPhase = false
        guard on else { return }
        toggleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / max(1, settings.toggleRate)))
                autoPhase.toggle()
            }
        }
    }

    private func duplicate(_ index: Int) {
        guard let project, project.frameFilenames.indices.contains(index) else { return }
        store.duplicateFrame(named: project.frameFilenames[index], in: project)
    }

    private func hold(_ index: Int, frames: Int) {
        guard let project, project.frameFilenames.indices.contains(index) else { return }
        store.holdFrame(named: project.frameFilenames[index], frames: frames, in: project)
    }

    private func delete(_ index: Int) {
        guard let project, project.frameFilenames.indices.contains(index) else { return }
        store.removeFrames(at: IndexSet(integer: index), from: project)
        if let selected, selected >= urls.count { self.selected = urls.isEmpty ? nil : urls.count - 1 }
    }

    private func editNote(_ frame: Int) {
        noteDraft = project?.note(forFrame: frame) ?? ""
        noteFrame = frame
    }

    private func toggleTimelapse() {
        if controller.captureMode == .interval {
            controller.captureMode = .motion
            return
        }
        // Eigener Takt des Studios – der gespeicherte Intervall-Regler der
        // einfachen Kamera (1–30 s) bleibt unberührt.
        controller.intervalOverride = settings.intervalSeconds
        let start = settings.useStartTime ? Date().addingTimeInterval(settings.startDelayMinutes * 60) : Date()
        controller.intervalStartDate = settings.useStartTime ? start : nil
        controller.intervalEndDate = settings.useEndTime ? start.addingTimeInterval(settings.durationMinutes * 60) : nil
        controller.intervalFrameLimit = settings.useFrameLimit ? settings.frameLimit : nil
        controller.captureMode = .interval
    }

    // MARK: Ablauf

    private func activate() {
        hub.isActive = true
        fps = max(1, PipelineSettings.restored().outputFPS)
        #if DEBUG
        debugPreset()
        #endif
        apply(settings)
        cache.preload(Array(urls.suffix(12)))
        reloadAudio()
        rebuildGreenScreen()
    }

    #if DEBUG
    /// Screenshots und Prüfungen ohne Klicks: FF_STUDIO="view=difference,
    /// mask=scope,grid=3x3,safe=1,onion=3,play=1,select=1"
    private func debugPreset() {
        guard let spec = ProcessInfo.processInfo.environment["FF_STUDIO"] else { return }
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=").map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "view": settings.viewMode = StudioViewMode(rawValue: kv[1]) ?? .normal
            case "mask": settings.mask = MaskAspect(rawValue: kv[1]) ?? .none
            case "safe": settings.safeFrames = kv[1] == "1"
            case "onion": settings.onionFrames = Int(kv[1]) ?? 1
            case "grid":
                let g = kv[1].split(separator: "x").compactMap { Int($0) }
                if g.count == 2 { settings.gridColumns = g[0]; settings.gridRows = g[1] }
            case "auto": settings.autoShutter = kv[1] == "1"
            case "average": settings.averageFrames = Int(kv[1]) ?? 1
            case "blackout": settings.captureBlackout = kv[1] == "1"
            case "select": selected = Int(kv[1])
            case "play":
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { handle(.play) }
            case "test":
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { handle(.testShot) }
            case "audio":
                if let project, !(project.audioTracks ?? []).contains(where: { $0.name == "dialog" }) {
                    store.addAudioTrack(from: URL(fileURLWithPath: kv[1]), startFrame: 2, to: project)
                }
            case "dialogue":
                // Beispiel-Dialog ohne Spracherkennung (die fragt um Erlaubnis)
                let words = [TimedWord(text: "Hallo", start: 0.2, duration: 0.6),
                             TimedWord(text: "ich", start: 1.0, duration: 0.3),
                             TimedWord(text: "bin", start: 1.3, duration: 0.3),
                             TimedWord(text: "Papier", start: 1.9, duration: 0.7)]
                if let project {
                    store.replaceDialogue(of: kv[1], with: DialogueReading.entries(
                        for: words, character: kv[1], fps: fps, offsetFrames: 2), in: project)
                }
            case "loupe":
                settings.loupe = kv[1] != "0"
                if let zoom = Int(kv[1]), [2, 4, 8].contains(zoom) { settings.loupeZoom = zoom }
            case "watch":
                folderWatch.choose(URL(fileURLWithPath: kv[1], isDirectory: true))
                folderWatch.start { image, data in controller.commit(frame: image, originalData: data) }
            case "xsheet":
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { handle(.xsheet) }
            case "voice":
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { handle(.record) }
            case "note":
                if let project { store.setNote(kv[1], forFrame: urls.count + 1, in: project) }
            default: break
            }
        }
    }
    #endif

    private func deactivate() {
        hub.isActive = false
        folderWatch.stop()
        tether.stop()
        lights.disconnect()
        stopPlayback()
        setAutoToggle(false)
        StudioBlackout.set(false)
        // Die übrigen Ansichten kennen diese Schalter nicht – zurück auf Standard.
        controller.publishesLiveFrames = false
        controller.averageFrames = 1
        controller.captureBlackout = false
        controller.autoShutter = true
        controller.intervalStartDate = nil
        controller.intervalEndDate = nil
        controller.intervalFrameLimit = nil
        if controller.intervalOverride != nil, controller.captureMode == .interval {
            controller.captureMode = .motion   // Studio-Zeitraffer endet mit dem Studio
        }
        controller.intervalOverride = nil
    }

    private func apply(_ s: StudioSettings) {
        controller.publishesLiveFrames = s.viewMode != .normal || s.loupe || s.greenPreview
        controller.averageFrames = s.averageFrames
        controller.captureBlackout = s.captureBlackout
        controller.autoShutter = s.autoShutter
        reference.setKey(s.referenceKey)
        if s.viewMode == .normal, !s.greenPreview { processed = nil }
    }

    private func referenceFollow() {
        reference.show(frame: frameOnViewer ?? urls.count, fps: fps)
    }

    /// Differenz- oder Belichtungsbild aus dem jüngsten Kamerabild rechnen –
    /// im Hintergrund, damit der Betrachter flüssig bleibt.
    private func rebuildGreenScreen() {
        guard let project, let green = project.greenScreen else { greenCompositor = nil; return }
        greenCompositor = GreenScreenCompositor(key: green.key, background: store.greenScreenBackgroundURL(for: project),
                                                fps: fps)
    }

    private func updateProcessed() {
        guard let live = controller.liveFrame else { return }
        if settings.viewMode == .normal {
            // Greenscreen-Vorschau: das Live-Bild vor dem Hintergrund
            guard greenPreviewActive, let compositor = greenCompositor else { return }
            let index = urls.count
            Task {
                let image = await compositor.composite(live, index: index)
                processed = UIImage(cgImage: image)
            }
            return
        }
        let mode = settings.viewMode
        let against = urls.last.flatMap { cache.image($0)?.cgImage }
        Task.detached(priority: .userInitiated) {
            let image: CGImage?
            switch mode {
            case .difference:
                image = against.flatMap { StudioImaging.difference(live: live, against: $0) } ?? live
            case .clipping:
                image = StudioImaging.clipping(live)
            case .normal:
                image = nil
            }
            await MainActor.run { processed = image.map { UIImage(cgImage: $0) } }
        }
    }
}

/// Bildschirm beim Auslösen abdunkeln: eine schwarze Fläche über dem ganzen
/// Fenster, auch über Tab- und Menüleiste der App.
@MainActor
enum StudioBlackout {
    private static weak var cover: UIView?

    static func set(_ on: Bool) {
        if on {
            guard cover == nil,
                  let window = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            let view = UIView(frame: window.bounds)
            view.backgroundColor = .black
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(view)
            cover = view
        } else {
            cover?.removeFromSuperview()
        }
    }
}

/// Vergrößerungsstufe der Lupe als Auswahl-Element.
private struct LoupeZoom: Hashable, Identifiable {
    let id: Int
}
