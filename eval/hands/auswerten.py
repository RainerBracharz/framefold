"""Wertet film.csv/neg.csv gegen truth.py aus. Aufruf: python3 auswerten.py"""
import csv
from truth import NO_HANDS
r = list(csv.DictReader(open("film.csv"))); neg = list(csv.DictReader(open("neg.csv")))
num = lambda x: int(x["datei"][2:6])
truth = {num(x): num(x) not in NO_HANDS for x in r}
P = sum(truth.values()); N = len(truth) - P
g = lambda k, t: (lambda x: float(x[k]) >= t)
def ev(name, f):
    tp = sum(1 for x in r if truth[num(x)] and f(x)); fp = sum(1 for x in r if not truth[num(x)] and f(x))
    fpn = sum(1 for x in neg if f(x) and not x["datei"].startswith("io_00"))
    print(f"{name:42} erkannt {tp:3}/{P} ({tp/P:4.0%})  Fehlalarm {fp:2}/{N}  Gegenprobe {fpn}/{len(neg)-2}")
    return [num(x) for x in r if truth[num(x)] and not f(x)]
pose = g("pose", 0.3)
ev("heute: Pose", pose)
ev("Pose auf Kacheln", g("pose_kacheln", 0.3))
ev("Pose oder Kacheln", lambda x: pose(x) or g("pose_kacheln", 0.3)(x))
for k in ("person_schnell", "person", "person_genau"):
    for t in (0.03, 0.05):
        ev(f"Pose oder {k} ≥{t}", lambda x, k=k, t=t: pose(x) or g(k, t)(x))
for t in (0.03, 0.05):
    m = ev(f"Pose oder Kacheln oder Person(bal.) ≥{t}", lambda x, t=t: pose(x) or g("pose_kacheln", 0.3)(x) or g("person", t)(x))
print("übersehen:", m)
