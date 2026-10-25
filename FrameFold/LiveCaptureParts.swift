import SwiftUI
import AVFoundation
import AVKit   // AVCaptureEventInteraction (Hardware-Fernauslöser)
import UIKit

// Bausteine der Live-Aufnahme: Sucher-Hilfen, Kamerabild, Fernauslöser.

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
        .accessibilityElement()
        .accessibilityLabel(Text("Bewegung im Bild"))
        .accessibilityValue(motion <= threshold ? Text("ruhig") : Text("unruhig"))
    }
}

/// UIKit-Brücke für die Kamera-Vorschau. Tippen setzt Fokus-/Belichtungspunkt.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onFocusTap: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        #if targetEnvironment(macCatalyst)
        // Am Mac liefert die Kamera Querformat in ein frei großes Fenster:
        // ganzes Bild zeigen, sonst fehlt am Rand ein Teil des Tisches.
        view.videoPreviewLayer.videoGravity = .resizeAspect
        #else
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        #endif
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onFocusTap = onFocusTap
        uiView.setNeedsLayout()   // iPad: Drehung anbinden, sobald die Kamera da ist
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
        /// iPad: Die Vorschau folgt der Gerätelage (am iPhone fest Hochformat).
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        override func layoutSubviews() {
            super.layoutSubviews()
            #if !targetEnvironment(macCatalyst)
            // Neu anbinden, wenn die Kamera gewechselt hat (Objektivwahl)
            guard UIDevice.current.userInterfaceIdiom == .pad,
                  let device = (videoPreviewLayer.session?.inputs.first as? AVCaptureDeviceInput)?.device,
                  rotationCoordinator?.device != device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: videoPreviewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: [.initial, .new]) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    guard let conn = self?.videoPreviewLayer.connection,
                          conn.isVideoRotationAngleSupported(angle) else { return }
                    conn.videoRotationAngle = angle
                }
            }
            #endif
        }
    }
}


// MARK: Hardware-Fernauslöser

/// Lautstärketasten, AirPods-Stiel und Bluetooth-Kamerafernbedienungen lösen
/// die Aufnahme aus, ohne das Stativ zu berühren – über Apples offizielle
/// Capture-Event-API (iOS 17.2+). Die unsichtbare View trägt die Interaction.
struct HardwareShutterBridge: UIViewRepresentable {
    let onTrigger: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 17.2, *) {
            let trigger = onTrigger
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { trigger() }
            }
            interaction.isEnabled = true
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Hält den Mac während einer Aufnahme wach (Ruhezustand und Bildschirm-
/// sperre würden die Kamera-Sitzung beenden). Am iPhone ohne Wirkung – dort
/// erledigt das `isIdleTimerDisabled`.
@MainActor
final class SessionWakeLock {
    static let shared = SessionWakeLock()
    private var activity: NSObjectProtocol?

    func begin() {
        #if targetEnvironment(macCatalyst)
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "Stopmotion-Aufnahme läuft")
        #endif
    }

    func end() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Werk, das in der Kamera fortgesetzt werden soll – falls der Kamera-Tab
/// die Nachricht verpasst, weil er noch nie offen war.
@MainActor
enum ContinueWork {
    static var pending: UUID?
}

/// „Neu aufnehmen“ aus dem Kontaktbogen: welches Bild welches Werks das
/// nächste ausgelöste Bild ersetzt. `pending` trägt die Bitte in den
/// Kamera-Tab, `active` gilt, solange der Sucher auf das Bild wartet.
@MainActor
enum RetakeFrame {
    struct Target: Equatable {
        let project: UUID
        let filename: String
    }
    static var pending: Target?
    static var active: Target?
}


