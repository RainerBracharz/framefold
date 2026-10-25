import SwiftUI

/// Kurze Anleitungen in der App – nach Themen, jeweils wenige Schritte.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    struct Topic: Identifiable {
        let id: String
        let symbol: String
        let title: LocalizedStringKey
        let steps: [LocalizedStringKey]
    }

    static let topics: [Topic] = [
        Topic(id: "start", symbol: "sparkles", title: "Erste Schritte", steps: [
            "Im Tab „Kamera“ ein Werk anlegen und das Gerät aufs Stativ stellen.",
            "Ein kleines Stück bewegen, Hände aus dem Bild – FrameFold löst von selbst aus.",
            "„Fertig“ zeigt den Film. Im Tab „Werke“ geht es weiter: exportieren, Ton, Titel.",
            "Das Beispielwerk „Faltung“ zeigt, wie ein fertiges Werk aussieht.",
        ]),
        Topic(id: "camera", symbol: "camera.aperture", title: "Kamera und Auslöser", steps: [
            "Der Auto-Auslöser wartet, bis die Szene ruhig ist und keine Hände zu sehen sind.",
            "Auslösen geht auch von Hand: großer Knopf, Lautstärketasten, Apple Watch, Klatschen.",
            "Gedrückt halten startet einen Selbstauslöser von 3 Sekunden.",
            "„Kamera verrutscht?“ erscheint, wenn das Stativ angestoßen wurde – das erste Bild hilft beim Ausrichten.",
        ]),
        Topic(id: "set", symbol: "lightbulb", title: "Tipps fürs Set", steps: [
            "Gleichmäßiges Raumlicht statt Fenster: Wolken lassen den Film flackern.",
            "Kleine Schritte machen weiche, große Schritte schnelle Bewegung.",
            "10 Bilder sind eine Sekunde Film bei 10 Bildern pro Sekunde.",
            "Die Zwiebelhaut zeigt das vorige Bild durchscheinend – so sieht man den letzten Schritt.",
        ]),
        Topic(id: "works", symbol: "square.grid.3x3", title: "Werke und Kontaktbogen", steps: [
            "Ein Bild lange drücken: neu aufnehmen, verdoppeln, verschieben, Text & Zeichnen, Geräusch.",
            "Bilder per Ziehen umordnen; entfernte Bilder liegen 30 Tage im Papierkorb.",
            "Alles lässt sich rückgängig machen: mit den Pfeil-Knöpfen oder ⌘Z.",
            "Fotos aus der Mediathek lassen sich als Bilder anhängen.",
        ]),
        Topic(id: "export", symbol: "square.and.arrow.up", title: "Exportieren", steps: [
            "Bildrate, Format und Look wählen, dann „Stopmotion exportieren“.",
            "Titel und Abspann eintragen – sie kommen vor und hinter den Film.",
            "Greenscreen ersetzt Grün oder Blau durch ein Bild oder einen Film.",
            "Daumenkino und Kontaktbogen gibt es als PDF zum Drucken.",
        ]),
        Topic(id: "sound", symbol: "waveform", title: "Ton", steps: [
            "Musik oder Ton aus Dateien hinzufügen, Stimme direkt aufnehmen oder Text sprechen lassen.",
            "Geräusche wie Plopp, Wusch oder Tadaa lassen sich an jedes Bild hängen.",
            "Im Studio hat jede Spur ein Startbild und eine Lautstärke; die Wellenform liegt unter der Zeitleiste.",
            "Im X-Sheet werden Mundformen den Bildern zugeordnet – auf Wunsch automatisch.",
        ]),
        Topic(id: "studio", symbol: "slider.horizontal.below.rectangle", title: "Studio", steps: [
            "Ab „Erweitert“ zeigt die Kamera am Mac und iPad die Studio-Arbeitsfläche, am iPhone nach Einschalten in den Kamera-Einstellungen.",
            "Zeitleiste, Abspielen, Umschalten zwischen Live-Bild und Aufnahme, Zwiebelhaut über mehrere Bilder.",
            "Masken, Raster, Lupe, Referenzbild mit Chroma-Key, Differenz- und Belichtungsansicht.",
            "Alle Befehle mit Tastatur: Menü „Studio“.",
        ]),
        Topic(id: "drawing", symbol: "pencil.and.scribble", title: "Text und Zeichnen", steps: [
            "Ein Bild lange drücken und „Text & Zeichnen …“ wählen.",
            "Ins Bild tippen setzt Text oder Sprechblase; sie gelten für mehrere Bilder.",
            "Mit dem Stift auf genau dieses Bild zeichnen.",
            "Im Export wird alles in den Film eingebrannt.",
        ]),
        Topic(id: "privacy", symbol: "lock", title: "Datenschutz", steps: [
            "Kein Konto, keine Werbung, keine Netzwerkverbindung.",
            "Bilder, Ton und Werke bleiben auf dem Gerät.",
            "Mikrofon nur auf Wunsch: für Sprachaufnahmen und das Auslösen per Klatschen.",
            "Spracherkennung und Sprachausgabe laufen auf dem Gerät.",
        ]),
    ]

    var body: some View {
        NavigationStack {
            List(Self.topics) { topic in
                Section {
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                                .frame(width: 16, alignment: .trailing)
                            Text(step).font(Theme.body).foregroundStyle(Theme.ink)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(topic.title, systemImage: topic.symbol)
                        .font(Theme.caption(11)).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(Theme.graphite)
                }
                .listRowBackground(Theme.paperShade.opacity(0.5))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CatalogLabel("Hilfe", color: Theme.ink, size: 12)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.foregroundStyle(Theme.ink)
                }
            }
        }
    }
}

/// Knopf „Hilfe“ für Einstellungen und Inspektor.
struct HelpButton: View {
    var dark = false
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: {
            Label("Hilfe", systemImage: "questionmark.circle")
                .font(dark ? Theme.mono(11) : Theme.body)
                .foregroundStyle(dark ? Theme.paperOnDark : Theme.ink)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $shown) { HelpView() }
    }
}
