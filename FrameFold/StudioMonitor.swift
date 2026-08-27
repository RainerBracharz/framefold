import SwiftUI
import AVFoundation
import UIKit

/// „FrameFold im Studio": Hängt ein Monitor oder Beamer am iPhone (HDMI-Adapter
/// oder AirPlay), zeigt der externe Bildschirm NUR das Kamerabild mit einer
/// Katalogzeile — ohne Bedienelemente. Die Bedienung bleibt auf dem iPhone,
/// alle im Raum sehen das Werk.
///
/// Ohne laufende Aufnahme zeigt der Monitor einen Galerie-Standby mit Signet —
/// besser als ein gespiegelter Homescreen.
@MainActor
final class StudioMonitorHub: ObservableObject {
    static let shared = StudioMonitorHub()

    /// Die gerade aktive Aufnahme-Session (schwach – der Sucher besitzt sie).
    @Published private(set) var controller: LiveCaptureController?
    /// Name des Werks für die Katalogzeile am Monitor.
    @Published var projectName: String?
    /// Ist gerade ein externer Bildschirm verbunden?
    @Published private(set) var isConnected = false

    private var windows: [String: UIWindow] = [:]
    private var didActivate = false
    private var observers: [NSObjectProtocol] = []

    func register(_ controller: LiveCaptureController, projectName: String?) {
        self.controller = controller
        self.projectName = projectName
    }

    func unregister(_ controller: LiveCaptureController) {
        if self.controller === controller {
            self.controller = nil
            self.projectName = nil
        }
    }

    /// Einmal beim App-Start aufrufen – ab dann kümmert sich der Hub selbst
    /// um auftauchende und verschwindende externe Bildschirme.
    func activate() {
        // Mehrfaches Aufrufen (neue Szene, neu aufgebaute View) würde sonst
        // doppelte Fenster erzeugen.
        guard !didActivate else { return }
        didActivate = true

        // Hängt der Beamer beim App-Start schon dran, ist die Benachrichtigung
        // längst durch – diese Displays müssen wir selbst einsammeln.
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene,
               ws.session.role == .windowExternalDisplayNonInteractive {
                attach(to: ws)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { note in
            Task { @MainActor in
                guard let scene = note.object as? UIWindowScene,
                      scene.session.role == .windowExternalDisplayNonInteractive
                else { return }
                StudioMonitorHub.shared.attach(to: scene)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { note in
            Task { @MainActor in
                guard let scene = note.object as? UIWindowScene else { return }
                StudioMonitorHub.shared.windows
                    .removeValue(forKey: scene.session.persistentIdentifier)
                StudioMonitorHub.shared.isConnected =
                    !StudioMonitorHub.shared.windows.isEmpty
            }
        })
    }

    /// Ein Fenster auf dem externen Bildschirm öffnen.
    private func attach(to scene: UIWindowScene) {
        let id = scene.session.persistentIdentifier
        guard windows[id] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: StudioMonitorView())
        window.isHidden = false
        windows[id] = window
        isConnected = true
    }
}

// MARK: Die Ansicht auf dem Monitor

struct StudioMonitorView: View {
    @ObservedObject private var hub = StudioMonitorHub.shared

    var body: some View {
        ZStack {
            Theme.darkroom.ignoresSafeArea()
            if let controller = hub.controller {
                StudioLiveView(controller: controller, projectName: hub.projectName)
            } else {
                standby
            }
        }
    }

    /// Galerie-Standby: das Signet atmet leise, mehr nicht.
    private var standby: some View {
        VStack(spacing: 22) {
            FoldMark(size: 72, color: Theme.paperOnDark)
            Text("FrameFold")
                .font(Theme.serif(34, .light))
                .foregroundStyle(Theme.paperOnDark)
            CatalogLabel("Studio-Monitor · bereit",
                         color: Theme.paperOnDark.opacity(0.5), size: 12)
        }
    }
}

/// Live-Bild plus Katalogzeile – beobachtet den Aufnahme-Controller direkt,
/// damit der Zähler auf dem Monitor mitläuft.
private struct StudioLiveView: View {
    @ObservedObject var controller: LiveCaptureController
    let projectName: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            #if targetEnvironment(simulator)
            if let preview = controller.simulatedPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #else
            MonitorPreview(session: controller.session)
                .ignoresSafeArea()
            #endif

            // Katalogzeile wie unter einem gehängten Werk
            HStack(spacing: 14) {
                FoldMark(size: 22, color: Theme.paperOnDark)
                if let projectName, !projectName.isEmpty {
                    Text(projectName)
                        .font(Theme.serif(19, .light))
                        .foregroundStyle(Theme.paperOnDark)
                }
                Spacer()
                CatalogLabel(
                    String(format: "Blatt %02d", controller.capturedCount),
                    color: Theme.paperOnDark, size: 13)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Theme.darkroom.opacity(0.85))
        }
    }
}

/// Zweite Vorschau-Ebene derselben Kamera-Session – eine AVCaptureSession
/// kann beliebig viele Preview-Layer speisen.
private struct MonitorPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreview.PreviewView {
        let view = CameraPreview.PreviewView()
        view.videoPreviewLayer.session = session
        // Ganzes Bild zeigen (Balken statt Beschnitt) – am Monitor soll
        // nichts vom Werk fehlen.
        view.videoPreviewLayer.videoGravity = .resizeAspect
        if let conn = view.videoPreviewLayer.connection,
           conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90   // wie im Aufnahmeweg (Hochformat)
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreview.PreviewView, context: Context) {
        // Wechselt die Session (zweite Aufnahme), muss der Layer nachziehen.
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
}
