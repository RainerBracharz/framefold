# FrameFold — vom Code auf dein iPhone 17 Pro Max

**Das Xcode-Projekt ist fertig vorbereitet** — du musst nichts mehr anlegen, keine Dateien hineinziehen, keine Berechtigungen eintragen. Dein kompletter Weg:

## Der 4-Schritte-Weg (ca. 5–10 Min.)

1. **ZIP auf den Mac** (AirDrop oder Cloud), entpacken → Doppelklick auf **FrameFold.xcodeproj**. Falls Xcode fragt, ob dem Projekt vertraut werden soll: Ja.
2. **Team wählen (einmalig):** Blaues FrameFold-Projekt im Navigator anklicken → Tab **Signing & Capabilities** → bei **Team** dein „(Personal Team)" wählen. Falls das Dropdown leer ist: Xcode → Settings… → **Accounts** → **+** → mit deiner Apple-ID anmelden, dann zurück und Team wählen. Kein bezahlter Account nötig.
3. **iPhone anschließen** (USB-C-Ladekabel) → am iPhone „Diesem Computer vertrauen" → in Xcode oben in der Mitte statt Simulator dein iPhone wählen → **⌘R**. Beim allerersten Mal verlangt das iPhone den **Entwicklermodus** (Einstellungen → Datenschutz & Sicherheit → Entwicklermodus → ein → Neustart), danach ⌘R erneut.
4. **App freigeben:** Einstellungen → Allgemein → **VPN & Geräteverwaltung** → deine Apple-ID → **Vertrauen**. App öffnen. Fertig.

Danach geht Deployment auch kabellos (gleiches WLAN). Gratis-Profil: Signatur läuft nach 7 Tagen ab → einfach neu ⌘R; Projekte und Frames auf dem iPhone bleiben erhalten.

---

## Referenz (nur bei Bedarf)

### Was im Projekt schon konfiguriert ist

- Alle 17 Swift-Dateien sind im Build-Target eingetragen
- Kamera-Berechtigung (für den Live-Tab) ist gesetzt
- Automatisches Signing, Bundle-ID `com.rainer.framefold`, iOS 17+, Portrait
- Info.plist wird von Xcode automatisch generiert

### Die Dateien im Ordner `FrameFold/`

- FrameFoldApp.swift (App + Tab-Navigation)
- Theme.swift (Design-System „Papier & Falz" nach Aldo Tolinos Arbeiten: Papierweiß/Tuschschwarz, scharfe Kanten, Haarlinien, Falz-Signet, Katalog-Typografie; Live-Tab als Dunkelkammer)
- Algorithms.swift (pure Kernlogik – auf Linux mit Swift 6 kompiliert und durch 39 Tests verifiziert)
- ContentView.swift (Video-Import-Tab)
- Models.swift (Einstellungen, Export-Presets, Loop-Modi)
- FrameAnalyzer.swift (Bewegung, Schärfe, dHash)
- KeyframeSelector.swift (Otsu-Schwelle, Ruhefenster)
- HandDetector.swift (Apple Vision, Stufe A)
- CoreMLHandDetector.swift (RF-DETR, Stufe B, optional)
- FrameAligner.swift (Stabilisierung zwischen Frames)
- StopMotionAssembler.swift (Video-Assembly, Crop, Boomerang, Interferenz-Echo, Falz-Blende)
- ContactSheetRenderer.swift (Kontaktbogen als druckfertiges A4-PDF)
- ProcessingViewModel.swift (Pipeline-Orchestrierung)
- LiveCaptureController.swift (Auto-Shutter-Logik)
- LiveCaptureView.swift (Live-Tab mit Onion-Skin)
- ProjectStore.swift (Projekte/Sessions-Persistenz)
- ProjectsView.swift (Projekte-Tab mit Timeline & Export)

## Die drei Tabs

**Video-Tab:** Arbeitsvideo aus der Mediathek wählen → App analysiert, entfernt Hand-Frames, zeigt die fertige Stopmotion mit Statistik. Über das Regler-Symbol: Empfindlichkeit, Mindest-Ruhezeit, Handerkennung, Framerate, **Format (9:16 Reel / 1:1 / 16:9)**, **Abspielmodus (Boomerang / Rückwärts)** und **Frame-Ausrichtung**. „Als Projekt sichern" legt die Keyframes in ein Projekt.

**Live-Tab (Auto-Shutter):** iPhone aufs Stativ, Projekt wählen, arbeiten. Die App erkennt „Hände weg + Szene ruhig" und nimmt automatisch einen Frame — mit Onion-Skin-Overlay des letzten Frames (Ebenen-Symbol schaltet es um). „Fertig" beendet die Session; die Frames liegen im Projekt.

**Projekte-Tab:** Ein Projekt pro Werk, Sessions über Tage/Wochen sammelbar. Timeline aller Frames (langes Drücken auf einen Frame → entfernen), Export mit allen Presets, direkt teilbar.

## RF-DETR nachrüsten (Stufe B, optional)

Die App nutzt automatisch Apples Vision-Handerkennung. Für die präzisere, auf Aldos Atelier trainierbare Variante:

1. Auf app.roboflow.com ein Projekt anlegen, ~200 Fotos aus dem Atelier hochladen und Hände (optional Arme/Werkzeuge) annotieren
2. RF-DETR Nano trainieren → als **CoreML** exportieren
3. Die Datei in **HandDetector.mlpackage** umbenennen und per Drag & Drop ins Xcode-Projekt ziehen (Target-Häkchen setzen)
4. Neu bauen — `CoreMLHandDetector` findet das Modell automatisch, kein Codeänderung nötig

## Wenn etwas nicht baut

Der Code wurde maschinell vorgeprüft: Alle 17 Dateien haben den Swift-6-Syntax-Check bestanden, die komplette Algorithmus-Logik wurde mit echtem Swift kompiliert und mit 62 Tests verifiziert (siehe `linux-tests/`), und die Projektdatei wurde mit einem pbxproj-Parser validiert. Was in der Cloud nicht prüfbar ist, sind die Apple-Framework-Aufrufe (SwiftUI, AVFoundation, Vision) — die gibt es nur auf dem Mac.

Falls Xcode rote Fehler zeigt: Meldung kopieren und mir schicken, ich korrigiere sofort. Bekannter Stolperstein: Zeigt Xcode viele Fehler mit „actor isolation" oder „Sendable", dann in den Build Settings des Targets **Swift Language Version** auf **Swift 5** stellen (im generierten Projekt bereits so gesetzt).

## Was im Paket noch drin ist

- `reference-pipeline/pipeline.py` — die gleiche Pipeline in Python (OpenCV), um Parameter an echten Videos von Aldo schnell am Mac zu tunen: `python3 pipeline.py atelier.mp4 stopmotion.mp4`
- `reference-pipeline/make_test_video.py` — erzeugt das synthetische Testvideo, mit dem die Logik verifiziert wurde (8 Arbeitsschritte → 8 Keyframes korrekt erkannt)

## Stand der Ausbaustufen

Bereits enthalten: Live-Capture mit Auto-Shutter und Onion-Skin, Projekte/Sessions über mehrere Tage, Frame-Alignment, Export-Presets (9:16/1:1/16:9), Boomerang/Rückwärts, manueller Frame-Override, RF-DETR-Anbindung (Modell einfach reinziehen, siehe oben), Design-System „Papier & Falz".

**Neu — die Tolino-Stufe:**

- **Interferenz-Echo** (Einstellungen → Interferenz, oder im Projekt-Export): Jeder Output-Frame schimmert im nächsten nach — eine Rekursion des eigenen Bildes, Stärke regelbar. Das Werk „erinnert" sich an seinen vorherigen Zustand.
- **Falz-Blende** (Aus/Kurz/Weich): Übergänge decken den nächsten Frame entlang einer wandernden Diagonale auf, mit feiner heller Falzkante — wie ein umgeschlagenes Blatt.
- **Kontaktbogen (PDF)** (im Projekt, unter dem Export): Alle Frames eines Werks als druckfertiger A4-Bogen im Katalog-Layout (nummerierte Zellen, Haarlinien, Kopfzeile mit Werktitel und Datum, mehrseitig). Zum Ausdrucken — und Wiederfalten: Bild → Objekt → Bild.

Mögliche nächste Schritte: Filmkorn/Jitter-Look (Metal), Audio/Click-Track, Saliency-basierter Smart-Crop, Hintergrundverarbeitung langer Videos, TestFlight für Aldo.
