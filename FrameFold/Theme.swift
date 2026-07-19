import SwiftUI

/// Look & Feel „Papier & Falz" – abgeleitet aus Aldo Tolinos Arbeiten
/// (gefaltete Porträtfotografien, Serien „Crumbled Faces" / „Interferenz"):
/// Papierweiß und Tuschschwarz statt iOS-Systemfarben, scharfe Kanten
/// statt runder Ecken (gefaltetes Papier ist eckig), Haarlinien wie
/// Falzmarken, Katalog-Typografie in gesperrten Versalien.
/// Der Live-Tab arbeitet als „Dunkelkammer" in Schwarz.
enum Theme {

    // MARK: Farben

    /// Warmes Papierweiß (Bühne der App)
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    /// Etwas tieferes Papier für Flächen auf Papier
    static let paperShade = Color(red: 0.922, green: 0.906, blue: 0.871)
    /// Tuschschwarz (Text, Primäraktionen)
    static let ink = Color(red: 0.090, green: 0.082, blue: 0.078)
    /// Graphit (Sekundärtext, Bildunterschriften)
    static let graphite = Color(red: 0.42, green: 0.40, blue: 0.38)
    /// Haarlinie / Falzmarke
    static let hairline = Color(red: 0.78, green: 0.76, blue: 0.72)
    /// Dunkelkammer (Live-Tab)
    static let darkroom = Color(red: 0.051, green: 0.047, blue: 0.043)
    /// Papierton auf Dunkel
    static let paperOnDark = Color(red: 0.91, green: 0.89, blue: 0.86)

    // MARK: Typografie (Katalog-Stil)

    /// Gesperrte Versalien für Abschnitts- und Statuszeilen
    static func caption(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium).width(.expanded)
    }
    /// Werktitel
    static let title = Font.system(size: 22, weight: .light)
    /// Fließtext
    static let body = Font.system(size: 15, weight: .regular)
    /// Zahlen (Frames, Sekunden) – gleichbreite Ziffern
    static let numeral = Font.system(size: 15, weight: .medium).monospacedDigit()
}

// MARK: Falz-Signet

/// Das Signet der App: ein Quadrat mit diagonalem Falz –
/// eine Hälfte Fläche, eine Hälfte Linie, wie ein halb gefaltetes Blatt.
struct FoldMark: View {
    var size: CGFloat = 56
    var color: Color = Theme.ink

    var body: some View {
        ZStack {
            // umgeschlagene Ecke (gefüllt)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size))
                p.closeSubpath()
            }
            .fill(color)
            // offenes Blatt (Kontur)
            Path { p in
                p.move(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: size, y: size))
                p.addLine(to: CGPoint(x: 0, y: size))
            }
            .stroke(color, lineWidth: 1)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Bausteine

/// Gesperrte Versalien-Zeile, z. B. "8 KEYFRAMES · 34 S"
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
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// Primäraktion: schwarzes Rechteck, weiße Versalien, scharfe Kanten.
struct InkButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption(12))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.paper)
            .padding(.vertical, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.75 : 1))
    }
}

/// Sekundäraktion: Haarlinien-Rahmen auf Papier.
struct HairlineButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption(12))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .background(configuration.isPressed ? Theme.paperShade : Theme.paper)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Haarlinien-Rahmen (Passepartout) für Bilder und Video.
struct PassepartoutFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(Theme.paper)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
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
    func passepartout() -> some View {
        modifier(PassepartoutFrame())
    }
    /// Papierbühne als Hintergrund der ganzen Ansicht.
    func paperStage() -> some View {
        self.background(Theme.paper.ignoresSafeArea())
    }
}
