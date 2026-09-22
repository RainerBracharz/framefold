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
            "-AppleLocale", lang == "de" ? "de_AT" : "en_US",
            // Erststart herstellen: Onboarding und Kamera-Tipp sollen mit drauf.
            "--ff-fresh-start",
        ]
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
        tap(["Next", "Weiter"])
        shot("onboarding-2")
        tap(["Next", "Weiter"])
        usleep(500_000)   // Kartenwechsel ist animiert; sonst trifft der nächste Tipp die alte Karte
        if showAll { tap(["Show all", "Alles zeigen"]) }
        shot("onboarding-3")
        tap(["Get started", "Los geht's"])

        // 4 Video-Tab, Startansicht
        sleep(1)
        shot("video-start")

        // 5 Einstellungen (Regler-Symbol oben rechts)
        if tap(["Settings", "Einstellungen"]) {
            sleep(1)
            shot("video-settings")
            tap(["Done", "Fertig"])
        }

        // 6 Kamera-Tab: Tipp beim ersten Öffnen
        tap(["Camera", "Kamera"])
        sleep(1)
        shot("camera-tip")
        tap(["Got it", "Verstanden"])

        // 7 Werk wählen
        sleep(1)
        shot("camera-chooser")

        // 8 Neues Werk anlegen → Sucher
        if tap(["New work", "Neues Werk"]) {
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                let field = alert.textFields.firstMatch
                field.tap()
                field.typeText("Origami crane")
                shot("camera-new-work")
                // Alert-Knöpfe hängen in iOS 26 nicht unter dem Alert-Element
                tap(["Create & start", "Anlegen & starten"])
            }
        }

        // Sucher: Simulator-Kamera liefert synthetische Bilder, kurz warten
        sleep(5)
        shot("camera-capture")

        // 9 Aufnahme-Einstellungen
        if tap(["Capture settings", "Aufnahme-Einstellungen"]) {
            sleep(1)
            shot("camera-settings")
            tap(["Done", "Fertig"])
        }

        // Drei Bilder von Hand auslösen, dann abschließen („Done · 3")
        for _ in 0..<3 {
            tap(["Shutter", "Auslöser"])
            usleep(700_000)
        }
        sleep(1)
        shot("camera-capture-3")
        tap(["Done ·", "Fertig ·"], prefix: true)

        // 10 Ergebnis
        sleep(4)
        shot("camera-result")
        tap(["Done", "Fertig"])

        // 11 Projekte-Tab
        tap(["Projects", "Projekte"])
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
            if tap(["Delete project", "Projekt löschen"]) {
                tap(["Delete permanently", "Endgültig löschen"])
                sleep(1)
            }
            // Falls wir noch im Detail stehen: zurück zur Liste
            if app.navigationBars.buttons.firstMatch.exists,
               !app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'frames' OR label CONTAINS[c] 'Bilder'")).firstMatch.exists {
                tap(["Back", "Zurück"], timeout: 1)
            }
        }

        // 13 Ein älteres Werk mit echtem Material, falls vorhanden – für den
        // Store sind das die stärkeren Bilder als die Simulator-Testaufnahme.
        // „Fratze" bevorzugt – 28 echte Bilder, ohne Simulator-Reste –, sonst
        // das erste Werk, das nicht unser Testwerk ist.
        let faltung = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Fratze'")).firstMatch
        let older = app.buttons.matching(NSPredicate(
            format: "(label CONTAINS[c] 'frames' OR label CONTAINS[c] 'Bilder') AND NOT label CONTAINS 'Origami'"
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
            if tap(["Export stop-motion", "Stopmotion exportieren"]) {
                // Montage abwarten: fertig, sobald „Teilen" auftaucht (max. 60 s)
                let share = app.buttons.matching(NSPredicate(
                    format: "label CONTAINS[c] 'share' OR label CONTAINS[c] 'teilen'")).firstMatch
                _ = share.waitForExistence(timeout: 60)
                sleep(1)
                app.swipeUp(); app.swipeUp()
                sleep(1)
                shot("project-detail-exported")
            }
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
        let image = XCUIScreen.main.screenshot()

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
