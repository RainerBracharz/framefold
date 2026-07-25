import SwiftUI
import UIKit
import CoreText

/// Registriert die gebündelten Schriften (Fraunces, Inter) aus dem
/// Asset-Katalog zur Laufzeit – ohne Info.plist-Eintrag.
enum AppFonts {
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        for name in ["Fraunces-Regular", "Fraunces-Light", "Inter-Regular", "Inter-Medium"] {
            guard let asset = NSDataAsset(name: name),
                  let provider = CGDataProvider(data: asset.data as CFData),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }
}

/// Designsystem „Falz & Flut" — abgeleitet aus Aldo Tolinos aktueller Praxis:
/// mattes Papier, gefaltet über geologische und wässrige Fotografie
/// (Bone, Stein, Marmor, ein Marine-Blau der Fluten), in Serien gedacht,
/// und seiner Grundidee der endlosen Schleife Bild → Objekt → Bild.
///
/// Zwei Zustände statt bunter Oberfläche:
///   • Galerie (warme Papierwand)  – sehen, ordnen, prüfen
///   • Kammer (warme Dunkelkammer) – belichten, aufnehmen
///
/// Farbe kommt nur aus dem Falz – als weiches Licht (Papier → Ocker → Marine),
/// nie als Neon. Typografie: New York (Serif) als Katalog-Stimme für Titel;
/// eine ruhige Grotesk mit Tabellenziffern für Angaben, Zähler und Zustände.
/// Auswahl wird durch Inversion markiert (Tuscheblock – wie ein Passepartout).
enum Theme {

    // MARK: Farben („Falz & Flut" – warmes Papier, geologische Ruhe)

    /// Galeriewand, warmes Bone (sein Papier ist warm, nicht kaltweiß)
    static let paper = Color(red: 0.937, green: 0.914, blue: 0.871)
    /// Fläche auf der Wand (Papierschatten)
    static let paperShade = Color(red: 0.890, green: 0.863, blue: 0.800)
    /// Tusche – warmes Schwarz statt hartem Neutralschwarz
    static let ink = Color(red: 0.114, green: 0.102, blue: 0.086)
    /// Stein/Graphit (Sekundärtext, Anmerkungen)
    static let graphite = Color(red: 0.420, green: 0.392, blue: 0.349)
    /// Haarlinie / Falzmarke (Gips)
    static let hairline = Color(red: 0.839, green: 0.804, blue: 0.741)
    /// Dunkelkammer – warmes Fast-Schwarz
    static let darkroom = Color(red: 0.078, green: 0.071, blue: 0.059)
    /// Schrift auf Dunkel (warmes Bone)
    static let paperOnDark = Color(red: 0.922, green: 0.894, blue: 0.839)

    // MARK: Akzente (aus seiner Werkwelt: Flut, Fels, Salbei, Marmor – entsättigt)

    static let violet  = Color(red: 0.208, green: 0.341, blue: 0.416) // Flut (Marine) #35576A
    static let blue    = Color(red: 0.173, green: 0.275, blue: 0.341) // Tiefsee #2C4657
    static let cyan    = Color(red: 0.596, green: 0.655, blue: 0.549) // Salbei #98A78C
    static let magenta = Color(red: 0.780, green: 0.604, blue: 0.573) // Marmor (Blush) #C79A92
    static let lime    = Color(red: 0.541, green: 0.604, blue: 0.431) // Moos #8A9A6E
    static let amber   = Color(red: 0.690, green: 0.486, blue: 0.263) // Fels (Ocker) #B07C43
    /// Warnung/Löschen – gedämpftes Oxblood statt grellem Systemrot.
    static let oxblood = Color(red: 0.510, green: 0.208, blue: 0.180) // #82352E

    /// „Falz im Licht" – weiche, entsättigte Tonwelle (Papier → Ocker → Marine)
    /// statt Neon-Regenbogen. Für Logo und Hero-Momente.
    static let spectrum = LinearGradient(
        colors: [Color(red: 0.937, green: 0.898, blue: 0.804),   // warmes Papierlicht
                 Color(red: 0.855, green: 0.729, blue: 0.545),   // Ocker-Schimmer
                 Color(red: 0.561, green: 0.651, blue: 0.690)],  // Marine-Licht
        startPoint: .leading, endPoint: .trailing)

    /// Der gebrochene Falz – Auswahl, Fortschritt, Pegel (Marine, ruhig).
    static let crease = LinearGradient(
        colors: [Color(red: 0.286, green: 0.427, blue: 0.502),   // Flut hell
                 Color(red: 0.173, green: 0.275, blue: 0.341)],  // Tiefsee
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Akzentpalette; jedes Projekt trägt genau einen daraus (entsättigt).
    static let accents: [Color] = [violet, amber, cyan, magenta, lime, blue]

    /// Deterministischer Akzent aus einer UUID (stabil über App-Starts –
    /// bewusst nicht hashValue, das ist pro Prozess zufällig).
    static func accent(for id: UUID) -> Color {
        let sum = id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return accents[sum % accents.count]
    }

    // MARK: Typografie

    /// Serif (Fraunces) – die Katalog-/Buchstimme: Titel, Werknamen, Wortmarke.
    /// Fällt sauber auf die System-Serife zurück, falls die Schrift fehlt.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let light: Set<Font.Weight> = [.ultraLight, .thin, .light]
        let ps = light.contains(weight) ? "Fraunces-Light" : "Fraunces-Regular"
        if UIFont(name: ps, size: size) != nil { return .custom(ps, size: size) }
        return .system(size: size, weight: weight, design: .serif)
    }
    /// Grotesk (Inter) mit Tabellenziffern – Angaben, Zähler, Zustände, Knöpfe.
    /// Fällt sauber auf SF Pro zurück, falls die Schrift fehlt.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let strong: Set<Font.Weight> = [.medium, .semibold, .bold, .heavy, .black]
        let ps = strong.contains(weight) ? "Inter-Medium" : "Inter-Regular"
        if UIFont(name: ps, size: size) != nil { return .custom(ps, size: size).monospacedDigit() }
        return .system(size: size, weight: weight, design: .default).monospacedDigit()
    }

    /// Gesperrte Grotesk-Versalien für Abschnitts- und Statuszeilen.
    static func caption(_ size: CGFloat = 11) -> Font { mono(size, .medium) }
    /// Werktitel (Serif).
    static var title: Font { serif(23, .light) }
    /// Kurzer Fließtext / Anmerkung (Grotesk).
    static var body: Font { mono(13, .regular) }
    /// Zahlen – gleichbreite Ziffern (Tabellenziffern).
    static var numeral: Font { mono(14, .medium) }
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
            // Hauptfalz (Diagonale) – bricht das Licht ins Spektrum
            Path { p in
                p.move(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size))
            }
            .stroke(Theme.crease, lineWidth: 1.6)
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

// MARK: Gefaltetes Papier (Facetten-Fläche)

/// Deterministische Facetten-Geometrie: ein leicht verzogenes Dreiecksraster
/// in Einheitskoordinaten (0…1) – dieselbe Faltung bei jedem App-Start.
enum FoldFacets {
    struct Tri { let a: CGPoint; let b: CGPoint; let c: CGPoint }

    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
    }

    static func triangles(cols: Int = 4, rows: Int = 3, seed: UInt64 = 7) -> [Tri] {
        var rng = Rng(state: seed &* 2654435761 &+ 12345)
        var grid: [[CGPoint]] = []
        for r in 0...rows {
            var row: [CGPoint] = []
            for c in 0...cols {
                let fx = CGFloat(c) / CGFloat(cols)
                let fy = CGFloat(r) / CGFloat(rows)
                // Randpunkte bleiben am Blattrand – gefaltet wird innen
                let jx: CGFloat = (c == 0 || c == cols) ? 0 : CGFloat(rng.next() - 0.5) * 0.12
                let jy: CGFloat = (r == 0 || r == rows) ? 0 : CGFloat(rng.next() - 0.5) * 0.12
                row.append(CGPoint(x: fx + jx, y: fy + jy))
            }
            grid.append(row)
        }
        var out: [Tri] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let p00 = grid[r][c], p01 = grid[r][c + 1]
                let p10 = grid[r + 1][c], p11 = grid[r + 1][c + 1]
                out.append(Tri(a: p00, b: p01, c: p11))
                out.append(Tri(a: p00, b: p11, c: p10))
            }
        }
        return out
    }

    /// Wie stark eine Facette das Licht fängt (−1 Schatten … +1 Licht).
    /// Das Licht fällt von links oben – wie in Tolinos Aufnahmen.
    static func light(_ t: Tri, index: Int) -> Double {
        let cx = Double(t.a.x + t.b.x + t.c.x) / 3
        let cy = Double(t.a.y + t.b.y + t.c.y) / 3
        let lit = 1 - (cx + cy) / 2
        let alternate = index % 2 == 0 ? 0.12 : -0.10
        return (lit - 0.5) * 0.9 + alternate
    }
}

/// Stabile Faltung pro Werk: dieselbe Geometrie bei jedem App-Start.
enum FoldSeed {
    static func make(_ id: UUID?) -> UInt64 {
        guard let id else { return 7 }
        return id.uuidString.unicodeScalars.reduce(UInt64(7)) { ($0 &* 31) &+ UInt64($1.value) }
    }
}

/// Eine gefaltete Papierfläche – das Werk als Objekt.
/// Liegt ein Bild vor, wird es über die Facetten gefaltet; sonst entsteht ein
/// Blatt aus Papierton mit einzelnen farbigen Splittern.
struct FoldedPaperHero: View {
    var image: UIImage? = nil
    var seed: UInt64 = 7
    var accent: Color = Theme.violet
    var animatesLight: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var tris: [FoldFacets.Tri] { FoldFacets.triangles(seed: seed) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Theme.paperShade
                }

                Canvas { ctx, canvasSize in
                    for (i, t) in tris.enumerated() {
                        var path = Path()
                        path.move(to: scaled(t.a, canvasSize))
                        path.addLine(to: scaled(t.b, canvasSize))
                        path.addLine(to: scaled(t.c, canvasSize))
                        path.closeSubpath()

                        // Ohne Bild: einzelne Splitter in Werkfarbe
                        if image == nil, i % 7 == 3 {
                            ctx.fill(path, with: .color(accent.opacity(0.70)))
                        } else if image == nil, i % 11 == 5 {
                            ctx.fill(path, with: .color(Theme.amber.opacity(0.45)))
                        }

                        let l = FoldFacets.light(t, index: i)
                        ctx.fill(path, with: .color(l >= 0
                            ? Color.white.opacity(l * 0.55)
                            : Color(red: 0.11, green: 0.10, blue: 0.09).opacity(-l * 0.42)))
                        ctx.stroke(path, with: .color(Theme.ink.opacity(0.13)), lineWidth: 0.6)
                    }
                }

                // Das Licht wandert langsam über die Faltung
                if animatesLight, !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: max(size.width * 0.55, 1))
                        .offset(x: sweep ? size.width : -size.width)
                        .blendMode(.softLight)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .onAppear {
                guard animatesLight, !reduceMotion, !sweep else { return }
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
        }
    }

    private func scaled(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: p.x * s.width, y: p.y * s.height)
    }
}

/// Das FrameFold-Logo als Kachel (wie das App-Icon): schwarze Fläche,
/// weißes Serif-F, Spektral-Falz über die linke obere Ecke – Rand zu Rand.
struct LogoTile: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.ink)
            Text("F")
                .font(Theme.serif(size * 0.58, .medium))
                .foregroundStyle(Theme.paper)
                .offset(x: size * 0.02, y: size * 0.03)
            Path { p in
                p.move(to: CGPoint(x: size * 0.5, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size * 0.5))
            }
            .stroke(Theme.crease, lineWidth: max(1.5, size * 0.055))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// Logo-Lockup für Titelleisten: Kachel + Wortmarke in Serif.
struct LogoLockup: View {
    var tileSize: CGFloat = 26
    var textSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 9) {
            LogoTile(size: tileSize)
            Text("FrameFold")
                .font(Theme.serif(textSize, .regular))
                .foregroundStyle(Theme.ink)
        }
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
/// Standard: spektraler Balken (der Falz „wandert" farbig voran).
struct HairlineProgress: View {
    let value: Double
    var trackColor: Color = Theme.hairline
    var gradient: LinearGradient = Theme.crease

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(trackColor).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
                Rectangle().fill(gradient)
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
