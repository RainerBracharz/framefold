//
//  FrameFoldUITests.swift
//  FrameFoldUITests
//
//  Tippt sich durch die App und legt an jeder Station einen Screenshot ab.
//  Gedacht für die Durchsicht von Übersetzungen (Knopfbreiten, Umbrüche) und
//  als Rohmaterial für Store-Screenshots – in jeder Sprache, ohne Handarbeit.
//
//  Aufruf (Sprache und Zielordner kommen per Umgebung, Vorgabe: en / Attachments):
//
//    TEST_RUNNER_FF_LANG=en TEST_RUNNER_FF_SHOT_DIR=$HOME/Desktop/ff-shots \
//    xcodebuild test -scheme FrameFold -destination 'id=<SIMULATOR-UDID>' \
//      -only-testing:FrameFoldUITests
//
//  Die Knöpfe werden über ihre sichtbaren Texte gefunden, Groß/Klein egal;
//  jede Station kennt die englische und die deutsche Fassung, damit derselbe
//  Lauf für beide Sprachen taugt.
//

import XCTest

final class FrameFoldUITests: XCTestCase {

    private var app: XCUIApplication!
    private var shotDir: URL?
    private var lang = "en"
    /// FF_MODE=all: im Onboarding „Alles zeigen" wählen – die Store-Bilder
    /// entstehen in der vollen Werkstatt, die Durchsicht im Einfach-Modus.
    private var showAll = false
    private var shotIndex = 0

    override func setUpWithError() throws {
        continueAfterFailure = true   // eine fehlende Station soll die übrigen nicht kosten

        let env = ProcessInfo.processInfo.environment
        lang = env["FF_LANG"] ?? "en"
        showAll = env["FF_MODE"] == "all"
        if let dir = env["FF_SHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(lang)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            shotDir = url
        }

        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(lang))",
            "-AppleLocale", ["de": "de_AT", "fr": "fr_FR"][lang] ?? "en_US",
            // Erststart herstellen: Onboarding und Kamera-Tipp sollen mit drauf.
            "--ff-fresh-start",
        ]
        // App-Vorschau: Simulator-Kamera spielt die vorbereitete Faltung ab
        if let frames = env["FF_SIM_FRAMES"], !frames.isEmpty {
            app.launchEnvironment["FF_SIM_FRAMES"] = frames
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Durchgang

    @MainActor
    func testWalkthrough() throws {
        // 1–3 Onboarding
        shot("onboarding-1")
        tap(["Next", "Weiter", "Suivant"])
        shot("onboarding-2")
        tap(["Next", "Weiter", "Suivant"])
        usleep(500_000)   // Kartenwechsel ist animiert; sonst trifft der nächste Tipp die alte Karte
        if showAll { tap(["Show all", "Alles zeigen", "Tout afficher"]) }
        shot("onboarding-3")
        tap(["Get started", "Los geht's", "C’est parti"], prefix: true)

        // 4 Video-Tab, Startansicht
        sleep(1)
        shot("video-start")

        // 5 Einstellungen (Regler-Symbol oben rechts)
        if tap(["Settings", "Einstellungen", "Réglages"]) {
            sleep(1)
            shot("video-settings")
            tap(["Done", "Fertig", "Terminé"])
        }

        // 6 Kamera-Tab: Tipp beim ersten Öffnen
        tap(["Camera", "Kamera", "Caméra"])
        sleep(1)
        shot("camera-tip")
        tap(["Got it", "Verstanden", "Compris"])

        // 7 Werk wählen
        sleep(1)
        shot("camera-chooser")

        // 8 Neues Werk anlegen → Sucher
        if tap(["New work", "Neues Werk", "Nouvelle œuvre"]) {
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                let field = alert.textFields.firstMatch
                field.tap()
                field.typeText("Origami crane")
                shot("camera-new-work")
                // Alert-Knöpfe hängen in iOS 26 nicht unter dem Alert-Element
                tap(["Create & start", "Anlegen & starten", "Créer et lancer"])
            }
        }

        // Sucher: Simulator-Kamera liefert synthetische Bilder, kurz warten
        sleep(5)
        shot("camera-capture")

        // 9 Aufnahme-Einstellungen
        if tap(["Capture settings", "Aufnahme-Einstellungen", "Réglages de prise de vue"]) {
            sleep(1)
            shot("camera-settings")
            tap(["Done", "Fertig", "Terminé"])
        }

        // Drei Bilder von Hand auslösen, dann abschließen („Done · 3")
        for _ in 0..<3 {
            tap(["Shutter", "Auslöser", "Déclencheur"])
            usleep(700_000)
        }
        sleep(1)
        shot("camera-capture-3")
        tap(["Done ·", "Fertig ·", "Terminé ·"], prefix: true)

        // 10 Ergebnis
        sleep(4)
        shot("camera-result")
        tap(["Done", "Fertig", "Terminé"])

        // 11 Projekte-Tab
        tap(["Projects", "Projekte", "Projets"])
        sleep(1)
        shot("projects")

        // 12 Werk öffnen
        if tap(["Origami crane"], prefix: true) {
            sleep(1)
            shot("project-detail")
            // Testwerk wieder wegräumen, sonst sammelt sich mit jedem Lauf eines an.
            // Der Knopf steht ganz unten – in der vollen Werkstatt außerhalb
            // des Bildschirms, ein Tipp ins Leere öffnet keine Rückfrage.
            app.swipeUp(); app.swipeUp(); app.swipeUp()
            if tap(["Delete project", "Projekt löschen", "Supprimer le projet"]) {
                tap(["Delete permanently", "Endgültig löschen", "Supprimer définitivement"])
                sleep(1)
            }
            // Falls wir noch im Detail stehen: zurück zur Liste
            if app.navigationBars.buttons.firstMatch.exists,
               !app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'frames' OR label CONTAINS[c] 'Bilder' OR label CONTAINS[c] 'images'")).firstMatch.exists {
                tap(["Back", "Zurück", "Retour", "Projets"], timeout: 1)
            }
        }

        // 13 Ein älteres Werk mit echtem Material, falls vorhanden – für den
        // Store sind das die stärkeren Bilder als die Simulator-Testaufnahme.
        // „Fratze" bevorzugt – 28 echte Bilder, ohne Simulator-Reste –, sonst
        // das erste Werk, das nicht unser Testwerk ist.
        let faltung = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Fratze'")).firstMatch
        let older = app.buttons.matching(NSPredicate(
            format: "(label CONTAINS[c] 'frames' OR label CONTAINS[c] 'Bilder' OR label CONTAINS[c] 'images') AND NOT label CONTAINS 'Origami'"
        )).firstMatch
        let pick = faltung.waitForExistence(timeout: 2) ? faltung : older
        if pick.waitForExistence(timeout: 2) {
            pick.tap()
            sleep(1)
            shot("project-detail-existing")
            // Ans Ende scrollen: Vorschau, Teilen, Druckoptionen
            app.swipeUp(); app.swipeUp(); app.swipeUp()
            sleep(1)
            shot("project-detail-bottom")
            // Video montieren: danach stehen Vorschau und „Teilen" im Bild
            if tap(["Export stop-motion", "Stopmotion exportieren", "Exporter le stop motion"]) {
                // Montage abwarten: fertig, sobald „Teilen" auftaucht (max. 60 s)
                let share = app.buttons.matching(NSPredicate(
                    format: "label CONTAINS[c] 'share' OR label CONTAINS[c] 'teilen' OR label CONTAINS[c] 'partager'")).firstMatch
                _ = share.waitForExistence(timeout: 60)
                sleep(1)
                app.swipeUp(); app.swipeUp()
                sleep(1)
                shot("project-detail-exported")
            }
        }
    }

    // MARK: - App-Vorschau

    /// Ablauf für die Store-Vorschau (scripts/record_preview.sh nimmt dabei den
    /// Bildschirm auf): Faltung live aufnehmen, Film wächst mit, Ergebnis,
    /// Daumenkino. Gemächlicher als der Durchgang – hier wird zugeschaut.
    /// Jeder Schritt landet mit Uhrzeit in events.txt, damit der Schnitt
    /// die Stellen im Video findet.
    @MainActor
    func testPreview() throws {
        guard ProcessInfo.processInfo.environment["FF_SIM_FRAMES"] != nil else {
            throw XCTSkip("Nur für die App-Vorschau (FF_SIM_FRAMES fehlt)")
        }
        let name = ["de": "Faltung", "fr": "Pliage"][lang] ?? "Fold"
        mark("launch")
        tap(["Next", "Weiter", "Suivant"])
        usleep(400_000)
        tap(["Next", "Weiter", "Suivant"])
        usleep(600_000)
        // Apostroph typografisch oder gerade – nur den Anfang vergleichen
        tap(["Get started", "Los geht", "C’est parti", "C'est parti"], prefix: true)
        sleep(1)
        tap(["Camera", "Kamera", "Caméra"])
        sleep(1)
        tap(["Got it", "Verstanden", "Compris"])
        sleep(1)
        mark("chooser")
        if tap(["New work", "Neues Werk", "Nouvelle œuvre"]) {
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                let field = alert.textFields.firstMatch
                field.tap()
                field.typeText(name)
                tap(["Create & start", "Anlegen & starten", "Créer et lancer"])
            }
        }
        mark("camera")
        // Die Bildfolge hält jede Faltung ~9,5 s still: Nach einem starken
        // Motivwechsel gibt das Schärfe-Tor erst nach 8 s frei. 8 Faltungen ≈ 95 s.
        sleep(40)
        // Im geteilten Sucher (iPhone Duo aufgeklappt) gibt es keine Kachel
        // zum Antippen – der Film steht dort ohnehin groß daneben.
        let loopTile = app.buttons.matching(NSPredicate(
            format: "label ==[c] 'The film so far' OR label ==[c] 'Der Film bisher' OR label ==[c] 'Le film jusqu’ici'")).firstMatch
        if loopTile.waitForExistence(timeout: 2), loopTile.isHittable {
            loopTile.tap()
            mark("loop-large")
        }
        sleep(56)
        mark("finish")
        tap(["Done ·", "Fertig ·", "Terminé ·"], prefix: true)
        // Ergebnis: Der Film wird erst montiert – auf „Fertig" warten statt raten
        let doneButton = app.buttons.matching(NSPredicate(
            format: "label ==[c] 'Done' OR label ==[c] 'Fertig' OR label ==[c] 'Terminé'")).firstMatch
        _ = doneButton.waitForExistence(timeout: 30)
        mark("result")
        sleep(5)
        tap(["Done", "Fertig", "Terminé"], timeout: 10)
        sleep(1)
        tap(["Projects", "Projekte", "Projets"])
        sleep(1)
        mark("projects")
        if tap([name], prefix: true) {
            sleep(2)
            mark("detail")
            app.swipeUp()
            sleep(1)
            app.swipeUp()
            sleep(1)
            if tap(["Flip book", "Daumenkino", "Folioscope"]) {
                mark("flipbook")
                let share = app.buttons.matching(NSPredicate(
                    format: "label ==[c] 'Share flip book' OR label ==[c] 'Daumenkino teilen' OR label ==[c] 'Partager le folioscope'")).firstMatch
                if share.waitForExistence(timeout: 30) {
                    mark("flipbook-ready")
                    sleep(4)
                }
            }
            mark("end")
            // Aufräumen wie im Durchgang
            app.swipeUp(); app.swipeUp(); app.swipeUp()
            if tap(["Delete project", "Projekt löschen", "Supprimer le projet"]) {
                tap(["Delete permanently", "Endgültig löschen", "Supprimer définitivement"])
                sleep(1)
            }
        }
    }

    private func mark(_ event: String) {
        guard let dir = shotDir else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, event)
        let url = dir.appendingPathComponent("events.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helfer

    /// Tippt das erste Element, dessen Beschriftung zu einer der Varianten
    /// passt – Groß/Klein egal, weil Versalien-Knöpfe ihr Label mit
    /// hochschreiben. Knöpfe zuerst, dann alles andere (SwiftUI meldet
    /// Textknöpfe gelegentlich als StaticText).
    @discardableResult
    private func tap(_ labels: [String], in root: XCUIElement? = nil,
                     prefix: Bool = false, timeout: TimeInterval = 4) -> Bool {
        let scope = root ?? app!
        let op = prefix ? "BEGINSWITH[c]" : "==[c]"
        let subs = labels.map { NSPredicate(format: "label \(op) %@ OR title \(op) %@", $0, $0) }
        let pred = NSCompoundPredicate(orPredicateWithSubpredicates: subs)

        let button = scope.buttons.matching(pred).firstMatch
        if button.waitForExistence(timeout: timeout) {
            button.tap()
            return true
        }
        let any = scope.descendants(matching: .any).matching(pred).firstMatch
        if any.waitForExistence(timeout: 1) {
            any.tap()
            return true
        }
        note(labels.joined(separator: " / "))
        return false
    }

    private func shot(_ name: String) {
        shotIndex += 1
        let file = String(format: "%02d-%@", shotIndex, name)
        usleep(600_000)   // Übergänge ausklingen lassen, sonst halb ausgeblendete Knöpfe
        // iPhone Duo, aufgeklappt: `XCUIScreen.main` läuft dort in eine
        // Zeitüberschreitung, also das App-Fenster fotografieren
        // (FF_SHOT_WINDOW=1). Zugeklappt ist es umgekehrt – dort hängt das
        // Fensterfoto, und der Hauptbildschirm ist der richtige Weg.
        let useWindow = ProcessInfo.processInfo.environment["FF_SHOT_WINDOW"] == "1"
        let image = useWindow ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: image)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)

        if let dir = shotDir {
            try? image.pngRepresentation.write(to: dir.appendingPathComponent(file + ".png"))
        }
    }

    /// Nicht gefundene Knöpfe sind ein Hinweis, kein Scheitern: sie landen
    /// in log.txt, der Lauf gilt trotzdem als bestanden, solange die Bilder da sind.
    private func note(_ message: String) {
        log("Kein Knopf gefunden: " + message)
    }

    private func log(_ message: String) {
        guard let dir = shotDir else { return }
        let line = "[\(String(format: "%02d", shotIndex))] \(message)\n"
        let url = dir.appendingPathComponent("log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Jeder Fehlschlag landet auch als Zeile in log.txt neben den Bildern –
    /// xcodebuild gibt die Testfehler nicht mehr auf der Konsole aus.
    override func record(_ issue: XCTIssue) {
        log("FEHLER: " + issue.compactDescription)
        super.record(issue)
    }
}
