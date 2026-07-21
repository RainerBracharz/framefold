import Foundation
import CoreMotion

/// Liefert die Neigung des iPhones für die Wasserwaage im Sucher.
/// Nutzt die Schwerkraftkomponente in der Bildschirmebene (gx, gy):
/// Beim ebenen Halten über der Arbeit (Kamera nach unten) sind beide ~0,
/// die Blase steht dann mittig. Braucht keine Berechtigung.
final class MotionLevel: ObservableObject {
    @Published var gx: Double = 0
    @Published var gy: Double = 0

    private let manager = CMMotionManager()

    /// In der Bildschirmebene zentriert (nahezu waagerecht/ausgerichtet).
    var isLevel: Bool { abs(gx) < 0.035 && abs(gy) < 0.035 }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            // leichte Glättung gegen Zittern
            self.gx = self.gx * 0.6 + g.x * 0.4
            self.gy = self.gy * 0.6 + g.y * 0.4
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
