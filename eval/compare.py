#!/usr/bin/env python3
"""
Vergleicht zwei Läufe gepaart, Video für Video.

  python3 eval/compare.py r0-baseline.train r1-blocks.train

Gepaart heißt: Unterschied pro Video, dann Mittel und Bootstrap-Intervall
über diese Unterschiede. Das ist viel schärfer als zwei getrennte
Intervalle zu vergleichen, weil die Schwierigkeit des einzelnen Videos
herausfällt.
"""
import json
import random
import statistics
import sys
from pathlib import Path

R = Path(__file__).parent / "results"


def load(tag):
    return {json.loads(l)["video"]: json.loads(l) for l in (R / f"{tag}.jsonl").read_text().splitlines()}


def paired(a_tag, b_tag, key="f1"):
    a, b = load(a_tag), load(b_tag)
    common = sorted(set(a) & set(b))
    d = [b[v][key] - a[v][key] for v in common]
    rnd = random.Random(0)
    boots = sorted(statistics.fmean(rnd.choices(d, k=len(d))) for _ in range(4000))
    return {"n": len(d), "a": statistics.fmean(a[v][key] for v in common),
            "b": statistics.fmean(b[v][key] for v in common),
            "delta": statistics.fmean(d), "lo": boots[100], "hi": boots[3899],
            "better": sum(x > 1e-9 for x in d), "worse": sum(x < -1e-9 for x in d),
            "worse_videos": [v for v, x in zip(common, d) if x < -1e-9]}


if __name__ == "__main__":
    r = paired(sys.argv[1], sys.argv[2])
    print(f"{sys.argv[1]} → {sys.argv[2]}  (n={r['n']})")
    print(f"  F1 {r['a']:.3f} → {r['b']:.3f}   Δ {r['delta']:+.3f}  95 % [{r['lo']:+.3f}, {r['hi']:+.3f}]")
    print(f"  besser {r['better']}, schlechter {r['worse']}  {r['worse_videos']}")
