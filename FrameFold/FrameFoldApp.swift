import SwiftUI

/// Erststart in drei Karten: was die App macht, die zwei Wege, und wie
/// ausführlich sie sich zeigen soll. Erscheint genau einmal, überspringbar.
struct OnboardingView: View {
    let onFinish: () -> Void

    @AppStorage("appMode") private var modeRaw: Int = AppMode.basic.rawValue
    @State private var page = 0

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
                .padding(.horizontal, 26)
                .padding(.top, 20)

                Spacer(minLength: 12)

                Group {
                    switch page {
                    case 0: cardOne
                    case 1: cardTwo
                    default: cardThree
                    }
                }
                .padding(.horizontal, 26)

                Spacer()

                // Fortschritt als Falzmarken
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Rectangle()
                            .fill(i == page ? Theme.ink : Theme.hairline)
                            .frame(width: i == page ? 22 : 10, height: 2)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 14)

                if page < 2 {
                    Button("Weiter") {
                        withAnimation(.smooth(duration: 0.35)) { page += 1 }
                    }
                    .buttonStyle(InkButtonStyle())
                    .padding(.horizontal, 26)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    // 1 – Was die App macht
    private var cardOne: some View {
        VStack(alignment: .leading, spacing: 16) {
            FoldedPaperHero(seed: 11, accent: Theme.amber, animatesLight: true)
                .frame(height: 210)
                .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
                .hung()
            CatalogLabel("Bild · Objekt · Bild")
            Text("Aus deiner Arbeit\nwird eine Stopmotion.")
                .font(Theme.serifItalic(27))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("FrameFold findet die ruhigen Momente und verwirft Bilder, auf denen deine Hände zu sehen sind. Alles bleibt auf dem Gerät.")
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.graphite)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 2 – Die zwei Wege
    private var cardTwo: some View {
        VStack(alignment: .leading, spacing: 16) {
            CatalogLabel("Zwei Wege")
            Text("Video wählen —\noder live aufnehmen.")
                .font(Theme.serifItalic(27))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            wayRow(icon: "film",
                   title: "Video wählen",
                   text: "Ein fertiges Video aus der Mediathek — FrameFold macht den Rest.")
            wayRow(icon: "camera",
                   title: "Direkt aufnehmen",
                   text: "iPhone aufs Stativ, arbeiten. Es löst von selbst aus, sobald deine Hände aus dem Bild sind.")
        }
    }

    // 3 – Modus wählen
    private var cardThree: some View {
        VStack(alignment: .leading, spacing: 16) {
            CatalogLabel("Zum Schluss")
            Text("Wie möchtest du\narbeiten?")
                .font(Theme.serifItalic(27))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            modeChoice(mode: .basic,
                       title: "Einfach",
                       text: "Nur das Nötigste: auswählen, auslösen, fertig. Empfohlen für den Anfang.")
            modeChoice(mode: .tolino,
                       title: "Alles zeigen",
                       text: "Format, Bildrate, Effekte, Faltvorlagen, Ausstellung — die volle Werkstatt.")

            Text("Lässt sich jederzeit über das Regler-Symbol ändern.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.graphite)

            Button("Los geht's") { onFinish() }
                .buttonStyle(InkButtonStyle())
                .padding(.top, 4)
        }
    }

    private func wayRow(icon: String, title: String, text: String) -> some View {
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
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.graphite)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func modeChoice(mode: AppMode, title: String, text: String) -> some View {
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
                        .font(Theme.mono(11.5))
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
    }
}

@main
struct FrameFoldApp: App {
    @StateObject private var projectStore = ProjectStore()
    @State private var selectedTab = 0
    /// Erststart: einmaliger Onboarding-Flow, der auch den Modus setzt.
    @AppStorage("didOnboard") private var didOnboard = false

    init() {
        AppFonts.register() // Fraunces + Inter aus dem Asset-Katalog registrieren
        // Papier-&-Falz-Erscheinungsbild für Tab- und Navigationsleiste
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Theme.paper)
        tabAppearance.shadowColor = UIColor(Theme.hairline)
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
                    .tabItem { Label("Projekte", systemImage: "folder") }
                    .tag(2)
            }
            .environmentObject(projectStore)
            // Die Tab-Leiste steht IMMER auf Papier – die schwebende Leiste
            // passt sich sonst dem Inhalt an (dunkel in der Dunkelkammer,
            // hell überm Kamerabild), und keine einzelne Akzentfarbe bleibt
            // auf beidem lesbar. Fester Grund + Tusche funktioniert überall.
            .tint(Theme.ink)
            .preferredColorScheme(.light) // Galeriewand, konsistent im Atelier
            .overlay {
                if !didOnboard {
                    OnboardingView { didOnboard = true }
                        .transition(.opacity)
                }
            }
        }
    }
}
