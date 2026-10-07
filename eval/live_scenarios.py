#!/usr/bin/env python3
"""
Szenarien für das Eval der Live-Kamera (Auto-Auslöser).

Anders als beim Video-Eval gibt es hier keine fertigen Videos: Der Auslöser
greift in die Kamera ein (Fokus fixieren, neu scharf stellen), und was die
Kamera danach zeigt, hängt davon ab. Ein Szenario ist deshalb ein Drehbuch
plus ein kleines Kameramodell, das zur Laufzeit befragt wird:

  clean(i)        scharfes, rauschfreies Bild zum Analyse-Takt i (640 × 360, grau)
  subject_d(t)    Entfernung des Werks (willkürliche Einheit; 1,0 daneben
                  entspricht 3,2 px Unschärfe im 640er-Bild)
  hand_visible(t) ist eine Hand im Bild?
  rests           Ruhephasen mit Zustands-Nummer – die Wahrheit

Ein gutes Ergebnis: genau ein Bild pro Zustand, aus dessen Ruhephase, ohne
Hand, scharf. Zusätzlich zählt die Wartezeit von „Hände weg" bis „Klick".

Jedes Szenario steht für eine Situation, von der wir VORHER sagen können,
warum sie für einen kausalen Auslöser schwer ist.
"""
import math
from dataclasses import dataclass, field

import cv2
import numpy as np

from scenarios import W, H, Sheet, draw_hand, draw_shadow, make_table

TICK = 0.1            # Analyse-Takt der App (~10 Bilder/s)
HAND_OFFSET = 1.0     # so viel näher an der Kamera liegt eine Hand


@dataclass
class LiveParams:
    name: str
    why: str
    steps: int = 8
    lead_in: float = 6.0          # erste Ruhe: Kalibrierung + Fokus brauchen Zeit
    rest: tuple = (3.0, 4.5)      # wie lange die Hände danach aus dem Bild sind
    move: tuple = (1.2, 2.5)      # Dauer eines Handgriffs
    rig: str = "tripod"           # tripod | handheld
    noise: float = 0.6            # Sensorrauschen im 160er-Analysebild
    dark: float = 1.0
    flicker: float = 0.0
    jitter: float = 0.0           # Handkamera: Zittern in px (640er-Bild)
    af_hand: bool = False         # Autofokus springt auf die Hand, solange er frei läuft
    af_pump: float = 0.0          # Handkamera: Fokus pumpt nach jedem Griff (Einheiten)
    textured_until: int = -1      # bis zu diesem Zustand ist das Blatt bedruckt
    defocus_at: int = -1          # ab diesem Zustand liegt das Werk woanders (Einheiten: defocus_by)
    defocus_by: float = 0.8
    empty_every: int = 0          # jeder n-te Griff ändert nichts
    hand_rests: bool = False      # Hand bleibt nach dem Griff ruhig im Bild liegen
    slow_hand: bool = False       # sehr langsame, vorsichtige Hand
    shadow: bool = False          # Schatten zieht durch eine Ruhephase
    light_step: float = 0.0       # Lampe geht mitten in einer Ruhe an (Anteil)
    busy_start: bool = False      # schon während der Kalibrierung wird gearbeitet
    early_hand: bool = False      # erster Griff beginnt, bevor der Fokus sitzt


SCENARIOS = [
    LiveParams("sauber", "Referenz am Stativ: klare Griffe, lange Ruhe. Muss fehlerfrei sein."),
    LiveParams("motivwechsel", "Bedrucktes Blatt wird zur glatten Faltfläche: Die Schärfezahl fällt, "
               "obwohl der Fokus stimmt. Der Fehler aus 2.0.", textured_until=3),
    LiveParams("fokusverlust", "Das Werk wächst der Kamera entgegen, der fixierte Fokus stimmt nicht mehr. "
               "Die Schärfezahl fällt genauso wie beim Motivwechsel – hier ist es aber echt.",
               defocus_at=4),
    LiveParams("motiv_und_fokus", "Beides zugleich: erst wird das Motiv glatt (harmlos), später geht der "
               "Fokus wirklich verloren. Wer das erste durchwinkt, darf das zweite nicht übersehen.",
               textured_until=2, defocus_at=5),
    LiveParams("hand_beim_fixieren", "Der Künstler greift sofort nach dem Start zu: Der Autofokus misst auf "
               "die Hand und wird dort eingefroren.", early_hand=True, af_hand=True),
    LiveParams("hand_ruht", "Nach dem Griff bleibt die Hand ruhig am Blatt liegen. Ruhig, aber nicht frei.",
               hand_rests=True),
    LiveParams("langsame_hand", "Vorsichtiges Arbeiten: Die Hand bewegt sich so langsam, dass die Szene "
               "ruhig wirkt.", slow_hand=True, move=(5.0, 7.0)),
    LiveParams("leere_griffe", "Hand greift hin, ändert aber nichts. Die Ruhe danach zeigt dasselbe Bild "
               "wie zuvor – ein Auslöser, der nur Bewegung kennt, legt es doppelt ab.", empty_every=3),
    LiveParams("schatten", "Jemand geht vorbei: Bewegung ohne Arbeit, danach dasselbe Bild.", shadow=True),
    LiveParams("licht_an", "Eine Lampe geht an: ein Helligkeitssprung ohne Arbeit, bei fixierter "
               "Belichtung voll sichtbar.", light_step=0.25),
    LiveParams("flackern", "LED-Flackern, das die Netzfrequenz-Belichtung nicht abfängt: Ruhe sieht nach "
               "Bewegung aus.", flicker=0.04),
    LiveParams("dunkel", "Abendatelier: starkes Rauschen. Die Schärfezahl misst dann vor allem Rauschen.",
               dark=0.45, noise=1.3),
    LiveParams("dunkel_fokusverlust", "Wie dunkel, dazu echter Fokusverlust: Sieht das Schärfemaß ihn "
               "unter dem Rauschen überhaupt?", dark=0.45, noise=1.3, defocus_at=4),
    LiveParams("kurze_ruhe", "Zügiges Arbeiten: nur 1,2–1,6 s Pause zwischen den Griffen.",
               rest=(1.2, 1.6)),
    LiveParams("kalibrierung_gestoert", "Schon in den ersten zwei Sekunden wird gearbeitet: Die "
               "Bewegungsschwelle wird an der Hand statt am Grundrauschen eingemessen.", busy_start=True),
    LiveParams("handkamera", "iPhone in der Hand: Das Bild zittert, der Autofokus läuft weiter und pumpt "
               "nach jedem Griff.", rig="handheld", jitter=2.5, af_pump=0.6, noise=0.8),
]


class TexturedSheet(Sheet):
    """Blatt mit Druck: kontrastreiche Flächen und Linien (viel Struktur)."""
    def __init__(self, base: Sheet, seed: int):
        super().__init__(base.cx, base.cy, base.size, base.angle, list(base.folds))
        self.seed = seed

    def draw(self, img, shade=1.0):
        super().draw(img, shade)
        r = np.random.default_rng(self.seed)
        s = self.size / 2
        rot = np.array([[math.cos(self.angle), -math.sin(self.angle)],
                        [math.sin(self.angle), math.cos(self.angle)]], np.float32)
        for _ in range(26):
            c = r.uniform(-0.8, 0.8, 2)
            wh = r.uniform(0.04, 0.16, 2)
            quad = np.array([[-1, -1], [1, -1], [1, 1], [-1, 1]], np.float32) * wh + c
            pts = (quad * s) @ rot.T + [self.cx, self.cy]
            g = float(r.uniform(20, 120))
            cv2.fillConvexPoly(img, pts.astype(np.int32), (g, g, g), lineType=cv2.LINE_AA)


class PlainSheet(Sheet):
    """Gefaltete, glatte Fläche: kleiner, einfarbig, nur feine Falze."""
    def draw(self, img, shade=1.0):
        s = self.size * 0.36
        corners = np.array([[-s, -s], [s, -s], [s, s], [-s, s]], np.float32)
        rot = np.array([[math.cos(self.angle), -math.sin(self.angle)],
                        [math.sin(self.angle), math.cos(self.angle)]], np.float32)
        pts = corners @ rot.T + [self.cx, self.cy]
        cv2.fillConvexPoly(img, pts.astype(np.int32), (150, 190, 226), lineType=cv2.LINE_AA)
        for (a, b) in self.folds[-3:]:
            p = (np.array(a, np.float32) * s) @ rot.T + [self.cx, self.cy]
            q = (np.array(b, np.float32) * s) @ rot.T + [self.cx, self.cy]
            cv2.line(img, tuple(p.astype(int)), tuple(q.astype(int)), (135, 175, 212), 1, cv2.LINE_AA)


@dataclass
class Session:
    p: LiveParams
    seed: int
    duration: float
    timeline: list
    rests: list                      # {"t0","t1","state"}
    frames: list                     # scharfe Bilder je Takt (float32, 640 × 360)
    gains: list
    shifts: list
    kicks: list = field(default_factory=list)   # Zeitpunkte, an denen der Fokus pumpt
    defocus_t: float = math.inf

    def seg(self, t):
        for s in self.timeline:
            if s["t0"] <= t < s["t1"]:
                return s
        return self.timeline[-1]

    def hand_depth_at(self, t):
        s = self.seg(t)
        if s["kind"] == "still":
            return 1.0
        if s["kind"] in ("move", "exit"):
            return hand_depth(s, t)
        return 0.0

    def hand_visible(self, t):
        """Wahrheit: Fingerspitzen ragen ins Bild (ab etwa 14 px)."""
        return self.hand_depth_at(t) > 0.06

    def palm_visible(self, t):
        """Handfläche im Bild – das, was eine echte Handerkennung braucht.
        Fingerspitzen am Bildrand allein erkennt sie nicht."""
        return self.hand_depth_at(t) > 0.35

    def subject_d(self, t):
        return self.p.defocus_by if t >= self.defocus_t else 0.0

    def clean(self, i):
        return self.frames[min(i, len(self.frames) - 1)]


def hand_depth(s, t):
    u = (t - s["t0"]) / (s["t1"] - s["t0"])
    if s["kind"] == "exit":
        return 1.0 - u
    if s.get("enter_only"):
        return math.sin(math.pi * u / 2)
    if s.get("pause") and 0.3 < u < 0.7:
        return 1.0
    return math.sin(math.pi * u)


def build(p: LiveParams, seed: int) -> Session:
    rng = np.random.default_rng(seed * 7919 + sum(map(ord, p.name)))
    table = make_table(rng)
    size = {1: 120, 2: 170, 3: 220, 4: 145, 5: 195}.get(seed, 160)

    # ---- Drehbuch ---------------------------------------------------------
    tl, t, state = [], 0.0, 0

    def add(kind, dur, **kw):
        nonlocal t
        tl.append({"kind": kind, "t0": t, "t1": t + dur, "state": state, **kw})
        t += dur

    if p.busy_start:
        add("rest", 0.3)
        add("move", 2.4, changes=False, hx=rng.uniform(0.3, 0.7) * W)
        add("rest", 4.5)
    elif p.early_hand:
        add("rest", 2.3)
    else:
        add("rest", p.lead_in)
    mid = p.steps // 2
    for step in range(1, p.steps):
        changes = not (p.empty_every and step % p.empty_every == 2)
        md = rng.uniform(*p.move)
        first_early = p.early_hand and step == 1
        add("move", 3.0 if first_early else md, changes=changes, hx=rng.uniform(0.25, 0.75) * W,
            pause=first_early, enter_only=p.hand_rests)
        if changes:
            state += 1
        if p.hand_rests:
            add("still", rng.uniform(1.5, 2.5), hx=tl[-1]["hx"])
            add("exit", 0.6, hx=tl[-1]["hx"])
        rd = rng.uniform(*p.rest)
        if step == mid and p.shadow:
            add("rest", 2.5); add("shadow", 1.5); add("rest", 3.5)
        elif step == mid and p.light_step:
            add("rest", 2.5, light=0); add("rest", 4.0, light=1)
        else:
            add("rest", rd)
    duration = t

    # Licht: Sprung ab dem markierten Abschnitt
    light_t = next((s["t0"] for s in tl if s.get("light") == 1), math.inf)
    defocus_t = math.inf
    if p.defocus_at >= 0:
        s = next(x for x in tl if x["kind"] == "move" and x["changes"] and x["state"] == p.defocus_at - 1)
        defocus_t = (s["t0"] + s["t1"]) / 2

    # ---- Zustände ---------------------------------------------------------
    sheets = []
    s = Sheet(W * 0.5, H * 0.55, size, rng.uniform(-0.2, 0.2), [])
    for k in range(state + 1):
        base = Sheet(s.cx, s.cy, s.size, s.angle, list(s.folds))
        if p.textured_until >= 0:
            sheets.append(TexturedSheet(base, seed * 31 + 5) if k <= p.textured_until
                          else PlainSheet(base.cx, base.cy, base.size, base.angle, base.folds))
        else:
            sheets.append(base)
        s.cx = float(np.clip(s.cx + rng.uniform(-60, 60), s.size * 0.6, W - s.size * 0.6))
        s.cy = float(np.clip(s.cy + rng.uniform(-25, 25), s.size * 0.6, H - s.size * 0.6))
        s.angle += rng.uniform(-0.35, 0.35)
        a = rng.uniform(-1, 1, 2)
        s.folds.append((tuple(a), tuple(-a)))

    # ---- Wahrheit: aufeinanderfolgende Ruheabschnitte desselben Zustands
    # ohne Hand dazwischen gelten als EINE Ruhe erst recht nicht – jede Ruhe
    # bleibt einzeln, der Zustand entscheidet über „doppelt".
    # Bei `early_hand` ist die erste Ruhe kürzer als Kalibrierung plus
    # Ruhezeit – dort kann kein Bild entstehen, also wird keins erwartet.
    rests = [{"t0": x["t0"], "t1": x["t1"], "state": x["state"]} for x in tl
             if x["kind"] in ("rest", "shadow") and not (p.early_hand and x["t0"] == 0)]

    # ---- Bilder -----------------------------------------------------------
    n = int(math.ceil(duration / TICK))
    frames, gains, shifts, kicks = [], [], [], []
    jx = jy = 0.0
    for x in tl:
        if x["kind"] == "move" and p.af_pump:
            kicks.append(x["t1"])
    sess = Session(p, seed, duration, tl, rests, frames, gains, shifts, kicks, defocus_t)
    for i in range(n):
        tt = i * TICK
        x = sess.seg(tt)
        img = table.copy()
        st = x["state"]
        if x["kind"] == "move":
            u = (tt - x["t0"]) / (x["t1"] - x["t0"])
            nxt = st + 1 if x["changes"] else st
            cur = sheets[st] if u < 0.5 else sheets[nxt]
            cur.draw(img)
            depth = hand_depth(x, tt)
            side = 1 if x["hx"] > W / 2 else -1
            wobble = 0.0 if (x.get("pause") and 0.3 < u < 0.7) else 25 * math.sin(u * 4 * math.pi)
            hx = cur.cx + (1 - depth) * 180 * side + wobble
            hy = -60 + (cur.cy - 20 + 60) * depth
            draw_hand(img, hx, hy, seed * 100 + int(x["t0"] * 10))
        else:
            sheets[st].draw(img)
            if x["kind"] in ("still", "exit"):
                depth = hand_depth(x, tt) if x["kind"] == "exit" else 1.0
                side = 1 if x["hx"] > W / 2 else -1
                hx = sheets[st].cx + (1 - depth) * 180 * side
                hy = -60 + (sheets[st].cy - 20 + 60) * depth
                draw_hand(img, hx, hy, seed * 100 + 7)
            if x["kind"] == "shadow":
                u = (tt - x["t0"]) / (x["t1"] - x["t0"])
                draw_shadow(img, -100 + u * (W + 200), H * 0.5, 140, 220, 0.35)
        gain = p.dark
        if tt >= light_t:
            gain *= 1.0 + p.light_step * min(1.0, (tt - light_t) / 0.2)
        if p.flicker:
            gain *= 1.0 + p.flicker * math.sin(rng.uniform(0, 2 * math.pi))
        if p.jitter:
            jx = 0.8 * jx + rng.normal(0, p.jitter)
            jy = 0.8 * jy + rng.normal(0, p.jitter)
        frames.append(cv2.cvtColor(np.clip(img, 0, 255).astype(np.uint8), cv2.COLOR_BGR2GRAY)
                      .astype(np.float32))
        gains.append(gain)
        shifts.append((jx, jy))
    return sess


SEEDS = (1, 2, 3, 4, 5)
