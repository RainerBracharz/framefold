#!/usr/bin/env python3
"""
FrameFold-Eval: Szenarien erzeugen (falls nötig), Bildauswahl laufen lassen,
gegen die bekannte Wahrheit bewerten, Ergebnisseite schreiben.

  python3 eval/run_eval.py                 # Ausgangsmessung mit App-Standardwerten
  python3 eval/run_eval.py --regen         # Videos neu erzeugen
  python3 eval/run_eval.py --set motion_percentile=0.5 --tag versuch1

Bewertung pro Video (programmatisch, kein Modell):
  Treffer      Zustand hat ein sauberes Bild aus seiner Ruhephase
  Hand         gewähltes Bild zeigt eine Hand (App: Vision fängt das ab, hier nicht)
  unscharf     gewähltes Bild stammt aus einer Fokus-Suchphase
  Duplikat     zweites Bild für denselben Zustand
  verpasst     Zustand ohne jedes Bild

  Präzision = Treffer / gewählte Bilder, Ausbeute = Treffer / Zustände, F1.
"""
import argparse
import base64
import html
import json
import random
import statistics
import sys
import time
from dataclasses import fields
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import scenarios            # noqa: E402
from selector import Settings, select   # noqa: E402

ROOT = Path(__file__).parent
VIDEOS = ROOT / "videos"
RESULTS = ROOT / "results"


def in_any(t, spans, pad=0.0):
    return any(s["t0"] - pad <= t < s["t1"] + pad for s in spans)


def grade(truth, times):
    states = sorted({r["state"] for r in truth["rests"]})
    hit, verdicts = set(), []
    for t in times:
        if in_any(t, truth["hands"]):
            verdicts.append((t, "hand", None))
            continue
        rest = next((r for r in truth["rests"] if r["t0"] <= t < r["t1"]), None)
        if rest is None:
            verdicts.append((t, "hand", None))   # außerhalb jeder Ruhe = mitten im Griff
            continue
        if in_any(t, truth["blur"]):
            verdicts.append((t, "blur", rest["state"]))
            continue
        if rest["state"] in hit:
            verdicts.append((t, "dup", rest["state"]))
            continue
        hit.add(rest["state"])
        verdicts.append((t, "hit", rest["state"]))
    n_sel = len(times)
    precision = len(hit) / n_sel if n_sel else 0.0
    recall = len(hit) / len(states) if states else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    count = lambda k: sum(1 for v in verdicts if v[1] == k)   # noqa: E731
    return {"states": len(states), "selected": n_sel, "hits": len(hit),
            "hand": count("hand"), "blur": count("blur"), "dup": count("dup"),
            "missed": len(states) - len(hit),
            "precision": precision, "recall": recall, "f1": f1,
            "verdicts": verdicts}


def thumbs(video, verdicts, width=120):
    cap = cv2.VideoCapture(str(video))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    out = []
    for t, v, st in verdicts:
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(round(t * fps)))
        ok, frame = cap.read()
        if not ok:
            continue
        h = int(frame.shape[0] * width / frame.shape[1])
        small = cv2.resize(frame, (width, h), interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 70])
        out.append((t, v, st, base64.b64encode(buf).decode()))
    cap.release()
    return out


def bootstrap_ci(values, n=2000, seed=0):
    rnd = random.Random(seed)
    means = sorted(statistics.fmean(rnd.choices(values, k=len(values))) for _ in range(n))
    return means[int(0.025 * n)], means[int(0.975 * n)]


LABEL = {"hit": ("Treffer", "#2f6f4f"), "hand": ("Hand", "#a3342b"),
         "blur": ("unscharf", "#b7791f"), "dup": ("Duplikat", "#6b5b95")}


def write_report(rows, st, tag, path):
    f1s = [r["f1"] for r in rows]
    mean = statistics.fmean(f1s)
    lo, hi = bootstrap_ci(f1s)
    tot = lambda k: sum(r[k] for r in rows)   # noqa: E731
    by_scn = {}
    for r in rows:
        by_scn.setdefault(r["name"], []).append(r)

    parts = [f"""<!doctype html><meta charset="utf-8"><title>FrameFold-Eval · {html.escape(tag)}</title>
<style>
body{{font:14px/1.45 -apple-system,Helvetica,Arial,sans-serif;margin:32px auto;max-width:1100px;color:#1d1b19;background:#f6f3ee}}
h1{{font:italic 30px Georgia,serif;margin:0 0 4px}} h2{{font:italic 21px Georgia,serif;margin:34px 0 4px}}
.k{{text-transform:uppercase;letter-spacing:.12em;font-size:11px;color:#6d665e}}
table{{border-collapse:collapse;width:100%;margin:12px 0;background:#fff}}
td,th{{border-bottom:1px solid #e3ddd4;padding:6px 8px;text-align:right}} td:first-child,th:first-child{{text-align:left}}
.big{{font:36px Georgia,serif}} .why{{color:#6d665e;margin:2px 0 8px}}
.strip{{display:flex;gap:6px;flex-wrap:wrap;margin:6px 0 16px}}
.t{{width:120px;font-size:10px}} .t img{{display:block;width:120px;border:3px solid}}
.bad{{color:#a3342b}}
</style>
<p class="k">FrameFold · Eval der Bildauswahl · {html.escape(tag)} · {time.strftime('%d.%m.%Y %H:%M')}</p>
<h1>Ausgangsmessung</h1>
<p><span class="big">{mean:.3f}</span> &nbsp;mittlerer F1 über {len(rows)} Videos
&nbsp;<span class="k">95 %-Intervall {lo:.3f} – {hi:.3f}</span></p>
<table><tr><th>Summe</th><th>Zustände</th><th>gewählt</th><th>Treffer</th><th>verpasst</th>
<th>Hand</th><th>unscharf</th><th>Duplikat</th></tr>
<tr><td>alle Videos</td><td>{tot('states')}</td><td>{tot('selected')}</td><td>{tot('hits')}</td>
<td>{tot('missed')}</td><td>{tot('hand')}</td><td>{tot('blur')}</td><td>{tot('dup')}</td></tr></table>
<p class="k">Einstellungen: {html.escape(json.dumps(st.as_dict()))}</p>
<p class="why">Handerkennung „ideal": statt Apples Vision entscheidet die bekannte Wahrheit, ob ein Bild eine
Hand zeigt. Das ist die obere Schranke – die echte App kann nur schlechter sein. Fehler, die hier trotzdem
auftreten, liegen in der Bildauswahl selbst. Mit „aus" sieht man, was ohne Handerkennung durchrutschen würde.</p>
<h2>Nach Szenario</h2>
<table><tr><th>Szenario</th><th>F1</th><th>Treffer / Zustände</th><th>verpasst</th><th>Hand</th>
<th>unscharf</th><th>Duplikat</th></tr>"""]
    for name, rs in by_scn.items():
        parts.append(
            f"<tr><td>{name}</td><td>{statistics.fmean(r['f1'] for r in rs):.3f}</td>"
            f"<td>{sum(r['hits'] for r in rs)} / {sum(r['states'] for r in rs)}</td>"
            f"<td>{sum(r['missed'] for r in rs)}</td><td>{sum(r['hand'] for r in rs)}</td>"
            f"<td>{sum(r['blur'] for r in rs)}</td><td>{sum(r['dup'] for r in rs)}</td></tr>")
    parts.append("</table>")

    for name, rs in by_scn.items():
        parts.append(f"<h2>{name}</h2><p class='why'>{html.escape(rs[0]['why'])}</p>")
        for r in rs:
            parts.append(f"<p class='k'>Variante {r['seed']} · F1 {r['f1']:.2f} · "
                         f"{r['hits']}/{r['states']} Zustände · Schwelle {r['threshold']:.2f} · "
                         f"{r['windows']} Ruhefenster</p><div class='strip'>")
            for t, v, stt, b64 in r["thumbs"]:
                lab, col = LABEL[v]
                s = f" · Zustand {stt}" if stt is not None else ""
                parts.append(f"<div class='t'><img src='data:image/jpeg;base64,{b64}' style='border-color:{col}'>"
                             f"{t:.1f} s · <b style='color:{col}'>{lab}</b>{s}</div>")
            if r["missed"]:
                parts.append(f"<div class='t bad'>{r['missed']} Zustand/Zustände ohne Bild</div>")
            parts.append("</div>")
    path.write_text("".join(parts))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--regen", action="store_true")
    ap.add_argument("--set", action="append", default=[], help="feld=wert, z. B. motion_percentile=0.5")
    ap.add_argument("--tag", default="baseline")
    ap.add_argument("--only", default=None, help="nur Videos, deren Name so beginnt")
    ap.add_argument("--hands", choices=["ideal", "aus"], default="ideal",
                    help="ideal: perfekte Handerkennung (obere Schranke für Apple Vision); "
                         "aus: wie mit ausgeschalteter Handerkennung")
    a = ap.parse_args()

    if a.regen or not any(VIDEOS.glob("*.mp4")):
        print("Erzeuge Szenario-Videos …")
        scenarios.generate(VIDEOS)

    st = Settings()
    types = {f.name: f.type for f in fields(Settings)}
    for kv in a.set:
        k, v = kv.split("=")
        setattr(st, k, (int if types[k] in (int, "int") else float)(v))

    RESULTS.mkdir(exist_ok=True)
    rows = []
    for video in sorted(VIDEOS.glob("*.mp4")):
        if a.only and not video.stem.startswith(a.only):
            continue
        truth = json.loads(video.with_suffix(".json").read_text())
        hands = None
        if a.hands == "ideal":
            hands = lambda t, tr=truth: in_any(t, tr["hands"])   # noqa: E731
        sel = select(video, st, has_hand=hands)
        g = grade(truth, sel["times"])
        row = {"video": video.stem, "name": truth["name"], "seed": truth["seed"], "why": truth["why"],
               "threshold": sel["threshold"], "windows": sel["windows"], "dedup_dropped": sel["dupes"],
               **{k: v for k, v in g.items() if k != "verdicts"},
               "verdicts": [(round(t, 2), v, s) for t, v, s in g["verdicts"]]}
        rows.append(row)
        print(f"{video.stem:22s} F1 {g['f1']:.2f}  {g['hits']}/{g['states']}  "
              f"Hand {g['hand']}  unscharf {g['blur']}  Dup {g['dup']}")
        row["thumbs"] = thumbs(video, g["verdicts"])

    out = RESULTS / f"{a.tag}.jsonl"
    with out.open("w") as fh:
        for r in rows:
            fh.write(json.dumps({k: v for k, v in r.items() if k != "thumbs"}) + "\n")
    report = RESULTS / f"{a.tag}.html"
    write_report(rows, st, f"{a.tag} · Handerkennung {a.hands}", report)
    f1s = [r["f1"] for r in rows]
    lo, hi = bootstrap_ci(f1s)
    print(f"\nMittlerer F1 {statistics.fmean(f1s):.3f}  (95 % {lo:.3f}–{hi:.3f})  → {report}")


if __name__ == "__main__":
    main()
