import AVFoundation
import Foundation

/// Aufnahme in voller Auflösung: Analyse, Sucher und Zwiebelhaut laufen auf
/// dem schnellen 1080p-Videobild, das Bild fürs Werk kommt als Foto vom
/// Kamera-Sensor – auf aktuellen iPhones und iPads bis 4K und mehr.
extension LiveCaptureController {

    /// Foto-Ausgang einrichten (nur iPhone/iPad). Die größte Fotoauflösung,
    /// die das aktive Videoformat erlaubt – im Seitenverhältnis des Suchers.
    func configurePhotoOutput(for device: AVCaptureDevice) {
        #if !targetEnvironment(macCatalyst)
        guard photoOutput == nil else { return }
        let photo = AVCapturePhotoOutput()
        session.beginConfiguration()
        guard session.canAddOutput(photo) else { session.commitConfiguration(); return }
        session.addOutput(photo)
        session.commitConfiguration()
        if let best = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photo.maxPhotoDimensions = best
        }
        // Gleichmäßig statt „bestmöglich“: Die starke Bildverarbeitung
        // rechnet jedes Foto etwas anders – im Film flackert das.
        photo.maxPhotoQualityPrioritization = .speed
        if let conn = photo.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        photoOutput = photo
        #endif
    }

    /// Größe der Fotos in Megapixeln (nil = kein Foto-Ausgang).
    var photoMegapixels: Int? {
        #if !targetEnvironment(macCatalyst)
        guard let dims = photoOutput?.maxPhotoDimensions, dims.width > 0 else { return nil }
        return Int((Double(dims.width) * Double(dims.height) / 1_000_000).rounded())
        #else
        return nil
        #endif
    }

    /// Soll dieses Bild als Foto in voller Auflösung kommen?
    var usesFullResolutionPhoto: Bool {
        fullResolution && photoOutput != nil && isRunning
    }

    /// Ein Foto aufnehmen und als JPEG liefern (nil, wenn es nicht klappt –
    /// dann nimmt die Aufnahme das Videobild).
    func capturePhotoData() async -> Data? {
        #if !targetEnvironment(macCatalyst)
        guard let photoOutput else { return nil }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .speed
        if photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
        return await withCheckedContinuation { cont in
            let delegate = PhotoCaptureDelegate { data in cont.resume(returning: data) }
            photoDelegates.insert(delegate)
            delegate.onFinish = { [weak self, weak delegate] in
                if let delegate { self?.photoDelegates.remove(delegate) }
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
        #else
        return nil
        #endif
    }
}

/// Hält die Fortsetzung bis zum fertigen Foto.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Data?) -> Void
    private var done = false
    var onFinish: (() -> Void)?

    init(completion: @escaping (Data?) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard !done else { return }
        done = true
        completion(error == nil ? photo.fileDataRepresentation() : nil)
        DispatchQueue.main.async { self.onFinish?() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !done else { return }
        done = true
        completion(nil)
        DispatchQueue.main.async { self.onFinish?() }
    }
}
