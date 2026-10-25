import AVFoundation
import Foundation

/// Objektive des iPhone/iPad: Weitwinkel, Ultraweitwinkel, Tele, Frontkamera.
enum CameraLens: String, CaseIterable, Identifiable {
    case wide, ultraWide, tele, front
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: return String(localized: "Weitwinkel")
        case .ultraWide: return String(localized: "Ultraweitwinkel")
        case .tele: return String(localized: "Tele")
        case .front: return String(localized: "Frontkamera")
        }
    }

    #if !targetEnvironment(macCatalyst)
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide, .front: return .builtInWideAngleCamera
        case .ultraWide: return .builtInUltraWideCamera
        case .tele: return .builtInTelephotoCamera
        }
    }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }

    var device: AVCaptureDevice? { AVCaptureDevice.default(deviceType, for: .video, position: position) }
    #endif

    static let storageKey = "liveLens"
    static var stored: CameraLens { CameraLens(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .wide }

    /// Objektive, die dieses Gerät hat.
    static var available: [CameraLens] {
        #if targetEnvironment(macCatalyst)
        return []
        #else
        return allCases.filter { $0.device != nil }
        #endif
    }
}

extension LiveCaptureController {
    /// Objektiv wechseln – auch mitten in der Sitzung. Die Kamera wird danach
    /// neu eingemessen; eine manuelle Einstellung gilt nicht mehr.
    func switchLens(to lens: CameraLens) {
        #if !targetEnvironment(macCatalyst)
        UserDefaults.standard.set(lens.rawValue, forKey: CameraLens.storageKey)
        guard let newDevice = lens.device, newDevice != device,
              let input = try? AVCaptureDeviceInput(device: newDevice) else { return }
        manual = nil
        session.beginConfiguration()
        for old in session.inputs { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let device, let back = try? AVCaptureDeviceInput(device: device), session.canAddInput(back) {
                session.addInput(back)
            }
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()
        device = newDevice
        if let photo = photoOutput,
           let best = newDevice.activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photo.maxPhotoDimensions = best
        }
        applyCaptureRotation(device: newDevice)
        // Neues Objektiv, neuer Bildausschnitt – keine Warnung „Kamera verrutscht?“
        acceptCameraPosition()
        refixCamera()
        #endif
    }
}

extension LiveCaptureController {
    /// Klatsch-Auslöser an- oder abschalten – nur während einer Sitzung, und
    /// nur mit Erlaubnis fürs Mikrofon.
    func updateClapListener() {
        guard clapTrigger, isRunning else {
            clapListener?.stop()
            return
        }
        Task { @MainActor in
            guard await AVAudioApplication.requestRecordPermission() else {
                self.clapTrigger = false
                return
            }
            if self.clapListener == nil {
                self.clapListener = ClapListener { [weak self] in
                    Task { @MainActor in
                        guard let self, self.isRunning, !VoiceRecorder.isRecordingAnywhere else { return }
                        self.captureNow()
                    }
                }
            }
            _ = self.clapListener?.start()
        }
    }
}
