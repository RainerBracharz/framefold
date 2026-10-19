#!/usr/bin/env python3
"""Bilder für die README: Titelbild (drei iPhones mit den Store-Bildern),
Demo-GIF (das eigene Faltbeispiel aus dem Spot) und Social-Preview.
Nur eigenes Material.

  eval/.venv/bin/python scripts/readme_assets.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
SHOTS = ROOT / "fastlane" / "screenshots" / "en-US"
ASSETS = ROOT / "FrameFold" / "Assets.xcassets"
FOLD = ROOT.parent / "framefold-spot" / "faltung.npy"
INK, GRAPHITE, AMBER = (29, 26, 22), (104, 100, 91), (217, 155, 43)


def font(name, size):
    return ImageFont.truetype(str(ASSETS / f"{name}.dataset" / f"{name}.ttf"), size)


def backdrop(w, h):
    """Heller Galerieverlauf, oben warmes Papier, unten kühler."""
    top, bottom = np.array([244, 242, 236], np.float32), np.array([222, 225, 219], np.float32)
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    img = top * (1 - t) + bottom * t
    return Image.fromarray(np.repeat(img, w, axis=1).astype(np.uint8))


def phone(shot, width):
    """Bildschirmfoto im schlichten iPhone-Rahmen mit runden Ecken."""
    s = Image.open(shot).convert("RGB")
    sw = width - 2 * int(width * 0.035)
    sh = int(sw * s.height / s.width)
    s = s.resize((sw, sh), Image.LANCZOS)
    b = int(width * 0.035)
    w, h = width, sh + 2 * b
    body = Image.new("RGB", (w, h), INK)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=int(w * 0.16), fill=255)
    smask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(smask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius=int(w * 0.13), fill=255)
    body.paste(s, (b, b), smask)
    return body, mask


def header():
    W, H = 2400, 1900
    img = backdrop(W, H)
    pw = 680
    names = ["01-start.png", "04-kontaktbogen.png", "02-kamera.png"]
    xs = [140, (W - pw) // 2, W - 140 - pw]
    for name, x in zip(names, xs):
        body, mask = phone(SHOTS / name, pw)
        y = (H - body.height) // 2
        sh = Image.new("L", (W, H), 0)
        sh.paste(mask.point(lambda v: v * 0.30), (x + 10, y + 34))
        sh = sh.filter(ImageFilter.GaussianBlur(36))
        img.paste(Image.new("RGB", (W, H), (120, 116, 108)), (0, 0), sh)
        img.paste(body, (x, y), mask)
    img.save(DOCS / "app.png", optimize=True)


def demo_gif():
    """Das Faltbeispiel hin und zurück im Stopmotion-Takt, 420 × 560."""
    frames = np.load(FOLD)
    W, H = 420, 560
    picks = list(range(0, 96, 3)) + list(range(93, -1, -4))
    out = []
    bg = backdrop(W, H)
    for i in picks:
        f = Image.fromarray(frames[i]).resize((W, W), Image.LANCZOS)
        im = bg.copy()
        im.paste(f, (0, (H - W) // 2))
        out.append(im.quantize(colors=96, method=Image.MEDIANCUT, dither=Image.NONE))
    out[0].save(DOCS / "demo.gif", save_all=True, append_images=out[1:], duration=120, loop=0, optimize=True)
    return len(out)


def social():
    W, H = 2560, 1280
    img = backdrop(W, H)
    d = ImageDraw.Draw(img)
    d.text((240, 330), "STOP-MOTION · BY ITSELF", font=font("Inter-Medium", 46), fill=GRAPHITE)
    d.text((228, 400), "FrameFold", font=font("Fraunces-Regular", 250), fill=INK)
    d.text((240, 700), "You fold. It films.", font=font("Fraunces-Italic", 92), fill=INK)
    d.text((240, 850), "Shoots the moment your hands leave the frame.",
           font=font("Inter-Regular", 46), fill=GRAPHITE)
    d.line((240, 960, 900, 960), fill=(200, 196, 188), width=3)
    d.text((240, 1000), "iPhone · Mac · Apple Watch · on-device · free", font=font("Inter-Regular", 40), fill=GRAPHITE)
    fold = np.load(FOLD)[47]
    f = Image.fromarray(fold).resize((760, 760), Image.LANCZOS)
    img.paste(f, (W - 760 - 200, (H - 760) // 2))
    img.save(DOCS / "social-preview.png", optimize=True)


if __name__ == "__main__":
    header()
    n = demo_gif()
    social()
    print("app.png, demo.gif (%d Bilder), social-preview.png" % n)
