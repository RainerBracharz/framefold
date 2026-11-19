#!/usr/bin/env python3
"""Prüft einen fertigen Film vor dem Hochladen und gibt Zahlen aus.

    python3 scripts/film_pruefen.py film.mp4 [--schleife] [--halten 1.0] [--bogen bogen.jpg]

Geprüft wird die fertige Datei, also nach dem Kodieren:
  Bild      Maße, Bildrate, Dauer, Drehvermerk, erstes Bild nicht schwarz
  Bewegung  Bildänderung von Bild zu Bild, längste Standstrecke, Verlauf je Sekunde
  Naht      (--schleife) Sprung vom letzten zum ersten Bild gegen die üblichen Bildschritte
  Ton       Lautheit (Ziel -14 LUFS) und Spitze (höchstens -2 dBTP)

Stop-Motion hält Bilder absichtlich. Als Auffälligkeit zählt deshalb erst eine Standstrecke,
die länger ist als --halten Sekunden. Gewollte lange Halte (Titel) mit --halten anheben.
Ein stehendes Schlussbild zählt nur bei --schleife als Auffälligkeit.
Ende mit Status 1, wenn etwas auffällt.
"""
import argparse, json, re, subprocess, sys
import numpy as np

W, H = 160, 90          # Messgröße, reicht für die Bildänderung
STILL = 0.35            # mittlere Abweichung (0-255), darunter gilt ein Bildschritt als Stillstand
LUFS_ZIEL, LUFS_TOL, SPITZE_MAX = -14.0, 1.0, -2.0


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"ffprobe kann die Datei nicht lesen: {out.stderr.strip()}")
    return json.loads(out.stdout)


def frames(path):
    """Liefert alle Bilder verkleinert in Graustufen, in der Bildrate der Datei."""
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-map", "0:v:0", "-vf", f"scale={W}:{H}:flags=area,format=gray",
           "-f", "rawvideo", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = W * H
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        yield np.frombuffer(buf, np.uint8).astype(np.float32)
    p.wait()


def loudness(path):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-map", "0:a:0", "-af", "ebur128=peak=true",
                          "-f", "null", "-"], capture_output=True, text=True).stderr
    tail = out[out.rfind("Summary:"):] if "Summary:" in out else ""
    i = re.search(r"I:\s+(-?[\d.]+) LUFS", tail)
    pk = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", tail)
    lra = re.search(r"LRA:\s+(-?[\d.]+) LU", tail)
    f = lambda m: None if not m else (float("-inf") if m.group(1) == "-inf" else float(m.group(1)))
    return f(i), f(pk), f(lra)


def spark(values):
    marks = " ▁▂▃▄▅▆▇█"
    top = max(values) if len(values) and max(values) > 0 else 1.0
    return "".join(marks[min(8, int(round(v / top * 8)))] for v in values)


def main():
    ap = argparse.ArgumentParser(description="Film vor dem Hochladen prüfen")
    ap.add_argument("film")
    ap.add_argument("--schleife", action="store_true", help="Naht zwischen letztem und erstem Bild prüfen")
    ap.add_argument("--halten", type=float, default=1.0, help="längste erlaubte Standstrecke in Sekunden (Vorgabe 1.0)")
    ap.add_argument("--bogen", help="Kontaktbogen (ein Bild je Viertelsekunde) in diese Datei schreiben")
    a = ap.parse_args()

    info = probe(a.film)
    v = next((s for s in info["streams"] if s["codec_type"] == "video"), None)
    au = next((s for s in info["streams"] if s["codec_type"] == "audio"), None)
    if not v:
        sys.exit("Kein Bildstrom in der Datei.")
    num, den = (int(x) for x in v["avg_frame_rate"].split("/"))
    fps = num / den if den else 0.0
    dur = float(info["format"].get("duration", 0))
    rot = 0
    for sd in v.get("side_data_list", []):
        rot = int(sd.get("rotation", rot))
    flags = []

    print(f"Datei     {a.film}")
    print(f"Bild      {v['width']} × {v['height']}, {fps:.2f} Bilder/s, {dur:.2f} s, {v['codec_name']}, {v.get('pix_fmt', '?')}"
          + (f", Drehvermerk {rot}°" if rot else ""))
    if rot:
        flags.append(f"Drehvermerk {rot}° in der Datei (manche Abspieler zeigen den Film gedreht)")
    if v.get("pix_fmt") not in ("yuv420p", "yuvj420p"):
        flags.append(f"Pixelformat {v.get('pix_fmt')} statt yuv420p")

    # Bewegung
    prev = first = last = None
    diffs = []
    for f in frames(a.film):
        if prev is None:
            first = f
        else:
            diffs.append(float(np.abs(f - prev).mean()))
        prev = last = f
    if first is None or not diffs:
        sys.exit("Keine Bilder gelesen.")
    d = np.array(diffs)
    n = len(d) + 1
    moving = d >= STILL
    steps = d[moving]
    # Standstrecken: aufeinanderfolgende Bildschritte ohne Änderung
    runs, start = [], None
    for i, m in enumerate(moving):
        if not m and start is None:
            start = i
        if m and start is not None:
            runs.append((start, i)); start = None
    if start is not None:
        runs.append((start, len(d)))
    holds = sorted(((e - s + 1) / fps, s / fps) for s, e in runs)[::-1]   # Dauer, Beginn
    changes = int(moving.sum())
    print(f"Bewegung  {n} Bilder, {changes} Bildwechsel ({changes / dur:.1f} je Sekunde), "
          f"{100 * (1 - moving.mean()):.0f} % der Bildschritte ohne Änderung")
    if len(steps):
        print(f"          Bildschritt mittel {np.median(steps):.2f}, größter {steps.max():.2f} (Skala 0 bis 255)")
    per_sec = [float(d[int(s * fps):int((s + 1) * fps)].mean()) for s in range(max(1, int(np.ceil(dur)))) if len(d[int(s * fps):int((s + 1) * fps)])]
    print(f"          Verlauf je Sekunde  |{spark(per_sec)}|")
    if holds:
        print("          längste Standstrecken: " + ", ".join(f"{h:.2f} s ab {t:.2f} s" for h, t in holds[:5]))
    for h, t in holds:
        am_ende = t + h >= dur - 2 / fps
        if am_ende and not a.schleife and h > a.halten:
            print(f"          Schlussbild steht {h:.2f} s (zählt nicht als Auffälligkeit)")
        elif h > a.halten:
            flags.append(f"Standstrecke {h:.2f} s ab {t:.2f} s (erlaubt {a.halten:.2f} s)")
    if changes == 0:
        flags.append("Der Film bewegt sich nicht")
    if first.mean() < 8:
        flags.append("Das erste Bild ist schwarz")

    # Naht
    if a.schleife:
        seam = float(np.abs(first - last).mean())
        ref = float(np.percentile(steps, 90)) if len(steps) else 0.0
        print(f"Naht      Sprung letztes→erstes Bild {seam:.2f}, übliche Bildschritte bis {ref:.2f}")
        if seam < STILL:
            flags.append("Letztes und erstes Bild sind gleich (doppeltes Bild an der Naht, die Schleife stockt)")
        elif ref and seam > 1.5 * ref:
            flags.append(f"Sprung an der Naht {seam:.2f}, das {seam / ref:.1f}-Fache eines üblichen Bildschritts")

    # Ton
    if au:
        i, pk, lra = loudness(a.film)
        if i is None or pk is None:
            flags.append("Ton vorhanden, Lautheit nicht messbar")
            print("Ton       nicht messbar")
        else:
            print(f"Ton       {au['codec_name']}, {i:.1f} LUFS, Spitze {pk:.1f} dBTP, Umfang {lra:.1f} LU")
            if i == float("-inf") or i < -60:
                flags.append("Die Tonspur ist stumm")
            elif abs(i - LUFS_ZIEL) > LUFS_TOL:
                flags.append(f"Lautheit {i:.1f} LUFS, Ziel {LUFS_ZIEL:.0f} ± {LUFS_TOL:.0f}")
            if pk > SPITZE_MAX:
                flags.append(f"Spitze {pk:.1f} dBTP, erlaubt höchstens {SPITZE_MAX:.0f}")
    else:
        print("Ton       keine Tonspur")

    if a.bogen:
        cols = 8
        rows = max(1, int(np.ceil(dur * 4 / cols)))
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", a.film, "-vf", f"fps=4,scale=240:-2,tile={cols}x{rows}",
                            "-frames:v", "1", "-update", "1", a.bogen], capture_output=True, text=True)
        print(f"Bogen     {a.bogen}" if r.returncode == 0 else f"Bogen     nicht geschrieben: {r.stderr.strip()[:200]}")

    print()
    if flags:
        print("AUFFÄLLIG")
        for f in flags:
            print(f"  - {f}")
        sys.exit(1)
    print("Keine Auffälligkeit. Den Film trotzdem einmal mit Ton abspielen.")


if __name__ == "__main__":
    main()
