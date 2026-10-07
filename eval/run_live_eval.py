#!/usr/bin/env python3
"""
Eval der Live-Kamera: Sitzungen durchspielen, gegen die Wahrheit bewerten.

  eval/.venv/bin/python eval/run_live_eval.py                       # Stand der App
  eval/.venv/bin/python eval/run_live_eval.py --set motif_change=0 --tag wie-2.0
  eval/.venv/bin/python eval/run_live_eval.py --split train --tag versuch
  eval/.venv/bin/python eval/run_live_eval.py --only fokusverlust_1 --trace

Urteil pro Aufnahme:
  Treffer    erstes sauberes Bild eines Zustands, aus seiner Ruhephase
  Hand       Hand im Bild oder mitten im Griff ausgelöst
  unscharf   Fehlfokus ≥ 1,2 px (im 640er-Bild) im Moment der Aufnahme
  Duplikat   Zustand hatte schon ein Bild
  verpasst   Zustand ohne jedes Bild

F1 wie im Video-Eval. Dazu die Wartezeit: Sekunden von „Hände weg" bis zum
Klick, nur für Treffer.
"""
import argparse
import base64
import html
import json
import random
import statistics
import sys
from dataclasses import fields
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).parent))
import live_scenarios as ls                       # noqa: E402
from live_controller import Tunables, simulate    # noqa: E402

ROOT = Path(__file__).parent
RESULTS = ROOT / "results"
BLUR_LIMIT = 1.2


def load_split():
    """Pro Szenario 2 von 5 Varianten als Test, einmal festgelegt."""
    path = ROOT / "live_split.json"
    split = json.loads(path.read_text()) if path.exists() else {}
    rnd = random.Random(20261007)
    changed = False
    for p in ls.SCENARIOS:
        test = set(rnd.sample(list(ls.SEEDS), 2))
        for sd in ls.SEEDS:
            key = f"{p.name}_{sd}"
            if key not in split:
                split[key] = "test" if sd in test else "train"
                changed = True
    if changed:
        path.write_text(json.dumps(split, indent=1, sort_keys=True))
    return split


def grade(sess, shots):
    states = sorted({r["state"] for r in sess.rests})
    hit, verdicts, waits = set(), [], []
    for s in shots:
        t = s["t"]
        rest = next((r for r in sess.rests if r["t0"] <= t < r["t1"]), None)
        if sess.hand_visible(t) or rest is None:
            verdicts.append((t, "hand", None))
        elif s["blur_px"] >= BLUR_LIMIT:
            verdicts.append((t, "blur", rest["state"]))
        elif rest["state"] in hit:
            verdicts.append((t, "dup", rest["state"]))
        else:
            hit.add(rest["state"])
            verdicts.append((t, "hit", rest["state"]))
            waits.append(t - rest["t0"])
    n = len(shots)
    precision = len(hit) / n if n else 0.0
    recall = len(hit) / len(states)
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    count = lambda k: sum(1 for v in verdicts if v[1] == k)   # noqa: E731
    return {"states": len(states), "selected": n, "hits": len(hit), "hand": count("hand"),
            "blur": count("blur"), "dup": count("dup"), "missed": len(states) - len(hit),
            "precision": precision, "recall": recall, "f1": f1,
            "wait": statistics.fmean(waits[1:]) if len(waits) > 1 else None,   # ohne Startphase
            "verdicts": verdicts}


def bootstrap_ci(values, n=4000):
    rnd = random.Random(0)
    boots = sorted(statistics.fmean(rnd.choices(values, k=len(values))) for _ in range(n))
    return boots[int(n * 0.025)], boots[int(n * 0.975)]


LABEL = {"hit": ("Treffer", "#2a7"), "hand": ("Hand", "#c33"), "blur": ("unscharf", "#c80"),
         "dup": ("Duplikat", "#888")}


def write_report(rows, tun, title, path):
    parts = [f"<!doctype html><meta charset='utf-8'><title>{html.escape(title)}</title>"
             "<style>body{font:14px -apple-system,sans-serif;margin:24px;max-width:1100px}"
             "table{border-collapse:collapse}td,th{padding:4px 10px;border-bottom:1px solid #ddd;text-align:right}"
             "td:first-child,th:first-child{text-align:left}.why{color:#666;max-width:760px}"
             ".strip{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 14px}.t{font-size:11px;text-align:center}"
             ".t img{display:block;border:3px solid;width:160px}.k{color:#666;margin:10px 0 0}</style>",
             f"<h1>{html.escape(title)}</h1>",
             "<p class='why'>" + html.escape(", ".join(f"{f.name}={getattr(tun, f.name)}" for f in fields(tun)))
             + "</p>"]
    f1s = [r["f1"] for r in rows]
    parts.append(f"<p><b>Mittlerer F1 {statistics.fmean(f1s):.3f}</b> über {len(rows)} Sitzungen</p>")
    parts.append("<table><tr><th>Szenario</th><th>F1</th><th>Treffer</th><th>verpasst</th><th>Hand</th>"
                 "<th>unscharf</th><th>Duplikat</th><th>Wartezeit</th></tr>")
    by = {}
    for r in rows:
        by.setdefault(r["name"], []).append(r)
    for name, rs in by.items():
        w = [r["wait"] for r in rs if r["wait"] is not None]
        parts.append(f"<tr><td>{name}</td><td>{statistics.fmean(r['f1'] for r in rs):.2f}</td>"
                     f"<td>{sum(r['hits'] for r in rs)} / {sum(r['states'] for r in rs)}</td>"
                     f"<td>{sum(r['missed'] for r in rs)}</td><td>{sum(r['hand'] for r in rs)}</td>"
                     f"<td>{sum(r['blur'] for r in rs)}</td><td>{sum(r['dup'] for r in rs)}</td>"
                     f"<td>{statistics.fmean(w):.1f} s</td></tr>" if w else
                     f"<tr><td>{name}</td><td>{statistics.fmean(r['f1'] for r in rs):.2f}</td>"
                     f"<td>{sum(r['hits'] for r in rs)} / {sum(r['states'] for r in rs)}</td>"
                     f"<td>{sum(r['missed'] for r in rs)}</td><td>{sum(r['hand'] for r in rs)}</td>"
                     f"<td>{sum(r['blur'] for r in rs)}</td><td>{sum(r['dup'] for r in rs)}</td><td>–</td></tr>")
    parts.append("</table>")
    for name, rs in by.items():
        parts.append(f"<h2>{name}</h2><p class='why'>{html.escape(rs[0]['why'])}</p>")
        for r in rs:
            parts.append(f"<p class='k'>Variante {r['seed']} · F1 {r['f1']:.2f} · {r['hits']}/{r['states']} "
                         f"Zustände · Schwelle {r['threshold']:.1f} · {html.escape(r['events'])}</p>"
                         "<div class='strip'>")
            for (t, v, st), b64 in zip(r["verdicts"], r["thumbs"]):
                lab, col = LABEL[v]
                s = f" · Zustand {st}" if st is not None else ""
                parts.append(f"<div class='t'><img src='data:image/jpeg;base64,{b64}' style='border-color:{col}'>"
                             f"{t:.1f} s · <b style='color:{col}'>{lab}</b>{s}</div>")
            parts.append("</div>")
    path.write_text("".join(parts))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", action="append", default=[], help="feld=wert, z. B. motif_change=0")
    ap.add_argument("--tag", default="live-baseline")
    ap.add_argument("--split", choices=["train", "test", "all"], default="all")
    ap.add_argument("--only", default=None)
    ap.add_argument("--hands", choices=["ideal", "teil", "aus"], default="teil",
                    help="ideal: jede Fingerspitze wird erkannt (obere Schranke); teil: erst die "
                         "Handfläche (realistischer); aus: ohne Handerkennung")
    ap.add_argument("--trace", action="store_true", help="Protokoll und Messwerte je Takt ausgeben")
    a = ap.parse_args()

    tun = Tunables()
    types = {f.name: f.type for f in fields(Tunables)}
    for kv in a.set:
        k, v = kv.split("=")
        setattr(tun, k, {"int": int, "float": float, int: int, float: float}[types[k]](v))

    split = load_split()
    RESULTS.mkdir(exist_ok=True)
    rows = []
    for p in ls.SCENARIOS:
        for sd in ls.SEEDS:
            key = f"{p.name}_{sd}"
            if a.only and not key.startswith(a.only):
                continue
            if a.split != "all" and split[key] != a.split:
                continue
            sess = ls.build(p, sd)
            out = simulate(sess, tun, hands=a.hands)
            g = grade(sess, out["shots"])
            events = ", ".join(f"{t:.1f} {e}" for t, e in out["log"] if e != "klick")
            thumbs = [base64.b64encode(cv2.imencode(".jpg", s["gray"], [cv2.IMWRITE_JPEG_QUALITY, 75])[1]).decode()
                      for s in out["shots"]]
            rows.append({"video": key, "name": p.name, "seed": sd, "why": p.why,
                         "threshold": out["threshold"], "events": events,
                         **{k: v for k, v in g.items() if k != "verdicts"},
                         "verdicts": [(round(t, 2), v, s) for t, v, s in g["verdicts"]], "thumbs": thumbs})
            w = f"{g['wait']:.1f} s" if g["wait"] is not None else "–"
            print(f"{key:26s} F1 {g['f1']:.2f}  {g['hits']}/{g['states']}  Hand {g['hand']}  "
                  f"unscharf {g['blur']}  Dup {g['dup']}  Wartezeit {w}  Schwelle {out['threshold']:.1f}")
            if a.trace:
                for t, e in out["log"]:
                    print(f"    {t:6.2f}  {e}")
                for r in sess.rests:
                    print(f"    Ruhe {r['t0']:6.2f}–{r['t1']:6.2f}  Zustand {r['state']}")
                for t, m, sr, ref, bl in out["trace"][::5]:
                    print(f"    {t:6.1f}  Bewegung {m:5.1f}  Schärfe {sr:7.1f} / {ref:7.1f}  Fehlfokus {bl:.1f} px")

    if a.split != "all":
        a.tag = f"{a.tag}.{a.split}"
    if a.hands != "teil":
        a.tag = f"{a.tag}.hands-{a.hands}"
    if not a.only:
        with (RESULTS / f"{a.tag}.jsonl").open("w") as fh:
            for r in rows:
                fh.write(json.dumps({k: v for k, v in r.items() if k != "thumbs"}) + "\n")
        write_report(rows, tun, f"Live-Kamera · {a.tag} · Handerkennung {a.hands}", RESULTS / f"{a.tag}.html")
    f1s = [r["f1"] for r in rows]
    if len(f1s) > 1:
        lo, hi = bootstrap_ci(f1s)
        waits = [r["wait"] for r in rows if r["wait"] is not None]
        print(f"\nMittlerer F1 {statistics.fmean(f1s):.3f}  (95 % {lo:.3f}–{hi:.3f})  "
              f"Wartezeit {statistics.fmean(waits):.2f} s  → eval/results/{a.tag}.html")


if __name__ == "__main__":
    main()
