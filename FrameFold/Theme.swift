import SwiftUI

/// Designsystem „Bild · Objekt · Bild" — abgeleitet aus Aldo Tolinos Praxis:
/// gefaltete Porträtfotografien, streng monochrom, in Serien gedacht,
/// und seiner Grundidee der endlosen Schleife Bild → Objekt → Bild.
///
/// Zwei Zustände statt bunter Oberfläche:
///   • Galerie (weiße Wand)  – sehen, ordnen, prüfen
///   • Kammer (Dunkelkammer) – belichten, aufnehmen
///
/// Typografie: New York (Serif) als Katalog-/Buchstimme für Titel;
/// SF Mono für alle Angaben, Zähler und Zustände – wie Anmerkungen auf
/// der Rückseite eines Abzugs. Auswahl wird nicht farbig, sondern durch
/// Inversion markiert (schwarzer Block – wie ein Passepartout).
enum Theme {

    // MARK: Farben (streng monochrom – wie sein Werk)

    /// Galeriewand, neutralweiß (bewusst kein Creme)
    static let paper = Color(red: 0.957, green: 0.953, blue: 0.945)
    /// Fläche auf der Wand
    static let paperShade = Color(red: 0.925, green: 0.918, blue: 0.905)
    /// Tuscheschwarz
    static let ink = Color(red: 0.067, green: 0.063, blue: 0.063)
    /// Graphit (Sekundärtext, Anmerkungen)
    static let graphite = Color(red: 0.29, green: 0.28, blue: 0.26)
    /// Haarlinie / Falzmarke
    static let hairline = Color(red: 0.812, green: 0.800, blue: 0.776)
    /// Dunkelkammer
    static let darkroom = Color(red: 0.039, green: 0.039, blue: 0.039)
    /// Schrift auf Dunkel
    static let paperOnDark = Color(red: 0.929, green: 0.921, blue: 0.906)

    // MARK: Typografie

    /// Serif (New York) – die authored/Buch-Stimme: Titel, Werknamen, Wortmarke.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Monospace (SF Mono) – alle Angaben, Zähler, Zustände, Knöpfe.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Gesperrte Mono-Versalien für Abschnitts- und Statuszeilen.
    static func caption(_ size: CGFloat = 11) -> Font { mono(size, .medium) }
    /// Werktitel (Serif).
    static let title = Font.system(size: 23, weight: .light, design: .serif)
    /// Kurzer Fließtext / Anmerkung (Mono).
    static let body = Font.system(size: 13, weight: .regular, design: .monospaced)
    /// Zahlen – gleichbreite Ziffern (Mono ist ohnehin dimensionsgleich).
    static let numeral = Font.system(size: 14, weight: .medium, design: .monospaced)
}

// MARK: Falz-Signet (Dreiecksfacette)

/// Das Signet: ein Blatt, entlang der Diagonale gefaltet – eine Hälfte Fläche,
/// eine Hälfte Kontur, mit feiner zweiter Falzlinie. Echo der triangulierten
/// Faltungen in Tolinos Porträts.
struct FoldMark: View {
    var size: CGFloat = 56
    var color: Color = Theme.ink
    var creaseColor: Color = Theme.graphite

    var body: some View {
        ZStack {
            // umgeschlagene Ecke (Fläche)
            Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size))
                p.closeSubpath()
            }
            .fill(color)
            // offenes Blatt (Kontur rechts + unten)
            Path { p in
                p.move(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: size, y: size))
                p.addLine(to: CGPoint(x: 0, y: size))
            }
            .stroke(color, lineWidth: 1.2)
            // Hauptfalz (Diagonale)
            Path { p in
                p.move(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size))
            }
            .stroke(color, lineWidth: 1)
            // zweite Falzlinie (Facette)
            Path { p in
                p.move(to: CGPoint(x: size * 0.5, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size * 0.5))
            }
            .stroke(creaseColor, lineWidth: 0.8)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Bausteine

/// Gesperrte Mono-Versalien-Zeile, z. B. "23 BLÄTTER · 2026".
struct CatalogLabel: View {
    let text: String
    var color: Color = Theme.graphite
    var size: CGFloat = 11

    init(_ text: String, color: Color = Theme.graphite, size: CGFloat = 11) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.caption(size))
            .tracking(2.0)
            .foregroundStyle(color)
    }
}

/// Werktitel im Katalog-/Buchstil (Serif).
struct WorkTitle: View {
    let text: String
    var size: CGFloat = 20
    var color: Color = Theme.ink
    init(_ text: String, size: CGFloat = 20, color: Color = Theme.ink) {
        self.text = text; self.size = size; self.color = color
    }
    var body: some View {
        Text(text)
            .font(Theme.serif(size, .regular))
            .foregroundStyle(color)
    }
}

/// Primäraktion: schwarzer Block, weiße Mono-Versalien, scharfe Kanten.
struct InkButtonStyle: ButtonStyle {
    var fullWidth = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption(12))
            .tracking(2.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.paper)
            .padding(.vertical, 15)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 22)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.72 : 1))
    }
}

/// Sekundäraktion: Haarlinien-Rahmen auf der Wand.
struct HairlineButtonStyle: ButtonStyle {
    var fullWidth = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption(12))
            .tracking(2.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 15)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 22)
            .background(configuration.isPressed ? Theme.paperShade : Theme.paper)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Gerahmte Tafel (Plate): schwarze Keyline, weißes Passepartout – Galerierahmung.
struct PlateFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(Theme.paper)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
    }
}

/// Schmale Fortschrittslinie wie eine Falzmarke.
struct HairlineProgress: View {
    let value: Double
    var trackColor: Color = Theme.hairline
    var barColor: Color = Theme.ink

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(trackColor).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
                Rectangle().fill(barColor)
                    .frame(width: geo.size.width * max(0, min(1, value)), height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: 3)
    }
}

extension View {
    /// Gerahmte Tafel (schwarze Keyline).
    func plate() -> some View { modifier(PlateFrame()) }
    /// Alias (Rückwärtskompatibilität mit älteren Views).
    func passepartout() -> some View { modifier(PlateFrame()) }
    /// Galeriewand als Hintergrund der ganzen Ansicht.
    func galleryStage() -> some View {
        self.background(Theme.paper.ignoresSafeArea())
    }
    /// Alias (Rückwärtskompatibilität).
    func paperStage() -> some View {
        self.background(Theme.paper.ignoresSafeArea())
    }
}
