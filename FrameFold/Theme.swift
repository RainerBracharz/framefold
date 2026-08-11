import SwiftUI
import UIKit
import CoreText
import CoreMotion

/// Registriert die gebündelten Schriften (Fraunces, Inter) aus dem
/// Asset-Katalog zur Laufzeit – ohne Info.plist-Eintrag.
enum AppFonts {
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        for name in ["Fraunces-Regular", "Fraunces-Light", "Fraunces-Italic", "Inter-Regular", "Inter-Medium"] {
            guard let asset = NSDataAsset(name: name),
                  let provider = CGDataProvider(data: asset.data as CFData),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }
}

/// Designsystem „Bruch & Licht" — abgeleitet aus Aldo Tolinos Arbeiten von
/// 2024 (Full-Blown, Cracked, die Reliefs): zerknülltes weißes Papier auf
/// leuchtenden Verlaufsfeldern, Farbe die durch das Blatt scheint, Amber
/// als wiederkehrendes Signal — und seiner Grundidee der endlosen Schleife
/// Bild → Objekt → Bild.
///
/// Zwei Zustände statt bunter Oberfläche:
///   • Galerie (helle Wand mit Lichtverlauf) – sehen, ordnen, prüfen
///   • Kammer (warme Dunkelkammer)           – belichten, aufnehmen
///
/// Farbe kommt aus dem Licht hinter dem Papier (Amber, Teal, Schiefer),
/// nie als Neon. Typografie: Fraunces (Serif, kursiv als Stimme) für Titel;
/// Inter mit Tabellenziffern für Angaben, Zähler und Zustände.
/// Auswahl wird durch Inversion markiert (Tuscheblock – wie ein Passepartout).
enum Theme {

    // MARK: Farben („Bruch & Licht" – helle Galerie, leuchtende Akzente)

    /// Galeriewand – helles, leicht kühles Papierweiß (Ausstellungslicht)
    static let paper = Color(red: 0.957, green: 0.949, blue: 0.925)
    /// Fläche auf der Wand (Papierschatten)
    static let paperShade = Color(red: 0.902, green: 0.894, blue: 0.859)
    /// Unteres Ende des Wand-Verlaufs – Salbei/Schiefer-Hauch
    static let paperDeep = Color(red: 0.851, green: 0.871, blue: 0.851)
    /// Tusche – warmes Schwarz statt hartem Neutralschwarz
    static let ink = Color(red: 0.114, green: 0.102, blue: 0.086)
    /// Stein/Graphit (Sekundärtext, Anmerkungen)
    static let graphite = Color(red: 0.408, green: 0.392, blue: 0.357)
    /// Haarlinie / Falzmarke
    static let hairline = Color(red: 0.847, green: 0.835, blue: 0.796)
    /// Dunkelkammer – warmes Fast-Schwarz
    static let darkroom = Color(red: 0.078, green: 0.071, blue: 0.059)
    /// Schrift auf Dunkel (warmes Bone)
    static let paperOnDark = Color(red: 0.922, green: 0.894, blue: 0.839)

    // MARK: Akzente (aus den 2024er-Serien: Amber-Signal, Teal, Schiefer)

    static let amber   = Color(red: 0.851, green: 0.608, blue: 0.169) // Amber (Signal) #D99B2B
    static let amberLight = Color(red: 0.949, green: 0.796, blue: 0.420) // Amber hell #F2CB6B
    static let violet  = Color(red: 0.306, green: 0.478, blue: 0.502) // Teal #4E7A80
    static let blue    = Color(red: 0.369, green: 0.455, blue: 0.518) // Schiefer #5E7484
    static let cyan    = Color(red: 0.596, green: 0.655, blue: 0.549) // Salbei #98A78C
    static let magenta = Color(red: 0.780, green: 0.604, blue: 0.573) // Marmor (Blush) #C79A92
    static let lime    = Color(red: 0.541, green: 0.604, blue: 0.431) // Moos #8A9A6E
    /// Warnung/Löschen – gedämpftes Oxblood statt grellem Systemrot.
    static let oxblood = Color(red: 0.510, green: 0.208, blue: 0.180) // #82352E

    /// „Licht im Blatt" – Papierlicht → Amber → Teal. Für Logo und Hero-Momente.
    static let spectrum = LinearGradient(
        colors: [Color(red: 0.957, green: 0.929, blue: 0.855),
                 amberLight,
                 Color(red: 0.498, green: 0.659, blue: 0.671)],
        startPoint: .leading, endPoint: .trailing)

    /// Der gebrochene Falz – Auswahl, Fortschritt, Pegel (Amber, sein Signal).
    static let crease = LinearGradient(
        colors: [amberLight, amber],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Akzentpalette; jedes Projekt trägt genau einen daraus.
    static let accents: [Color] = [amber, violet, blue, cyan, magenta, lime]

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

    /// Kursive Serifenstimme (Fraunces Italic) – Begrüßung, Fragen, Zitate.
    static func serifItalic(_ size: CGFloat) -> Font {
        if UIFont(name: "Fraunces-Italic", size: size) != nil {
            return .custom("Fraunces-Italic", size: size)
        }
        return .system(size: size, design: .serif).italic()
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

// MARK: Signet „Rekursion"

/// Das Signet: ein Blatt, dessen umgeschlagene Ecke ein Blatt enthält, dessen
/// Ecke wieder ein Blatt enthält — Aldo Tolinos endlose Schleife
/// „Bild → Objekt → Bild" als Figur. Die mittlere Falz trägt Amber: die Ebene,
/// auf der man gerade steht.
struct FoldMark: View {
    var size: CGFloat = 56
    var color: Color = Theme.ink
    /// Farbe der hervorgehobenen (mittleren) Falz-Ecke.
    var accent: Color = Theme.amber
    /// Anzahl der Verschachtelungen.
    var depth: Int = 3

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height)
            let line = max(1, s * 0.045)

            for level in 0..<depth {
                // Jede Ebene sitzt zentriert und ist kleiner als die vorige
                let inset = s * 0.20 * CGFloat(level)
                let side = s - inset * 2
                guard side > line * 2 else { break }
                let rect = CGRect(x: inset, y: inset, width: side, height: side)

                // Blattkontur
                ctx.stroke(Path(rect), with: .color(color),
                           lineWidth: line * (1 - CGFloat(level) * 0.15))

                // Umgeschlagene Ecke rechts oben
                let corner = side * 0.40
                var fold = Path()
                fold.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                fold.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
                fold.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
                fold.closeSubpath()

                // Die mittlere Ebene trägt das Amber – der aktuelle Zustand
                let isAccent = (level == depth / 2)
                ctx.fill(fold, with: .color(isAccent ? accent : color))
            }
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

    static func triangles(cols: Int = 5, rows: Int = 4, seed: UInt64 = 7) -> [Tri] {
        var rng = Rng(state: seed &* 2654435761 &+ 12345)
        var grid: [[CGPoint]] = []
        for r in 0...rows {
            var row: [CGPoint] = []
            for c in 0...cols {
                let fx = CGFloat(c) / CGFloat(cols)
                let fy = CGFloat(r) / CGFloat(rows)
                // Randpunkte bleiben am Blattrand – geknüllt wird innen.
                // Kräftigerer Versatz: Bruch statt sauberem Raster.
                let jx: CGFloat = (c == 0 || c == cols) ? 0 : CGFloat(rng.next() - 0.5) * 0.24
                let jy: CGFloat = (r == 0 || r == rows) ? 0 : CGFloat(rng.next() - 0.5) * 0.24
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
    /// Grundlicht von links oben; `tilt` verschiebt die Lichtrichtung –
    /// die Neigung des iPhones, als hielte man den Abzug unter Galerielicht.
    static func light(_ t: Tri, index: Int, tilt: CGPoint = .zero) -> Double {
        let cx = Double(t.a.x + t.b.x + t.c.x) / 3
        let cy = Double(t.a.y + t.b.y + t.c.y) / 3
        let wx = 0.5 + max(-0.45, min(0.45, Double(tilt.x) * 1.6))
        let wy = 0.5 + max(-0.45, min(0.45, Double(tilt.y) * 1.6))
        let lit = 1 - (cx * wx + cy * wy)
        // Bruch-Varianz: jede Facette liegt anders im Licht (deterministisch)
        let h = Double((UInt64(index) &* 2654435761) & 0xFF) / 255.0
        return (lit - 0.5) * 1.05 + (h - 0.5) * 0.5
    }
}

/// Neigungs-Licht: reagiert auf Änderungen der Gerätelage und driftet
/// langsam zur Ruhe zurück – unabhängig davon, wie man das iPhone hält.
/// Ohne Bewegungsdaten (Simulator) bleibt der Versatz null.
final class LightTilt: ObservableObject {
    @Published var offset: CGPoint = .zero
    private let manager = CMMotionManager()
    private var baseX = 0.0, baseY = 0.0, hasBase = false

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        hasBase = false
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            if !hasBase { baseX = g.x; baseY = g.y; hasBase = true }
            // Basislage folgt sehr langsam → Effekt reagiert auf Neigung,
            // kehrt in Ruhe aber sanft zur Mitte zurück
            baseX = baseX * 0.995 + g.x * 0.005
            baseY = baseY * 0.995 + g.y * 0.005
            let dx = g.x - baseX, dy = g.y - baseY
            offset = CGPoint(x: offset.x * 0.7 + dx * 0.3,
                             y: offset.y * 0.7 + dy * 0.3)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Stabile Faltung pro Werk: dieselbe Geometrie bei jedem App-Start.
enum FoldSeed {
    static func make(_ id: UUID?) -> UInt64 {
        guard let id else { return 7 }
        return id.uuidString.unicodeScalars.reduce(UInt64(7)) { ($0 &* 31) &+ UInt64($1.value) }
    }
}

/// Eine geknüllte Papierfläche – das Werk als Objekt.
/// Liegt ein Bild vor, wird es über die Facetten gebrochen; sonst entsteht
/// ein weißes Blatt, durch das Licht in Amber und Werkfarbe scheint –
/// wie in Tolinos Serien von 2024 (Full-Blown, Cracked).
/// `tilt` verschiebt die Lichtrichtung mit der Neigung des iPhones.
struct FoldedPaperHero: View {
    var image: UIImage? = nil
    var seed: UInt64 = 7
    var accent: Color = Theme.violet
    var animatesLight: Bool = true
    var tilt: CGPoint = .zero

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
                    // Leises Leuchten der Werkfarbe – vereint Foto und Blatt
                    Ellipse()
                        .fill(accent)
                        .frame(width: size.width * 0.8, height: size.height * 0.7)
                        .offset(x: -size.width * 0.3, y: size.height * 0.3)
                        .blur(radius: 34)
                        .opacity(0.22)
                        .blendMode(.softLight)
                } else {
                    // Lichtfelder HINTER dem Papier – Farbe scheint durchs Blatt
                    Theme.paperShade
                    Ellipse()
                        .fill(LinearGradient(colors: [Theme.amberLight, Theme.amber],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: size.width * 0.85, height: size.height * 0.8)
                        .offset(x: -size.width * 0.24, y: size.height * 0.2)
                        .blur(radius: 26)
                        .opacity(0.9)
                    Ellipse()
                        .fill(accent)
                        .frame(width: size.width * 0.75, height: size.height * 0.7)
                        .offset(x: size.width * 0.3, y: -size.height * 0.18)
                        .blur(radius: 30)
                        .opacity(0.85)
                }

                Canvas { ctx, canvasSize in
                    for (i, t) in tris.enumerated() {
                        var path = Path()
                        path.move(to: scaled(t.a, canvasSize))
                        path.addLine(to: scaled(t.b, canvasSize))
                        path.addLine(to: scaled(t.c, canvasSize))
                        path.closeSubpath()

                        // Ohne Bild: Papier in wechselnder Deckung –
                        // dünne Stellen lassen das Licht durch
                        if image == nil {
                            let h = Double((UInt64(i) &* 40503) & 0xFF) / 255.0
                            ctx.fill(path, with: .color(Color.white.opacity(0.40 + h * 0.48)))
                        }

                        let l = FoldFacets.light(t, index: i, tilt: tilt)
                        ctx.fill(path, with: .color(l >= 0
                            ? Color.white.opacity(l * 0.60)
                            : Color(red: 0.11, green: 0.10, blue: 0.09).opacity(-l * 0.45)))
                        ctx.stroke(path, with: .color(Theme.ink.opacity(0.12)), lineWidth: 0.5)
                        // Grat-Licht: stark belichtete Facetten glänzen an der Kante
                        if l > 0.28 {
                            ctx.stroke(path, with: .color(.white.opacity(min(0.55, l * 0.7))),
                                       lineWidth: 1.1)
                        }
                    }
                }

                // Ohne Neigungsdaten wandert das Licht langsam von selbst
                if animatesLight, !reduceMotion, tilt == .zero {
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
            // Reine Dekoration: darf niemals Tipps abfangen, sonst reagieren
            // die Zeilen und Kacheln nicht, in denen das Blatt sitzt.
            .allowsHitTesting(false)
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
            // Das Signet selbst – kein Buchstabe, sondern die Rekursion
            FoldMark(size: size * 0.66, color: Theme.paper, accent: Theme.amber)
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

/// Modus-Umschalter als Katalog-Reiter (statt System-Segmentschalter).
/// Wird im Video- und im Kamera-Tab verwendet.
struct ModeTabs: View {
    @Binding var modeRaw: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppMode.allCases) { m in
                Button { modeRaw = m.rawValue } label: {
                    Text(m.label)
                        .font(Theme.caption(11)).tracking(1.1).textCase(.uppercase)
                        .foregroundStyle(modeRaw == m.rawValue ? Theme.paper : Theme.ink)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(modeRaw == m.rawValue ? Theme.ink : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

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

/// Primäraktion in der Dunkelkammer: gefüllter Papierton auf Dunkel.
struct DarkPrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption(11))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.darkroom)
            .padding(.vertical, 13)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .background(Theme.paperOnDark.opacity(configuration.isPressed ? 0.78 : 1))
    }
}

/// Sekundäraktion in der Dunkelkammer: Kontur auf Dunkel.
struct DarkSecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption(11))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.paperOnDark.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 13)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .overlay(Rectangle().stroke(Theme.paperOnDark.opacity(0.35), lineWidth: 1))
    }
}

/// Quadratischer Icon-Knopf (48 pt) – z. B. Mistkübel oder Werkzeuge.
/// `stage` wählt Galerie- oder Dunkelkammer-Farben, `destructive` färbt
/// das Symbol Oxblood (nur auf heller Bühne sinnvoll).
struct IconSquare: View {
    enum Stage { case paper, dark }
    let icon: String
    var stage: Stage = .paper
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(destructive && stage == .paper
                                 ? Theme.oxblood
                                 : stage == .paper ? Theme.ink : Theme.paperOnDark.opacity(0.85))
                .frame(width: 48, height: 48)
                .background(stage == .paper ? Theme.paper : Color.black.opacity(0.35))
                .overlay(Rectangle().stroke(
                    destructive && stage == .paper
                    ? Theme.oxblood.opacity(0.45)
                    : stage == .paper ? Theme.hairline : Theme.paperOnDark.opacity(0.35),
                    lineWidth: 1))
        }
        .buttonStyle(.plain)
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

/// Edition unter Acrylglas: Passepartout, Keyline, feiner Glanz, Schatten –
/// wie seine „fine art pigment prints sealed under acrylic glass".
struct EditionFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(Theme.paper)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
            .overlay(
                LinearGradient(colors: [.white.opacity(0.20), .clear, .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
            )
            .shadow(color: Theme.ink.opacity(0.20), radius: 18, x: 0, y: 10)
    }
}

extension View {
    /// Gerahmte Tafel (schwarze Keyline).
    func plate() -> some View { modifier(PlateFrame()) }
    /// Alias (Rückwärtskompatibilität mit älteren Views).
    func passepartout() -> some View { modifier(PlateFrame()) }
    /// Edition unter Acrylglas (Glanz + Schatten).
    func editionPlate() -> some View { modifier(EditionFrame()) }
    /// Wie ein gerahmter Abzug an der Wand: weicher Schlagschatten.
    func hung() -> some View {
        self.shadow(color: Theme.ink.opacity(0.16), radius: 15, x: 0, y: 8)
    }
    /// Galeriewand mit Lichtverlauf – Ausstellungslicht statt flacher Fläche.
    func galleryStage() -> some View {
        self.background(
            LinearGradient(colors: [Theme.paper, Theme.paper, Theme.paperDeep],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }
    /// Alias (Rückwärtskompatibilität).
    func paperStage() -> some View { galleryStage() }
}
