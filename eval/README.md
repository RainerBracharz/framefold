# Eval der Bildauswahl

> Für den Auto-Auslöser der Live-Kamera gibt es ein eigenes Eval: [LIVE.md](LIVE.md).

Misst, wie gut FrameFold aus einem Arbeitsvideo die richtigen Bilder wählt:
genau eins pro Arbeitsschritt, ohne Hand, scharf, ohne Duplikate.

```
pip install opencv-python numpy
python3 eval/run_eval.py --regen            # Videos erzeugen + Ausgangsmessung
python3 eval/run_eval.py --set dedup_threshold=2 --tag versuch1
```

Ergebnis: `eval/results/<tag>.html` (Übersicht, pro Szenario, Kontaktbogen je
Video mit Urteil pro Bild) und `<tag>.jsonl` (eine Zeile pro Video).

## Aufbau

- `scenarios.py` erzeugt 11 Situationen × 3 Varianten (kleines, mittleres,
  großes Werk im Bild). Zu jedem Video gibt es die Wahrheit: Ruhephasen mit
  Zustands-Nummer, Handgriffe, unscharfe Stellen. Jede Situation ist mit einem
  Satz begründet, warum sie schwer ist.
- `selector.py` baut die Bildauswahl der App nach (Otsu-Schwelle mit
  Perzentil-Untergrenze, Ruhefenster, schärfstes Bild, dHash-Duplikate), mit
  den Standardwerten aus `PipelineSettings`.
- `run_eval.py` bewertet programmatisch, kein Modell im Spiel.

## Grenzen

- **Handerkennung:** Apples Vision läuft nur auf dem Gerät. Standard ist
  `--hands ideal`: die Wahrheit entscheidet, ob ein Bild eine Hand zeigt.
  Das ist die obere Schranke, die echte App kann nur schlechter sein.
- **Nur synthetische Videos.** Für Hillclimbing braucht es einen
  zurückgehaltenen Satz echter Atelier-Videos, sonst optimiert man auf die
  eigene Vorstellung vom Atelier.
- **Rauschen:** Bei 33 Videos ist das 95-%-Intervall rund ±0,06 breit.
  Kleinere Verbesserungen sind nicht messbar; dann mehr Varianten erzeugen.
