import SwiftUI
import AVFoundation

/// Einstellungen des Auto-Shutters – vor UND während der Aufnahme änderbar
/// (der Controller liest die Werte bei jeder Analyse frisch).
struct LiveSettingsView: View {
    @ObservedObject var controller: LiveCaptureController
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    /// iPhone Duo, aufgeklappt bei laufender Aufnahme: Nur dann gibt es ein
    /// Außendisplay, für das der Schalter etwas bewirkt.
    var outerDisplayAvailable = false
    @AppStorage("liveOuterDisplay") private var outerDisplayOn = true
    @Environment(\.dismiss) private var dismiss
    @AppStorage("liveOnionOpacity") private var onionOpacity: Double = 0.35
    @AppStorage("liveOnionFirst") private var onionFirst: Bool = false
    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    @AppStorage("iPhoneStudio") private var iPhoneStudio = false
    private var mode: AppMode { AppMode.current(modeRaw) }

    var body: some View {
        NavigationStack {
            Form {
                // Der Modus steht oben – im Einfach-Modus ist er das Einzige,
                // was man hier überhaupt einstellen kann.
                Section {
                    ModeTabs(modeRaw: $modeRaw)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    Text(mode == .basic
                         ? "Einfach: nur Auslöser und Fertig. Alles Weitere erscheint ab \"Erweitert\"."
                         : mode.showsTolino
                         ? (Platform.isMac
                            ? "Labor-Ansicht: Blattnummer, Sitzungsuhr, Messwerte – und der Falz-Countdown wandert in Amber um den Auslöser."
                            : "Labor-Ansicht: Blattnummer, Sitzungsuhr, fixierte Belichtung, Messwerte – und der Falz-Countdown wandert in Amber um den Auslöser.")
                         : Platform.isMac
                         ? "Alle Werkzeuge sichtbar: Raster, Pegel, Daumenkino mit Zurücknehmen, Neu-Einmessen, Referenzbild."
                         : "Alle Werkzeuge sichtbar: Raster, Wasserwaage, Pegel, Daumenkino mit Zurücknehmen, Neu-Fixieren, Referenzbild.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                        .lineSpacing(2)
                } header: {
                    CatalogLabel("Modus")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                #if targetEnvironment(macCatalyst)
                MacCameraSection(controller: controller)
                #endif

                if outerDisplayAvailable {
                Section {
                    Toggle("Film auf dem Außendisplay", isOn: $outerDisplayOn)
                        .font(Theme.body)
                    Text("Aufgeklappt zeigt das iPhone Duo den bisherigen Film außen – zum Tisch hin.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.graphite)
                } header: {
                    CatalogLabel("iPhone Duo")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
                }

                if mode.showsAdvanced, CameraOptionsPanel.isAvailable || controller.manualCapabilities.any {
                    Section {
                        CameraOptionsPanel(controller: controller)
                    } header: {
                        CatalogLabel("Kamera")
                    }
                    .listRowBackground(Theme.paperShade.opacity(0.5))
                }

                if mode.showsAdvanced, !Platform.isMac, !Platform.isPad {
                    Section {
                        Toggle(isOn: $iPhoneStudio) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Studio-Arbeitsfläche").font(Theme.body)
                                Text("Zeitleiste, Abspielen, Zwiebelhaut über mehrere Bilder, Masken, Lupe, Ton und X-Sheet – wie am iPad und Mac.")
                                    .font(Theme.mono(10)).foregroundStyle(Theme.graphite)
                            }
                        }
                    } header: {
                        CatalogLabel("Studio")
                    }
                    .listRowBackground(Theme.paperShade.opacity(0.5))
                }

                if mode.showsAdvanced {
                    Section {
                        ClapTriggerToggle(controller: controller)
                    } header: {
                        CatalogLabel("Auslöser")
                    }
                    .listRowBackground(Theme.paperShade.opacity(0.5))
                }

                if mode.showsAdvanced {
                Section {
                    Toggle("Drittel-Raster", isOn: $showGrid)
                        .font(Theme.body)
                    if !Platform.isMac {
                        Toggle("Wasserwaage", isOn: $showLevel)
                            .font(Theme.body)
                    }
                } header: {
                    CatalogLabel("Sucher")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(controller.rig == .handheld
                             ? "Auslöse-Wartezeit: \(controller.stableSeconds, specifier: "%.1f") s (+0,4 s aus der Hand)"
                             : "Auslöse-Wartezeit: \(controller.stableSeconds, specifier: "%.1f") s")
                            .font(Theme.body)
                        Slider(value: $controller.stableSeconds, in: 0.3...2.5, step: 0.1)
                        Text("So lange muss die Szene ruhig sein, bevor automatisch ausgelöst wird.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.graphite)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bewegungs-Toleranz: \(controller.motionThreshold, specifier: "%.1f")")
                            .font(Theme.body)
                        Slider(value: Binding(get: { controller.motionThreshold },
                                              set: { controller.setUserMotionThreshold($0) }),
                               in: 0.5...8.0, step: 0.5)
                        Text("Höher = kleine Wackler und Bildrauschen werden ignoriert. Wenn der Auslöser nie Ruhe findet, diesen Wert erhöhen.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.graphite)
                    }
                    Toggle("Nicht auslösen, solange Hände im Bild sind", isOn: $controller.checkHands)
                        .font(Theme.body)
                } header: {
                    CatalogLabel("Auto-Shutter")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Picker("Auslöser", selection: $controller.captureMode) {
                        ForEach(LiveCaptureController.CaptureMode.allCases) { Text($0.label).tag($0) }
                    }
                    .font(Theme.body)
                    if controller.captureMode == .interval {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Intervall: \(controller.intervalSeconds, specifier: "%.0f") s")
                                .font(Theme.body)
                            Slider(value: $controller.intervalSeconds, in: 1...30, step: 1)
                            Text("Im Intervall-Modus löst FrameFold in festem Takt aus – unabhängig von Bewegung.")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.graphite)
                        }
                    }
                    // Netzfrequenz ist Labor-Wissen – erst im Tolino-Modus zeigen
                    // Am Mac regelt die Kamera die Belichtung selbst – die
                    // Netzfrequenz hätte nichts, worauf sie wirken könnte.
                    if mode.showsTolino, !Platform.isMac {
                        Picker("Netzfrequenz", selection: $controller.mainsHz) {
                            Text("50 Hz (EU)").tag(50)
                            Text("60 Hz (US)").tag(60)
                        }
                        .font(Theme.body)
                    }
                    Toggle("Auslöse-Ton", isOn: $controller.playShutterSound)
                        .font(Theme.body)
                } header: {
                    CatalogLabel("Auslöser & Belichtung")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))

                Section {
                    Toggle("Gegen erstes Bild (Drift)", isOn: $onionFirst)
                        .font(Theme.body)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Deckkraft: \(Int(onionOpacity * 100)) %")
                            .font(Theme.body)
                        Slider(value: $onionOpacity, in: 0.1...0.8, step: 0.05)
                        Text("Zeigt das erste oder letzte Bild als Überblendung – zum Ausrichten und um Drift zu erkennen.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.graphite)
                    }
                } header: {
                    CatalogLabel("Zwiebelhaut")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
                } // Ende: nur ab „Erweitert"

                Section {
                    tipRow("lightbulb", "Licht konstant halten: Kunstlicht nutzen, Fenster abdunkeln. Billige LED-/Leuchtstofflampen flackern im Netztakt und streifen einzelne Bilder.")
                    if Platform.isMac {
                        tipRow("hand.raised", "Kamera nicht berühren: fest über dem Tisch montieren und den Auto-Shutter arbeiten lassen (oder den runden Knopf).")
                        tipRow("lock", "Licht ruhig halten: Gleichmäßiges Kunstlicht ohne Sonne hält den Film ruhig. Wo die Kamera es erlaubt, sperrt FrameFold Belichtung und Weißabgleich.")
                        tipRow("scope", "Dokumentenkamera mit Fokus-Schalter: auf Einzelfokus (S) stellen und einmal scharfstellen – sonst stellt sie bei jeder Hand im Bild neu scharf. Helligkeit und Weißabgleich lassen sich meist mit der App des Herstellers fest einstellen.")
                    } else {
                        tipRow("hand.raised", "iPhone nicht berühren: aufs Stativ stellen und den Auto-Shutter arbeiten lassen (oder den runden Knopf).")
                        tipRow("lock", "Kamera bleibt ruhig: FrameFold sperrt Belichtung und Weißabgleich nach der kurzen Kalibrierung – so driftet zwischen den Bildern nichts. Der Fokus wird am Stativ fixiert, aus der Hand läuft er mit.")
                    }
                    tipRow("square.2.layers.3d", "Drift früh erkennen: Zwiebelhaut anlassen und die Aufnahme ab und zu mit dem ersten Bild vergleichen.")
                    tipRow("timer", Platform.isMac
                           ? "Ohne Wackeln auslösen: Auslöser gedrückt halten startet einen 3-Sekunden-Countdown. Die Leertaste löst ebenfalls aus."
                           : "Ohne Wackeln auslösen: Auslöser gedrückt halten startet einen 3-Sekunden-Countdown. Auch die Lautstärketasten von Kopfhörern oder AirPods lösen aus.")
                } header: {
                    CatalogLabel("Aufnahme-Tipps")
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .tint(Theme.ink)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CatalogLabel("Live-Einstellungen", color: Theme.ink, size: 12)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    /// `LocalizedStringResource` statt `String` — sonst landen die fünf Tipps
    /// nie im Katalog und bleiben deutsch, obwohl der Rest übersetzt ist.
    private func tipRow(_ icon: String, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ink)
                .frame(width: 18)
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Kamerawahl am Mac: Dort hängen oft mehrere Kameras – die eingebaute, ein
/// iPhone über Continuity Camera und die Dokumentenkamera über dem Tisch.
/// Steckt man eine Kamera an oder ab, aktualisiert sich die Liste.
struct MacCameraSection: View {
    @ObservedObject var controller: LiveCaptureController
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        Section {
            if cameras.isEmpty {
                Text("Keine Kamera angeschlossen.")
                    .font(Theme.body)
            } else {
                Picker("Kamera", selection: Binding(
                    get: { controller.currentCameraID ?? cameras.first?.uniqueID ?? "" },
                    set: { controller.switchCamera(to: $0) })) {
                    ForEach(cameras, id: \.uniqueID) { camera in
                        Text(verbatim: camera.localizedName).tag(camera.uniqueID)
                    }
                }
                .font(Theme.body)
            }
            Text("Ideal ist eine Dokumentenkamera, die senkrecht von oben auf den Tisch blickt. Eine angesteckte USB-Kamera wählt FrameFold von selbst.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.graphite)
        } header: {
            CatalogLabel("Kamera")
        }
        .listRowBackground(Theme.paperShade.opacity(0.5))
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in reload() }
    }

    private func reload() {
        cameras = LiveCaptureController.availableCameras()
    }
}
#endif
