#!/usr/bin/env python3
"""
Erzeugt ein synthetisches "Atelier-Video" zum Testen der Pipeline:
Ein Papierquadrat wandert in 8 diskreten Schritten über den Tisch.
Zwischen den Schritten fährt eine "Hand" ins Bild (Bewegungsphase),
danach liegt die Szene ~1 s still (Ruhefenster).

Erwartung: Die Pipeline findet ~8 Keyframes (einen pro Ruhephase).
"""
import cv2
import numpy as np

W, H, FPS = 640, 360, 30
STEPS = 8
STILL_SEC = 1.0     # Ruhephase pro Schritt
MOVE_SEC = 0.6      # "Hand" bewegt Objekt

writer = cv2.VideoWriter("test_input.mp4", cv2.VideoWriter_fourcc(*"mp4v"), FPS, (W, H))
rng = np.random.default_rng(42)


def scene(obj_x, hand_pos=None):
    frame = np.full((H, W, 3), (203, 219, 231), np.uint8)  # heller Tisch
    cv2.rectangle(frame, (0, 300), (W, H), (140, 160, 175), -1)  # Tischkante
    # Papierquadrat
    cv2.rectangle(frame, (obj_x, 150), (obj_x + 80, 230), (245, 248, 250), -1)
    cv2.rectangle(frame, (obj_x, 150), (obj_x + 80, 230), (90, 90, 95), 2)
    cv2.line(frame, (obj_x, 150), (obj_x + 80, 230), (120, 120, 125), 1)  # Faltlinie
    # "Hand" (hautfarbener Kreis + Arm)
    if hand_pos is not None:
        hx, hy = hand_pos
        cv2.rectangle(frame, (hx - 18, hy), (hx + 18, H), (120, 160, 205), -1)
        cv2.circle(frame, (hx, hy), 34, (130, 170, 215), -1)
    # Sensorrauschen, damit motion nie exakt 0 ist
    noise = rng.integers(-2, 3, frame.shape, dtype=np.int16)
    return np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)


positions = np.linspace(40, W - 140, STEPS).astype(int)
for i, x in enumerate(positions):
    # Ruhephase: Objekt liegt, keine Hand
    for _ in range(int(STILL_SEC * FPS)):
        writer.write(scene(x))
    # Bewegungsphase: Hand fährt rein, schiebt Objekt zur nächsten Position
    if i < STEPS - 1:
        nxt = positions[i + 1]
        n = int(MOVE_SEC * FPS)
        for f in range(n):
            t = f / n
            # Hand kommt von unten, Objekt interpoliert
            ox = int(x + (nxt - x) * t)
            hy = int(300 - 180 * np.sin(np.pi * t))
            writer.write(scene(ox, hand_pos=(ox + 40, hy)))

writer.release()
print(f"test_input.mp4: {STEPS} Ruhephasen à {STILL_SEC}s, {STEPS-1} Bewegungsphasen à {MOVE_SEC}s")
print(f"Erwartete Keyframes: ~{STEPS}")
