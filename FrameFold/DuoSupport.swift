import SwiftUI

/// Läuft FrameFold gerade als Mac-App (Mac Catalyst)? Dort nimmt eine Kamera
/// über dem Tisch auf – meist eine Dokumentenkamera –, und alles, was ein
/// iPhone in der Hand oder auf dem Stativ voraussetzt, entfällt: Lagesensor,
/// Wasserwaage, Aufnahmeart, Apple Watch, Lautstärketasten.
enum Platform {
    static let isMac: Bool = {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }()

    /// Ersatzkamera mit synthetischen Bildern: immer im Simulator, in der
    /// Mac-Testfassung nur mit gesetztem FF_SIM_FRAMES – für Store-Screenshots
    /// ohne echte Kamera (und ohne jemanden zu filmen).
    static let simulatedCamera: Bool = {
        #if targetEnvironment(simulator)
        return true
        #elseif targetEnvironment(macCatalyst) && DEBUG
        return !(ProcessInfo.processInfo.environment["FF_SIM_FRAMES"] ?? "").isEmpty
        #else
        return false
        #endif
    }()

    /// Start-Tab für Store-Screenshots (FF_TAB=0/1/2), sonst nil.
    static let startTab: Int? = {
        #if targetEnvironment(simulator) || (targetEnvironment(macCatalyst) && DEBUG)
        return ProcessInfo.processInfo.environment["FF_TAB"].flatMap { Int($0) }
        #else
        return nil
        #endif
    }()

    /// Erstes Werk gleich öffnen (FF_OPEN_WORK=1) – Store-Screenshots der
    /// Werkansicht ohne Klick.
    static let openFirstWork: Bool = {
        #if targetEnvironment(simulator) || (targetEnvironment(macCatalyst) && DEBUG)
        return ProcessInfo.processInfo.environment["FF_OPEN_WORK"] == "1"
        #else
        return false
        #endif
    }()

    /// Dieses Video gleich beim Start verarbeiten (FF_VIDEO=<Pfad>) – für
    /// UI-Tests des Video-Ablaufs, ohne die Fotomediathek zu bedienen.
    static let testVideo: URL? = {
        #if targetEnvironment(simulator) || (targetEnvironment(macCatalyst) && DEBUG)
        guard let path = ProcessInfo.processInfo.environment["FF_VIDEO"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
        #else
        return nil
        #endif
    }()

    /// Direkt in die Aufnahme springen (Layout-Prüfung, Screenshots).
    static let autostart: Bool = {
        #if targetEnvironment(simulator) || (targetEnvironment(macCatalyst) && DEBUG)
        return ProcessInfo.processInfo.environment["FF_AUTOSTART"] == "1"
        #else
        return false
        #endif
    }()
}

/// Alles, was nur das iPhone Duo betrifft, an einer Stelle – samt der
/// Vorkehrungen, damit derselbe Code auch mit älteren SDKs baut und auf
/// älteren Systemen läuft.
///
/// Die Schnittstellen dahinter (`ArrangementView`, reservierte Bereiche,
/// `CameraCaptureAccessory`) gibt es erst im iOS-27.1-SDK. `#available`
/// allein reicht nicht: Ein älteres SDK kennt die Namen gar nicht und bricht
/// beim Übersetzen ab. Deshalb zusätzlich `#if canImport(SwiftUI, _version:)`
/// – 8.0.85 ist die SwiftUI-Fassung aus Xcode 27.1.
enum Duo {
    /// Gibt es Apples Anordnung um den Falz (`ArrangementView`, iOS 27.1)?
    ///
    /// Sie darf nicht in einem `GeometryReader` stecken: Im aufgeklappten
    /// Querformat drehte sich das Layout dann endlos im Kreis und die App
    /// blieb weiß. Deshalb entscheidet der Sucher über die Größenklasse und
    /// setzt die Anordnung als äußerste Ansicht.
    static var canArrange: Bool {
        // Unter Mac Catalyst gilt `#available(iOS 27.1, *)` auch für
        // macOS 27.1 – ohne diesen Riegel nähme der Mac dann den Duo-Sucher.
        #if targetEnvironment(macCatalyst)
        return false
        #else
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["FF_NO_ARRANGE"] == "1" { return false }
        #endif
        #if canImport(SwiftUI, _version: "8.0.85")
        if #available(iOS 27.1, *) { return true }
        #endif
        return false
        #endif
    }
}

/// Kamera und Film um den Falz herum: nebeneinander, wenn die Fläche breiter
/// als hoch ist – das System legt die Grenze in den Falz. Ist sie höher als
/// breit, steht die Kamera allein; ihr hochkantes Bild braucht dort die
/// ganze Fläche.
struct FoldArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        #if canImport(SwiftUI, _version: "8.0.85")
        if #available(iOS 27.1, *) {
            ArrangementView(primary: primary, secondary: secondary)
                .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    /// Wird nur erreicht, wenn `Duo.canArrange` falsch liegt – der Vollständigkeit halber.
    private var fallback: some View {
        HStack(spacing: 0) {
            primary()
            secondary()
        }
    }
}

extension View {
    /// Aufgeklappt und bei laufender Aufnahme mit der Rückkamera kann das Duo
    /// auf dem Außendisplay etwas zeigen – es blickt in dieselbe Richtung wie
    /// die Kamera. Am Stativ von oben ist das die Seite zum Tisch hin: Dort
    /// sieht, wer arbeitet, den bisherigen Film, ohne zum iPhone aufzusehen.
    ///
    /// Ob und wann der Inhalt erscheint, entscheidet das System; der Sucher
    /// muss ohne ihn vollständig bleiben. `available` meldet, ob es gerade
    /// etwas zeigen kann – nur dann lohnt der Schalter in den Einstellungen.
    @ViewBuilder
    func duoOuterDisplay<Content: View>(isOn: Binding<Bool>, available: Binding<Bool>,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        // Am Mac gibt es kein Außendisplay – und `#available(iOS 27.1, *)`
        // wäre dort ab macOS 27.1 wahr.
        #if canImport(SwiftUI, _version: "8.0.85") && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            self.sceneAccessory {
                CameraCaptureAccessory(isEnabled: isOn, content: content)
                    .onAvailabilityChange { isAvailable in
                        available.wrappedValue = isAvailable
                    }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Was das Außendisplay während der Aufnahme zeigt: den bisherigen Film,
/// groß, darunter Zähler und Stand der Kamera. Bewusst ohne Bedienung – alles
/// Nötige bleibt im Sucher, das System kann diese Ansicht jederzeit wegnehmen.
struct OuterDisplayFilm: View {
    @ObservedObject var controller: LiveCaptureController
    let playful: Bool

    var body: some View {
        VStack(spacing: 14) {
            CatalogLabel("Der Film bisher", color: Theme.paperOnDark.opacity(0.7))
            Group {
                if controller.loopFrames.isEmpty {
                    Rectangle()
                        .stroke(Theme.paperOnDark.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .overlay { FoldMark(size: 40, color: Theme.paperOnDark.opacity(0.35)) }
                } else {
                    LiveLoopView(frames: controller.loopFrames)
                        .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.6), lineWidth: 1))
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 6) {
                Text("\(controller.capturedCount) Bilder")
                    .font(Theme.serifItalic(30))
                    .foregroundStyle(Theme.paperOnDark)
                Text(verbatim: controller.status.label(playful: playful))
                    .font(Theme.caption(13)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.amberLight)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.darkroom.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}
