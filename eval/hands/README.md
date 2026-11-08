# Eval der Handerkennung

Misst, wie zuverlässig `VisionHandDetector` (FrameFold/HandDetector.swift) Bilder
mit Händen erkennt. Die Video-Umwandlung und die Live-Kamera nutzen ihn beide.

## Prüfsatz

- **Film:** „Learning to Set Type“ (1959, Prelinger Archives, gemeinfrei), eine
  Sekunde = ein Bild, 621 Bilder. Fast nur Hände: Nahaufnahmen, angeschnittene
  Finger am Rand, Arme, Bewegungsunschärfe, Schwarzweiß. Von Hand beschriftet in
  `truth.py` (514 mit Händen, Armen oder Menschen; 107 ohne).
- **Gegenprobe:** 32 Bilder ohne Hände (gefaltetes Papier, Beispielbilder der App).

Die Bilder liegen nicht im Repo (`.gitignore`). Erzeugen:

```
ffmpeg -i Learning1959.mp4 -vf fps=1 -q:v 3 eval/hands/frames/l_%04d.jpg
```

## Werkzeuge

- `handcheck.swift`: vergleicht Varianten (Hand-Pose, Pose auf vergrößerter Fläche,
  Kontrast, Kacheln, Personen-Segmentierung in drei Stufen, Randberührung).
  `swiftc -O handcheck.swift -o bin/handcheck && bin/handcheck frames > film.csv`
- `auswerten.py`: wertet `film.csv`/`neg.csv` gegen `truth.py` aus.
- `appcheck/main.swift`: prüft den echten App-Code.
  `swiftc -O ../../FrameFold/HandDetector.swift appcheck/main.swift -o bin/appcheck`

## Ergebnis (08.11.2026)

| Verfahren | erkannt | Fehlalarm (107) | Gegenprobe (30) |
|---|---|---|---|
| Hand-Pose allein (bis 2.8) | 77 % | 0 | 0 |
| Pose auf vergrößerter Fläche | 56 % | 0 | 0 |
| Pose auf 4 Kacheln | 55 % | 1 | 1 |
| Pose + Segmentierung „balanced“ ≥ 3 % | 90 % | 6 | 0 |
| Pose + Segmentierung „accurate“ ≥ 3 % | 90 % | 6 | 0 |
| **Pose + Segmentierung „fast“ ≥ 3 % und Rand ≥ 1 %** | **96 %** | **0** | **0** |

Die feineren Segmentierungsstufen schlagen auf plastisch geprägten Titeltafeln an,
die schnelle nicht. Die Randbedingung kostet im Film keinen Treffer (Hände kommen
immer vom Rand) und schützt Figuren mitten im Bild.

Übersehen werden noch 19 Bilder: Bewegungsunschärfe, winzige Fingerspitzen am
unteren Rand, völlig unscharfe Daumen im Vordergrund.

## Auswahl im Fenster (08.11.2026)

Die bessere Erkennung allein reichte nicht. In der App kamen am Lehrfilm weiter
Bilder mit Händen durch, weil die Auswahl je ruhigem Fenster Kandidat um
Kandidat probierte, bis einer *nicht* als Hand erkannt wurde. Ruht eine Hand
im Bild, ist das genau ein Aussetzer der Erkennung. Bei 96 % Trefferquote und
rund hundert Kandidaten je Fenster findet sich fast immer einer.

Neue Regel (`ProcessingViewModel.computeCandidates`, gespiegelt in
`eval/selector.py`):

1. Stichprobe von neun Bildern je Fenster, gleichmäßig über die Zeit verteilt.
   Zeigt mehr als die Hälfte Hände, entfällt das Fenster.
2. Sonst das schärfste Bild, das selbst und dessen Nachbarn bis 0,2 s davor
   und danach handfrei sind.

| | behalten | davon mit Hand | Fenster überwiegend ohne Hand verloren |
|---|---|---|---|
| bis 2.8 | 22 | 15 | 0 von 4 |
| neu | 6 | 1 | 0 von 4 |

Messung: `fenster.py` schreibt die Fenster des Films, `videocheck/main.swift`
prüft alle 6143 Kandidaten mit dem App-Detektor (640 px wie in der App),
`pipeline_sim.py` vergleicht die Regeln. Die App selbst lieferte am Film
dieselben 6 Bilder.

Künstlicher Testsatz (`eval/run_eval.py`, 55 Videos), mittlerer F1:

| Erkennung | bis 2.8 | neu |
|---|---|---|
| fehlerfrei (`--hands ideal`) | 0,882 | 0,877 |
| übersieht 5 % (`--hands fehl:0.05`) | 0,826, 35 Handbilder | 0,850, 19 Handbilder |
| übersieht 20 % (`--hands fehl:0.2`) | 0,696, 126 Handbilder | 0,774, 83 Handbilder |

Verworfen: Versuche je Fenster begrenzen (F1 0,35 bis 0,74, weil Hände oft nur
an den Rändern eines Fensters stehen und die schärfsten Bilder sind), Sperrzone
um erkannte Hände, Mehrheit unter den schärfsten statt über die Zeit.

## Offen

- Gegenprobe mit echten Knetfiguren, Puppen und LEGO-Figuren fehlt. Figuren, die
  den Bildrand berühren, könnte die Segmentierung für Menschen halten.
- Farbaufnahmen aus echten Ateliers fehlen. Der Prüfsatz ist ein Schwarzweißfilm.
