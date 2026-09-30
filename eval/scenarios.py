#!/usr/bin/env python3
"""
Szenario-Generator für das FrameFold-Eval.

Jedes Szenario ist ein kurzes Atelier-Video mit bekannter Wahrheit: Ein Werk
auf dem Tisch durchläuft eine Folge von Zuständen. Zwischen zwei Zuständen
greift eine Hand ins Bild und verändert etwas, danach ruht die Szene.

Zu jedem Video entsteht eine JSON-Datei mit
  - rests:  Zeitfenster, in denen die Szene ruht, mit Zustands-Nummer
  - hands:  Zeitfenster, in denen eine Hand im Bild ist
  - blur:   Zeitfenster, in denen das Bild unscharf ist
Ein gutes Ergebnis enthält genau ein Bild pro Zustand, aus dessen
Ruhefenster, ohne Hand, scharf, in der richtigen Reihenfolge.

Jedes Szenario steht für eine Situation, von der wir VORHER sagen können,
warum sie schwer ist (Regel aus dem Eval-Artikel: keine Fälle aufnehmen,
nur weil die aktuelle App an ihnen scheitert).
"""
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

W, H, FPS = 640, 360, 30


# --------------------------------------------------------------------------
# Szenen-Bausteine
# --------------------------------------------------------------------------

def make_table(rng):
    """Holztisch mit Maserung und leichtem Verlauf – Struktur, damit
    Schärfe- und Bewegungsmaße nicht auf einer glatten Fläche rechnen."""
    base = np.array(rng.uniform([170, 190, 205], [200, 215, 230]), np.float32)
    img = np.ones((H, W, 3), np.float32) * base
    x = np.linspace(0, 1, W, dtype=np.float32)
    grain = (np.sin(x[None, :] * rng.uniform(40, 90) + rng.uniform(0, 6)) * 6
             + rng.normal(0, 3, (H, W)).astype(np.float32))
    img += grain[..., None]
    y = np.linspace(-1, 1, H, dtype=np.float32)[:, None, None]
    img *= 1.0 - 0.06 * y
    return img


@dataclass
class Sheet:
    """Ein Blatt Papier mit Faltlinien. Zustand = Lage + Faltungen."""
    cx: float
    cy: float
    size: float
    angle: float
    folds: list = field(default_factory=list)   # Liste von (t0, t1): Linien in Blattkoordinaten

    def draw(self, img, shade=1.0):
        s = self.size / 2
        corners = np.array([[-s, -s], [s, -s], [s, s], [-s, s]], np.float32)
        rot = np.array([[math.cos(self.angle), -math.sin(self.angle)],
                        [math.sin(self.angle), math.cos(self.angle)]], np.float32)
        pts = corners @ rot.T + [self.cx, self.cy]
        cv2.fillConvexPoly(img, pts.astype(np.int32), (246 * shade, 247 * shade, 249 * shade),
                           lineType=cv2.LINE_AA)
        cv2.polylines(img, [pts.astype(np.int32)], True, (80, 80, 88), 2, cv2.LINE_AA)
        for (a, b) in self.folds:
            p = (np.array(a, np.float32) * s) @ rot.T + [self.cx, self.cy]
            q = (np.array(b, np.float32) * s) @ rot.T + [self.cx, self.cy]
            cv2.line(img, tuple(p.astype(int)), tuple(q.astype(int)), (120, 118, 125), 2, cv2.LINE_AA)
            # Falz wirft eine leichte Schattenseite
            cv2.line(img, tuple((p + 2).astype(int)), tuple((q + 2).astype(int)),
                     (205, 205, 210), 1, cv2.LINE_AA)


def draw_hand(img, x, y, rng_seed, scale=1.0):
    """Hand von oben ins Bild: Unterarm, Handfläche, vier Finger, Daumen.
    Hauttöne mit leichter Schattierung – kein Kreis, damit Bewegungs- und
    Schärfemaße etwas Handähnliches sehen."""
    r = np.random.default_rng(rng_seed)
    skin = np.array(r.uniform([120, 150, 190], [150, 175, 220]))
    dark = skin * 0.8
    s = scale
    arm = np.array([[x - 32 * s, -10], [x + 32 * s, -10], [x + 36 * s, y - 30 * s], [x - 36 * s, y - 30 * s]])
    cv2.fillConvexPoly(img, arm.astype(np.int32), tuple(dark.tolist()), cv2.LINE_AA)
    cv2.ellipse(img, (int(x), int(y)), (int(42 * s), int(36 * s)), 0, 0, 360, tuple(skin.tolist()), -1, cv2.LINE_AA)
    for i, dx in enumerate((-27, -9, 9, 27)):
        L = (40, 48, 46, 36)[i] * s
        cv2.line(img, (int(x + dx * s), int(y + 20 * s)), (int(x + dx * s * 1.1), int(y + 20 * s + L)),
                 tuple(skin.tolist()), int(15 * s), cv2.LINE_AA)
        cv2.line(img, (int(x + dx * s), int(y + 20 * s)), (int(x + dx * s * 1.1), int(y + 20 * s + L)),
                 tuple(dark.tolist()), 1, cv2.LINE_AA)
    cv2.line(img, (int(x + 38 * s), int(y)), (int(x + 64 * s), int(y + 22 * s)), tuple(skin.tolist()),
             int(16 * s), cv2.LINE_AA)


def draw_shadow(img, x, y, rx, ry, strength):
    mask = np.zeros((H, W), np.float32)
    cv2.ellipse(mask, (int(x), int(y)), (int(rx), int(ry)), 0, 0, 360, 1.0, -1)
    mask = cv2.GaussianBlur(mask, (0, 0), 25)
    img *= (1.0 - strength * mask)[..., None]


# --------------------------------------------------------------------------
# Szenario-Beschreibung
# --------------------------------------------------------------------------

@dataclass
class Params:
    name: str
    why: str                     # warum ist das schwer – vorher formuliert
    steps: int = 8
    rest: tuple = (1.0, 1.4)     # Dauer der Ruhephasen (min, max) in s
    move: tuple = (0.6, 0.9)     # Dauer eines Handgriffs
    change: str = "normal"       # normal | tiny | none_sometimes
    flicker: float = 0.0         # Helligkeitsflackern (Anteil)
    jitter: float = 0.0          # Handkamera: Zittern in Pixeln
    drift: float = 0.0           # Helligkeitsdrift über das Video (Anteil)
    noise: float = 2.0           # Sensorrauschen (Standardabweichung)
    dark: float = 1.0            # Gesamthelligkeit
    hand_pause: bool = False     # Hand bleibt mitten im Griff kurz stehen
    shadow_in_rest: bool = False # Schatten zieht durch eine Ruhephase
    focus_pump: float = 0.0      # erste Sekundenbruchteile jeder Ruhe unscharf


SCENARIOS = [
    Params("sauber", "Referenz: klare Ruhe, klare Bewegung. Muss praktisch fehlerfrei sein."),
    Params("flackern", "LED/Leuchtstoff bei 50 Hz: Helligkeit schwankt auch in der Ruhe, "
           "Ruhe sieht nach Bewegung aus.", flicker=0.05),
    Params("handkamera", "iPhone in der Hand: das ganze Bild zittert dauernd, der Abstand "
           "zwischen Ruhe und Bewegung schrumpft.", jitter=2.5),
    Params("kurze_ruhe", "Schnelles Arbeiten: Ruhephasen von 0,3–0,5 s, knapp über der "
           "Mindestdauer.", rest=(0.3, 0.5), move=(0.4, 0.6)),
    Params("hand_pause", "Hand hält mitten im Griff still im Bild: ruhig, aber mit Hand. "
           "Ohne Handerkennung rutscht sie durch.", hand_pause=True),
    Params("schatten", "Jemand geht vorbei: weicher Schatten zieht durch eine Ruhephase, "
           "sie zerfällt in Bewegung.", shadow_in_rest=True),
    Params("lichtdrift", "Wolken: Helligkeit ändert sich langsam über das ganze Video, "
           "verschiebt die Bewegungsverteilung.", drift=0.25),
    Params("kleine_schritte", "Feine Arbeit: jeder Schritt fügt nur eine kurze Falzlinie hinzu. "
           "Gefahr, echte Schritte als Duplikat zu verwerfen.", change="tiny"),
    Params("leere_griffe", "Hand greift hin, ändert aber nichts: diese Ruhephasen sind echte "
           "Duplikate und gehören NICHT ins Ergebnis.", change="none_sometimes"),
    Params("fokus_pumpt", "Autofokus sucht nach jedem Griff 0,3 s: Anfang jeder Ruhe unscharf.",
           focus_pump=0.3),
    Params("dunkel", "Abendatelier: wenig Licht, starkes Rauschen, geringer Kontrast.",
           dark=0.45, noise=7.0),
]


# --------------------------------------------------------------------------
# Rendern
# --------------------------------------------------------------------------

def render(p: Params, seed: int, out_dir: Path):
    rng = np.random.default_rng(seed)
    table = make_table(rng)
    # Werkgröße im Bild variiert mit der Variante: klein (weit weg), mittel,
    # groß (füllt das Bild fast). Alle drei kommen im Atelier vor.
    size = {1: 110, 2: 170, 3: 230, 4: 140, 5: 200}.get(seed, 150)
    sheet = Sheet(cx=W * 0.5, cy=H * 0.55, size=size, angle=rng.uniform(-0.2, 0.2))

    # Zeitplan: Ruhe, Griff, Ruhe, Griff ...
    timeline = []   # (kind, t0, t1, state, extra)
    t = 0.0
    state = 0
    for step in range(p.steps):
        rd = rng.uniform(*p.rest)
        timeline.append(("rest", t, t + rd, state, {}))
        t += rd
        if step == p.steps - 1:
            break
        md = rng.uniform(*p.move)
        changes = True
        if p.change == "none_sometimes" and step % 3 == 1:
            changes = False
        timeline.append(("move", t, t + md, state, {"changes": changes,
                                                    "hx": rng.uniform(0.25, 0.75) * W}))
        t += md
        if changes:
            state += 1
    duration = t

    # Zustände vorab festlegen
    sheets = []
    s = Sheet(sheet.cx, sheet.cy, sheet.size, sheet.angle, [])
    for k in range(state + 1):
        sheets.append(Sheet(s.cx, s.cy, s.size, s.angle, list(s.folds)))
        if p.change == "tiny":
            a = rng.uniform(-0.8, 0.8, 2)
            s.folds.append((tuple(a), tuple(a + rng.uniform(-0.25, 0.25, 2))))
        else:
            s.cx = float(np.clip(s.cx + rng.uniform(-60, 60), s.size * 0.6, W - s.size * 0.6))
            s.cy = float(np.clip(s.cy + rng.uniform(-25, 25), s.size * 0.6, H - s.size * 0.6))
            s.angle += rng.uniform(-0.35, 0.35)
            a = rng.uniform(-1, 1, 2)
            s.folds.append((tuple(a), tuple(-a)))

    truth = {"name": p.name, "seed": seed, "why": p.why, "fps": FPS,
             "duration": duration, "rests": [], "hands": [], "blur": [], "shadows": []}
    shadow_rest = None
    rest_items = [x for x in timeline if x[0] == "rest"]
    if p.shadow_in_rest:
        shadow_rest = rest_items[len(rest_items) // 2]
        # Schatten verlängert die Ruhe ein wenig, damit er Platz hat
    for kind, t0, t1, st, extra in timeline:
        if kind == "rest":
            truth["rests"].append({"t0": t0, "t1": t1, "state": st})
            if p.focus_pump > 0 and t0 > 0:
                truth["blur"].append({"t0": t0, "t1": min(t1, t0 + p.focus_pump)})
        else:
            truth["hands"].append({"t0": t0, "t1": t1})
    if shadow_rest:
        truth["shadows"].append({"t0": shadow_rest[1], "t1": shadow_rest[2]})

    path = out_dir / f"{p.name}_{seed}.mp4"
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), FPS, (W, H))
    n = int(math.ceil(duration * FPS))
    jx = jy = 0.0
    for i in range(n):
        tt = i / FPS
        seg = next(x for x in timeline if x[1] <= tt < x[2] or x is timeline[-1])
        kind, t0, t1, st, extra = seg
        img = table.copy()

        if kind == "rest":
            sheets[st].draw(img)
        else:
            u = (tt - t0) / (t1 - t0)
            # Blatt springt in der Mitte des Griffs in den neuen Zustand
            nxt = st + 1 if extra["changes"] else st
            (sheets[st] if u < 0.5 else sheets[nxt]).draw(img)
            target = sheets[st if u < 0.5 else nxt]
            side = 1 if extra["hx"] > W / 2 else -1
            if p.hand_pause and 0.3 < u < 0.7:
                # Hand steht still im Bild – ruhig, aber eben mit Hand
                depth, sweep = 1.0, 0.0
            else:
                # Hand ist ständig in Bewegung: kommt schräg von der Seite,
                # greift, zieht sich zurück. Kein Stillstand in der Mitte.
                depth = math.sin(math.pi * u)
                sweep = (1 - depth) * 180 * side + 25 * math.sin(u * 2 * math.pi * 2)
            hx = target.cx + sweep
            hy = -60 + (target.cy - 20 + 60) * depth
            draw_hand(img, hx, hy, seed * 100 + int(t0 * 10))

        if shadow_rest and shadow_rest[1] <= tt < shadow_rest[2]:
            u = (tt - shadow_rest[1]) / (shadow_rest[2] - shadow_rest[1])
            draw_shadow(img, -100 + u * (W + 200), H * 0.5, 140, 220, 0.35)

        # Licht
        gain = p.dark
        if p.flicker:
            # 100-Hz-Helligkeitsschwankung bei 30 fps, mit Belichtungsjitter
            gain *= 1.0 + p.flicker * math.sin(2 * math.pi * 100 * tt + rng.normal(0, 0.8))
        if p.drift:
            gain *= 1.0 - p.drift * (0.5 - 0.5 * math.cos(math.pi * tt / duration))
        img *= gain

        # Unschärfe (Fokus sucht)
        blurred = any(b["t0"] <= tt < b["t1"] for b in truth["blur"])
        if blurred:
            img = cv2.GaussianBlur(img, (0, 0), 3.2)

        # Handkamera
        if p.jitter:
            jx = 0.8 * jx + rng.normal(0, p.jitter)
            jy = 0.8 * jy + rng.normal(0, p.jitter)
            M = np.float32([[1, 0, jx], [0, 1, jy]])
            img = cv2.warpAffine(img, M, (W, H), borderMode=cv2.BORDER_REFLECT)

        img += rng.normal(0, p.noise, img.shape).astype(np.float32)
        writer.write(np.clip(img, 0, 255).astype(np.uint8))
    writer.release()

    (out_dir / f"{p.name}_{seed}.json").write_text(json.dumps(truth, indent=1))
    return path


def generate(out_dir: Path, seeds=(1, 2, 3, 4, 5)):
    out_dir.mkdir(parents=True, exist_ok=True)
    made = []
    for p in SCENARIOS:
        for s in seeds:
            made.append(render(p, s, out_dir))
    return made


if __name__ == "__main__":
    import sys
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / "videos")
    for m in generate(out):
        print(m.name)
