import Foundation

/// Wann FrameFold um eine Bewertung bittet: nach dem ersten, dem fünften
/// und dem fünfzehnten fertigen Film, höchstens einmal je App-Version – nie
/// mitten in der Arbeit. Der erste Film ist der Moment, in dem die App ihr
/// Versprechen eingelöst hat; bis zum dritten kamen zu wenige (Stand 11/2026:
/// eine Bewertung bei 131 Installationen). Apple begrenzt die Abfrage ohnehin
/// auf dreimal im Jahr.
enum ReviewPrompt {
    static let milestones: Set<Int> = [1, 5, 15]

    /// Einen fertigen Film zählen; `true`, wenn jetzt gefragt werden soll.
    static func noteFinishedFilm(defaults: UserDefaults = .standard,
                                 version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") -> Bool {
        // UI-Tests und Screenshot-Läufe: nie fragen, der Dialog läge über allem
        #if DEBUG
        if CommandLine.arguments.contains("--ff-fresh-start") { return false }
        #endif
        if Platform.autostart { return false }
        let count = defaults.integer(forKey: "finishedFilms") + 1
        defaults.set(count, forKey: "finishedFilms")
        guard milestones.contains(count), defaults.string(forKey: "reviewAskedVersion") != version else { return false }
        defaults.set(version, forKey: "reviewAskedVersion")
        return true
    }
}
