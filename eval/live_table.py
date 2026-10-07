#!/usr/bin/env python3
"""Pro Szenario: F1 und Fehlerarten mehrerer Live-Läufe nebeneinander.
   eval/.venv/bin/python eval/live_table.py <tag> [<tag> ...]
   Zelle: F1 · verpasst/Hand/unscharf/Duplikat"""
import json, statistics, sys
from pathlib import Path
R = Path(__file__).parent / "results"
tags = sys.argv[1:]
data = {t: [json.loads(l) for l in (R / f"{t}.jsonl").read_text().splitlines()] for t in tags}
names = list(dict.fromkeys(r["name"] for rs in data.values() for r in rs))
print(f"{'Szenario':22s}" + "".join(f"{t[-20:]:>22s}" for t in tags))
for n in names + ["GESAMT"]:
    cells = []
    for t in tags:
        rs = [r for r in data[t] if n in (r["name"], "GESAMT")]
        cells.append(f"{statistics.fmean(r['f1'] for r in rs):.2f} · "
                     f"{sum(r['missed'] for r in rs)}/{sum(r['hand'] for r in rs)}/"
                     f"{sum(r['blur'] for r in rs)}/{sum(r['dup'] for r in rs)}")
    print(f"{n:22s}" + "".join(f"{c:>22s}" for c in cells))
