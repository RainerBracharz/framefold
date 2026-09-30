#!/usr/bin/env python3
"""Pro Szenario: F1, Treffer, Fehlerarten. python3 eval/by_scenario.py <tag> [<tag> ...]"""
import collections, json, statistics, sys
from pathlib import Path
R = Path(__file__).parent / "results"
tags = sys.argv[1:]
data = {t: [json.loads(l) for l in (R / f"{t}.jsonl").read_text().splitlines()] for t in tags}
names = sorted({r["name"] for rs in data.values() for r in rs})
print(f"{'Szenario':16s}" + "".join(f"{t[:22]:>24s}" for t in tags))
for n in names:
    cells = []
    for t in tags:
        rs = [r for r in data[t] if r["name"] == n]
        cells.append(f"{statistics.fmean(r['f1'] for r in rs):.2f} {sum(r['hits'] for r in rs)}/{sum(r['states'] for r in rs)} D{sum(r['dup'] for r in rs)}")
    print(f"{n:16s}" + "".join(f"{c:>24s}" for c in cells))
