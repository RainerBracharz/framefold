import SwiftUI

/// Erststart in drei Karten: was die App macht, die zwei Wege, und wie
/// ausführlich sie sich zeigen soll. Erscheint genau einmal, überspringbar.
struct OnboardingView: View {
    let onFinish: () -> Void

    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    @State private var page = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Breite Fläche (aufgeklapptes iPhone Duo): Karten als Doppelseite.
    private var isSpread: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.paper, Theme.paper, Theme.paperDeep],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    LogoTile(size: 30)
                    Spacer()
                    if page < 2 {
                        Button("Überspringen") { onFinish() }
                            .font(Theme.caption(11))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.graphite)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer(minLength: 12)

                Group {
                    switch page {
                    case 0: cardOne
                    case 1: cardTwo
                    default: cardThree
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // Fortschritt als Falzmarken
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Rectangle()
                            .fill(i == page ? Theme.ink : Theme.hairline)
                            .frame(width: i == page ? 22 : 10, height: 2)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                if page < 2 {
                    Button("Weiter") {
                        withAnimation(.smooth(duration: 0.35)) { page += 1 }
                    }
                    .buttonStyle(InkButtonStyle())
                    .frame(maxWidth: isSpread ? 360 : .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    // 1 – Was die App macht
    private var cardOne: some View {
        spread {
            FoldedPaperHero(seed: 11, accent: Theme.amber, animatesLight: true)
                .frame(height: isSpread ? 320 : 210)
                .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                .hung()
        } right: {
            CatalogLabel("Bild · Objekt · Bild")
            Text("Aus deiner Arbeit\nwird eine Stopmotion.")
                .font(Theme.serifItalic(28))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("FrameFold findet die ruhigen Momente und verwirft Bilder, auf denen deine Hände zu sehen sind. Alles bleibt auf dem Gerät.")
                .font(Theme.mono(13))
                .foregroundStyle(Theme.graphite)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 2 – Die zwei Wege
    private var cardTwo: some View {
        spread {
            CatalogLabel("Zwei Wege")
            Text("Video wählen —\noder live aufnehmen.")
                .font(Theme.serifItalic(28))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } right: {

            wayRow(icon: "film",
                   title: "Video wählen",
                   text: "Ein fertiges Video aus der Mediathek — FrameFold macht den Rest.")
            wayRow(icon: "camera",
                   title: "Direkt aufnehmen",
                   text: Platform.isMac
                       ? "Kamera über den Tisch, arbeiten. Es löst von selbst aus, sobald deine Hände aus dem Bild sind."
                       : "iPhone aufs Stativ, arbeiten. Es löst von selbst aus, sobald deine Hände aus dem Bild sind.")
        }
    }

    // 3 – Modus wählen
    private var cardThree: some View {
        spread {
            CatalogLabel("Zum Schluss")
            Text("Wie möchtest du\narbeiten?")
                .font(Theme.serifItalic(28))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } right: {

            modeChoice(mode: .basic,
                       title: "Einfach",
                       text: "Nur das Nötigste: auswählen, auslösen, fertig. Empfohlen für den Anfang.")
            modeChoice(mode: .tolino,
                       title: "Atelier",
                       text: "Format, Bildrate, Effekte, Faltvorlagen, Ausstellung — die volle Werkstatt.")

            Text("Lässt sich jederzeit über das Regler-Symbol ändern.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.graphite)

            Button("Los geht's") { onFinish() }
                .buttonStyle(InkButtonStyle())
                .padding(.top, 4)
        }
    }

    /// Eine Karte: schmal untereinander, breit als Doppelseite – links und
    /// rechts des Falzes je eine Hälfte.
    @ViewBuilder
    private func spread<L: View, R: View>(@ViewBuilder _ left: () -> L,
                                           @ViewBuilder right: () -> R) -> some View {
        if isSpread {
            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 16) { left() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) { right() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                left()
                right()
            }
        }
    }

    private func wayRow(icon: String, title: LocalizedStringResource, text: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.ink)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.caption(13)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.graphite)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func modeChoice(mode: AppMode, title: LocalizedStringResource, text: LocalizedStringResource) -> some View {
        let selected = modeRaw == mode.rawValue
        return Button {
            withAnimation(.snappy(duration: 0.18)) { modeRaw = mode.rawValue }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.caption(13)).tracking(1.5).textCase(.uppercase)
                        .foregroundStyle(selected ? Theme.paper : Theme.ink)
                    Text(text)
                        .font(Theme.mono(12))
                        .foregroundStyle(selected ? Theme.paper.opacity(0.75) : Theme.graphite)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Rectangle()
                    .fill(selected ? Theme.paper : Color.clear)
                    .frame(width: 12, height: 12)
                    .overlay(Rectangle().stroke(selected ? Theme.paper : Theme.graphite, lineWidth: 1.2))
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.ink : Theme.paper)
            .overlay(Rectangle().stroke(selected ? Theme.ink : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@main
struct FrameFoldApp: App {
    @StateObject private var projectStore = ProjectStore()
    @State private var selectedTab = Platform.startTab ?? (Platform.autostart ? 1 : 0)
    /// Erststart: einmaliger Onboarding-Flow, der auch den Modus setzt.
    @AppStorage("didOnboard") private var didOnboard = false
    @ObservedObject private var studioHub = StudioHub.shared

    init() {
        // UI-Test-Lauf: Erststart herstellen (Onboarding, Kamera-Tipp, Modus).
        // Als Löschung statt als Startargument-Wert, weil ein Argument-Wert
        // alles überstimmen würde, was die App danach selbst speichert.
        // Nur in der Debug-Fassung: Die Store-Fassung hat keine versteckten
        // Schalter (App Review Guideline 2.5.19).
        #if DEBUG
        if CommandLine.arguments.contains("--ff-fresh-start") {
            let defaults = UserDefaults.standard
            for key in ["didOnboard", "didSeeCameraTip", "appMode"] {
                defaults.removeObject(forKey: key)
            }
        }
        #endif
        AppFonts.register() // Fraunces + Inter aus dem Asset-Katalog registrieren
        // Papier-&-Falz-Erscheinungsbild für Tab- und Navigationsleiste
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Theme.paper)
        tabAppearance.shadowColor = UIColor(Theme.hairline)
        // Item-Farben explizit: Tusche für aktiv, Graphit für inaktiv –
        // unabhängig davon, was der System-Stil sonst erraten würde.
        for item in [tabAppearance.stackedLayoutAppearance,
                     tabAppearance.inlineLayoutAppearance,
                     tabAppearance.compactInlineLayoutAppearance] {
            item.selected.iconColor = UIColor(Theme.ink)
            item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.ink)]
            item.normal.iconColor = UIColor(Theme.graphite)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.graphite)]
        }
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Theme.paper)
        navAppearance.shadowColor = UIColor(Theme.hairline)
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContentView(selectedTab: $selectedTab)
                    .toolbarBackground(Theme.paper, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem { Label("Video", systemImage: "film") }
                    .tag(0)
                LiveCaptureView()
                    .toolbarBackground(Theme.paper, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem { Label("Kamera", systemImage: "camera") }
                    .tag(1)
                ProjectsView()
                    .toolbarBackground(Theme.paper, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem { Label("Werke", systemImage: "folder") }
                    .tag(2)
            }
            .environmentObject(projectStore)
            // „Mit der Kamera weiterarbeiten" aus der Werkansicht
            .onReceive(NotificationCenter.default.publisher(for: .ffContinueWork)) { _ in
                selectedTab = 1
            }
            // Ein Bild wurde neu aufgenommen: zurück ins Werk
            .onReceive(NotificationCenter.default.publisher(for: .ffOpenWork)) { _ in
                selectedTab = 2
            }
            // Externe Bildschirme (HDMI/AirPlay) zeigen den Studio-Monitor
            .task {
                StudioMonitorHub.shared.activate()
                WatchLink.shared.activate()   // Fernauslöser am Handgelenk
                #if targetEnvironment(macCatalyst)
                // Kleiner gezogen, quetscht sich der Sucher neben der
                // Seitenleiste auf Briefmarkengröße.
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.sizeRestrictions?.minimumSize = CGSize(width: 820, height: 620)
                    #if DEBUG
                    // Store-Screenshots: feste Fenstergröße, z. B. FF_WINDOW=1440x900.
                    if let spec = ProcessInfo.processInfo.environment["FF_WINDOW"],
                       case let parts = spec.split(separator: "x").compactMap({ Double($0) }),
                       parts.count == 2 {
                        let size = CGSize(width: parts[0], height: parts[1])
                        scene.sizeRestrictions?.minimumSize = size
                        scene.sizeRestrictions?.maximumSize = size
                    }
                    #endif
                }
                #endif
            }
            // Die Tab-Leiste steht IMMER auf Papier – die schwebende Leiste
            // passt sich sonst dem Inhalt an (dunkel in der Dunkelkammer,
            // hell überm Kamerabild), und keine einzelne Akzentfarbe bleibt
            // auf beidem lesbar. Fester Grund + Tusche funktioniert überall.
            .tint(Theme.ink)
            // Schriften wachsen mit „Größerer Text" mit; nach oben begrenzt,
            // damit Sucher-HUD und Kontaktbogen nicht auseinanderfallen.
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            // Galeriewand, konsistent im Atelier – außer in der Dunkelkammer:
            // Dort brauchen Uhrzeit und Akku in der Statusleiste helle Schrift,
            // sonst stehen sie dunkel auf dunkel. Sheets und Dialoge setzen
            // für sich wieder hell (siehe LiveCaptureView).
            .preferredColorScheme(selectedTab == 1 && didOnboard ? .dark : .light)
            .overlay {
                if !didOnboard {
                    OnboardingView { didOnboard = true }
                        .transition(.opacity)
                }
            }
        }
        .commands { menuCommands }
    }

    /// Menüleiste und Tastenkürzel (am Mac, an iPad-/iPhone-Tastaturen).
    /// „Neues Fenster" fällt bewusst weg: Ein zweites Fenster bekäme eine
    /// zweite Kamera-Sitzung auf dieselbe Kamera.
    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Werk") { show(tab: 2, then: .ffNewWork) }
                .keyboardShortcut("n")
            Button("Video öffnen …") { show(tab: 0, then: .ffOpenVideoFile) }
                .keyboardShortcut("o")
        }
        CommandMenu("Aufnahme") {
            // „Bild ab/auf“: die Vor-/Zurück-Tasten jeder Präsentations-
            // Fernbedienung – auslösen und zurücknehmen, ohne Kamera oder
            // Tisch zu berühren (Klassenzimmer, Dokumentenkamera).
            Button("Auslösen") { post(.ffCaptureNow) }
                .keyboardShortcut(.pageDown, modifiers: [])
            Button("Fertig") { post(.ffFinishSession) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Letztes Bild zurücknehmen") { post(.ffUndoLastFrame) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Zurücknehmen (Fernbedienung)") { post(.ffUndoLastFrame) }
                .keyboardShortcut(.pageUp, modifiers: [])
        }
        CommandMenu("Studio") {
            // Nur aktiv, solange die Studio-Arbeitsfläche offen ist – sonst
            // würden einfache Tasten jedes Textfeld der App kapern.
            Group {
                studioButton("Auslösen", .capture, .return)
                studioButton("Testaufnahme", .testShot, "t", [.shift, .option])
                Divider()
                studioButton("Bild zurück", .stepBack, .leftArrow)
                studioButton("Bild vor", .stepForward, .rightArrow)
                studioButton("Live-Bild", .live, "l")
                studioButton("Abspielen / Stopp", .play, "p")
                studioButton("Kurz abspielen", .shortPlay, "k")
                Divider()
                studioButton("Umschalten Live / Aufnahme", .toggle, "t")
                studioButton("Auto-Umschalten", .autoToggle, "t", .shift)
                studioButton("Schleifenanfang", .loopIn, "i")
                studioButton("Schleifenende", .loopOut, "o")
                studioButton("Schleife aufheben", .loopClear, "x")
            }
            Group {
                Divider()
                studioButton("Bild verdoppeln", .duplicate, "d")
                studioButton("Bild entfernen", .delete, .delete)
                studioButton("Notiz …", .note, "n")
                studioButton("X-Sheet …", .xsheet, "x", .shift)
                Divider()
                studioButton("Mehr Zwiebelhaut", .onionMore, "]")
                studioButton("Weniger Zwiebelhaut", .onionLess, "[")
                studioButton("Ansicht wechseln", .cycleView, "m")
            }
        }
        CommandGroup(before: .toolbar) {
            Divider()
            Button("Video") { selectedTab = 0 }.keyboardShortcut("1")
            Button("Kamera") { selectedTab = 1 }.keyboardShortcut("2")
            Button("Werke") { selectedTab = 2 }.keyboardShortcut("3")
        }
    }

    private func studioButton(_ title: LocalizedStringKey, _ command: StudioCommand,
                              _ key: KeyEquivalent, _ modifiers: EventModifiers = []) -> some View {
        Button(title) { studioHub.send(command) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!studioHub.isActive)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Erst den Tab zeigen, dann den Befehl schicken – die Ansicht muss
    /// erschienen sein, um ihn zu empfangen.
    private func show(tab: Int, then name: Notification.Name) {
        selectedTab = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { post(name) }
    }
}
