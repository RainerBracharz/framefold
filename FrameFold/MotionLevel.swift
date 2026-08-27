import Foundation
import CoreMotion

/// Liefert die Neigung des iPhones für die Wasserwaage im Sucher.
/// Nutzt die Schwerkraftkomponente in der Bildschirmebene (gx, gy):
/// Beim ebenen Halten über der Arbeit (Kamera nach unten) sind beide ~0,
/// die Blase steht dann mittig. Braucht keine Berechtigung.
final class MotionLevel: ObservableObject {
    @Published var gx: Double = 0
    @Published var gy: Double = 0

    /// Geglättete Drehrate in rad/s. Auf einem Stativ liegt sie im
    /// Sensorrauschen (< 0,005), in der Hand erzeugt schon ruhiges Halten
    /// ein Zittern von 0,02 aufwärts. Das unterscheidet die beiden
    /// Aufnahmearten zuverlässiger als jede Bildanalyse, weil es allein die
    /// Kamera misst und nicht das, was vor ihr passiert.
    private var shake: Double = 0

    /// `true`, wenn das iPhone auf etwas steht statt gehalten zu werden.
    /// Mit Hysterese, damit die Aufnahmeart nicht hin- und herspringt,
    /// wenn jemand kurz das Stativ berührt.
    @Published private(set) var looksMounted = true

    private let manager = CMMotionManager()
    /// Zählt aufeinanderfolgende Ausschläge, damit ein einzelner Stoß die
    /// Aufnahmeart nicht umwirft.
    private var peakCount = 0
    /// Seit wann die Drehrate ununterbrochen unter der Rückkehrschwelle liegt.
    private var calmSince: Date?

    /// In der Bildschirmebene zentriert (nahezu waagerecht/ausgerichtet).
    var isLevel: Bool { abs(gx) < 0.035 && abs(gy) < 0.035 }

    func start() {
        // Nicht den Stand der letzten Sitzung übernehmen: Wer das iPhone
        // zwischendurch vom Stativ genommen hat, bekäme sonst eine
        // Einschätzung, die nicht mehr stimmt – und einen fixierten Fokus
        // in der Hand.
        shake = 0
        calmSince = nil
        peakCount = 0
        // Nur bei echter Änderung zuweisen: `start()` läuft aus `onAppear`,
        // und `@Published` meldet auch dann, wenn sich nichts ändert – das
        // gäbe die Laufzeitwarnung „Publishing changes from within view
        // updates".
        if !looksMounted { looksMounted = true }
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            // leichte Glättung gegen Zittern
            self.gx = self.gx * 0.6 + g.x * 0.4
            self.gy = self.gy * 0.6 + g.y * 0.4

            let r = motion.rotationRate
            let magnitude = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            // träge geglättet: einzelne Stöße (jemand stellt etwas ab) sollen
            // die Einschätzung nicht kippen
            self.shake = self.shake * 0.92 + magnitude * 0.08

            // Der Rückweg zu „steht" verlangt zusätzlich, dass die Ruhe eine
            // Weile anhält. Ohne das bliebe ein iPhone auf einem Tisch mit
            // Trittschall oder Lüftungsvibration womöglich dauerhaft als
            // „gehalten" eingestuft – und der Fokus würde nie fixiert.
            if self.looksMounted {
                self.calmSince = nil
                // Zwei Kriterien: der geglättete Wert für ruhiges Halten, und
                // wiederholte Ausschläge für die Hand, die zu ruhig ist, um
                // den geglätteten Wert zu heben. Ein EINZELNER Ausschlag
                // zählt bewusst nicht — das ist der Fingertipp auf ein
                // geklemmtes iPhone, also Bedienung und kein Herunternehmen.
                // Die Schwellen sind niedrig angesetzt: Fälschlich „aus der
                // Hand" kostet nur den fixierten Fokus, fälschlich „Stativ"
                // friert einen falschen Fokus ein. Die teurere Verwechslung
                // vermeiden.
                if magnitude > 0.08 {
                    self.peakCount = min(4, self.peakCount + 1)
                } else {
                    self.peakCount = max(0, self.peakCount - 1)
                }
                if self.shake > 0.020 || self.peakCount >= 3 {
                    self.looksMounted = false
                }
            } else if self.shake < 0.010 {
                if self.calmSince == nil { self.calmSince = Date() }
                if let since = self.calmSince,
                   Date().timeIntervalSince(since) > 1.0 {
                    self.looksMounted = true
                    self.calmSince = nil
                }
            } else {
                self.calmSince = nil
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
