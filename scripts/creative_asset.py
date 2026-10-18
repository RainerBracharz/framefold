#!/usr/bin/env python3
"""Creative Asset für den App Store (Produktseiten-Kopf und Suche).

Ein „Universal"-Bild, 16:9, 5244 × 2950 px, PNG ohne Transparenz. Apple
schneidet daraus den Kopf (21:9) und die Suchkachel (3:2) mittig zu – alles
Wichtige steht deshalb in der Mitte (Schnittmenge ≈ 4425 × 2247 px).

Motiv: das eigene Faltbeispiel aus dem Werbespot als Bildstreifen, darüber
die Zeile aus dem Spot. Kein Fremdmaterial.

  eval/.venv/bin/python scripts/creative_asset.py <ausgabeordner> [de en fr]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = Path(sys.argv[1]).resolve()
LANGS = sys.argv[2:] or ["de", "en", "fr"]
ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "FrameFold" / "Assets.xcassets"
FOLD = ROOT.parent / "framefold-spot" / "faltung.npy"
W, H = 5244, 2950
PAPER = (244, 242, 236)
INK = (29, 26, 22)
GRAPHITE = (120, 114, 104)
AMBER = (217, 155, 43)
LINE = {"de": "Du faltest. Sie filmt.", "en": "You fold. It films.", "fr": "Tu plies. Elle filme."}
FRAMES = [0, 18, 30, 42, 54, 66, 90]          # Faltung in sieben Schritten


def font(name, size):
    return ImageFont.truetype(str(ASSETS / f"{name}.dataset" / f"{name}.ttf"), size)


def paper():
    rng = np.random.default_rng(5)
    base = np.ones((H, W, 3), np.float32) * np.array(PAPER, np.float32)
    grain = rng.normal(0, 1, (H // 4, W // 4)).astype(np.float32)
    grain = np.asarray(Image.fromarray(grain).resize((W, H), Image.BICUBIC))
    base *= (1 + 0.012 * grain)[..., None]
    # leichter Lichtabfall zu den Rändern
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = ((xx - W / 2) / W) ** 2 + ((yy - H / 2) / H) ** 2
    base *= (1 - 0.10 * d)[..., None]
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))


def strip(img):
    frames = np.load(FOLD)
    tile, gap = 470, 34
    n = len(FRAMES)
    total = n * tile + (n - 1) * gap
    x0, y0 = (W - total) // 2, 1330
    shadow = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shadow)
    for k in range(n):
        x = x0 + k * (tile + gap)
        sd.rectangle((x + 10, y0 + 22, x + tile + 10, y0 + tile + 22), fill=70)
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    img.paste(Image.new("RGB", (W, H), (150, 144, 134)), (0, 0), shadow)
    d = ImageDraw.Draw(img)
    num = font("Inter-Medium", 40)
    for k, i in enumerate(FRAMES):
        x = x0 + k * (tile + gap)
        img.paste(Image.fromarray(frames[i]).resize((tile, tile), Image.LANCZOS), (x, y0))
        d.rectangle((x, y0, x + tile - 1, y0 + tile - 1), outline=(205, 200, 190), width=2)
        # Bildnummer wie im Kontaktbogen
        label = f"{k + 1:02d}"
        lw = d.textlength(label, font=num)
        d.rectangle((x + 16, y0 + tile - 76, x + 16 + lw + 28, y0 + tile - 16), fill=INK)
        d.text((x + 30, y0 + tile - 70), label, font=num, fill=PAPER)
    return y0 + tile


def headline(img, text):
    d = ImageDraw.Draw(img)
    f = font("Fraunces-Italic", 300)
    width = sum(d.textlength(ch, font=f) for ch in text)
    x, y = (W - width) / 2, 830
    for ch in text:
        d.text((x, y), ch, font=f, fill=AMBER if ch == "." else INK)
        x += d.textlength(ch, font=f)


def signature(img, top):
    icon = Image.open(ASSETS / "AppIcon.appiconset" / "icon.png").convert("RGB").resize((150, 150), Image.LANCZOS)
    mask = Image.new("L", (150, 150), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 149, 149), radius=34, fill=255)
    d = ImageDraw.Draw(img)
    f = font("Fraunces-Regular", 104)
    name = "FrameFold"
    tw = d.textlength(name, font=f)
    total = 150 + 40 + tw
    x = (W - total) / 2
    y = top + 150
    img.paste(icon, (int(x), y), mask)
    d.text((x + 190, y + 12), name, font=f, fill=INK)


OUT.mkdir(parents=True, exist_ok=True)
for lang in LANGS:
    img = paper()
    bottom = strip(img)
    headline(img, LINE[lang])
    signature(img, bottom)
    path = OUT / f"creative-universal-{lang}.png"
    img.convert("RGB").save(path, optimize=True)
    print(path, img.size)
