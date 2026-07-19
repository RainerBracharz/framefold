import SwiftUI

@main
struct FrameFoldApp: App {
    @StateObject private var projectStore = ProjectStore()

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
            TabView {
                ContentView()
                    .tabItem { Label("Video", systemImage: "film.stack") }
                LiveCaptureView()
                    .tabItem { Label("Live", systemImage: "camera") }
                ProjectsView()
                    .tabItem { Label("Projekte", systemImage: "folder") }
            }
            .environmentObject(projectStore)
            .tint(Theme.ink)
            .preferredColorScheme(.light) // Papierbühne, konsistent im Atelier
        }
    }
}
