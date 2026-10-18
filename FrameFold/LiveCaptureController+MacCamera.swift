import AVFoundation
import UIKit

// Kamerawahl am Mac: angeschlossene Kameras, Wechsel, An- und Abstecken.
#if targetEnvironment(macCatalyst)
extension LiveCaptureController {
    /// Merkt sich die gewählte Kamera über ihre eindeutige Kennung. Ist sie
    /// beim nächsten Start nicht angesteckt, greift die Reihenfolge oben.
    static let cameraKey = "macCameraID"
    static let macCameraTypes: [AVCaptureDevice.DeviceType] = [.external, .continuityCamera, .builtInWideAngleCamera]

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: macCameraTypes, mediaType: .video,
                                         position: .unspecified).devices
            .filter(\.isConnected)
    }

    /// Kennung der Kamera, die gerade aufnimmt (für die Auswahl in den
    /// Einstellungen).
    var currentCameraID: String? { device?.uniqueID }

    /// Wechselt mitten in der Sitzung die Kamera. Die Bewegungs-Kalibrierung
    /// gehört zum alten Bild und wird neu gemessen.
    func switchCamera(to id: String) {
        UserDefaults.standard.set(id, forKey: Self.cameraKey)
        guard id != device?.uniqueID, !session.inputs.isEmpty,
              let next = Self.availableCameras().first(where: { $0.uniqueID == id }) else { return }
        attach(next)
    }

    /// Ersetzt den Kamera-Eingang der laufenden Sitzung.
    @discardableResult
    func attach(_ next: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: next) else { return false }
        session.beginConfiguration()
        let old = session.inputs
        old.forEach(session.removeInput)
        guard session.canAddInput(input) else {
            old.forEach { if session.canAddInput($0) { session.addInput($0) } }
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        session.commitConfiguration()
        device = next
        objectWillChange.send()
        if isRunning { refixCamera() }
        return true
    }

    /// Am Mac kommen und gehen Kameras: Die Dokumentenkamera wird oft erst
    /// nach dem Start angesteckt, ein USB-Kabel kann sich lösen.
    func observeCameraChanges() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameraConnected() }
        }
        center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            let gone = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.cameraDisconnected(uniqueID: gone) }
        }
    }

    func cameraConnected() {
        // Vorher keine Kamera: Hinweis wegnehmen – der Sucher startet beim
        // Erscheinen neu und findet die neue Kamera selbst.
        if cameraUnavailable {
            cameraUnavailable = false
            return
        }
        // Die gewählte Kamera ist zurück: wieder auf sie wechseln.
        if let chosen = UserDefaults.standard.string(forKey: Self.cameraKey),
           chosen != device?.uniqueID,
           let back = Self.availableCameras().first(where: { $0.uniqueID == chosen }),
           !session.inputs.isEmpty {
            attach(back)
        }
    }

    func cameraDisconnected(uniqueID: String?) {
        guard let current = device, uniqueID == nil || uniqueID == current.uniqueID else { return }
        // Auf die nächstbeste Kamera ausweichen; die gewählte bleibt gemerkt
        // und kommt zurück, sobald sie wieder angesteckt ist.
        let fallback = Self.availableCameras().first { $0.uniqueID != current.uniqueID }
        if let fallback, attach(fallback) { return }
        // Keine Kamera mehr: Sitzung beenden und es sagen, statt mit
        // eingefrorenem Bild weiterzulaufen.
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        device = nil
        stop()
        cameraUnavailable = true
    }
}
#endif
