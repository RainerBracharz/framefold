import Foundation
import ImageCaptureCore
import UIKit

/// Spiegelreflex- oder Systemkamera per USB direkt auslösen (Mac).
///
/// Apple stellt Auslösen und Herunterladen über ImageCaptureCore bereit.
/// Den Auslösebefehl blendet das SDK für Mac-Catalyst-Apps aus – das
/// Framework darunter ist aber das des Macs, der Befehl ist zur Laufzeit
/// da. Darum wird er erst geprüft (`responds(to:)`) und dann aufgerufen.
/// Ein Livebild liefert ImageCaptureCore nicht: Die Kamera löst aus, das
/// fertige Foto wird geholt und wird das nächste Bild – in voller
/// Auflösung, auch RAW (wie beim Kamera-Ordner).
@MainActor
final class TetherCamera: NSObject, ObservableObject {
    @Published private(set) var cameraName: String?
    @Published private(set) var isReady = false
    /// Kann diese Kamera über USB auslösen?
    @Published private(set) var canTakePicture = false
    @Published private(set) var captured = 0
    @Published var lastError: String?
    @Published private(set) var isSearching = false

    private var browser: ICDeviceBrowser?
    private var camera: ICCameraDevice?
    private var onImage: ((CGImage, Data) -> Void)?
    private var waitingForPicture = false
    private var known: Set<String> = []

    nonisolated static var isSupported: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private static let takePicture = NSSelectorFromString("requestTakePicture")

    /// Kameras suchen und mit der ersten verbinden.
    func start(onImage: @escaping (CGImage, Data) -> Void) {
        self.onImage = onImage
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
        self.browser = browser
        isSearching = true
        lastError = nil
        browser.requestControlAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if status == .authorized {
                    browser.start()
                } else {
                    self.isSearching = false
                    self.lastError = String(localized: "Kein Zugriff auf angeschlossene Kameras – in den Systemeinstellungen erlauben.")
                }
            }
        }
    }

    func stop() {
        camera?.requestCloseSession()
        camera = nil
        browser?.stop()
        browser = nil
        isReady = false
        isSearching = false
        canTakePicture = false
        cameraName = nil
        waitingForPicture = false
    }

    /// Auslösen. Das Foto kommt über `onImage`, sobald die Kamera es meldet.
    func shoot() {
        guard let camera, isReady else {
            lastError = String(localized: "Keine Kamera verbunden.")
            return
        }
        guard canTakePicture, camera.responds(to: Self.takePicture) else {
            lastError = String(localized: "Diese Kamera lässt sich über USB nicht auslösen – den Kamera-Ordner nutzen.")
            return
        }
        lastError = nil
        waitingForPicture = true
        camera.perform(Self.takePicture)
    }

    fileprivate func handleNewItems(_ items: [ICCameraItem]) {
        // Nur Fotos, die nach dem Verbinden entstanden sind
        let files = items.compactMap { $0 as? ICCameraFile }.filter { file in
            guard let name = file.name, !known.contains(name) else { return false }
            known.insert(name)
            return StudioFolderWatch.imageExtensions.contains((name as NSString).pathExtension.lowercased())
        }
        guard waitingForPicture, let file = files.last else { return }
        waitingForPicture = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ff-tether-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = file.requestDownload(options: [.downloadsDirectoryURL: folder, .overwrite: true]) { [weak self] filename, error in
            let url = filename.map { folder.appendingPathComponent($0) }
            Task.detached(priority: .userInitiated) {
                let loaded = url.flatMap { StudioFolderWatch.load($0) }
                try? FileManager.default.removeItem(at: folder)
                await MainActor.run {
                    guard let self else { return }
                    if let (image, data) = loaded {
                        self.captured += 1
                        self.onImage?(image, data)
                    } else {
                        self.lastError = error?.localizedDescription
                            ?? String(localized: "Das Foto konnte nicht von der Kamera geholt werden.")
                    }
                }
            }
        }
    }

    fileprivate func connect(_ device: ICCameraDevice) {
        guard camera == nil else { return }
        camera = device
        device.delegate = self
        cameraName = device.name
        device.requestOpenSession()
    }

    fileprivate func sessionOpened(_ device: ICCameraDevice, error: Error?) {
        guard device == camera else { return }
        if let error {
            lastError = error.localizedDescription
            return
        }
        isSearching = false
        isReady = true
        // Vorhandene Fotos auf der Karte zählen nicht als neue Aufnahme
        known = Set((device.mediaFiles ?? []).compactMap { $0.name })
        canTakePicture = device.capabilities.contains("ICCameraDeviceCanTakePicture")
            && device.responds(to: Self.takePicture)
    }

    fileprivate func removed(_ device: ICDevice) {
        guard device == camera else { return }
        camera = nil
        isReady = false
        canTakePicture = false
        cameraName = nil
        isSearching = browser != nil
    }
}

extension TetherCamera: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in self.connect(camera) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in self.removed(device) }
    }
}

extension TetherCamera: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in self.sessionOpened(camera, error: error) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in self.handleNewItems(items) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.removed(device) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor in
            if camera == self.camera {
                self.canTakePicture = camera.capabilities.contains("ICCameraDeviceCanTakePicture")
                    && camera.responds(to: TetherCamera.takePicture)
            }
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
