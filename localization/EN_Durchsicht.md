# Englische Fassung — zum Durchsehen

Du musst nicht alles lesen. **Teil 1 sind Entscheidungen**, die den Ton festlegen —
die brauchen deinen Blick. Teil 2 und 3 sind Folgerungen daraus.

Wo ich unsicher war, steht es dabei. Wo es nur eine richtige Übersetzung gibt,
steht keine Anmerkung.

---

## Teil 1 — Begriffe, die den Ton tragen

Diese neun legen fest, wie die App auf Englisch klingt. Alles andere folgt daraus.

### Werk → **work**

Der zentrale Begriff. „Werke statt Dateien" ist die Ansage der App, und im
englischen Kunstbetrieb ist *a work* genau das — „a work on paper", „early works".

Verworfen: *piece* (zu salopp, Galeristensprache), *project* (Bürodeutsch,
zerstört die Ansage).

| Deutsch | Englisch |
|---|---|
| Neues Werk | New work |
| Werk anlegen | Start a work |
| Welches Werk nimmst du auf? | Which work are you shooting? |
| \(n) Werke · \(m) Bilder | \(n) works · \(m) frames |
| Ein Blatt pro Werk. | One sheet per work. |

### Blatt → **Sheet**  ✔ von Rainer entschieden

Zur Wahl standen *Plate* und *Sheet*. *Plate* ist das nummerierte Blatt im
Ausstellungskatalog („Plate I, Plate II"), kommt aber aus der Drucktechnik und
meint dort die Druckplatte. *Sheet* ist das Papier selbst.

**Entschieden: Sheet** — näher an Tolinos Papierarbeiten, und das Werk besteht
tatsächlich aus Blättern, nicht aus Tafeln eines Katalogs.

| Deutsch | Englisch |
|---|---|
| Blatt %02d | Sheet %02d |
| Blatt 01 – %02d | Sheets 01 – %02d |
| Ein Blatt | One sheet |
| Blatt %02d · %.1f s | Sheet %02d · %.1f s |

### Serie von N → **Series of N**

Nicht *Edition of N*. „Edition of 24" hieße im Kunstbetrieb: Es gibt 24 Exemplare
desselben Werks. Hier sind es aber 24 Bilder **innerhalb** eines Werks. *Series*
trifft das, *Edition* wäre sachlich falsch — auch wenn es katalogmäßiger klingt.

| Deutsch | Englisch |
|---|---|
| Serie von \(n) · datiert 2026 | Series of \(n) · dated 2026 |
| Serie von \(n) · datiert 2026 · Schleife | Series of \(n) · dated 2026 · looping |

*dated* ist die stehende Katalogwendung, da gibt es keine Alternative.

### Bild (gezählt) → **frame**

Wenn gezählt wird, sind es *frames* — so steht es auch schon im README. *Image*
wäre zu allgemein, *picture* zu beiläufig.

Ausnahme: Im Einfach-Modus, wo die App mit Schülern spricht, klingt *shot*
natürlicher. Siehe Teil 2.

### Falz → **Crease** · Facetten → **Facets** · Gewebe → **Weave**

Die drei Übergangsstile. Alle drei sind im README schon so gesetzt, ich bleibe
dabei. *Crease* ist die Faltkante, *Facets* die triangulierten Flächen, *Weave*
kommt von Tolinos geflochtenen Papierarbeiten.

### Daumenkino → **flip-book strip**

Der Streifen mit den letzten Aufnahmen unten im Sucher. Wörtlich wäre
*thumb cinema* — das gibt es nicht. *Flip book* ist der stehende Begriff, *strip*
macht klar, dass es die Leiste ist und nicht das fertige Büchlein.

### Pegel → **motion gauge** · Wasserwaage → **spirit level**

Beide aus dem README übernommen. *Level* allein wäre mehrdeutig (Pegel/Ebene),
*spirit level* ist eindeutig die Libelle.

### Nochmal → **Again**

Der Knopf nach einer fertigen Aufnahme. *Again* ist kurz und passt in die Zeile.
*Once more* wäre wörtlicher, aber zu lang für den Knopf.

### Aufnahmeart: Stativ / Aus der Hand → **Tripod / Handheld**

Im Sucher steht es gekürzt als `STATIV` / `HAND` → **`TRIPOD` / `HANDHELD`**.
*Handheld* ist ein Wort und passt.

---

## Teil 2 — Die zwei Register

Die Zustandsanzeige im Sucher gibt es doppelt: Werkstattsprache im
Einfach-Modus, Katalogton sonst. Das ist der Teil, den eine Maschine zuverlässig
kaputtmacht — deshalb hier nebeneinander.

| Zustand | Einfach (de) | Einfach (en) | Katalog (de) | Katalog (en) |
|---|---|---|---|---|
| Start | Gleich geht's los… | Nearly there… | Kamera startet… | Starting camera… |
| Kalibrieren | Halt kurz still… | Hold still a moment… | Kalibriere – kurz ruhig lassen… | Calibrating — keep it steady… |
| Fokus | Moment, wird scharf… | One sec, focusing… | Noch nicht scharf… | Not sharp yet… |
| Bereit | Los — ich schau zu | Go ahead — I'm watching | Bereit – arbeite einfach | Ready — just work |
| Arbeit | Ich warte, bis du weg bist… | I'll wait till you're clear… | Arbeit erkannt… | Work detected… |
| Ruhe | Nicht bewegen… | Don't move… | Ruhig halten… | Hold steady… |
| Aufgenommen | Klick! | Click! | Bild aufgenommen ✓ | Frame captured ✓ |

Zwei Anmerkungen:

**„Los — ich schau zu"** → *Go ahead — I'm watching*. Im Deutschen duzt die App
hier. Englisch hat das nicht, die Wärme muss über den Rhythmus kommen. „I'm
watching" ist bewusst zweideutig-freundlich, nicht überwachend — im Zweifel
prüfen, ob dir das behagt.

**„Ich warte, bis du weg bist…"** → *I'll wait till you're clear*. „Till you're
gone" wäre wörtlicher und klingt nach Abschied. *Clear* meint: aus dem Bild.

### Die beiden Begrüßungen

| Deutsch | Englisch |
|---|---|
| Was falten wir\nheute? | What are we folding\ntoday? |
| Woran arbeitest du\nheute? | What are you working on\ntoday? |
| Wie möchtest du\narbeiten? | How do you want\nto work? |
| Mehrere Werke,\nein durchlaufendes Reel. | Several works,\none continuous reel. |

Die Zeilenumbrüche habe ich gelassen, wo sie im Deutschen stehen — sie sind
gesetzt, nicht zufällig. Beim Einbauen muss man prüfen, ob sie im Englischen an
derselben Stelle noch sitzen.

---

## Teil 3 — Der Rest, nach Bildschirm

Hier gibt es wenig zu entscheiden. Überflieg es.

### Onboarding

| Deutsch | Englisch |
|---|---|
| Bild · Objekt · Bild | Image · Object · Image |
| Überspringen | Skip |
| Los geht's | Get started |
| Video wählen —\noder live aufnehmen. | Pick a video —\nor shoot live. |
| Ein fertiges Video aus der Mediathek — FrameFold macht den Rest. | A video from your library — FrameFold does the rest. |
| iPhone aufs Stativ, arbeiten. Es löst von selbst aus, sobald deine Hände aus dem Bild sind. | Phone on a tripod, then work. It fires by itself as soon as your hands leave the frame. |
| FrameFold findet die ruhigen Momente und verwirft Bilder, auf denen deine Hände zu sehen sind. Alles bleibt auf dem Gerät. | FrameFold finds the calm moments and drops any frame with your hands in it. Everything stays on the device. |
| Nur das Nötigste: auswählen, auslösen, fertig. Empfohlen für den Anfang. | Just the essentials: pick, shoot, done. Recommended to start with. |
| Format, Bildrate, Effekte, Faltvorlagen, Ausstellung — die volle Werkstatt. | Aspect, frame rate, effects, fold templates, exhibition — the full workshop. |
| Lässt sich jederzeit über das Regler-Symbol ändern. | You can change this any time from the sliders icon. |

### Modi

| Deutsch | Englisch |
|---|---|
| Einfach | Simple |
| Erweitert | Advanced |
| Nur das Nötigste: Video wählen → Stopmotion. | Just the essentials: pick a video → stop-motion. |
| Klassische Einstellungen: Format, Bildrate, Abspielmodus, Stabilisierung. | The usual settings: aspect, frame rate, playback, stabilisation. |
| Alles dabei — plus die Spezialfeatures: Facetten, Echo, Faltvorlage, Rekursion, Ausstellung. | Everything, plus the studio effects: facets, echo, fold template, recursion, exhibition. |

### Kamera

| Deutsch | Englisch |
|---|---|
| Dunkelkammer | Darkroom |
| So funktioniert die Kamera | How the camera works |
| iPhone aufs Stativ oder ruhig über die Arbeit halten. Arbeite einfach — FrameFold nimmt automatisch ein Bild auf, sobald deine Hände aus dem Bild sind und die Szene kurz ruht. | Phone on a tripod, or held steady over your work. Just work — FrameFold takes a frame by itself as soon as your hands leave the frame and the scene settles. |
| Der runde Knopf löst jederzeit von Hand aus. | The round button fires by hand at any time. |
| Verstanden | Got it |
| Auslöser | Shutter |
| Nimmt sofort ein Bild auf. Sonst löst die Kamera von selbst aus, sobald die Hände aus dem Bild sind. | Takes a frame right away. Otherwise the camera fires by itself once your hands are clear. |
| Auslöser · Bewegung | Shutter · Motion |
| Auslöser · Intervall %.0f s | Shutter · Interval %.0f s |
| Auslöser umschalten | Switch shutter mode |
| Zwiebelhaut | Onion skin |
| Blendet das vorherige Bild halbtransparent über den Sucher. | Lays the previous frame over the viewfinder, half transparent. |
| Letztes Bild zurücknehmen | Undo last frame |
| Aufgenommene Bilder | Captured frames |
| Kamera neu fixieren | Re-lock camera |
| Keine Kamera verfügbar | No camera available |
| Erlaube FrameFold den Kamerazugriff unter Einstellungen → FrameFold. | Allow FrameFold to use the camera in Settings → FrameFold. |
| Fertig · \(n) | Done · \(n) |
| Werk wird montiert… | Assembling the work… |
| Stopmotion wird montiert… | Assembling the stop-motion… |

### Fokus- und Bewegungshinweise

| Deutsch | Englisch |
|---|---|
| Aufnahmeart: Stativ. Tippen für aus der Hand. | Capture mode: tripod. Tap for handheld. |
| Aufnahmeart: aus der Hand. Tippen für Stativ. | Capture mode: handheld. Tap for tripod. |
| Am Stativ wird der Fokus fixiert, aus der Hand läuft er mit. | On a tripod focus stays locked; handheld it keeps tracking. |
| Fokus findet nichts Scharfes. Tippe im Sucher auf dein Werk. | Focus can't find anything sharp. Tap your work in the viewfinder. |
| Scharf gestellt und fixiert. Wirkt es unscharf? Tippe im Sucher auf dein Werk. | Focused and locked. Looks soft? Tap your work in the viewfinder. |
| Schärfe bricht immer wieder weg. Tippe im Sucher auf dein Werk. | Sharpness keeps dropping. Tap your work in the viewfinder. |
| Ich sehe kaum Struktur und kann die Schärfe nicht prüfen. Geh etwas weiter weg oder tippe im Sucher auf dein Werk. | I can barely see any detail, so I can't judge sharpness. Move back a little, or tap your work in the viewfinder. |
| Szene wirkt dauerhaft unruhig. Stativ prüfen – oder in den Einstellungen die Bewegungs-Toleranz erhöhen. | The scene never settles. Check the tripod — or raise the motion tolerance in settings. |
| Zu viel Wackeln – leg das iPhone irgendwo auf oder lehne es an. | Too much shake — set the phone down or lean it against something. |

### Bildauswahl

| Deutsch | Englisch |
|---|---|
| Antippen zum Abwählen | Tap to deselect |
| Weniger Bilder | Fewer frames |
| Mehr Bilder | More frames |
| \(n) von \(m) Bildern gewählt | \(n) of \(m) frames selected |
| Standard erfasst großzügig. Unerwünschte Bilder oben einfach abwählen. | The default errs on the generous side. Just deselect what you don't want above. |
| Keine ruhigen Momente gefunden. Das Video ist evtl. sehr kurz oder durchgehend in Bewegung — schiebe den Regler unten Richtung Mehr Bilder oder nimm etwas länger auf. | No calm moments found. The video may be very short, or in motion throughout — push the slider below towards More frames, or shoot a little longer. |
| Nur wenige Bilder gefunden. Für eine flüssigere Stopmotion den Regler unten Richtung Mehr Bilder schieben oder länger aufnehmen. | Only a few frames found. For a smoother stop-motion, push the slider towards More frames or shoot longer. |
| Zurück zur Bildauswahl | Back to frame selection |

### Ergebnis

| Deutsch | Englisch |
|---|---|
| Fertig! \(n) Bilder | Done! \(n) frames |
| \(n) Bilder aufgenommen | \(n) frames captured |
| \(n) Bilder · aus \(m) s Video | \(n) frames · from \(m) s of video |
| \(n) mit Händen entfernt · \(m) Duplikate | \(n) dropped for hands · \(m) duplicates |
| %.1f Sekunden · läuft in Schleife | %.1f seconds · loops |
| %d Bilder · ~%.1f s bei 10 fps | %d frames · ~%.1f s at 10 fps |
| noch \(n) für eine Sekunde Film | \(n) more for a second of film |
| Teilen | Share |
| Sichern | Save |
| Verwerfen | Discard |
| Als Projekt sichern | Save as a project |
| Die Bilder wandern in ein Projekt und lassen sich dort mit weiteren Aufnahmen ergänzen und neu exportieren. | The frames move into a project, where you can add more sessions and export again. |
| Lokal auf diesem Gerät | Local, on this device |
| Das hat leider nicht geklappt. | That didn't work. |
| Nochmal versuchen | Try again |

### Projekte

| Deutsch | Englisch |
|---|---|
| Ein Blatt pro Werk. | One sheet per work. |
| Bilder sammeln sich über beliebig viele\nAufnahmen – live oder aus Videos. | Frames collect across any number of\nsessions — live or from video. |
| Werk anlegen | Start a work |
| Neues Werk anlegen | Start a new work |
| Noch kein Werk – leg eines an, dann kann die Kamera loslegen. | No work yet — start one and the camera can go. |
| \(n) Bilder · Kontaktbogen | \(n) frames · contact sheet |
| Kontaktbogen | Contact sheet |
| Kontaktbogen teilen | Share contact sheet |
| Bild entfernen | Remove frame |
| Zuletzt gelöscht: \(n) Bilder wiederherstellen | Recently deleted: restore \(n) frames |
| Projekt löschen | Delete project |
| \(name) mit allen \(n) Bildern löschen? | Delete \(name) and all \(n) frames? |
| Endgültig löschen | Delete permanently |
| Bild \(n) von \(m) | Frame \(n) of \(m) |
| Ziehen zum Durchblättern | Drag to flip through |
| Video teilen | Share video |
| Faltvorlage konnte nicht erstellt werden. | The fold template couldn't be created. |
| Kontaktbogen konnte nicht erstellt werden. | The contact sheet couldn't be created. |

### Ausstellung

| Deutsch | Englisch |
|---|---|
| Ausstellung | Exhibition |
| Ausstellung erstellen | Build exhibition |
| Ausstellung montieren | Assemble exhibition |
| Ausstellung teilen | Share exhibition |
| Reel wird montiert… | Assembling the reel… |
| Mindestens zwei Werke wählen. | Pick at least two works. |
| Ein Werk gewählt – noch mindestens eines. | One work picked — at least one more to go. |
| \(n) Werke montieren | Assemble \(n) works |

### Effekte

| Deutsch | Englisch |
|---|---|
| Druckbild (Schwarzweiß) | Print look (black and white) |
| Schwarzweiß mit warmem Papierton — wie ein abfotografierter Druck. | Black and white on a warm paper tone — like a print photographed again. |
| Relief-Stärke: \(n) % | Relief strength: \(n) % |
| Jede Facette liegt anders im Licht — als wäre das Bild gefaltet und wieder abfotografiert worden. | Each facet catches the light differently — as if the image had been folded and photographed again. |
| Bild-Echo (Nachbild) | Image echo (afterimage) |
| Echo-Stärke: \(n) % | Echo strength: \(n) % |
| Das vorherige Bild schimmert im nächsten leicht nach. | The previous frame lingers faintly in the next. |
| Überblendung | Transition |
| Übergangsstil | Transition style |
| Blendet das nächste Bild ein — als Falzkante, als triangulierte Facetten oder als eingewobene Bildstreifen. | Brings in the next frame — as a crease, as triangulated facets, or as woven strips. |
| Rückwärts | Reverse |
| Letztes Bild halten | Hold last frame |
| Auflösung | Resolution |

### Export-Presets

| Deutsch | Englisch |
|---|---|
| Story | Story |
| Quadrat | Square |
| Galerie | Gallery |

### Einstellungen

| Deutsch | Englisch |
|---|---|
| Auslöse-Wartezeit: %.1f s | Shutter delay: %.1f s |
| Auslöse-Wartezeit: %.1f s (+0,4 s aus der Hand) | Shutter delay: %.1f s (+0.4 s handheld) |
| So lange muss die Szene ruhig sein, bevor automatisch ausgelöst wird. | How long the scene has to stay calm before the shutter fires. |
| Höher = kleine Wackler und Bildrauschen werden ignoriert. Wenn der Auslöser nie Ruhe findet, diesen Wert erhöhen. | Higher = small shakes and sensor noise are ignored. If the shutter never settles, raise this. |
| Nicht auslösen, solange Hände im Bild sind | Don't fire while hands are in frame |
| Im Intervall-Modus löst FrameFold in festem Takt aus – unabhängig von Bewegung. | In interval mode FrameFold fires on a fixed beat, regardless of motion. |
| Auslöse-Ton | Shutter sound |
| Auslöser & Belichtung | Shutter & exposure |
| Gegen erstes Bild (Drift) | Against first frame (drift) |
| Zeigt das erste oder letzte Bild als Überblendung – zum Ausrichten und um Drift zu erkennen. | Overlays the first or last frame — for lining up and spotting drift. |
| Schließen | Close |

### Tipps

| Deutsch | Englisch |
|---|---|
| Licht konstant halten: Kunstlicht nutzen, Fenster abdunkeln. Billige LED-/Leuchtstofflampen flackern im Netztakt und streifen einzelne Bilder. | Keep the light steady: use artificial light, shade the windows. Cheap LED and fluorescent lamps flicker at mains frequency and streak individual frames. |
| iPhone nicht berühren: aufs Stativ stellen und den Auto-Shutter arbeiten lassen (oder den runden Knopf). | Don't touch the phone: put it on a tripod and let the auto-shutter work (or use the round button). |
| Kamera bleibt ruhig: FrameFold sperrt Belichtung und Weißabgleich nach der kurzen Kalibrierung – so driftet zwischen den Bildern nichts. Der Fokus wird am Stativ fixiert, aus der Hand läuft er mit. | Camera stays calm: after a short calibration FrameFold locks exposure and white balance, so nothing drifts between frames. Focus stays locked on a tripod; handheld it keeps tracking. |
| Drift früh erkennen: Zwiebelhaut anlassen und die Aufnahme ab und zu mit dem ersten Bild vergleichen. | Spot drift early: leave onion skin on and compare against the first frame now and then. |
| Ohne Wackeln auslösen: Auslöser gedrückt halten startet einen 3-Sekunden-Countdown. Auch die Lautstärketasten von Kopfhörern oder AirPods lösen aus. | Fire without shake: hold the shutter for a three-second countdown. The volume buttons on headphones or AirPods fire too. |

*Der Tipp zur Kamera behauptete bis 1.2, der Fokus werde immer fixiert. Der
deutsche Text ist inzwischen korrigiert, beide Fassungen stimmen.*

### Verarbeitung

| Deutsch | Englisch |
|---|---|
| Lade Video… | Loading video… |
| Lese Bilder… | Reading frames… |
| Wähle Keyframes… | Picking keyframes… |
| Prüfe auf Hände… | Checking for hands… |
| Keyframes prüfen | Review keyframes |
| Das Video ist leer oder konnte nicht gelesen werden. | The video is empty or couldn't be read. |
| Das Stopmotion-Video konnte nicht geschrieben werden. | The stop-motion video couldn't be written. |
| Das Video konnte nicht geladen werden. | The video couldn't be loaded. |

### Watch

| Deutsch | Englisch |
|---|---|
| Verbinde… | Connecting… |
| Bereit | Ready |
| iPhone nicht erreichbar | iPhone not reachable |
| Kamera-Tab öffnen | Open the Camera tab |
| \(n) Bilder | \(n) frames |

---

## Was danach noch zu tun ist

**Pluralformen.** Englisch braucht „1 frame" / „2 frames". Im Deutschen steht
überall „Bilder", auch bei eins. String Catalogs können das sauber — ich lege die
Regeln beim Einbau an, das braucht keine Entscheidung von dir.

**Zeilenumbrüche.** Die gesetzten `\n` in den Überschriften sitzen im Englischen
womöglich falsch. Das sieht man erst im Simulator.

**Textlängen.** Englisch ist meist kürzer, aber „Capture mode: handheld. Tap for
tripod." ist länger als das deutsche Original. Knöpfe und Chips muss ich im
Simulator gegenprüfen.

**Store-Eintrag.** Beschreibung, Untertitel, Schlüsselwörter und vier Screenshots
auf Englisch — separat, sobald die Oberfläche steht.
