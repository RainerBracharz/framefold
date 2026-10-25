import Foundation

/// Wann FrameFold um eine Bewertung bittet: nach dem dritten und dem
/// zehnten fertigen Film, höchstens einmal je App-Version – nie mitten in
/// der Arbeit. Apple begrenzt die Abfrage ohnehin auf dreimal im Jahr.
enum ReviewPrompt {
    static let milestones: Set<Int> = [3, 10]

    /// Einen fertigen Film zählen; `true`, wenn jetzt gefragt werden soll.
    static func noteFinishedFilm(defaults: UserDefaults = .standard,
                                 version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") -> Bool {
        // UI-Tests und Screenshot-Läufe: nie fragen, der Dialog läge über allem
        if CommandLine.arguments.contains("--ff-fresh-start") || Platform.autostart { return false }
        let count = defaults.integer(forKey: "finishedFilms") + 1
        defaults.set(count, forKey: "finishedFilms")
        guard milestones.contains(count), defaults.string(forKey: "reviewAskedVersion") != version else { return false }
        defaults.set(version, forKey: "reviewAskedVersion")
        return true
    }
}
