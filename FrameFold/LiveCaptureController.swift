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

        var label: String { label(playful: false) }

        /// Im Einfach-Modus spricht die App wie ein Werkstatt-Kollege,
        /// in den anderen Modi im Katalogton.
        func label(playful: Bool) -> String {
            switch self {
            case .idle:
                return playful ? "Gleich geht's los…" : "Kamera startet…"
            case .calibrating:
                return playful ? "Halt kurz still…" : "Kalibriere – kurz ruhig lassen…"
            case .waitingForWork:
                return playful ? "Los — ich schau zu" : "Bereit – arbeite einfach"
            case .working:
                return playful ? "Ich warte, bis du weg bist…" : "Arbeit erkannt…"
            case .stabilizing:
                return playful ? "Nicht bewegen…" : "Ruhig halten…"
            case .captured:
                return playful ? "Klick!" : "Bild aufgenommen ✓"
            }
        }
    }

    @Published var status: Status = .idle
    @Published var capturedCount = 0
    @Published var lastCapturedImage: UIImage?   // für Onion-Skin
    @Published var permissionDenied = false
    /// Kein Aufnahmegerät vorhanden (z. B. iOS-Simulator oder Gerät ohne Kamera).
    @Published var cameraUnavailable = false
    /// Klartext-Hinweis, wenn der Auslöser aus erkennbarem Grund nicht kommt.
    @Published var hint: String?

    let session = AVCaptureSession()
    /// Aktuelles Aufnahmegerät – zum Fixieren von Belichtung/Fokus/Weißabgleich.
    private var device: AVCaptureDevice?

    /// Sekunden Stabilität bis zum Auto-Shutter (live änderbar)
    @Published var stableSeconds: Double = 0.8
    /// Bewegungsschwelle (mittlere Graustufendifferenz, 0–255; live änderbar)
    @Published var motionThreshold: Double = 2.0
    /// Handprüfung aktiv (live änderbar)
    @Published var checkHands = true
    /// Aktueller Bewegungswert (für den Pegel im Sucher)
    @Published var currentMotion: Double = 0
    /// Nach dem Fixieren: „1/100 s · ISO 32" – Labor-Anzeige im Tolino-Modus.
    @Published var exposureInfo: String?
    /// Beginn der laufenden Session – für die Sitzungsuhr im Labor-HUD.
    @Published var sessionStart: Date?

    // MARK: Aufnahme-Optionen (live änderbar)
    enum CaptureMode: Int, CaseIterable, Identifiable {
        case motion, interval
        var id: Int { rawValue }
        var label: String { self == .motion ? "Bewegung" : "Intervall" }
    }
    /// Auslöser: Bewegung (Auto-Shutter) oder fester Zeittakt.
    @Published var captureMode: CaptureMode = .motion {
        didSet { startIntervalIfNeeded() }
    }
    /// Intervall in Sekunden für den Zeitraffer-Auslöser.
    @Published var intervalSeconds: Double = 3.0
    /// Netzfrequenz für flackerarme Belichtungszeiten (50 Hz / 60 Hz).
    @Published var mainsHz: Int = 50
    /// Auslöse-Ton (Verschlussgeräusch) abspielen.
    @Published var playShutterSound = true
    /// Erster Frame der Session – als Drift-Referenz im Onion-Skin.
    @Published var firstCapturedImage: UIImage?

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
    private var intervalTask: Task<Void, Never>?
    private var relockTask: Task<Void, Never>?
    /// Beginn der laufenden Kalibrierung – für den Sicherheits-Timeout.
    private var calibrationStart: Date?
    /// Seit wann die Szene ununterbrochen zu unruhig zum Auslösen ist.
    private var restlessSince: Date?
    /// Simulator-Kamera: Task und aktuelles Vorschaubild.
    private var simulatorTask: Task<Void, Never>?
    /// Im Simulator statt des Kamerabilds angezeigt (nil auf echten Geräten).
    @Published var simulatedPreview: UIImage?

    // MARK: Lifecycle

    func start(onCapture: @escaping (Data) -> Void) {
        self.onCapture = onCapture
        cameraUnavailable = false   // jeder Start beginnt unbelastet

        #if targetEnvironment(simulator)
        // Im Simulator gibt es keine Kamera – wir speisen synthetische Frames
        // ein (Ruhephasen + „Hand"-Bewegung), damit der komplette Live-Ablauf
        // testbar ist: Kalibrierung, Auto-Shutter, Zähler, Ergebnis.
        resetSessionState()
        startSimulatedCamera()
        return
        #else
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                self.permissionDenied = true
                return
            }
            guard self.configureSession() else {
                // Kein Aufnahmegerät (Simulator/kameraloses Gerät): klar melden,
                // statt endlos in der Kalibrierung hängenzubleiben.
                self.cameraUnavailable = true
                return
            }
            Task.detached { [session = self.session] in
                session.startRunning()
            }
            self.resetSessionState()
        }
        #endif
    }

    /// Sauberer Start: Reste einer vorherigen Session verwerfen.
    private func resetSessionState() {
        sessionStart = Date()
        exposureInfo = nil
        capturedCount = 0
        // Sonst speichert ein sofortiger Auslöser das letzte Bild der
        // VORHERIGEN Session – und die Zwiebelhaut zeigt das alte Motiv.
        latestFrame = nil
        lastCapturedImage = nil   // Zähler gilt pro Session, nicht pro App-Lauf
        firstCapturedImage = nil
        previousGray = nil
        stableSince = nil
        restlessSince = nil
        currentMotion = 0
        hint = nil
        status = .calibrating
        calibrationSamples = []
        calibrationStart = Date()
        armed = false // scharf erst nach der Kalibrierung
    }

    func stop() {
        intervalTask?.cancel()
        // Ein laufender Selbstauslöser würde sonst NACH dem Beenden noch ein
        // Bild ins bereits montierte Werk legen.
        selfTimerTask?.cancel()
        selfTimerTask = nil
        selfTimerCount = nil
        intervalTask = nil
        relockTask?.cancel()
        relockTask = nil
        simulatorTask?.cancel()
        simulatorTask = nil
        hint = nil
        Task.detached { [session = self.session] in
            session.stopRunning()
        }
    }

    /// Baut die Capture-Session auf. Gibt `false` zurück, wenn kein
    /// Aufnahmegerät verfügbar ist (Simulator/kameraloses Gerät).
    @discardableResult
    private func configureSession() -> Bool {
        // Schon eingerichtet (zweite Session nach „Nochmal"): nicht erneut
        // dieselben Ein-/Ausgänge hinzufügen – das schlug bisher fehl und
        // ließ die App fälschlich „keine Kamera" melden.
        if !session.inputs.isEmpty, !session.outputs.isEmpty { return true }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        self.device = device

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        // Hochformat erzwingen: der Sensor liefert Querformat. Ohne diese
        // Rotation sind Zwiebelhaut, gespeicherte Frames und das fertige
        // Video um 90° gedreht – genau der gemeldete Fehler.
        if let conn = output.connection(with: .video),
           conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        session.commitConfiguration()
        return true
    }

    /// Fixiert Belichtung, Fokus und Weißabgleich für Stop-Motion. Wenn möglich
    /// mit niedriger ISO und entsprechend längerer Belichtungszeit (gleiche
    /// Helligkeit, weniger Rauschen – bei statischem Set unkritisch).
    private func lockCameraSettings() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()

            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }

            let exposure = Double(device.iso) * CMTimeGetSeconds(device.exposureDuration)
            if device.isExposureModeSupported(.custom), exposure > 0 {
                let format = device.activeFormat
                let minISO = format.minISO
                let maxISO = format.maxISO
                let minDur = CMTimeGetSeconds(format.minExposureDuration)
                let maxDur = CMTimeGetSeconds(format.maxExposureDuration)
                // ISO so niedrig wie möglich, die Belichtungszeit hält die Helligkeit
                var duration = max(minDur, min(maxDur, exposure / Double(minISO)))
                // Flacker-Vermeidung: Belichtungszeit auf ein Vielfaches der
                // Netz-Halbwelle runden (1/100 s bei 50 Hz, 1/120 s bei 60 Hz),
                // sonst streifen billige LED-/Leuchtstofflampen einzelne Frames.
                let halfCycle = 1.0 / (2.0 * Double(mainsHz))
                if duration >= halfCycle {
                    duration = max(minDur, min(maxDur, (duration / halfCycle).rounded() * halfCycle))
                }
                var iso = Float(exposure / duration)
                iso = min(maxISO, max(minISO, iso))
                device.setExposureModeCustom(
                    duration: CMTimeMakeWithSeconds(duration, preferredTimescale: 1_000_000),
                    iso: iso, completionHandler: nil)
                exposureInfo = Self.exposureLabel(duration: duration, iso: Double(iso))
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
                exposureInfo = Self.exposureLabel(
                    duration: CMTimeGetSeconds(device.exposureDuration),
                    iso: Double(device.iso))
            }

            device.unlockForConfiguration()
        } catch {
            // Fixieren nicht möglich – die App läuft mit Auto-Einstellungen weiter.
        }
    }

    /// Setzt Belichtung/Fokus/WB zurück auf Automatik und startet die kurze
    /// Kalibrierung neu – danach wird automatisch wieder fixiert. Für den Fall,
    /// dass sich Licht oder Aufbau während der Session geändert haben.
    func refixCamera() {
        relockTask?.cancel()
        resetToContinuous()
        status = .calibrating
        calibrationSamples = []
        calibrationStart = Date()
        restlessSince = nil
        hint = nil
        armed = false
    }

    /// Tippen im Sucher: Fokus- und Belichtungspunkt aufs Werk setzen und die
    /// Kamera neu fixieren. Die Bewegungs-Kalibrierung bleibt bewusst bestehen –
    /// sonst würde jeder Tipp den Auslöser entschärfen.
    func focus(atDevicePoint point: CGPoint) {
        guard let device else { return }
        try? device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
        }
        device.unlockForConfiguration()
        relockCamera()
    }

    /// Belichtung/Fokus/Weißabgleich neu einmessen und wieder fixieren –
    /// ohne die Bewegungs-Kalibrierung zu verwerfen.
    func relockCamera() {
        resetToContinuous()
        relockTask?.cancel()
        relockTask = Task { [weak self] in
            // Automatik einschwingen lassen – aber nicht stur eine feste Zeit:
            // Bei nahen Motiven oder wenig Licht sucht der Autofokus länger,
            // und wer mitten in der Suche einfriert, hat eine unscharfe Session.
            await self?.waitUntilAutoSettles()
            guard let self, !Task.isCancelled else { return }
            self.lockCameraSettings()
        }
    }

    /// Wartet, bis Autofokus und Belichtung wirklich fertig eingeschwungen
    /// sind (mindestens 0,5 s, höchstens 4 s). Erst danach darf fixiert werden.
    private func waitUntilAutoSettles() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let device else { return }
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            // Ohne diese Prüfung liefe die Schleife nach einem Abbruch bis zu
            // vier Sekunden leer auf dem Hauptthread weiter (Task.sleep kehrt
            // dann sofort zurück).
            if Task.isCancelled { return }
            if !device.isAdjustingFocus && !device.isAdjustingExposure {
                // kurz bestätigen – der Fokus meldet zwischen zwei Suchläufen
                // manchmal für einen Moment „fertig"
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !device.isAdjustingFocus && !device.isAdjustingExposure { return }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// „1/100 s · ISO 32" – Belichtungszeit als Bruch, ISO gerundet.
    private static func exposureLabel(duration: Double, iso: Double) -> String {
        let time = duration >= 1
            ? String(format: "%.1f s", duration)
            : "1/\(Int((1.0 / max(duration, 1e-6)).rounded())) s"
        return "\(time) · ISO \(Int(iso.rounded()))"
    }

    /// Belichtung/Fokus/Weißabgleich zurück auf kontinuierliche Automatik.
    private func resetToContinuous() {
        exposureInfo = nil
        guard let device else { return }
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()
    }

    /// Zeitraffer: alle `intervalSeconds` automatisch auslösen (nur im
    /// Intervall-Modus, unabhängig von Bewegung).
    private func startIntervalIfNeeded() {
        intervalTask?.cancel()
        guard captureMode == .interval else { return }
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.intervalSeconds ?? 3.0
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                self.captureNow()
            }
        }
    }

    // MARK: Simulator-Kamera (nur im Simulator einkompiliert)

    #if targetEnvironment(simulator)
    /// Erzeugt 10 Frames/s: ein Papierquadrat wandert in Schritten über den
    /// Tisch, dazwischen fährt eine „Hand" ins Bild. Dieselbe Struktur wie das
    /// Referenz-Testvideo – der Auto-Shutter sollte pro Ruhephase auslösen.
    private func startSimulatedCamera() {
        simulatorTask?.cancel()
        simulatorTask = Task { [weak self] in
            var tick = 0
            let stillFrames = 14        // ~1,4 s Ruhe
            let moveFrames = 6          // ~0,6 s Bewegung
            let cycle = stillFrames + moveFrames
            while !Task.isCancelled {
                guard let self else { return }
                let step = tick / cycle
                let inCycle = tick % cycle
                let moving = inCycle >= stillFrames
                let progress = moving ? Double(inCycle - stillFrames) / Double(moveFrames) : 0
                if let cg = Self.makeSimulatedFrame(step: step, moving: moving, progress: progress) {
                    self.simulatedPreview = UIImage(cgImage: cg)
                    let (gray, w, h) = FrameAnalyzer.grayscaleDownsampled(cg, targetWidth: 160)
                    self.analyze(gray: gray, w: w, h: h, fullFrame: cg)
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Zeichnet einen synthetischen Atelier-Frame (640×360).
    private static func makeSimulatedFrame(step: Int, moving: Bool, progress: Double) -> CGImage? {
        let w = 640, h = 360
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }

        // Tisch
        ctx.setFillColor(red: 0.91, green: 0.86, blue: 0.78, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.69, green: 0.63, blue: 0.55, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 60))

        // Papierquadrat wandert in 8 Schritten
        let positions = (0..<8).map { 40.0 + Double($0) * 70.0 }
        let from = positions[step % positions.count]
        let to = positions[(step + 1) % positions.count]
        let x = moving ? from + (to - from) * progress : from

        ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        ctx.fill(CGRect(x: x, y: 150, width: 80, height: 80))
        ctx.setStrokeColor(red: 0.35, green: 0.33, blue: 0.30, alpha: 1)
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: x, y: 150, width: 80, height: 80))
        ctx.move(to: CGPoint(x: x, y: 150))
        ctx.addLine(to: CGPoint(x: x + 80, y: 230))
        ctx.strokePath()

        // „Hand" nur während der Bewegung
        if moving {
            let hy = 60 + 150 * sin(Double.pi * progress)
            ctx.setFillColor(red: 0.85, green: 0.66, blue: 0.55, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: x + 10, y: hy, width: 70, height: 70))
            ctx.fill(CGRect(x: x + 30, y: 0, width: 34, height: hy))
        }

        // Sensorrauschen, damit die Bewegung nie exakt null ist
        for _ in 0..<220 {
            ctx.setFillColor(red: .random(in: 0...1), green: .random(in: 0...1),
                             blue: .random(in: 0...1), alpha: 0.05)
            ctx.fill(CGRect(x: .random(in: 0...Double(w)), y: .random(in: 0...Double(h)),
                            width: 2, height: 2))
        }
        return ctx.makeImage()
    }
    #endif

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
        // Gerundet und nur bei echter Änderung veröffentlichen – sonst
        // zeichnet SwiftUI den ganzen Sucher zehnmal pro Sekunde neu.
        let rounded = (motion * 10).rounded() / 10
        if abs(rounded - currentMotion) > 0.05 { currentMotion = rounded }

        // Kalibrierphase: Grundrauschen messen, Schwelle automatisch setzen
        if calibrationSamples != nil {
            status = .calibrating
            if hadPrevious { calibrationSamples?.append(motion) }
            // Sicherheits-Timeout: lieber mit weniger Messwerten starten, als
            // ewig in der Kalibrierung hängen zu bleiben.
            let enough = (calibrationSamples?.count ?? 0) >= 20
            let timedOut = calibrationStart.map { Date().timeIntervalSince($0) > 4.0 } ?? false
            if enough || timedOut {
                let samples = (calibrationSamples ?? []).sorted()
                let median = samples.isEmpty ? 1.0 : samples[samples.count / 2]
                motionThreshold = min(8.0, max(1.0, (median * 3 * 2).rounded() / 2))
                calibrationSamples = nil
                calibrationStart = nil
                armed = true // erster Frame darf sofort kommen, sobald stabil
                status = .waitingForWork
                // Für Stop-Motion: Belichtung, Fokus und Weißabgleich jetzt
                // fixieren – die Auto-Regelung würde sonst zwischen den Bildern
                // nachziehen und das Set „atmen" lassen. Aber erst, wenn der
                // Autofokus wirklich fertig ist: sonst friert eine unscharfe
                // Session ein (und die Handerkennung sieht nur noch Matsch).
                relockTask?.cancel()
                relockTask = Task { [weak self] in
                    await self?.waitUntilAutoSettles()
                    guard let self, !Task.isCancelled else { return }
                    self.lockCameraSettings()
                    // Einmal pro App-Leben erklären, wie man nachschärft –
                    // der fixierte Fokus ist sonst nicht zu durchschauen.
                    let key = "didExplainTapFocus"
                    if !UserDefaults.standard.bool(forKey: key) {
                        UserDefaults.standard.set(true, forKey: key)
                        self.hint = "Scharf gestellt und fixiert. Wirkt es unscharf? Tippe im Sucher auf dein Werk."
                        Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            if self?.hint?.hasPrefix("Scharf gestellt") == true { self?.hint = nil }
                        }
                    }
                }
                startIntervalIfNeeded()
            }
            return
        }

        // Intervall-Modus: fester Zeittakt statt Bewegungs-Trigger
        if captureMode == .interval { return }

        if motion > motionThreshold {
            // Es passiert etwas: scharf stellen auf die nächste Ruhephase
            armed = true
            stableSince = nil
            status = .working
            // Bleibt es dauerhaft unruhig, kommt nie ein Auslöser – sagen,
            // woran es liegt, statt den Nutzer raten zu lassen.
            if restlessSince == nil { restlessSince = Date() }
            if Date().timeIntervalSince(restlessSince!) > 6 {
                hint = "Szene wirkt dauerhaft unruhig. Stativ prüfen – oder in den Einstellungen die Bewegungs-Toleranz erhöhen."
            }
            return
        }
        restlessSince = nil
        if hint != nil { hint = nil }

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

    // MARK: Selbstauslöser

    /// Countdown des Selbstauslösers (nil = inaktiv) – wird groß im Sucher
    /// angezeigt, damit man sieht, wann es so weit ist.
    @Published var selfTimerCount: Int?
    private var selfTimerTask: Task<Void, Never>?

    /// Auslöser gedrückt halten: löst nach `seconds` Sekunden aus, wenn das
    /// Wackeln vom Antippen des Stativs abgeklungen ist. Ein zweiter Druck
    /// bricht den Countdown ab.
    func startSelfTimer(seconds: Int = 3) {
        if selfTimerCount != nil {
            selfTimerTask?.cancel()
            selfTimerCount = nil
            return
        }
        selfTimerTask?.cancel()
        selfTimerTask = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                self?.selfTimerCount = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { self?.selfTimerCount = nil; return }
            }
            guard let self, !Task.isCancelled else { return }
            self.selfTimerCount = nil
            self.captureNow()
        }
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
        if playShutterSound {
            AudioServicesPlaySystemSound(1108) // Kamera-Verschluss
        }

        let image = UIImage(cgImage: frame)
        lastCapturedImage = image
        if firstCapturedImage == nil { firstCapturedImage = image } // Drift-Referenz
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
