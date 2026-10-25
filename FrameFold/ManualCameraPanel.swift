import SwiftUI

/// Kamera-Optionen am iPhone/iPad: Objektiv, volle Auflösung und die
/// manuelle Kamera.
struct CameraOptionsPanel: View {
    @ObservedObject var controller: LiveCaptureController
    var dark = false
    @State private var lens = CameraLens.stored

    static var isAvailable: Bool { !Platform.isMac }

    private var text: Color { dark ? Theme.paperOnDark : Theme.ink }
    private var font: Font { dark ? Theme.mono(11) : Theme.body }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let lenses = CameraLens.available
            if lenses.count > 1 {
                HStack {
                    Text("Objektiv").font(font).foregroundStyle(text)
                    Spacer()
                    Picker("", selection: $lens) {
                        ForEach(lenses) { Text(verbatim: $0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .id(lens)
                }
                .onChange(of: lens) { _, new in controller.switchLens(to: new) }
            }
            Toggle(isOn: $controller.fullResolution) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.photoMegapixels.map { String(localized: "Volle Auflösung (\($0) MP)") }
                         ?? String(localized: "Volle Auflösung"))
                        .font(font).foregroundStyle(text)
                    Text("Jedes Bild als Foto vom Sensor statt als Videobild (1080p) – schärfer, braucht mehr Speicher.")
                        .font(Theme.mono(10)).foregroundStyle(text.opacity(0.55))
                }
            }
            ManualCameraPanel(controller: controller, dark: dark)
        }
    }
}

/// Auslösen per Klatschen – überall dort, wo es ein Mikrofon gibt.
struct ClapTriggerToggle: View {
    @ObservedObject var controller: LiveCaptureController
    var dark = false

    var body: some View {
        Toggle(isOn: $controller.clapTrigger) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auslösen per Klatschen").font(dark ? Theme.mono(11) : Theme.body)
                    .foregroundStyle(dark ? Theme.paperOnDark : Theme.ink)
                Text("Einmal klatschen = ein Bild. Das Mikrofon hört nur auf den Knall, nichts wird aufgenommen.")
                    .font(Theme.mono(10)).foregroundStyle((dark ? Theme.paperOnDark : Theme.ink).opacity(0.55))
            }
        }
    }
}

/// Regler der manuellen Kamera: ISO, Belichtungszeit, Fokus, Weißabgleich.
/// Erscheint nur, wenn die Kamera das kann (iPhone/iPad, nicht die meisten
/// USB-Kameras am Mac).
struct ManualCameraPanel: View {
    @ObservedObject var controller: LiveCaptureController
    var dark = false

    private var caps: ManualCameraCapabilities { controller.manualCapabilities }
    private var text: Color { dark ? Theme.paperOnDark : Theme.ink }

    var body: some View {
        if caps.any {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { controller.manual != nil },
                                     set: { $0 ? controller.beginManual() : controller.endManual() })) {
                    Text("Manuelle Kamera").font(dark ? Theme.mono(11) : Theme.body).foregroundStyle(text)
                }
                if let manual = controller.manual {
                    if caps.exposure {
                        row("ISO", "\(Int(manual.iso))") {
                            Slider(value: logBinding(\.iso, range: caps.isoRange), in: 0...1)
                        }
                        row("Belichtungszeit", LiveCaptureController.shutterLabel(manual.shutter)) {
                            Slider(value: shutterBinding(range: caps.shutterRange), in: 0...1)
                        }
                    }
                    if caps.focus {
                        row("Fokus", manual.lens < 0.05 ? String(localized: "nah") : manual.lens > 0.95 ? String(localized: "fern") : "\(Int(manual.lens * 100)) %") {
                            Slider(value: Binding(get: { Double(manual.lens) },
                                                  set: { controller.manual?.lens = Float($0) }), in: 0...1)
                        }
                    }
                    if caps.whiteBalance {
                        row("Weißabgleich", "\(Int(manual.kelvin)) K") {
                            Slider(value: Binding(get: { Double(manual.kelvin) },
                                                  set: { controller.manual?.kelvin = Float($0) }), in: 2500...8000, step: 50)
                        }
                    }
                    Text("Belichtung, Fokus und Weißabgleich bleiben, wie du sie stellst – die Automatik misst nicht mehr nach.")
                        .font(Theme.mono(10)).foregroundStyle(text.opacity(0.55))
                }
            }
        }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, _ value: String,
                                    @ViewBuilder control: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(dark ? Theme.mono(11) : Theme.body).foregroundStyle(text)
                Spacer()
                Text(verbatim: value).font(Theme.mono(11)).foregroundStyle(text.opacity(0.8))
            }
            control()
        }
    }

    /// ISO logarithmisch: Die Stufen 50–100–200–400 liegen gleich weit auseinander.
    private func logBinding(_ path: WritableKeyPath<ManualCamera, Float>, range: ClosedRange<Float>) -> Binding<Double> {
        Binding(get: {
            guard let value = controller.manual?[keyPath: path] else { return 0 }
            return Double(log(value / range.lowerBound) / log(range.upperBound / range.lowerBound))
        }, set: { t in
            controller.manual?[keyPath: path] = range.lowerBound * pow(range.upperBound / range.lowerBound, Float(t))
        })
    }

    private func shutterBinding(range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: {
            guard let value = controller.manual?.shutter else { return 0 }
            return log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }, set: { t in
            controller.manual?.shutter = range.lowerBound * pow(range.upperBound / range.lowerBound, t)
        })
    }
}
