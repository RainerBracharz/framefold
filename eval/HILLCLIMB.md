# Hillclimbing der Bildauswahl – Runde 1 (30.09.2026)

Ziel: bessere Bildauswahl (F1), nicht Geschwindigkeit. Stellschraube: die
Schwellen- und Vergleichslogik in `selector.py`. Jede Änderung einzeln, mit
Ursache begründet, erst auf Train, dann einmal auf Test.

Aufteilung: 55 Videos (11 Szenarien × 5 Varianten), pro Szenario 2 Varianten
fest als Test (`split.json`, 22 Videos), 33 als Train. Test-Kontaktbögen
wurden beim Klettern nicht angesehen.

Messrauschen: gepaarter Vergleich pro Video (`compare.py`). Ein Lauf ist
deterministisch; das Rauschen kommt allein aus der Auswahl der Videos.

| Runde | Änderung | Train Δ F1 | Test Δ F1 | Entscheidung |
|---|---|---|---|---|
| 1 | Duplikate über das stärkste von 8×8 Rasterfeldern statt 9×8-Fingerabdruck; Duplikat, wenn < 0,5 × Bewegungsschwelle | +0,060 [+0,003, +0,124] | +0,062 [−0,033, +0,168] | behalten |
| 2 | Globale Helligkeitsänderung (Median der Differenz) vor jedem Vergleich herausrechnen | +0,027 [0,000, +0,060] | +0,040 [0,000, +0,104] | behalten |
| 3a | Duplikatvergleich mit ±2–4 px Verschiebesuche | +0,002 | – | unter Rauschen, nicht übernommen |
| 3b | Jedes Analysebild per Phasenkorrelation auf das erste ausrichten | −0,180 | – | verworfen: Korrelation rastet auf das bewegte Blatt ein |
| 4 | Vergleiche auf Struktur (Bild minus Weichzeichnung, σ 2/4/8) | −0,041 … −0,009 | – | verworfen |

Nach zwei Runden ohne Gewinn: verbleibende Train-Fehler nach Ursache sortiert.

- **Handkamera, doppelte Bilder (11):** Zittern zerlegt jede Ruhephase in
  mehrere Fenster, und die Bilder unterscheiden sich um Subpixel-Versätze.
  Braucht echte Stabilisierung vor der Auswahl (die App hat `FrameAligner`,
  nutzt ihn aber erst beim Zusammenbau). Größerer Umbau, nicht in dieser Runde.
- **Schatten, verpasste Zustände (4):** Der Schatten zieht über die GESAMTE
  Ruhephase. Es gibt dort kein Bild ohne Schatten. Vermutlich ein zu strenger
  Fall im Eval, kein Fehler der App – beim nächsten Überarbeiten des
  Szenarios den Schatten nur einen Teil der Ruhe bedecken lassen.
- **Kleine Schritte (2):** je eine besonders kurze Falzlinie fällt unter die
  Duplikatschwelle. Grenzfall, bewusst so belassen.

## Ergebnis auf allen 55 Videos

F1 0,882 → 0,975, gepaart Δ +0,093 [+0,046, +0,148]; 18 besser, 2 schlechter
(beide Handkamera). Größter Gewinn: kleine Schritte 11/40 → 37/40 erkannt,
Flackern 26 → 0 doppelte Bilder.

Ohne Handerkennung (`--hands aus`) ändert sich wenig (0,200 → 0,219): die
Änderungen wirken, wo die Handerkennung ihre Arbeit tut.

## Übernahme in die App

Ursprünglich geplant: vor der Übernahme 5–10 echte Atelier-Videos als
Prüfstein. Stattdessen entschieden mit der Gegenprobe unten. Echte Videos
bleiben sinnvoll, sobald es welche gibt – als zusätzlicher Testsatz.

## Entscheidung ohne echte Videos (30.09.2026)

Statt auf eigene Aufnahmen zu warten: Gegenprobe an den beiden gerenderten
Faltvideos (`docs/assets/tolino-quelle.mp4`, `fratzen-quelle.mp4`). Sie haben
echte Fototexturen und waren am Klettern nicht beteiligt. Ergebnis:

- Tolino: alt 7, neu 8 Bilder. Fratze: alt 21, neu 23 Bilder.
- Kein Bild fällt weg, drei kommen dazu. Alle drei zeigen sichtbar neue
  Faltschritte, die der alte 9×8-Fingerabdruck als Duplikat verworfen hatte
  (Differenzbilder geprüft).

Damit übernommen in die App (Swift): `Algorithms.motionScoreGainCompensated`,
`Algorithms.maxBlockDifference`, Duplikatprüfung in `ProcessingViewModel`,
`PipelineSettings.dedupBlockFactor = 0.5`. Gleichheit mit dem Python-Nachbau
sichern Tests in `linux-tests/main.swift` mit Werten aus `eval/selector.py`.

Die Live-Kamera ist nicht betroffen, sie hat ihre eigene Kalibrierung.
