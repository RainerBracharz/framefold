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

- Alle 20 Swift-Dateien sind im Build-Target eingetragen
- Kamera-Berechtigung (für den Kamera-Tab) ist gesetzt
- Automatisches Signing, Bundle-ID `com.rainer.framefold`, iOS 17+, Portrait
- Info.plist wird von Xcode automatisch generiert
- Die Schriften Fraunces und Inter liegen als Data-Sets im Asset-Katalog und
  werden beim Start registriert – kein Info.plist-Eintrag nötig

### Die Dateien im Ordner `FrameFold/`

- FrameFoldApp.swift (App + Tab-Navigation, Schrift-Registrierung)
- Theme.swift (Design-System „Falz & Flut" nach Aldo Tolinos aktuellen Arbeiten: warmes Bone/Tusche, Marine-Akzent, Haarlinien, Falz-Signet, gefaltete Papierfläche `FoldedPaperHero`, Katalog-Typografie; Kamera-Tab als Dunkelkammer)
- Algorithms.swift (pure Kernlogik – auf Linux mit Swift 6 kompiliert und durch Tests verifiziert)
- ContentView.swift (Video-Tab: Startscreen, Bildauswahl, Ergebnis, Einstellungen)
- Models.swift (Einstellungen, Export-Presets, Loop-Modi)
- MotionLevel.swift (Wasserwaage über CoreMotion)
- FrameAnalyzer.swift (Bewegung, Schärfe, dHash)
- KeyframeSelector.swift (Otsu-Schwelle, Ruhefenster)
- HandDetector.swift (Apple Vision, Stufe A)
- CoreMLHandDetector.swift (RF-DETR, Stufe B, optional)
- FrameAligner.swift (Stabilisierung zwischen Frames)
- StopMotionAssembler.swift (Video-Assembly, Crop, Boomerang, Interferenz-Echo, Falz-Blende, Druckbild, Papierrelief)
- ContactSheetRenderer.swift (Kontaktbogen als druckfertiges A4-PDF)
- FoldTemplateRenderer.swift (Faltvorlage mit Falzlinien als PDF)
- ExhibitionBuilder.swift (mehrere Werke zu einem Ausstellungs-Reel montieren)
- ProcessingViewModel.swift (Pipeline-Orchestrierung)
- LiveCaptureController.swift (Auto-Shutter, Kamera-Fixierung, Intervall-Auslöser)
- LiveCaptureView.swift (Kamera-Tab mit Sucher, Onion-Skin, Live-Einstellungen)
- ProjectStore.swift (Projekte/Sessions-Persistenz)
- ProjectsView.swift (Projekte-Tab mit Kontaktbogen, Export, Ausstellung)

## Die drei Tabs

**Video-Tab:** Der Startscreen begrüßt dich und zeigt dein letztes Werk als gefaltete Papierfläche – die ganze Tafel ist der Griff zum Video-Import. Danach: App analysiert, entfernt Hand-Frames, zeigt die Bildauswahl zum Nachjustieren und die fertige Stopmotion (Vorschau läuft in Schleife). Über das Regler-Symbol: Modus, Empfindlichkeit, Bildrate, **Format**, **Auflösung**, **Abspielmodus**, **Frame-Ausrichtung** und die Tolino-Effekte. „Als Projekt sichern" legt die Keyframes in ein Projekt.

**Kamera-Tab (Auto-Shutter):** iPhone aufs Stativ, Werk wählen, arbeiten. Die App erkennt „Hände weg + Szene ruhig" und nimmt automatisch einen Frame. Nach der kurzen Kalibrierung **fixiert sie Belichtung, Fokus und Weißabgleich** (niedrige ISO, flackerarme Belichtungszeit nach Netzfrequenz), damit zwischen den Bildern nichts driftet. Dazu: **Tippen setzt Fokus/Belichtung**, **Neu fixieren** nach Lichtwechsel, **Intervall-Auslöser** als Alternative zum Bewegungs-Trigger, Onion-Skin wahlweise gegen den **ersten** Frame (Drift-Kontrolle) mit regelbarer Deckkraft, optionales **Referenzbild**, Bildschirm bleibt wach, Auslöse-Ton abschaltbar. „Fertig" beendet die Session.

**Projekte-Tab:** Ein Werk pro Projekt, Sessions über Tage/Wochen sammelbar. Nummerierter Kontaktbogen aller Frames (Bearbeiten → einzeln entfernen, 30 Tage Papierkorb), Export mit allen Presets, **Kontaktbogen-PDF** und **Faltvorlage-PDF** zum Drucken. Ab zwei Werken (Tolino-Modus) lässt sich über das Film-Symbol eine **Ausstellung** montieren.

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

Bereits enthalten: Live-Capture mit Auto-Shutter und Onion-Skin, Projekte/Sessions über mehrere Tage, Frame-Alignment, Export-Presets, Boomerang/Rückwärts, manueller Frame-Override, RF-DETR-Anbindung (Modell einfach reinziehen, siehe oben).

**Die Tolino-Stufe:**

- **Druckbild (Schwarzweiß)**: Graustufen auf warmem Papierton — wie ein abfotografierter Druck.
- **Papierrelief**: Jede Facette liegt anders im Licht — als wäre das Bild gefaltet und wieder abfotografiert worden. Stärke regelbar.
- **Interferenz-Echo**: Jeder Output-Frame schimmert im nächsten nach — eine Rekursion des eigenen Bildes. Das Werk „erinnert" sich an seinen vorherigen Zustand.
- **Überblendung** (Aus/Kurz/Weich) in drei **Übergangsstilen**: **Falz** (wandernde Diagonale mit heller Falzkante), **Facetten** (triangulierte Flächen) und **Verwebung** (eingewobene Bildstreifen, nach seinen gewebten Papierarbeiten).
- **Kontaktbogen (PDF)**: Alle Frames eines Werks als druckfertiger A4-Bogen im Katalog-Layout (nummerierte Zellen, Haarlinien, Kopfzeile mit Werktitel und Datum, mehrseitig).
- **Faltvorlage (PDF)**: Druckbare Seite mit gestrichelten Falzlinien zum Nachfalten — Bild → Objekt → Bild.
- **Ausstellung**: Mehrere Werke zu einem durchlaufenden Reel mit Katalog-Titelkarten montieren.
- **Erneut falten (Rekursion)**: Das fertige Ergebnis direkt wieder durch die Pipeline schicken.

**Design „Falz & Flut"** (abgeleitet aus seinen aktuellen Serien — mattes Papier über geologischer und wässriger Fotografie): warmes Bone statt Kaltweiß, warmes Tuscheschwarz, ein Marine-Akzent aus den Flood-Arbeiten, gedämpfte Werkfarben (Fels, Salbei, Marmor). Der Startscreen zeigt das letzte Werk als **gefaltete Papierfläche**, über die langsam Licht wandert. Schriften: **Fraunces** (Titel) und **Inter** (Angaben), beide eingebettet. Auswahl wird durch Inversion markiert, nie durch Farbe.

Mögliche nächste Schritte: Filmkorn/Jitter-Look (Metal), Audio/Click-Track, Saliency-basierter Smart-Crop, Hintergrundverarbeitung langer Videos, TestFlight für Aldo.
