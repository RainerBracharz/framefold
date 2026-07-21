import Foundation
import AVFoundation
import CoreImage
import UIKit
import AudioToolbox

/// Threadsichere Analyse-Drossel + CIContext für den Kamera-Thread –
/// bewusst außerhalb des MainActor-Controllers (Xcode 26 verbietet
/// synchronen Zugriff auf MainActor-Statik aus dem Capture-Callback).
private final class CaptureFrameGate: @unchecked Sendable {
    static let shared = CaptureFrameGate()
    let ciContext = CIContext()
    private var lastProcessed = Date.distantPast
    private let lock = NSLock()

    func allow(interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= interval else { return false }
        lastProcessed = now
        return true
    }
}

/// Live-Capture mit Auto-Shutter:
/// iPhone aufs Stativ, Aldo arbeitet – die App nimmt automatisch genau dann
/// einen Frame auf, wenn die Hände aus dem Bild sind und die Szene ruhig ist.
///
/// Zustandsautomat pro Kameraframe (~10 Analysen/s):
///   Bewegung hoch ODER Hände sichtbar  → "arbeitet" (armed = true)
///   danach Szene stabil für N Sekunden → Frame aufnehmen, wenn er sich
///   vom letzten Capture unterscheidet (dHash) → warten auf nächste Aktion
@MainActor
final class LiveCaptureController: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case calibrating          // misst 2 s das Grundrauschen der Szene
        case waitingForWork       // Szene ruhig, aber noch nichts Neues passiert
        case working              // Bewegung/Hände erkannt
        case stabilizing(Double)  // Countdown bis Auto-Shutter (0..1)
        case captured

        var label: String {
            switch self {
            case .idle: return "Kamera startet…"
            case .calibrating: return "Kalibriere – kurz ruhig lassen…"
            case .waitingForWork: return "Bereit – arbeite einfach"
            case .working: return "Arbeit erkannt…"
            case .stabilizing: return "Ruhig halten…"
            case .captured: return "Bild aufgenommen ✓"
            }
        }
    }

    @Published var status: Status = .idle
    @Published var capturedCount = 0
    @Published var lastCapturedImage: UIImage?   // für Onion-Skin
    @Published var permissionDenied = false

    let session = AVCaptureSession()

    /// Sekunden Stabilität bis zum Auto-Shutter (live änderbar)
    @Published var stableSeconds: Double = 0.8
    /// Bewegungsschwelle (mittlere Graustufendifferenz, 0–255; live änderbar)
    @Published var motionThreshold: Double = 2.0
    /// Handprüfung aktiv (live änderbar)
    @Published var checkHands = true
    /// Aktueller Bewegungswert (für den Pegel im Sucher)
    @Published var currentMotion: Double = 0

    private var previousGray: [UInt8]?
    private var stableSince: Date?
    private var armed = false            // erst nach erkannter Arbeit wieder auslösen
    private var latestFrame: CGImage?    // für den manuellen Auslöser
    /// Auto-Kalibrierung: sammelt beim Start ~2 s Bewegungswerte der ruhigen
    /// Szene und setzt die Schwelle auf das Dreifache des Grundrauschens.
    private var calibrationSamples: [Double]? = nil
    private var handDetector: HandDetecting = HandDetectorFactory.make()
    private let videoQueue = DispatchQueue(label: "framefold.livecapture")
    private var onCapture: ((Data) -> Void)?

    // MARK: Lifecycle

    func start(onCapture: @escaping (Data) -> Void) {
        self.onCapture = onCapture
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                self.permissionDenied = true
                return
            }
            self.configureSession()
            Task.detached { [session = self.session] in
                session.startRunning()
            }
            self.status = .calibrating
            self.calibrationSamples = []
            self.armed = false // scharf erst nach der Kalibrierung
        }
    }

    func stop() {
        Task.detached { [session = self.session] in
            session.stopRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    // MARK: Frame-Verarbeitung (auf videoQueue, UI-Updates via MainActor)

    nonisolated private func process(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CaptureFrameGate.shared.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(cgImage, targetWidth: 160)

        Task { @MainActor in
            self.analyze(gray: gray, w: w, h: h, fullFrame: cgImage)
        }
    }

    private func analyze(gray: [UInt8], w: Int, h: Int, fullFrame: CGImage) {
        var motion = 0.0
        let hadPrevious = previousGray != nil
        if let prev = previousGray, prev.count == gray.count {
            motion = Algorithms.motionScore(gray, prev)
        }
        previousGray = gray
        latestFrame = fullFrame
        currentMotion = motion

        // Kalibrierphase: Grundrauschen messen, Schwelle automatisch setzen
        if calibrationSamples != nil {
            status = .calibrating
            if hadPrevious { calibrationSamples?.append(motion) }
            if let samples = calibrationSamples, samples.count >= 20 {
                let median = samples.sorted()[samples.count / 2]
                motionThreshold = min(8.0, max(1.0, (median * 3 * 2).rounded() / 2))
                calibrationSamples = nil
                armed = true // erster Frame darf sofort kommen, sobald stabil
                status = .waitingForWork
            }
            return
        }

        if motion > motionThreshold {
            // Es passiert etwas: scharf stellen auf die nächste Ruhephase
            armed = true
            stableSince = nil
            status = .working
            return
        }

        // Szene ist ruhig
        guard armed else {
            if status != .captured { status = .waitingForWork }
            return
        }

        if stableSince == nil { stableSince = Date() }
        let elapsed = Date().timeIntervalSince(stableSince!)
        status = .stabilizing(min(1.0, elapsed / stableSeconds))
        guard elapsed >= stableSeconds else { return }

        // Stabil genug → Handprüfung (nur jetzt, nicht auf jedem Frame)
        if checkHands, handDetector.containsHands(cgImage: fullFrame, confidence: 0.3) {
            // Hände liegen ruhig im Bild → weiter warten
            stableSince = Date()
            return
        }

        // Capture! Duplikate verhindert bereits der Zustandsautomat:
        // ausgelöst wird nur nach erkannter Bewegung ("armed").
        // (Der frühere dHash-Abgleich hat subtile Änderungen fälschlich
        // als Duplikat verworfen und den Auslöser dauerhaft blockiert.)
        capture(frame: fullFrame)
    }

    /// Manueller Auslöser – nimmt den aktuellen Frame sofort auf,
    /// unabhängig von Bewegung und Handprüfung.
    func captureNow() {
        guard let frame = latestFrame else { return }
        capture(frame: frame)
    }

    /// Nimmt den letzten Frame zurück (Undo im Thumbnail-Streifen).
    func revertLastCapture(to previous: UIImage?) {
        lastCapturedImage = previous
        capturedCount = max(0, capturedCount - 1)
    }

    private func capture(frame: CGImage) {
        armed = false
        stableSince = nil
        capturedCount += 1
        status = .captured

        // Spürbar & hörbar: Aldo schaut aufs Werk, nicht aufs Display
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioServicesPlaySystemSound(1108) // Kamera-Verschluss

        let image = UIImage(cgImage: frame)
        lastCapturedImage = image
        if let data = image.jpegData(compressionQuality: 0.9) {
            onCapture?(data)
        }

        // Status nach kurzer Zeit zurücksetzen
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if self.status == .captured { self.status = .waitingForWork }
        }
    }
}

extension LiveCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Analyse drosseln (~10/s reicht völlig)
        guard CaptureFrameGate.shared.allow(interval: 0.1),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(pixelBuffer: pixelBuffer)
    }
}
