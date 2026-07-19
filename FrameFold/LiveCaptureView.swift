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
                    CatalogLabel("Live-Aufnahme", color: Theme.paperOnDark, size: 12)
                }
            }
            .toolbarBackground(Theme.darkroom, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: Projektwahl

    private var projectChooser: some View {
        VStack(spacing: 0) {
            Spacer()
            FoldMark(size: 56, color: Theme.paperOnDark)
                .padding(.bottom, 32)
            CatalogLabel("Wohin sollen die Frames?", color: Theme.paperOnDark)
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

                VStack {
                    Spacer()
                    statusBadge
                        .padding(.bottom, 12)
                }
            }
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.25), lineWidth: 1))
            .padding(16)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    CatalogLabel(project.name, color: Theme.paperOnDark, size: 12)
                    CatalogLabel("\(currentCount) Frames", color: Theme.paperOnDark.opacity(0.6))
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
            controller.start { jpegData in
                if let current = store.projects.first(where: { $0.id == project.id }) {
                    store.appendFrame(jpegData: jpegData, to: current)
                }
            }
        }
        .onDisappear {
            controller.stop()
        }
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
                                 trackColor: Theme.paperOnDark.opacity(0.3),
                                 barColor: Theme.paperOnDark)
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
