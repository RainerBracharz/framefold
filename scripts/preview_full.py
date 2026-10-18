#!/usr/bin/env python3
"""App-Vorschau für den App Store – rahmenlos.

Apple hat die gerahmte Fassung (App-Bild verkleinert in einem iPhone-Rahmen,
Textband darüber, Schlussbild mit Logo) am 15.10.2026 abgelehnt: Vorschauen
dürfen nur Bildschirmaufnahmen der App zeigen, mit Text höchstens als
Einblendung (Guideline 2.3.4). Diese Fassung füllt das ganze Bild mit der
Aufnahme und legt die Zeilen als halbtransparente Einblendung oben darüber.

Rohmaterial: scripts/record_preview.sh (Aufnahme + Zeitmarken je Sprache).

  eval/.venv/bin/python scripts/preview_full.py <preview-raw> <ausgabe> [de en fr]

886 × 1920, 30 fps, H.264 ~11 Mbit/s, AAC 256 kbit/s – Apples Vorgaben für
6,9"-iPhones. Ergebnis: <ausgabe>/<sprache>/framefold-preview.mp4
"""
import os
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

RAW, OUT = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
LANGS = sys.argv[3:] or ["de", "en", "fr"]
ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "FrameFold" / "Assets.xcassets"
SOUND = ROOT.parent / "framefold-spot" / "preview" / "sound_preview.py"
W, H, FPS = 886, 1920, 30
CAPTION = 300                                   # Höhe der Einblendung oben
PAPER = np.array([244, 242, 236]) / 255
INK = (29, 26, 22)
AMBER = (217, 155, 43)

TEXT = {
    "de": ["Du arbeitest.\nSie löst von selbst aus.", "Der Film wächst mit.", "Fertig: deine Stopmotion.",
           "Jedes Werk als Daumenkino."],
    "en": ["You work.\nIt shoots by itself.", "The film grows as you go.", "Done: your stop motion.",
           "Every work as a flip book."],
    "fr": ["Tu travailles.\nElle déclenche seule.", "Le film grandit avec toi.", "Terminé : ton stop motion.",
           "Chaque œuvre en folioscope."],
}

# Schnittliste: (Ereignis, Versatz s, Länge s, Textnummer) – wie die
# gerahmte Fassung, aber ohne Schlussbild.
CUTS = [("camera", 1.5, 6.0, 0),
        ("loop-large", -0.3, 4.0, 1),
        ("finish", -5.0, 5.0, 1),
        ("result", -0.3, 4.5, 2),
        ("flipbook", -0.3, 1.6, 3), ("flipbook-ready", 0.8, 2.6, 3)]


def font(name, size):
    return ImageFont.truetype(str(ASSETS / f"{name}.dataset" / f"{name}.ttf"), size)


def clamp(t):
    return max(0.0, min(1.0, t))


def ease_out(t):
    return 1 - (1 - t) ** 4


def events(lang):
    t0 = float((RAW / f"{lang}-start.txt").read_text().split()[0])
    ev = {}
    for line in (RAW / lang / "events.txt").read_text().splitlines():
        ts, name = line.split(" ", 1)
        ev.setdefault(name.strip(), float(ts) - t0)
    return ev


def caption_layer(text, p):
    """Einblendung: Papier mit 88 % Deckkraft, Zeilen gleiten von unten ein."""
    img = Image.new("RGBA", (W, CAPTION), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, W, CAPTION), fill=tuple(int(v * 255) for v in PAPER) + (int(0.88 * 255 * p),))
    fnt = font("Fraunces-Italic", 62)
    lines = text.split("\n")
    asc, desc = fnt.getmetrics()
    lh = asc + desc + 8
    y = CAPTION / 2 - lh * len(lines) / 2 + (1 - p) * 24 + 20
    for ln in lines:
        x = W / 2 - fnt.getlength(ln) / 2
        for ch in ln:
            col = AMBER if ch in ".:" else INK
            d.text((x, y), ch, font=fnt, fill=col + (int(255 * p),))
            x += fnt.getlength(ch)
        y += lh
    return np.asarray(img, np.float32) / 255


def compose(frame, text, p):
    """Aufnahme bildschirmfüllend (nur skaliert, nichts gezoomt), oben die
    Einblendung."""
    scale = W / frame.shape[1]
    h = int(round(frame.shape[0] * scale))
    a = cv2.resize(frame, (W, h), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
    top = max(0, (h - H) // 2)
    a = a[top:top + H]
    if a.shape[0] < H:                                       # sicherheitshalber auffüllen
        a = np.vstack([a, np.repeat(a[-1:], H - a.shape[0], axis=0)])
    cap = caption_layer(text, p)
    alpha = cap[..., 3:4]
    a[:CAPTION] = a[:CAPTION] * (1 - alpha) + cap[..., :3] * alpha
    return a


def to8(x):
    return (np.clip(x, 0, 1) * 255 + 0.5).astype(np.uint8)


def segment(path, t0, n):
    cap = cv2.VideoCapture(str(path))
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    p = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-ss", f"{max(0, t0):.3f}", "-i", str(path),
                          "-frames:v", str(n), "-vf", "fps=30", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         stdout=subprocess.PIPE)
    for _ in range(n):
        buf = p.stdout.read(w * h * 3)
        if len(buf) < w * h * 3:
            break
        yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    p.stdout.close()
    p.wait()


def build(lang):
    ev = events(lang)
    tmp = OUT / f"_{lang}.mp4"
    wr = cv2.VideoWriter(str(tmp), cv2.VideoWriter_fourcc(*"mp4v"), FPS, (W, H))
    n, last, seg_start = 0, None, 0
    for name, off, length, ti in CUTS:
        if name not in ev:
            print(f"  {lang}: Ereignis {name} fehlt – übersprungen")
            continue
        text = TEXT[lang][ti]
        if text != last:
            seg_start, last = n, text
        for fr in segment(RAW / f"{lang}.mp4", ev[name] + off, int(length * FPS)):
            p = ease_out(clamp((n - seg_start) / 10))
            wr.write(cv2.cvtColor(to8(compose(fr, text, p)), cv2.COLOR_RGB2BGR))
            n += 1
    wr.release()
    dur = n / FPS
    dst = OUT / lang
    dst.mkdir(parents=True, exist_ok=True)
    final = dst / "framefold-preview.mp4"
    video = ["-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-pix_fmt", "yuv420p",
             "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "22M",
             "-x264-params", "nal-hrd=cbr", "-r", "30"]
    if SOUND.exists():
        wav = OUT / f"_{lang}.wav"
        subprocess.run([sys.executable, str(SOUND)], check=True, cwd=OUT,
                       env={**os.environ, "FF_DUR": f"{dur:.3f}", "FF_DROP": str(n), "FF_OUT": str(wav)})
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(tmp), "-i", str(wav), *video,
                        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
                        "-shortest", "-movflags", "+faststart", str(final)], check=True)
        wav.unlink()
    else:
        # Apple verlangt eine Tonspur – zur Not eine stille
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(tmp),
                        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", *video,
                        "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", str(final)],
                       check=True)
    tmp.unlink()
    print(f"  {lang}: {dur:.1f} s → {final}")


OUT.mkdir(parents=True, exist_ok=True)
for L in LANGS:
    build(L)
