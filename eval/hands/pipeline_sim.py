"""Vergleicht Auswahlregeln nach einem Handtreffer an echten Detektorergebnissen.
Eingaben: fenster.json (fenster.py), video.csv (videocheck), truth.py.
Wahrheit je Zeitpunkt t: Bild l_{round(t)+1} der 1-Bild/s-Beschriftung."""
import csv, json
from truth import NO_HANDS

_f = json.load(open("fenster.json"))
wins = _f["windows"] if isinstance(_f, dict) else _f
det = {round(float(r["t"]), 3): r["hand"] == "1" for r in csv.DictReader(open("video.csv"))}
def truth(t): return (round(t) + 1) not in NO_HANDS   # True = Hand zu sehen

def current(w):            # bis 2.8: erster Kandidat ohne Treffer
    for t in w:
        if not det[t]: return t
def neu(w, k=9, share=0.5, r=0.2):   # ab 2.9: Stichprobe über die Zeit, dann Nachbarprüfung
    ts = sorted(w)
    top = ts if k >= len(ts) else [ts[round(i * (len(ts) - 1) / (k - 1))] for i in range(k)]
    if sum(det[t] for t in top) / len(top) > share:
        return None
    for t in w:
        if not det[t] and all(not det[u] for u in w if abs(u - t) <= r + 1e-6):
            return t

pol = {"bisher": current, "Stichprobe + Nachbarn": neu}
clean = [w for w in wins if sum(not truth(t) for t in w) / len(w) >= 0.5]
print(f"{len(wins)} Fenster, {len(clean)} davon überwiegend ohne Hand")
print(f"{'Regel':30s} behalten  mit Hand  davon verloren")
for name, f in pol.items():
    kept = [t for t in (f(w) for w in wins) if t is not None]
    bad = sum(truth(t) for t in kept)
    lost = sum(1 for w in clean if f(w) is None or truth(f(w)))
    print(f"{name:30s} {len(kept):8d}  {bad:8d}  {lost:6d}")
