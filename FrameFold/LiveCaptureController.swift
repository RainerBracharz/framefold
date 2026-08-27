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
        case focusing             // Bild noch nicht scharf – es wird nichts gespeichert
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
            case .focusing:
                return playful ? "Moment, wird scharf…" : "Noch nicht scharf…"
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

        /// Zustände, die sofort sichtbar sein müssen: Sie erklären entweder
        /// eine Verzögerung oder quittieren eine Aktion des Nutzers.
        /// `.focusing` gehört bewusst NICHT dazu – es würde sonst im
        /// Wechsel mit `.stabilizing` blinken, während das Tor auf Schärfe
        /// wartet. Es bekommt stattdessen eine Mindesthaltezeit.
        var isUrgent: Bool {
            switch self {
            case .captured, .calibrating, .idle: return true
            default: return false
            }
        }

        /// Vergleich ohne den Fortschrittswert: `.stabilizing(0.2)` und
        /// `.stabilizing(0.9)` sind derselbe Zustand, nur weiter fortgeschritten.
        func sameKind(as other: Status) -> Bool {
            switch (self, other) {
            case (.idle, .idle), (.calibrating, .calibrating),
                 (.focusing, .focusing), (.waitingForWork, .waitingForWork),
                 (.working, .working), (.stabilizing, .stabilizing),
                 (.captured, .captured):
                return true
            default:
                return false
            }
        }
    }

    /// Der im Sucher angezeigte Zustand. Bewusst träger als der interne:
    /// Zwischen „Arbeit erkannt" und „Ruhig halten" wechselt der Automat
    /// mehrmals pro Sekunde, und ein flackernder Text macht das Set unruhig,
    /// ohne irgendetwas zu erklären.
    @Published private(set) var status: Status = .idle

    /// Interner Wahrheitswert – hierauf reagiert die Logik.
    private var rawStatus: Status = .idle
    private var pendingStatus: Status?
    private var pendingSince: Date?
    private var lastStatusChange = Date.distantPast
    /// So lange muss ein neuer Zustand anhalten, bevor er angezeigt wird.
    private static let statusDwell: TimeInterval = 0.35
    /// Nach dieser Zeit wird der interne Zustand auf jeden Fall angezeigt –
    /// sonst könnten zwei schnell wechselnde Zustände (typisch: „arbeitet"
    /// und „ruhig halten", wenn die Bewegung um die Schwelle pendelt) die
    /// Anzeige beliebig lange auf einem veralteten Wert einfrieren.
    private static let statusMaxStale: TimeInterval = 1.2
    /// So lange bleibt „Noch nicht scharf…" mindestens stehen.
    private static let focusingMinHold: TimeInterval = 1.2

    /// Setzt den Zustand und entscheidet, ob er sofort angezeigt werden darf.
    private func setStatus(_ new: Status) {
        rawStatus = new
        // „Noch nicht scharf" erklärt als einziger Zustand, warum gerade
        // nichts gespeichert wird. Es erscheint sofort und bleibt dann eine
        // Weile stehen – sonst sieht der Nutzer nur einen Fortschrittsbalken,
        // der immer wieder bei null anfängt, und erfährt nie, woran es liegt.
        // Bewusst VOR der Gleichheitsprüfung: Jede erneute Blockade muss die
        // Haltezeit verlängern, sonst blinkt es im Sekundentakt doch wieder.
        if new == .focusing {
            publish(new)
            return
        }
        // Fortschritt innerhalb desselben Zustands ungebremst durchreichen,
        // sonst ruckelt der Balken.
        if new.sameKind(as: status) {
            if new != status { status = new }
            pendingStatus = nil
            pendingSince = nil
            return
        }
        if status == .focusing, !new.isUrgent,
           Date().timeIntervalSince(lastStatusChange) < Self.focusingMinHold {
            pendingStatus = new
            pendingSince = Date()
            return
        }
        // Wechsel zu oder von einem dringenden Zustand: sofort.
        if new.isUrgent || status.isUrgent {
            publish(new)
            return
        }
        // Notbremse gegen Einfrieren.
        if Date().timeIntervalSince(lastStatusChange) >= Self.statusMaxStale {
            publish(new)
            return
        }
        guard let pending = pendingStatus, pending.sameKind(as: new) else {
            pendingStatus = new
            pendingSince = Date()
            return
        }
        pendingStatus = new
        if let since = pendingSince, Date().timeIntervalSince(since) >= Self.statusDwell {
            publish(new)
        }
    }

    /// Reicht einen zurückgehaltenen Zustandswechsel nach. Der Dämpfer wird
    /// sonst nur durch den nächsten `setStatus` bewegt – und den gibt es im
    /// Intervallmodus nicht, weil die Analyse dort früher aussteigt. „Noch
    /// nicht scharf" bliebe dann bis zur nächsten Aufnahme stehen.
    private func flushPendingStatus() {
        guard !rawStatus.sameKind(as: status) else { return }
        if status == .focusing,
           Date().timeIntervalSince(lastStatusChange) < Self.focusingMinHold { return }
        let waited = Date().timeIntervalSince(lastStatusChange)
        let held = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        if waited >= Self.statusMaxStale || held >= Self.statusDwell {
            publish(rawStatus)
        }
    }

    private func publish(_ new: Status) {
        // Nur bei echter Änderung zuweisen – eine wiederholte Zuweisung
        // desselben Werts würde SwiftUI grundlos neu zeichnen lassen.
        if status != new { status = new }
        lastStatusChange = Date()
        pendingStatus = nil
        pendingSince = nil
    }
    @Published var capturedCount = 0
    @Published var lastCapturedImage: UIImage?   // für Onion-Skin
    @Published var permissionDenied = false
    /// Kein Aufnahmegerät vorhanden (z. B. iOS-Simulator oder Gerät ohne Kamera).
    @Published var cameraUnavailable = false
    /// Klartext-Hinweis, wenn der Auslöser aus erkennbarem Grund nicht kommt.
    @Published var hint: String?

    /// Hinweise rund um den Fokus. Bewusst getrennt von `hint`: Der wird bei
    /// ruhiger Szene laufend geleert, und genau dann entstehen Fokusmeldungen –
    /// sie wären nie länger als einen Frame zu sehen.
    @Published var focusHint: String? {
        didSet { scheduleFocusHintClear() }
    }
    private var focusHintTask: Task<Void, Never>?

    /// Setzt einen Fokus-Hinweis nur, wenn er nicht ohnehin schon steht.
    /// Sonst würde eine wiederkehrende Meldung (Tor blockiert im
    /// Sekundentakt) den Timer immer wieder neu starten, nie ablaufen und
    /// bei jedem Aufruf den ganzen Sucher neu zeichnen lassen.
    private func setFocusHint(_ text: String) {
        guard focusHint != text else { return }
        focusHint = text
    }

    /// Fokus-Hinweise verschwinden nach acht Sekunden von selbst.
    private func scheduleFocusHintClear() {
        focusHintTask?.cancel()
        guard focusHint != nil else { return }
        focusHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.focusHintTask = nil
            self.focusHint = nil
        }
    }

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

    // MARK: Aufnahmeart

    /// Steht das iPhone (Stativ, Tisch) oder wird es gehalten? Das entscheidet,
    /// ob der Fokus fixiert werden darf. Am Stativ ist ein fester Fokus das
    /// Beste, was man tun kann – aus der Hand ist er falsch, weil sich der
    /// Abstand zum Werk mit jeder Bewegung ändert.
    enum Rig: Int, CaseIterable, Identifiable {
        case tripod, handheld
        var id: Int { rawValue }
        var label: String { self == .tripod ? "Stativ" : "Aus der Hand" }
        var shortLabel: String { self == .tripod ? "STATIV" : "HAND" }
        /// Aufschlag auf die eingestellte Ruhezeit. Aus der Hand darf länger
        /// geruht werden – das Zittern der Hand erzeugt sonst nie ein
        /// sauberes Ruhefenster. Bewusst additiv, damit die Einstellung des
        /// Nutzers erhalten bleibt.
        var extraStableSeconds: Double { self == .tripod ? 0 : 0.4 }
        /// Nur am Stativ wird der Fokus eingefroren.
        var locksFocus: Bool { self == .tripod }
    }

    /// Ruhezeit, die tatsächlich gilt: Einstellung plus Aufschlag der
    /// Aufnahmeart.
    private var effectiveStableSeconds: Double {
        stableSeconds + rig.extraStableSeconds
    }

    @Published private(set) var rig: Rig = .tripod
    /// Solange `true`, folgt die Aufnahmeart dem Bewegungssensor. Sobald der
    /// Nutzer selbst umschaltet, hört die Automatik auf – seine Entscheidung
    /// wiegt schwerer als unsere Messung.
    @Published private(set) var rigIsAutomatic = true
    /// Letzter Stand des Bewegungssensors. `onChange` im Sucher feuert nur bei
    /// einer Flanke – wer die zweite Sitzung im selben Zustand beginnt wie er
    /// die erste beendet hat, bekäme sonst nie eine Meldung.
    private var lastMountedSignal = true
    /// Bis dahin wird die Sensor-Erkennung ignoriert – nach eigener Bedienung.
    /// 2,5 s, weil `MotionLevel` nach einem festen Tipp aufs Stativ selbst
    /// rund zwei Sekunden braucht, bis es wieder „steht" meldet.
    private var suppressRigUntil = Date.distantPast

    /// Holt eine aufgeschobene Sensormeldung nach. Wird aus der Analyse
    /// gepulst, damit eine während der Bedienung verschluckte Flanke nicht
    /// für den Rest der Sitzung verloren ist.
    private func serveRigDetection() {
        guard rigIsAutomatic, Date() >= suppressRigUntil else { return }
        let detected: Rig = lastMountedSignal ? .tripod : .handheld
        guard detected != rig else { return }
        apply(rig: detected)
    }

    /// Wird vom Sucher aus dem Bewegungssensor gespeist.
    func noteDeviceIsMounted(_ mounted: Bool) {
        lastMountedSignal = mounted
        guard rigIsAutomatic else { return }
        // Ein Tipp auf den Sucher oder den Auslöser wackelt am Stativ – das
        // ist Bedienung, keine Aufnahmeart. Ohne diese Sperre bräche genau
        // der Tipp, zu dem die App auffordert („Tippe im Sucher auf dein
        // Werk"), seinen eigenen Fokuslauf ab. Die Meldung wird dabei nur
        // aufgeschoben, nicht verworfen: `serveRigDetection()` holt sie nach.
        // Sie kommt nämlich nur bei einer Flanke – wer das iPhone in genau
        // diesem Moment hochnimmt und in der Hand behält, bekäme sonst nie
        // wieder eine, und der Fokus bliebe auf dem Stativabstand stehen.
        guard Date() >= suppressRigUntil else { return }
        let detected: Rig = mounted ? .tripod : .handheld
        guard detected != rig else { return }
        apply(rig: detected)
    }

    /// Manuelles Umschalten im Sucher.
    func setRig(_ new: Rig) {
        rigIsAutomatic = false
        guard new != rig else { return }
        apply(rig: new)
    }

    private func apply(rig new: Rig) {
        let wasHandheld = rig == .handheld
        rig = new
        if new.locksFocus {
            // Wieder abgestellt: einmal sauber scharfstellen und fixieren.
            // Gedrosselt wie der Wächter – wer sich übers Stativ beugt und es
            // streift, soll die Kamera nicht mehrfach neu einmessen lassen.
            if wasHandheld, calibrationSamples == nil {
                // Die Drossel darf die Fixierung nur verzögern, nicht
                // verschlucken: Wer das Stativ zweimal kurz hintereinander
                // berührt, hätte sonst für den Rest der Sitzung gar keinen
                // fixierten Fokus mehr – und damit auch keinen Wächter.
                pendingRigRelock = true
            }
        } else {
            // In die Hand genommen: Fokus sofort wieder freigeben, sonst
            // bleibt die ganze Sitzung auf dem alten Abstand hängen. Eine
            // offene Bitte zu fixieren ist damit gegenstandslos.
            pendingRigRelock = false
            focusTask?.cancel()
            focusTask = nil
            releaseFocusOnly()
            // Der abgebrochene Task kommt nicht mehr dazu, den Zustand
            // aufzulösen – im Intervallmodus bliebe „Noch nicht scharf"
            // sonst bis zum nächsten Takt stehen.
            if rawStatus == .focusing { setStatus(.waitingForWork) }
        }
    }

    // MARK: Schärfe

    /// Rohwert (Laplace-Varianz) des aktuellen Sucherbilds.
    private var sharpRaw: Double = 0

    /// Messlatte: der beste Schärfewert, der in dieser Sitzung bei ruhiger
    /// Szene gesehen wurde. Steigt sofort, sinkt nur sehr langsam.
    ///
    /// Ein gleitendes Fenster wäre hier der naheliegende, aber falsche
    /// Ansatz: Bleibt das Bild dauerhaft unscharf, fallen die scharfen Werte
    /// nach ein paar Sekunden heraus, die Messlatte sinkt auf den unscharfen
    /// Istwert – und das Schärfe-Tor öffnet sich für genau die Bilder, die es
    /// verhindern soll. Der langsame Zerfall (Halbwertszeit ~35 s) lässt
    /// echte Motivwechsel zu, ohne den Fehler zu verdecken.
    private var sharpReference: Double = 0
    /// Seit wann das Schärfe-Tor ununterbrochen blockiert – Notausstieg,
    /// falls die Messlatte durch ein strukturreiches Motiv zu hoch steht und
    /// das neue Motiv sie nie erreichen kann.
    private var gateBlockedSince: Date?
    /// Schärfe im Moment des Fixierens – die Messlatte für den Wächter.
    private var sharpAtLock: Double = 0
    /// Seit wann das Bild trotz fixiertem Fokus deutlich unschärfer ist.
    private var blurrySince: Date?
    /// Zeitpunkt der letzten automatischen Nachfokussierung.
    private var lastAutoRefocus = Date.distantPast
    /// Wie oft in dieser Sitzung schon automatisch nachgestellt wurde.
    private var autoRefocusCount = 0
    /// Eigene Drossel für den Wechsel der Aufnahmeart – teilt man sie mit dem
    /// Wächter, verschluckt eine gerade erfolgte Nachfokussierung das
    /// Fixieren beim Abstellen aufs Stativ, und zwar ersatzlos.
    private var lastRigRelock = Date.distantPast
    /// Offene Bitte, nach dem Abstellen aufs Stativ neu zu fixieren.
    private var pendingRigRelock = false
    /// Läuft gerade eine Sitzung? Schützt gegen Frames, die nach `stop()`
    /// noch aus der Kamera-Warteschlange nachrücken.
    private var isRunning = false

    /// Holt eine gedrosselte Fixierung nach, sobald es passt. Wird aus der
    /// Analyse gepulst.
    private func servePendingRigRelock() {
        guard pendingRigRelock, rig.locksFocus, calibrationSamples == nil,
              focusTask == nil, currentMotion <= motionThreshold,
              Date().timeIntervalSince(lastRigRelock) > 5 else { return }
        pendingRigRelock = false
        lastRigRelock = Date()
        setStatus(.focusing)
        relockFocusOnly()
    }
    /// Ist der Fokus gerade eingefroren?
    private var focusIsLocked = false
    /// Dieses Gerät kann den Fokus gar nicht fixieren (Simulator, fehlende
    /// Unterstützung). Dann ist Nachfokussieren sinnlos.
    private var focusLockUnavailable = false

    /// Unterhalb dieses Rohwerts hat das Motiv schlicht keine Struktur
    /// (weißes Blatt, glatte Fläche). Dann darf die Schärfeprüfung nicht
    /// blockieren – sie hätte nichts, woran sie messen könnte.
    private static let minMeaningfulSharpness: Double = 15
    /// Ab diesem Anteil am Bestwert gilt der Fokus als „sitzt".
    private static let lockRatio: Double = 0.88
    /// Darunter wird kein Bild gespeichert.
    private static let captureRatio: Double = 0.72
    /// Darunter greift der Wächter und stellt neu scharf.
    private static let watchdogRatio: Double = 0.55

    /// Hat das Motiv überhaupt genug Struktur, um Schärfe beurteilen zu können?
    private var sharpnessIsMeaningful: Bool {
        sharpReference >= Self.minMeaningfulSharpness
    }

    /// Ist das Sucherbild scharf genug, um es ins Werk zu legen?
    var isSharpEnough: Bool {
        guard sharpnessIsMeaningful else { return true }
        return sharpRaw >= sharpReference * Self.captureRatio
    }

    /// Setzt alles zurück, was zur Schärfebeurteilung eines Aufbaus gehört.
    private func resetSharpnessState() {
        sharpRaw = 0
        sharpReference = 0
        sharpAtLock = 0
        gateBlockedSince = nil
        blurrySince = nil
        focusIsLocked = false
        autoRefocusCount = 0
        lastAutoRefocus = .distantPast
        lastRigRelock = .distantPast
        pendingRigRelock = false
        focusLockUnavailable = false
    }

    /// Nimmt einen Schärfewert auf. `calm` sagt, ob die Szene ruhig genug ist,
    /// um daraus die Messlatte fortzuschreiben – während Hände im Bild sind,
    /// misst die Laplace-Varianz deren Struktur, nicht den Fokus.
    private func noteSharpness(_ value: Double, calm: Bool) {
        sharpRaw = value
        // Der Notausstieg des Tores darf nur eine UNUNTERBROCHENE Blockade
        // messen. Ohne dieses Zurücksetzen bliebe der Zeitstempel über
        // Arbeitsphasen hinweg stehen und das Ventil würde beim nächsten
        // unscharfen Moment sofort feuern – und die Messlatte auf Unschärfe
        // setzen. Genau der Fehler, den das Tor verhindern soll.
        if !calm || isSharpEnough { gateBlockedSince = nil }
        guard calm else { return }
        // steigt sofort, zerfällt langsam (Halbwertszeit ~35 s bei 10 Hz)
        sharpReference = max(sharpReference * 0.998, value)
    }

    /// Notausstieg für das Schärfe-Tor: Steht die Messlatte durch ein
    /// vorheriges, strukturreiches Motiv zu hoch, könnte ein glattes Blatt sie
    /// nie erreichen – die App würde still gar nichts mehr aufnehmen. Nach
    /// acht Sekunden Blockade wird die Latte auf das aktuelle Motiv gesetzt.
    private func releaseGateIfStuck() -> Bool {
        if gateBlockedSince == nil { gateBlockedSince = Date() }
        guard let since = gateBlockedSince,
              Date().timeIntervalSince(since) > 8 else { return false }
        sharpReference = sharpRaw
        gateBlockedSince = nil
        return true
    }

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
    /// Getrennte Slots: Ein abgebrochener Fokuslauf darf die Belichtung
    /// nicht mit sich reissen.
    private var focusTask: Task<Void, Never>?
    private var exposureTask: Task<Void, Never>?
    /// Wartet auf Schärfe, nachdem manuell ausgelöst wurde.
    private var pendingCaptureTask: Task<Void, Never>?
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
        isRunning = true
        // Reste der Vorsitzung abbrechen, bevor die Kamera entriegelt wird:
        // Ein noch laufender Fokuslauf würde sonst die alte Linsenposition in
        // die neue Sitzung hineinfrieren.
        focusTask?.cancel(); focusTask = nil
        exposureTask?.cancel(); exposureTask = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        // Zuerst die Hardware entriegeln: Ohne das stünde die Linse in einer
        // zweiten Sitzung noch auf der fixierten Position der ersten, der
        // Autofokus meldete sofort „fertig", und die App würde eine womöglich
        // unscharfe Einstellung erneut einfrieren.
        resetToContinuous()
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
        setStatus(.calibrating)
        calibrationSamples = []
        calibrationStart = Date()
        armed = false // scharf erst nach der Kalibrierung
        // Schärfe-Historie gehört zur Sitzung, nicht zum App-Lauf: Ein
        // Bestwert vom letzten Motiv wäre hier eine falsche Messlatte.
        resetSharpnessState()
        focusHint = nil
        // Jede Sitzung beginnt wieder mit der Sensorerkennung – sonst wirkt
        // ein einziger Tipp für den Rest des App-Laufs nach, ohne dass man
        // es sieht. Auch die Aufnahmeart selbst: Controller und Sensor sind
        // `@StateObject` derselben View und überleben das Sitzungsende. Eine
        // zweite Sitzung würde sonst als „HAND" starten, obwohl das iPhone
        // die ganze Zeit auf dem Stativ steht.
        rigIsAutomatic = true
        rig = lastMountedSignal ? .tripod : .handheld
    }

    func stop() {
        isRunning = false
        intervalTask?.cancel()
        // Ein laufender Selbstauslöser würde sonst NACH dem Beenden noch ein
        // Bild ins bereits montierte Werk legen.
        selfTimerTask?.cancel()
        selfTimerTask = nil
        selfTimerCount = nil
        intervalTask = nil
        focusTask?.cancel()
        focusTask = nil
        exposureTask?.cancel()
        exposureTask = nil
        // Sonst legt ein wartender Auslöser noch ein Bild ins fertige Werk.
        pendingCaptureTask?.cancel()
        pendingCaptureTask = nil
        focusHintTask?.cancel()
        focusHintTask = nil
        focusHint = nil
        // Nachzügler aus der Kamera-Warteschlange dürfen kein Bild mehr ins
        // bereits montierte Werk legen und keine Kalibrierung neu starten.
        onCapture = nil
        latestFrame = nil
        calibrationSamples = nil
        calibrationStart = nil
        armed = false
        pendingRigRelock = false
        setStatus(.idle)
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
    /// Friert allein den Fokus ein – nur am Stativ. Aus der Hand ändert sich
    /// der Abstand zum Werk ständig, ein fixierter Fokus wäre dort nach
    /// wenigen Sekunden zwangsläufig falsch.
    private func lockFocusOnly() {
        guard rig.locksFocus else { return }
        // Kein Gerät (Simulator) oder keine Unterstützung für `.locked`: Das
        // ist kein Fehlschlag, den man wiederholen könnte. Ohne diese Marke
        // liefe der Wächter bis zum Sitzungsende alle zwanzig Sekunden los
        // und behauptete dabei, die Schärfe breche weg – was schlicht nicht
        // stimmt.
        guard let device, device.isFocusModeSupported(.locked) else {
            focusLockUnavailable = true
            return
        }
        guard (try? device.lockForConfiguration()) != nil else {
            focusLockUnavailable = true
            return
        }
        device.focusMode = .locked
        device.unlockForConfiguration()
        focusIsLocked = true
        sharpAtLock = sharpRaw
        blurrySince = nil
        // Der eine Fall, den ein relatives Schärfemaß prinzipbedingt nicht
        // erkennen kann: Ist das Bild von der ersten Sekunde an unscharf,
        // sind Messlatte UND Vergleichswert unscharf, und weder Tor noch
        // Wächter schlagen an. Fehlende Struktur ist das einzige Anzeichen,
        // das dann noch übrig ist – typisch, wenn das Werk näher liegt als
        // die Naheinstellgrenze. Also wenigstens nicht schweigen.
        if sharpAtLock < Self.minMeaningfulSharpness {
            setFocusHint("Ich sehe kaum Struktur und kann die Schärfe nicht prüfen. Geh etwas weiter weg oder tippe im Sucher auf dein Werk.")
        }
    }

    /// Fixiert Belichtung und Weißabgleich. Läuft bewusst auch dann, wenn der
    /// Fokus nicht sitzt: Ein unscharfes Bild kann man nachschärfen, eine über
    /// die ganze Sitzung atmende Belichtung ist im fertigen Film nicht mehr
    /// zu retten.
    private func lockExposureAndWhiteBalance() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()

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
                // Im CMTime-Raum klemmen, nicht in Sekunden: Das Runden auf
                // Mikrosekunden kann sonst knapp unter `minExposureDuration`
                // landen, und AVFoundation wirft dafür eine Exception.
                var t = CMTimeMakeWithSeconds(duration, preferredTimescale: 1_000_000)
                t = CMTimeMaximum(CMTimeMinimum(t, format.maxExposureDuration),
                                  format.minExposureDuration)
                device.setExposureModeCustom(
                    duration: t, iso: iso, completionHandler: nil)
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
        focusTask?.cancel(); focusTask = nil
        exposureTask?.cancel(); exposureTask = nil
        // Der Zeitgeber muss mit: Sonst tickt er durch die Neu-Kalibrierung
        // und den Fokuslauf hindurch weiter und legt drei, vier weiche
        // Blätter ins Werk. `startIntervalIfNeeded()` startet ihn am Ende
        // der Kalibrierung ohnehin neu.
        intervalTask?.cancel(); intervalTask = nil
        // Ein wartender Auslöser würde sonst sofort losgehen, weil
        // `resetSharpnessState()` die Messlatte auf null setzt.
        pendingCaptureTask?.cancel()
        pendingCaptureTask = nil
        focusHint = nil
        resetToContinuous()
        setStatus(.calibrating)
        calibrationSamples = []
        calibrationStart = Date()
        restlessSince = nil
        hint = nil
        armed = false
        // „Neu fixieren" ist der Knopf für einen veränderten Aufbau. Die alte
        // Schärfe-Messlatte gehört zum alten Motiv und würde das Tor sonst
        // grundlos blockieren.
        resetSharpnessState()
    }

    /// Tippen im Sucher: Fokus- und Belichtungspunkt aufs Werk setzen und die
    /// Kamera neu fixieren. Die Bewegungs-Kalibrierung bleibt bewusst bestehen –
    /// sonst würde jeder Tipp den Auslöser entschärfen.
    func focus(atDevicePoint point: CGPoint) {
        suppressRigUntil = Date().addingTimeInterval(2.5)
        guard let device else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
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
    ///
    /// Fokus und Belichtung laufen in getrennten Tasks. Das ist kein Detail:
    /// Der Fokus darf lange suchen, die Belichtung ist in gut einer Sekunde
    /// eingeschwungen. Steckten beide im selben Task, würde ein Abbruch des
    /// Fokuslaufs (etwa weil das iPhone gerade aufs Stativ kommt) auch die
    /// Belichtung ungefixiert zurücklassen – und das Set atmet die ganze
    /// Sitzung lang.
    func relockCamera() {
        relockExposure()
        relockFocusOnly()
    }

    /// Misst Belichtung und Weißabgleich neu ein und fixiert sie wieder.
    private func relockExposure() {
        releaseExposureOnly()
        exposureTask?.cancel()
        exposureTask = Task { [weak self] in
            await self?.waitUntilExposureSettles()
            guard let self, !Task.isCancelled else { return }
            self.lockExposureAndWhiteBalance()
        }
    }

    /// Misst den Fokus neu ein und fixiert ihn wieder – ohne Belichtung und
    /// Weißabgleich anzufassen.
    ///
    /// Der erste Schritt, `releaseFocusOnly()`, ist der wichtigste: Ohne ihn
    /// stünde die Linse noch auf `.locked` aus einer vorherigen Messung, der
    /// Autofokus meldete sofort „fertig", und die App würde dieselbe – womöglich
    /// falsche – Position ein zweites Mal einfrieren. Genau daran krankte die
    /// zweite Sitzung.
    private func relockFocusOnly(explainOnce: Bool = false) {
        releaseFocusOnly()
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            // Automatik einschwingen lassen – aber nicht stur eine feste Zeit:
            // Bei nahen Motiven oder wenig Licht sucht der Autofokus länger,
            // und wer mitten in der Suche einfriert, hat eine unscharfe Session.
            let good = await self?.waitUntilFocusIsGood() ?? false
            guard let self, !Task.isCancelled else { return }
            if good {
                self.lockFocusOnly()
            } else if self.rig.locksFocus {
                // Lieber gar nicht fixieren als unscharf fixieren: Der
                // Autofokus läuft weiter und holt sich das Bild irgendwann.
                self.focusIsLocked = false
                self.setFocusHint("Fokus findet nichts Scharfes. Tippe im Sucher auf dein Werk.")
            }
            if self.rawStatus == .focusing { self.setStatus(.waitingForWork) }

            // Einmal pro App-Leben erklären, wie man nachschärft – der
            // fixierte Fokus ist sonst nicht zu durchschauen. Nur wenn
            // wirklich fixiert wurde: Im Simulator und auf Geräten ohne
            // `.locked` wäre die Aussage schlicht falsch.
            let key = "didExplainTapFocus"
            if explainOnce, self.focusIsLocked,
               !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                self.setFocusHint("Scharf gestellt und fixiert. Wirkt es unscharf? Tippe im Sucher auf dein Werk.")
            }
            // Slot freigeben – der Wächter erkennt an ihm, ob gerade ein
            // Fokuslauf unterwegs ist.
            self.focusTask = nil
        }
    }

    /// Belichtung und Weißabgleich zurück auf Automatik – der Fokus bleibt,
    /// wo er ist.
    private func releaseExposureOnly() {
        exposureInfo = nil
        guard let device else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()
    }

    /// Belichtung schwingt schnell ein – hier reicht die einfache Prüfung.
    private func waitUntilExposureSettles() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard let device else { return }
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if Task.isCancelled { return }
            if !device.isAdjustingExposure && !device.isAdjustingWhiteBalance { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// Wartet, bis der Autofokus tatsächlich sein Optimum gefunden hat.
    ///
    /// Die frühere Fassung fragte nur, ob der Fokus noch *sucht*. Das reicht
    /// nicht: Nach dem Umschalten auf Automatik hat er in der ersten halben
    /// Sekunde oft noch gar nicht begonnen, meldet also „fertig" – und wenn
    /// in diesem Moment eine Hand durchs Bild wischt, friert die App auf den
    /// Abstand der Hand ein. Danach ist die ganze Sitzung unscharf.
    ///
    /// Deshalb wird jetzt zusätzlich die Bildschärfe gemessen und erst
    /// fixiert, wenn sie ihren Bestwert nahezu erreicht hat und niemand mehr
    /// im Bild steht. Gibt `false` zurück, wenn das binnen acht Sekunden
    /// nicht gelingt – dann bleibt die Automatik lieber an.
    private func waitUntilFocusIsGood() async -> Bool {
        // Anlauf: Dem Autofokus Zeit geben, die Suche überhaupt zu beginnen.
        try? await Task.sleep(nanoseconds: 800_000_000)
        // Kein Aufnahmegerät (Simulator, kameraloses Gerät) heißt „nichts zu
        // prüfen" – nicht „fehlgeschlagen". Sonst meldet der Simulator bei
        // jedem Start fälschlich einen Fokusfehler.
        guard let device else { return true }
        let deadline = Date().addingTimeInterval(8.0)

        while Date() < deadline {
            // Ohne diese Prüfung liefe die Schleife nach einem Abbruch leer
            // auf dem Hauptthread weiter (Task.sleep kehrt dann sofort zurück).
            if Task.isCancelled { return false }

            let stillSearching = device.isAdjustingFocus || device.isAdjustingExposure
            // Solange sich etwas bewegt, misst die Kamera auf etwas, das
            // gleich wieder weg ist – typischerweise auf die Hand.
            let sceneIsBusy = currentMotion > max(motionThreshold, 2.0)

            if !stillSearching && !sceneIsBusy {
                // Kein Kontrast im Motiv? Dann gibt es nichts zu messen, und
                // wir vertrauen der Kamera.
                if !sharpnessIsMeaningful { return true }
                if sharpRaw >= sharpReference * Self.lockRatio {
                    // Kurz bestätigen: der Fokus meldet zwischen zwei
                    // Suchläufen manchmal für einen Moment „fertig".
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { return false }
                    guard !device.isAdjustingFocus else { continue }
                    if sharpRaw >= sharpReference * Self.lockRatio { return true }
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return false
    }

    /// Gibt allein den Fokus wieder frei – Belichtung und Weißabgleich
    /// bleiben fixiert. Genau das braucht die Aufnahme aus der Hand: gleiche
    /// Helligkeit über alle Bilder, aber ein Fokus, der dem Abstand folgt.
    private func releaseFocusOnly() {
        focusIsLocked = false
        blurrySince = nil
        guard let device else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()
    }

    /// Prüft bei fixiertem Fokus, ob die Schärfe weggebrochen ist – etwa weil
    /// beim Fixieren doch eine Hand im Bild stand oder das Stativ verrückt
    /// wurde. Gemessen wird gegen den Wert im Moment des Fixierens, nicht
    /// gegen den gleitenden Bestwert: Der würde nach ein paar Sekunden
    /// Unschärfe selbst absinken und den Fehler damit verdecken.
    private func checkFocusWatchdog(motion: Double) {
        // Während gearbeitet wird, ist das Bild ohnehin verwischt – nur die
        // ruhige Szene ist ein gültiger Messpunkt.
        guard motion <= motionThreshold else {
            blurrySince = nil
            return
        }
        // Der wichtigere der beiden Fälle: Am Stativ sollte der Fokus fixiert
        // sein, ist es aber nicht – der Versuch ist also gescheitert. Ohne
        // diesen Zweig gäbe die App nach einem einzigen Fehlschlag für den
        // Rest der Sitzung auf, und zwar stumm: Der Wächter unten prüft
        // `focusIsLocked`, der Torpfad ebenso, und der Hinweis verschwindet
        // nach acht Sekunden.
        if rig.locksFocus, !focusIsLocked, !focusLockUnavailable,
           calibrationSamples == nil, focusTask == nil {
            blurrySince = nil
            autoRefocus()
            return
        }
        guard focusIsLocked, sharpAtLock >= Self.minMeaningfulSharpness else {
            blurrySince = nil
            return
        }
        guard sharpRaw < sharpAtLock * Self.watchdogRatio else {
            blurrySince = nil
            return
        }
        // Bewusst träge: Ein Motivwechsel (der Künstler nimmt ein
        // strukturreiches Objekt aus dem Bild) senkt die Varianz ebenfalls,
        // ohne dass am Fokus etwas falsch wäre. Vier Sekunden Nachweis
        // trennen das vom echten Schärfeverlust.
        if blurrySince == nil {
            blurrySince = Date()
        } else if Date().timeIntervalSince(blurrySince!) > 4.0 {
            autoRefocus()
        }
    }

    /// Der Wächter: Fällt die Schärfe nach dem Fixieren dauerhaft ab, stellt
    /// die App von selbst neu scharf, statt eine ganze Sitzung zu verlieren.
    /// Nur der Fokus wird neu gemessen – die Belichtung bleibt, wo sie ist,
    /// sonst gäbe es mitten im Film einen Helligkeitssprung.
    private func autoRefocus() {
        guard rig.locksFocus else { return }
        // Einen laufenden Versuch nicht abwürgen: Ein Fokuslauf darf fast
        // neun Sekunden dauern, und gerade im Zielfall (nahes Motiv, wenig
        // Licht) braucht er sie. Ohne diese Zeile bräche die Reparatur genau
        // dort ab, wofür sie gebaut wurde.
        guard focusTask == nil else { return }
        guard !focusLockUnavailable else { return }
        // Erst zügig, dann geduldig: Die ersten vier Versuche kommen im
        // Zehn-Sekunden-Takt (länger als ein Versuch dauern kann), danach
        // alle zwanzig – aber es hört nie ganz auf. Aufzugeben hieße, den
        // Rest der Sitzung unscharf aufzuzeichnen.
        let interval: TimeInterval = autoRefocusCount < 4 ? 10 : 20
        guard Date().timeIntervalSince(lastAutoRefocus) > interval else { return }
        if autoRefocusCount >= 4 {
            setFocusHint("Schärfe bricht immer wieder weg. Tippe im Sucher auf dein Werk.")
        }
        lastAutoRefocus = Date()
        autoRefocusCount += 1
        blurrySince = nil
        setStatus(.focusing)
        relockFocusOnly()
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
        focusIsLocked = false
        blurrySince = nil
        guard let device else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
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
                self.captureNow(userInitiated: false)
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
        // Nach `stop()` treffen noch Frames aus der Kamera-Warteschlange ein
        // (`stopRunning()` läuft asynchron). Die dürfen weder ein Bild ins
        // fertige Werk legen noch den Zustand vom Ruhestand wegziehen.
        guard isRunning else { return }
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

        // Schärfe auf demselben Graustufen-Puffer messen, der ohnehin für die
        // Bewegung berechnet wurde – das kostet praktisch nichts und ist die
        // einzige Größe, die verrät, ob der Fokus wirklich sitzt.
        // Die Messlatte wird nur bei ruhiger Szene fortgeschrieben: Eine Hand
        // im Bild bringt eigene Struktur mit und würde sie verfälschen.
        let calm = hadPrevious && motion <= motionThreshold
        noteSharpness(Algorithms.laplacianVariance(gray: gray, width: w, height: h),
                      calm: calm)
        checkFocusWatchdog(motion: motion)
        serveRigDetection()
        servePendingRigRelock()
        // Puls für den Status-Dämpfer – muss vor jedem vorzeitigen Ausstieg
        // stehen, sonst friert die Anzeige im Intervallmodus ein.
        flushPendingStatus()

        // Kalibrierphase: Grundrauschen messen, Schwelle automatisch setzen
        if calibrationSamples != nil {
            setStatus(.calibrating)
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
                setStatus(.focusing)
                // Für Stop-Motion: Belichtung, Fokus und Weißabgleich jetzt
                // fixieren – die Auto-Regelung würde sonst zwischen den Bildern
                // nachziehen und das Set „atmen" lassen. Aber erst, wenn der
                // Autofokus sein Optimum wirklich gefunden hat: sonst friert
                // eine unscharfe Session ein. Bis dahin wird nichts gespeichert.
                relockExposure()
                relockFocusOnly(explainOnce: true)
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
            setStatus(.working)
            // Bleibt es dauerhaft unruhig, kommt nie ein Auslöser – sagen,
            // woran es liegt, statt den Nutzer raten zu lassen.
            if restlessSince == nil { restlessSince = Date() }
            if Date().timeIntervalSince(restlessSince!) > 6 {
                hint = "Szene wirkt dauerhaft unruhig. Stativ prüfen – oder in den Einstellungen die Bewegungs-Toleranz erhöhen."
            }
            return
        }
        restlessSince = nil
        // Nur die Unruhe-Meldung zurücknehmen. Fokus-Hinweise laufen über
        // `focusHint` und werden hier bewusst nicht angefasst.
        if hint != nil { hint = nil }

        // Szene ist ruhig
        guard armed else {
            if rawStatus != .captured { setStatus(.waitingForWork) }
            return
        }

        if stableSince == nil { stableSince = Date() }
        let elapsed = Date().timeIntervalSince(stableSince!)
        setStatus(.stabilizing(min(1.0, elapsed / effectiveStableSeconds)))
        guard elapsed >= effectiveStableSeconds else { return }

        // Stabil genug → Handprüfung (nur jetzt, nicht auf jedem Frame)
        if checkHands, handDetector.containsHands(cgImage: fullFrame, confidence: 0.3) {
            // Hände liegen ruhig im Bild → weiter warten
            stableSince = Date()
            return
        }

        // Schärfe-Tor: Ein unscharfes Bild ist im fertigen Film nicht zu
        // reparieren, ein paar Sekunden Warten dagegen schon. Also lieber
        // gar nicht auslösen und sagen, woran es liegt.
        if !isSharpEnough, !releaseGateIfStuck() {
            setStatus(.focusing)
            stableSince = Date()
            // Einmal von selbst nachstellen, statt den Nutzer warten zu lassen.
            if rig.locksFocus { autoRefocus() }
            return
        }
        gateBlockedSince = nil

        // Capture! Duplikate verhindert bereits der Zustandsautomat:
        // ausgelöst wird nur nach erkannter Bewegung ("armed").
        // (Der frühere dHash-Abgleich hat subtile Änderungen fälschlich
        // als Duplikat verworfen und den Auslöser dauerhaft blockiert.)
        capture(frame: fullFrame)
    }

    /// Manueller Auslöser – nimmt den aktuellen Frame auf, unabhängig von
    /// Bewegung und Handprüfung. Ist das Bild unscharf, wird der Druck nicht
    /// verworfen: Die App stellt neu scharf und löst aus, sobald es sitzt
    /// (spätestens nach zweieinhalb Sekunden). Ein Tastendruck soll immer ein
    /// Bild ergeben – nur eben kein unscharfes, wenn es sich vermeiden lässt.
    func captureNow(userInitiated: Bool = true) {
        guard latestFrame != nil else { return }
        // Während der Kalibrierung ist noch nichts eingemessen – ein
        // automatischer Takt hätte hier nichts, woran er sich orientiert.
        guard userInitiated || (isRunning && calibrationSamples == nil) else { return }
        if isSharpEnough {
            captureLatest()
            return
        }
        // Läuft schon ein Auslöser und wartet auf Schärfe? Dann diesen Druck
        // verwerfen statt den wartenden abzubrechen – sonst löscht im
        // Intervallmodus jeder Takt den Vorgänger und es entsteht kein Bild.
        if let running = pendingCaptureTask, !running.isCancelled { return }
        setStatus(.focusing)
        // Sofortige Rückmeldung: Der Druck ist angekommen, auch wenn das Bild
        // erst gleich entsteht. Nur bei echtem Tastendruck – ein
        // unbeaufsichtigter Zeitraffer soll das Stativ nicht bei jedem Takt
        // anstoßen.
        if userInitiated {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            suppressRigUntil = Date().addingTimeInterval(2.5)
        }
        // Nur den Fokus neu messen, und nur wenn die Szene ruhig ist:
        // Bewegungsunschärfe ist kein Fokusfehler, und ein währenddessen
        // freigegebener Fokus liefert ein Bild mitten aus der Suche.
        if focusIsLocked, currentMotion <= motionThreshold { relockFocusOnly() }
        // Im Intervallmodus nie länger warten als bis zum nächsten Takt.
        let budget = captureMode == .interval
            ? min(2.5, max(0.4, intervalSeconds * 0.8))
            : 2.5
        pendingCaptureTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(budget)
            while Date() < deadline {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isSharpEnough { break }
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingCaptureTask = nil
            // Ein Tastendruck ergibt immer ein Bild – ein unbeaufsichtigter
            // Zeitraffer lässt den Takt lieber aus. Ein weiches Blatt im Werk
            // ist teurer als ein fehlendes.
            guard userInitiated || self.isSharpEnough else { return }
            self.captureLatest()
        }
    }

    private func captureLatest() {
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
        setStatus(.captured)

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
            if self.rawStatus == .captured { self.setStatus(.waitingForWork) }
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
