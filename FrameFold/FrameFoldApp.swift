import SwiftUI

@main
struct FrameFoldApp: App {
    @StateObject private var projectStore = ProjectStore()
    @State private var selectedTab = 0

    init() {
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
                    .tabItem { Label("Video", systemImage: "film") }
                    .tag(0)
                LiveCaptureView()
                    .tabItem { Label("Kamera", systemImage: "camera") }
                    .tag(1)
                ProjectsView()
                    .tabItem { Label("Projekte", systemImage: "folder") }
                    .tag(2)
            }
            .environmentObject(projectStore)
            .tint(Theme.ink)
            .preferredColorScheme(.light) // Galeriewand, konsistent im Atelier
        }
    }
}
