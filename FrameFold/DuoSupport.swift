import SwiftUI

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
    /// Soll der Sucher als Anordnung aus Kamera und Film gesetzt werden?
    /// Ja, wenn die Fläche breit ist (aufgeklappt, quer) oder wenn der Falz
    /// gerade durch die Fläche läuft (halb aufgeklappt): Dann gehört auf
    /// jede Seite des Falzes eine eigene Ansicht statt einer, die er teilt.
    static func arranges(_ geo: GeometryProxy, wide: Bool) -> Bool {
        #if canImport(SwiftUI, _version: "8.0.85")
        if #available(iOS 27.1, *) {
            return wide || !geo.reservedRegions(kind: .division).isEmpty
        }
        #endif
        return false
    }
}

/// Kamera und Film um den Falz herum: nebeneinander, wenn die Fläche breiter
/// als hoch ist, sonst übereinander. Das System legt die Grenze in den Falz.
struct FoldArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        #if canImport(SwiftUI, _version: "8.0.85")
        if #available(iOS 27.1, *) {
            ArrangementView(primary: primary, secondary: secondary)
                .arrangementViewStyle(.split)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    /// Wird nur erreicht, wenn `Duo.arranges` falsch liegt – der Vollständigkeit halber.
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
        #if canImport(SwiftUI, _version: "8.0.85")
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
