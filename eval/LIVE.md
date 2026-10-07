# Eval der Live-Kamera (07.10.2026)

Das Video-Eval (`README.md`, `HILLCLIMB.md`) prüft die Bildauswahl aus einem
fertigen Video. Dieses hier prüft den Auto-Auslöser: Er entscheidet kausal,
Bild für Bild, und greift dabei in die Kamera ein. Der Fehler aus 2.0 (kein
Klick nach einem Motivwechsel) lag genau hier und war vom Video-Eval nicht zu
sehen.

```
python3 -m venv eval/.venv && eval/.venv/bin/pip install numpy opencv-python-headless
eval/.venv/bin/python eval/run_live_eval.py                    # Stand der App
eval/.venv/bin/python eval/run_live_eval.py --only fokusverlust_1 --trace
eval/.venv/bin/python eval/live_table.py live-baseline live-final
```

## Aufbau

- `live_scenarios.py`: 16 Situationen × 5 Varianten. Jede ist ein Drehbuch
  (Ruhe, Griff, Hand bleibt liegen, Schatten, Lampe) mit bekannter Wahrheit
  und einem Satz, warum sie schwer ist.
- `live_controller.py`: Nachbau von `LiveCaptureController.analyze` samt
  Schärfe-Tor, Wächter und Fokuslauf, auf simulierter Uhr. Dazu ein
  Kameramodell: Linse mit Autofokus, die auf Fixieren und Freigeben reagiert.
  Die Unschärfe im Bild hängt also davon ab, was der Auslöser tut.
- `run_live_eval.py`: Urteil pro Aufnahme (Treffer, Hand, unscharf, Duplikat),
  F1 pro Sitzung, Wartezeit von „Hände weg" bis Klick.
- Handerkennung in drei Stufen: `ideal` (jede Fingerspitze), `teil` (erst die
  Handfläche, Standard), `aus`.
- Aufteilung: pro Szenario 3 Varianten Train, 2 Test (`live_split.json`).

## Ausgangsmessung (App 2.0.2)

F1 0,75 über 80 Sitzungen. Was dahinter steckt:

| Befund | Szenarien | Ursache im Code |
|---|---|---|
| Echter Fokusverlust wird als Motivwechsel durchgewinkt: 16 unscharfe Bilder | fokusverlust, motiv_und_fokus | `acceptMotifChange()` aus 2.0.1 unterscheidet die beiden Fälle nicht. Beide senken nur die Laplace-Varianz. |
| Nach jedem Motivwechsel stellt der Wächter 4 s später grundlos neu scharf und blockiert die nächsten Bilder | motivwechsel, motiv_und_fokus | `acceptMotifChange()` setzt `sharpReference` neu, aber nicht `sharpAtLock`. |
| Langsame Hand am Bildrand: Klick mit Fingerspitzen, die echte Ruhe danach geht verloren | langsame_hand | Bewegung als Bildmittel: Eine kleine, langsame Hand bleibt unter der Schwelle. Nach dem Klick fehlt die Bewegung, die neu scharf schaltet. |
| Bei Flackern, wenig Licht oder Arbeit schon beim Einmessen landet die Schwelle so hoch, dass Griffe nicht mehr als Bewegung zählen | flackern, dunkel, kalibrierung_gestoert | Schwelle = 3 × Median des Bildmittels, ohne Helligkeitsausgleich. Der Ausgleich aus dem Video-Eval wurde nie in die Live-Kamera übernommen. |
| Griff ohne Änderung, Schatten, Lampe: dasselbe Bild doppelt | leere_griffe, schatten, licht_an | Scharf geschaltet wird durch Bewegung, nicht durch Veränderung. |

Ohne Fehler: sauber, kurze Ruhe, Hand beim Fixieren, ruhende Hand (mit
Handerkennung), Handkamera fast.

## Hillclimbing

Jede Änderung einzeln auf Train (48 Sitzungen), die Kombination einmal auf
Test (32).

| Änderung | Train F1 | Wirkung |
|---|---|---|
| Ausgang | 0,75 | |
| Helligkeitsausgleich (Median der Differenz abziehen) | 0,79 | Flackern 20 → 4 verpasst |
| Bewegung im stärksten von 8 × 8 Feldern, mit Ausgleich | 0,89 | langsame Hand, dunkel, Flackern, gestörtes Einmessen fehlerfrei. Aus der Hand unbrauchbar (Zittern trifft jedes Feld, 0,93 → 0,52) – deshalb ab der letzten Zeile nur am Stativ, aus der Hand bleibt das Bildmittel. |
| Motivwechsel setzt auch `sharpAtLock` – allein | 0,72 | schlechter: Der grundlose Wächterlauf war zugleich die einzige Reparatur bei echtem Fokusverlust. Nur zusammen mit der nächsten Zeile sinnvoll. |
| Kantenschärfe als zweite Meinung: Motivwechsel nur, wenn das Verhältnis Laplace/Gradient an den stärksten Kanten ≥ 0,7 des Bestwerts bleibt | 0,94 (mit den beiden darüber) | unscharfe Bilder 24 → 0 |
| Kein Bild, wenn es dem letzten gleicht (stärkstes Feld < 0,5 × Schwelle); Feldmaß nur am Stativ | 0,99 | Duplikate 13 → 3, Handkamera wieder 0,93 |
| Schwelle gleitend absenken (ruhigstes Zehntel der letzten 10 s) | – | verworfen: mit dem Feldmaß überflüssig, allein schadet es bei Flackern |
| Abkürzung aus 2.0.1 wieder ausbauen | 0,74 | verworfen: keine unscharfen Bilder mehr, dafür kehrt der Fehler aus 2.0 zurück |

**Test: F1 0,742 → 0,996**, gepaart Δ +0,254 [+0,153, +0,367], 18 besser,
0 schlechter. Alle 80: 0,749 → 0,992, eine Sitzung schlechter (`licht_an_5`).
Die Wartezeit steigt von 0,66 auf 0,99 s, weil die verfrühten Klicks mit
Fingerspitzen wegfallen.

Gewählte Einstellung:

```
--set block_motion=1 --set gain_comp=1 --set motif_updates_lock=1 \
--set acutance=1 --set acutance_ratio=0.7 --set dedup_factor=0.5
```

## Grenzen

- **Alles synthetisch**, auch die Kamera. Reaktionszeit und Tempo des
  Autofokus, das Rauschen im Analysebild und die Grenze der Handerkennung
  sind geschätzt, nicht gemessen. Ein Ergebnis von 0,99 heißt: Die Szenarien
  sind gelöst – nicht: die Kamera ist fertig.
- **Kantenschärfe:** Die Schwelle 0,7 hat ein enges Fenster (0,6 lässt
  Unschärfe durch, 0,8 hält echte Motivwechsel auf). Das trägt auf Test, muss
  aber am Gerät mit echten Motiven bestätigt werden. Ein Fehlurteil
  „unscharf" kostet nur Wartezeit (Verhalten wie 2.0), ein Fehlurteil
  „Motivwechsel" ein weiches Bild (Verhalten wie 2.0.2).
- **Lampe geht an:** bleibt ein Duplikat. Ein Helligkeitssprung um 25 % ist
  kein gleichmäßiger Versatz, der Ausgleich fängt ihn nicht.
- **Handkamera** läuft unverändert mit dem Bildmittel.
- Nicht nachgebaut: Intervallmodus, manueller Auslöser, Wechsel
  Stativ/Hand mitten in der Sitzung.

## Noch nicht in der App

Die Änderungen stehen nur in `live_controller.py`. Für die App wären es:
`Algorithms.maxBlockDifference` gegen das Vorbild statt `motionScore` (am
Stativ), ein Kantenmaß neben `laplacianVariance`, zwei Zeilen in
`acceptMotifChange()` und der Vergleich mit dem letzten Bild vor `capture()`.
