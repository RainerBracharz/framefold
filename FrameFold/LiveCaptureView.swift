import SwiftUI
import AVFoundation

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Theme.paperOnDark)
                    }
                }
            }
            .toolbarBackground(Theme.darkroom, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                LiveSettingsView(controller: controller,
                                 showGrid: $showGrid, showLevel: $showLevel)
            }
            .overlay {
                // Einmaliger, überspringbarer Tipp beim ersten Öffnen
                if !didSeeCameraTip && !controller.permissionDenied {
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

    // MARK: Projektwahl

    private var projectChooser: some View {
        VStack(spacing: 0) {
            Spacer()
            FoldMark(size: 56, color: Theme.paperOnDark)
                .padding(.bottom, 32)
            CatalogLabel("In welches Projekt?", color: Theme.paperOnDark)
                .padding(.bottom, 12)
            Text("iPhone aufs Stativ, Projekt wählen, arbeiten.\nFrameFold nimmt automatisch einen Frame auf,\nsobald deine Hände aus dem Bild sind.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.paperOnDark.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()

            VStack(spacing: 10) {
                ForEach(store.projects.prefix(3)) { project in
                    Button {
                        targetProject = project
                    } label: {
                        HStack {
                            Text(project.name)
                            Spacer()
                            Text("\(project.frameCount)")
                        }
                        .font(Theme.caption(12))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.paperOnDark)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
                    }
                }
                Button {
                    showNewProject = true
                } label: {
                    Text("Neues Projekt")
                        .font(Theme.caption(12))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.darkroom)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.paperOnDark)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
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

    // MARK: Aufnahme

    private func captureView(project: Project) -> some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreview(session: controller.session)

                if onionSkin, let last = controller.lastCapturedImage {
                    Image(uiImage: last)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.35)
                        .allowsHitTesting(false)
                }

                if showGrid { ThirdsGrid().allowsHitTesting(false) }
                if showLevel {
                    BubbleLevel(gx: level.gx, gy: level.gy, isLevel: level.isLevel)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 8) {
                    Spacer()
                    // Bewegungs-Pegel: links ruhig, Markierung = Schwelle.
                    // Man sieht live, warum der Auto-Shutter (nicht) auslöst.
                    MotionGauge(motion: controller.currentMotion,
                                threshold: controller.motionThreshold)
                        .frame(width: 150, height: 10)
                    statusBadge
                        .padding(.bottom, 12)
                }
            }
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Streifen der letzten Frames – letzter ist per ✕ zurücknehmbar
            if !recentThumbs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(recentThumbs.enumerated()), id: \.offset) { index, thumb in
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipped()
                            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
                            .overlay(alignment: .topTrailing) {
                                if index == recentThumbs.count - 1 {
                                    Button {
                                        undoLastFrame(project: project)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.darkroom)
                                            .padding(4)
                                            .background(Theme.paperOnDark)
                                    }
                                }
                            }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    WorkTitle(project.name, size: 16, color: Theme.paperOnDark)
                    CatalogLabel("\(currentCount) Bilder", color: Theme.paperOnDark.opacity(0.6))
                }
                Spacer()
                Button {
                    onionSkin.toggle()
                } label: {
                    Image(systemName: "square.2.layers.3d")
                        .foregroundStyle(onionSkin ? Theme.darkroom : Theme.paperOnDark)
                        .padding(10)
                        .background(onionSkin ? Theme.paperOnDark : .clear)
                        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
                }

                // Manueller Auslöser – nimmt sofort einen Frame,
                // unabhängig vom Auto-Shutter
                Button {
                    controller.captureNow()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Theme.paperOnDark, lineWidth: 2)
                            .frame(width: 54, height: 54)
                        Circle()
                            .fill(Theme.paperOnDark)
                            .frame(width: 42, height: 42)
                    }
                }

                Button {
                    controller.stop()
                    targetProject = nil
                } label: {
                    Text("Fertig")
                        .font(Theme.caption(12))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.darkroom)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(Theme.paperOnDark)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            recentThumbs = []
            level.start()
            controller.start { jpegData in
                if let current = store.projects.first(where: { $0.id == project.id }) {
                    store.appendFrame(jpegData: jpegData, to: current)
                }
                if let image = UIImage(data: jpegData) {
                    recentThumbs.append(image)
                    if recentThumbs.count > 6 { recentThumbs.removeFirst() }
                }
            }
        }
        .onDisappear {
            controller.stop()
            level.stop()
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
            CatalogLabel(controller.status.label, color: Theme.paperOnDark)
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

    var body: some View {
        NavigationStack {
            Form {
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
}

/// UIKit-Brücke für die Kamera-Vorschau.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
