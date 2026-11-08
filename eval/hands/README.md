# Eval der Handerkennung

Misst, wie zuverlässig `VisionHandDetector` (FrameFold/HandDetector.swift) Bilder
mit Händen erkennt. Die Video-Umwandlung und die Live-Kamera nutzen ihn beide.

## Prüfsatz

- **Film:** „Learning to Set Type“ (1959, Prelinger Archives, gemeinfrei), eine
  Sekunde = ein Bild, 621 Bilder. Fast nur Hände: Nahaufnahmen, angeschnittene
  Finger am Rand, Arme, Bewegungsunschärfe, Schwarzweiß. Von Hand beschriftet in
  `truth.py` (514 mit Händen, Armen oder Menschen; 107 ohne).
- **Gegenprobe:** 32 Bilder aus der App (gefaltetes Papier, Beispielbilder). Zwei
  davon (`io_0000`, `io_0020`) zeigen ein Foto eines Menschen mit sichtbaren
  Händen; dass sie anschlagen, ist richtig.
- **Puppenfilm:** „Round and Round“ (1939, Jam Handy, Prelinger, gemeinfrei),
  355 Bilder, nur Holzfiguren mit Armen und Händen, keine echte Hand. Jeder
  Treffer ist ein Fehlalarm.
- **Starewicz:** „The Revenge of a Kinematograph Cameraman“ (1912, gemeinfrei),
  1309 Bilder, Insektenpuppen, keine echte Hand.

Die Bilder liegen nicht im Repo (`.gitignore`). Erzeugen:

```
ffmpeg -i Learning1959.mp4 -vf fps=1 -q:v 3 eval/hands/frames/l_%04d.jpg
ffmpeg -i Roundand1939.mp4 -vf fps=1 -q:v 3 eval/hands/archiv/round1939/f_%04d.jpg
```

Quellen: archive.org/details/Learning1959, archive.org/details/Roundand1939,
archive.org/details/silent-the-revenge-of-a-kinematograph-cameraman.

## Werkzeuge

- `handcheck.swift`: vergleicht Varianten (Hand-Pose, Pose auf vergrößerter Fläche,
  Kontrast, Kacheln, Personen-Segmentierung in drei Stufen, Randberührung).
  `swiftc -O handcheck.swift -o bin/handcheck && bin/handcheck frames > film.csv`
- `auswerten.py`: wertet `film.csv`/`neg.csv` gegen `truth.py` aus.
- `posegeo/main.swift`: je Bild Größe und Randabstand der erkannten Hand und
  den Wert der Personenmaske an der Hand.
- `blatt.py`: Kontaktbogen, Treffer rot umrandet, zum Nachsehen von Hand.
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

## Gegenprobe mit Figuren (08.11.2026)

Der Puppenfilm zeigte, dass schon die Hand-Pose von 2.8 Figurenhände für echte
hält: 64 von 355 Bildern. Mit Segmentierung waren es 67. In Nahaufnahmen von
Figuren wären so ganze Szenen weggefallen.

Abhilfe: Ein Treffer der Hand-Pose zählt nur, wenn die Personenmaske an der
Hand anschlägt (≥ 0,1 im Umkreis von 4 % um die Gelenkpunkte). Holzfiguren
sieht die Segmentierung fast nie als Mensch. Die Segmentierung allein braucht
jetzt 5 % Fläche und 3 % Rand.

| Verfahren | Lehrfilm erkannt | Fehlalarm Lehrfilm | Puppenfilm | Starewicz |
|---|---|---|---|---|
| Hand-Pose allein (bis 2.8) | 77 % | 0 | 64 | 2 |
| Pose + Segmentierung (erster Stand) | 96 % | 0 | 67 | 1 |
| **Pose nur mit Maske + Segmentierung 5 %/3 %** | **91 %** | **0** | **10** | **0** |

Größe oder Randnähe der Hand trennten nicht: Die Hand-Pose meldet auch echte
Hände oft mit wenigen Gelenken, und die Konfidenz ist bei Figuren ebenfalls 1,0.

Ganzer Ablauf mit Fenster-Regel: Puppenfilm 33 von 42 Fenstern behalten
(wie 2.8). Weg fällt nur eine vier Sekunden lange Nahaufnahme einer Figur mit
Kiste, die den Bildrand füllt. Lehrfilm 8 Bilder, davon 3 mit Hand (2.8: 22
und 15).

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
| neu mit Maskenregel (siehe oben) | 8 | 3 | 0 von 4 |

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

## Gegenprobe mit Knete (08.11.2026)

| Film (archive.org) | Inhalt | Bilder | als Hand | ganzer Ablauf: Fenster behalten |
|---|---|---|---|---|
| Gumby „Robot Rumpus“ (`GumbyAdventuresPigeonInAPlumTree1`) | Knetfiguren, Farbe | 359 | 6 (Fehlalarm) | 105 von 107 |
| „Gumbasia“ 1955 (`Gumbasia_331`) | abstrakte Knetformen | 192 | 6 (Fehlalarm) | – |
| „Munchers“ 1973 (`munchers`) | Knetzähne, Farbe | 584 | 5 (Fehlalarm) | 131 von 131 |
| Modellierkurs „Haciendo una mosca“ (Aldo Sánchez) | echte Hände formen Knete | 370 | 321 | – |

Fehlalarm auf Knete 17 von 1135 Bildern (1,5 %). Die Fenster-Regel fängt
einzelne Fehlalarme ab; im Gumby-Film fallen nur 2 von 107 Szenen weg.
Im Modellierkurs blieben 49 Bilder ohne Treffer: fast alle Titel, Zwischenblenden
und fertige Figuren ohne Hand; übersehen wurden etwa 5 Bilder mit
Fingerspitzen am Rand oder halb überblendeten Händen.

## Gegenprobe mit LEGO (08.11.2026)

Brickfilme von archive.org, zwei Bilder je Sekunde:

| Film | Bilder | als Hand | ganzer Ablauf: Szenen behalten (2.8) |
|---|---|---|---|
| „All of the Dead“ (`allofthedead`) | 204 | 9 | 66 von 66 (66) |
| „Spider-Man: The Peril of Doc Ock“ (`peril_of_doc_ock`) | 460 | 21 | 130 von 134 (133) |
| „The Han Solo Affair“ (`hansoloaffair`) | 342 | 4 | 127 von 128 (127) |
| „ONE: A Space Odyssey Redux“ | 152 | 0 | 26 von 26 |
| „Penalty!“ (`penalty`) | 40 | 0 | – |
| „Them Twickenham Knights“ (`twickenhamknights`) | 224 | 23 | 4 von 4 (4) |

Fehlalarm auf LEGO 57 von 1422 Bildern (4 %), mehr als auf Holz oder Knete,
weil Minifiguren der Personen-Segmentierung menschlich genug sind. In
„Twickenham“ schlägt sie 12 s lang auf eine ruhige Szene an. Die Fenster-Regel
fängt das meist ab: Szenen gehen in Summe 5 von 358 verloren (2.8: 2).

Echte Hände an LEGO, Making-ofs von Spite Your Face:
„Making of the Han Solo Affair“ 35 von 273 Bildern erkannt, ungefähr 60 % der
Bilder mit Hand (Sepia, 416×240, Hände oft nur als Finger im Anschnitt).
„Inside the Studio“: Hände am Set erkannt, Rückenansichten von Menschen nicht.

Balken: Beide Making-ofs und mehrere Brickfilme sind Breitbild mit schwarzen
Balken. Die Randbedingung der Segmentierung sah deshalb Hände am Bildrand
nicht. `VisionHandDetector.contentBox` schneidet die Balken jetzt ab:
Making-of 25 → 35 erkannt, Brickfilme 4 Fehlalarme mehr, Lehrfilm, Knete
und Holz unverändert.

## Offen

- LEGO ist der schwächste Fall: 4 % Fehlalarm, Hände in dunklen oder
  farbstichigen Making-ofs nur zu gut der Hälfte erkannt. Figuren in Nahaufnahme, die den Bildrand
  füllen, hält die Segmentierung manchmal für Menschen.
- Echte Atelieraufnahmen mit Händen, die vom Rand in eine Knetszene greifen,
  fehlen noch; der Modellierkurs zeigt Hände in der Bildmitte.
