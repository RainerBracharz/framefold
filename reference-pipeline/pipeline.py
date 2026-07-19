#!/usr/bin/env python3
"""
FrameFold – Python-Referenzimplementierung der Stopmotion-Pipeline.

Identische Logik wie die Swift-App (FrameAnalyzer + KeyframeSelector):
  1. Sampling bei ~6 fps, downscale auf 160 px, Graustufen
  2. motion[i] = mittlere absolute Differenz zum Vorgänger
  3. Adaptive Schwelle = Perzentil der Motion-Verteilung
  4. Ruhefenster >= 0.5 s -> schärfster Frame (Laplacian-Varianz)
  5. dHash-Dedup benachbarter Keyframes
  6. Assembly mit 10 fps

Dient zum schnellen Parameter-Tuning an echten Atelier-Videos,
bevor Werte in PipelineSettings (Swift) übernommen werden.

Nutzung:
  python3 pipeline.py input.mp4 output.mp4 [--fps 6] [--percentile 0.35]
"""
import argparse
import sys

import cv2
import numpy as np


def dhash(gray, hash_size=8):
    small = cv2.resize(gray, (hash_size + 1, hash_size), interpolation=cv2.INTER_AREA)
    diff = small[:, 1:] > small[:, :-1]
    return sum(1 << i for i, v in enumerate(diff.flatten()) if v)


def hamming(a, b):
    return bin(a ^ b).count("1")


def otsu_threshold(values, bins=128):
    """1D-Otsu: findet die Schwelle, die die bimodale Motion-Verteilung
    (Ruhe vs. Bewegung) optimal in zwei Klassen trennt."""
    lo, hi = float(values.min()), float(values.max())
    if hi <= lo:
        return hi
    hist, edges = np.histogram(values, bins=bins, range=(lo, hi))
    total = hist.sum()
    best_var = -1.0
    first_best = last_best = 0
    w0 = 0.0
    sum0 = 0.0
    centers = (edges[:-1] + edges[1:]) / 2
    total_mean = float((hist * centers).sum()) / total
    for i in range(bins - 1):
        w0 += hist[i]
        if w0 == 0:
            continue
        w1 = total - w0
        if w1 == 0:
            break
        sum0 += hist[i] * centers[i]
        m0 = sum0 / w0
        m1 = (total_mean * total - sum0) / w1
        between = w0 * w1 * (m0 - m1) ** 2
        if between > best_var:
            best_var = between
            first_best = last_best = i
        elif between == best_var:
            last_best = i
    # Mitte des Maximum-Plateaus: Schwelle liegt in der Cluster-Lücke
    return centers[(first_best + last_best) // 2]


def run(input_path, output_path, sampling_fps=6.0, analysis_width=160,
        motion_percentile=0.35, min_still_seconds=0.5, dedup_threshold=3,
        output_fps=10, verbose=True):
    cap = cv2.VideoCapture(input_path)
    if not cap.isOpened():
        sys.exit(f"Kann Video nicht öffnen: {input_path}")

    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    step = max(1, round(src_fps / sampling_fps))

    # [1] + [2] Sampling & Motion-Scores
    samples = []  # (frame_index, motion, gray_small)
    prev = None
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if idx % step == 0:
            h = int(frame.shape[0] * analysis_width / frame.shape[1])
            gray = cv2.cvtColor(cv2.resize(frame, (analysis_width, h)), cv2.COLOR_BGR2GRAY)
            motion = 0.0
            if prev is not None:
                motion = float(np.mean(np.abs(gray.astype(int) - prev.astype(int))))
            samples.append((idx, motion, gray))
            prev = gray
        idx += 1

    if len(samples) < 3:
        sys.exit("Video zu kurz.")

    # [3] Adaptive Schwelle + Ruhefenster
    # Otsu-Split auf der Motion-Verteilung: trennt den "Ruhe-Cluster"
    # (Sensorrauschen) vom "Bewegungs-Cluster" (Hände/Objekt), unabhängig
    # von Licht und Kamera. --percentile dient als Untergrenze-Fallback.
    motions_arr = np.array([m for _, m, _ in samples[1:]])
    threshold = otsu_threshold(motions_arr)
    floor = np.quantile(motions_arr, motion_percentile)
    threshold = max(threshold, floor)
    min_frames = max(1, int(min_still_seconds * sampling_fps))

    windows, current = [], []
    for s in samples[1:]:
        if s[1] <= threshold:
            current.append(s)
        else:
            if len(current) >= min_frames:
                windows.append(current)
            current = []
    if len(current) >= min_frames:
        windows.append(current)

    if verbose:
        print(f"Quelle: {total} Frames @ {src_fps:.1f} fps | {len(samples)} Samples | "
              f"Motion-Schwelle {threshold:.2f} | {len(windows)} Ruhefenster")

    # [4] Bester Frame pro Fenster (Schärfe) + Dedup
    keyframes = []
    last_hash = None
    dupes = 0
    for window in windows:
        best = max(window, key=lambda s: cv2.Laplacian(s[2], cv2.CV_64F).var())
        h = dhash(best[2])
        if last_hash is not None and hamming(h, last_hash) < dedup_threshold:
            dupes += 1
            continue
        keyframes.append(best[0])
        last_hash = h

    if not keyframes:
        sys.exit("Keine Keyframes gefunden – --percentile erhöhen.")
    if verbose:
        print(f"{len(keyframes)} Keyframes gewählt, {dupes} Duplikate verworfen")

    # [5] Assembly in voller Auflösung
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    wanted = set(keyframes)
    frames_full = {}
    idx = 0
    while wanted:
        ok, frame = cap.read()
        if not ok:
            break
        if idx in wanted:
            frames_full[idx] = frame
            wanted.discard(idx)
        idx += 1
    cap.release()

    first = frames_full[keyframes[0]]
    h, w = first.shape[:2]
    writer = cv2.VideoWriter(output_path, cv2.VideoWriter_fourcc(*"mp4v"), output_fps, (w, h))
    for k in keyframes:
        writer.write(frames_full[k])
    writer.release()
    if verbose:
        print(f"Stopmotion geschrieben: {output_path} "
              f"({len(keyframes)} Frames @ {output_fps} fps = {len(keyframes)/output_fps:.1f} s)")
    return keyframes


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--fps", type=float, default=6.0, help="Sampling-fps")
    p.add_argument("--percentile", type=float, default=0.35)
    p.add_argument("--min-still", type=float, default=0.5)
    p.add_argument("--out-fps", type=int, default=10)
    a = p.parse_args()
    run(a.input, a.output, sampling_fps=a.fps, motion_percentile=a.percentile,
        min_still_seconds=a.min_still, output_fps=a.out_fps)
