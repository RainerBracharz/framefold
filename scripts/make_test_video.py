#!/usr/bin/env python3
"""Synthetisches Testvideo für den UI-Test des Video-Ablaufs.

Ein Papierquadrat wandert in acht Schritten über einen Holztisch; zwischen
den Ruhephasen fährt eine hautfarbene „Hand" ins Bild. Kein echtes Material.

  eval/.venv/bin/python scripts/make_test_video.py /private/tmp/ff-uitest/clip.mp4
"""
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

out = Path(sys.argv[1]); out.parent.mkdir(parents=True, exist_ok=True)
W, H, FPS = 720, 1280, 30
rng = np.random.default_rng(7)
table = np.full((H, W, 3), (70, 110, 150), np.uint8)          # BGR: Holzton
table = cv2.add(table, rng.integers(0, 18, (H, W, 3), dtype=np.uint8))
tmp = out.with_suffix(".raw.mp4")
wr = cv2.VideoWriter(str(tmp), cv2.VideoWriter_fourcc(*"mp4v"), FPS, (W, H))
for step in range(8):
    x, y = 120 + step * 50, 300 + step * 70
    still = table.copy()
    cv2.rectangle(still, (x, y), (x + 260, y + 260), (236, 242, 244), -1)
    cv2.line(still, (x, y), (x + 260, y + 260), (150, 150, 150), 2)
    for _ in range(int(1.6 * FPS)):
        wr.write(still)
    for i in range(int(0.7 * FPS)):                           # Hand fährt durch
        f = still.copy()
        cx = int(-150 + (W + 300) * i / (0.7 * FPS))
        cv2.ellipse(f, (cx, y + 130), (170, 110), 0, 0, 360, (120, 150, 215), -1)
        wr.write(f)
wr.release()
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(tmp), "-c:v", "libx264",
                "-pix_fmt", "yuv420p", str(out)], check=True)
tmp.unlink()
print(out)
