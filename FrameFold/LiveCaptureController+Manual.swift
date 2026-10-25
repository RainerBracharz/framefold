import AVFoundation
import Foundation

/// Werte der manuellen Kamera. Solange sie gesetzt sind, fasst die
/// Fixier-Automatik Belichtung, Fokus und Weißabgleich nicht an.
struct ManualCamera: Equatable {
    var iso: Float
    /// Belichtungszeit in Sekunden
    var shutter: Double
    /// Linsenstellung 0 (nah) … 1 (fern)
    var lens: Float
    /// Farbtemperatur in Kelvin
    var kelvin: Float
}

/// Was die angeschlossene Kamera manuell kann – externe USB-Kameras am Mac
/// meist nichts davon, die iPhone-Kamera alles.
struct ManualCameraCapabilities: Equatable {
    var exposure = false
    var focus = false
    var whiteBalance = false
    var isoRange: ClosedRange<Float> = 50...1600
    var shutterRange: ClosedRange<Double> = 1.0 / 8000...0.5

    var any: Bool { exposure || focus || whiteBalance }
}

extension LiveCaptureController {

    var manualCapabilities: ManualCameraCapabilities {
        guard let device else { return ManualCameraCapabilities() }
        var caps = ManualCameraCapabilities()
        #if !targetEnvironment(macCatalyst)
        let format = device.activeFormat
        caps.exposure = device.isExposureModeSupported(.custom)
        if caps.exposure {
            caps.isoRange = format.minISO...max(format.minISO + 1, format.maxISO)
            let lo = CMTimeGetSeconds(format.minExposureDuration)
            caps.shutterRange = lo...max(lo * 2, min(0.5, CMTimeGetSeconds(format.maxExposureDuration)))
        }
        caps.focus = device.isLockingFocusWithCustomLensPositionSupported
        caps.whiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        #endif
        return caps
    }

    /// Manuell einschalten – mit den Werten, die die Kamera gerade hat, damit
    /// das Bild beim Umschalten nicht springt.
    func beginManual() {
        guard let device else { return }
        let caps = manualCapabilities
        guard caps.any else { return }
        var values = ManualCamera(iso: device.iso,
                                  shutter: CMTimeGetSeconds(device.exposureDuration),
                                  lens: device.lensPosition,
                                  kelvin: 5000)
        #if !targetEnvironment(macCatalyst)
        if caps.whiteBalance {
            values.kelvin = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
        }
        #endif
        values.iso = min(caps.isoRange.upperBound, max(caps.isoRange.lowerBound, values.iso))
        values.shutter = min(caps.shutterRange.upperBound, max(caps.shutterRange.lowerBound, values.shutter))
        // Laufende Automatik-Läufe dürfen die Werte nicht mehr überschreiben
        focusTask?.cancel(); focusTask = nil
        exposureTask?.cancel(); exposureTask = nil
        manual = values
        applyManual()
    }

    /// Zurück zur Automatik: neu einmessen und fixieren wie gewohnt.
    func endManual() {
        guard manual != nil else { return }
        manual = nil
        relockCamera()
    }

    /// Setzt die manuellen Werte an der Kamera.
    func applyManual() {
        guard let manual, let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        #if !targetEnvironment(macCatalyst)
        let caps = manualCapabilities
        if caps.exposure {
            let format = device.activeFormat
            var t = CMTimeMakeWithSeconds(manual.shutter, preferredTimescale: 1_000_000)
            t = CMTimeMaximum(CMTimeMinimum(t, format.maxExposureDuration), format.minExposureDuration)
            let iso = min(format.maxISO, max(format.minISO, manual.iso))
            device.setExposureModeCustom(duration: t, iso: iso, completionHandler: nil)
            exposureInfo = Self.exposureLabel(duration: CMTimeGetSeconds(t), iso: Double(iso))
        }
        if caps.focus {
            device.setFocusModeLocked(lensPosition: min(1, max(0, manual.lens)), completionHandler: nil)
            focusIsLocked = true
        }
        if caps.whiteBalance {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: manual.kelvin, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(maxGain, max(1, gains.redGain))
            gains.greenGain = min(maxGain, max(1, gains.greenGain))
            gains.blueGain = min(maxGain, max(1, gains.blueGain))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
        #endif
    }

    /// Belichtungszeit als „1/250 s“ oder „0,5 s“.
    nonisolated static func shutterLabel(_ seconds: Double) -> String {
        seconds >= 0.3 ? String(format: "%.1f s", seconds) : "1/\(Int((1 / max(seconds, 1e-6)).rounded())) s"
    }
}
