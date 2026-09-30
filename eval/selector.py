"""
Bildauswahl – Python-Nachbau der Swift-App, Schritt für Schritt:

  ProcessingViewModel → FrameAnalyzer → KeyframeSelector → Algorithms

Die Standardwerte sind die aus PipelineSettings (Models.swift), NICHT die der
älteren reference-pipeline/pipeline.py (6 fps / 0,35 / 0,5 s). Weicht hier
etwas von der App ab, misst das Eval eine andere App als die im Store.

Nicht nachgebaut: die Handerkennung (Apple Vision, nur auf dem Gerät).
"""
from dataclasses import dataclass, asdict

import cv2
import numpy as np


@dataclass
class Settings:
    sampling_fps: float = 10.0        # PipelineSettings.samplingFPS
    analysis_width: int = 160         # PipelineSettings.analysisWidth
    motion_percentile: float = 0.6    # PipelineSettings.motionPercentile
    min_still_seconds: float = 0.15   # PipelineSettings.minStillWindowSeconds
    dedup_threshold: int = 3          # PipelineSettings.dedupHashThreshold

    def as_dict(self):
        return asdict(self)


def otsu(values, bins=128):
    """Algorithms.otsuThreshold, Zeile für Zeile."""
    lo, hi = float(min(values)), float(max(values))
    if hi <= lo:
        return values[0]
    hist = [0] * bins
    scale = bins / (hi - lo)
    for v in values:
        hist[min(bins - 1, int((v - lo) * scale))] += 1
    centers = [lo + (i + 0.5) * (hi - lo) / bins for i in range(bins)]
    total = float(len(values))
    total_mean = sum(h * c for h, c in zip(hist, centers)) / total
    best, first, last = -1.0, 0, 0
    w0 = s0 = 0.0
    for i in range(bins - 1):
        w0 += hist[i]
        if w0 <= 0:
            continue
        w1 = total - w0
        if w1 <= 0:
            break
        s0 += hist[i] * centers[i]
        m0 = s0 / w0
        m1 = (total_mean * total - s0) / w1
        between = w0 * w1 * (m0 - m1) ** 2
        if between > best:
            best, first, last = between, i, i
        elif between == best:
            last = i
    return centers[(first + last) // 2]


def motion_threshold(scores, percentile):
    """Algorithms.motionThreshold: max(Otsu, Perzentil-Untergrenze)."""
    s = sorted(scores)
    idx = min(len(s) - 1, max(0, int(len(s) * percentile)))
    return max(otsu(scores), s[idx])


def laplacian_variance(gray):
    g = gray.astype(np.float64)
    lap = (-4 * g[1:-1, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:] + g[:-2, 1:-1] + g[2:, 1:-1])
    return float(lap.var())


def dhash(gray):
    small = cv2.resize(gray, (9, 8), interpolation=cv2.INTER_AREA)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    return sum(1 << i for i, b in enumerate(bits) if b)


def sample(video_path, st: Settings):
    """Frames bei sampling_fps, Graustufen in Analysebreite, Bewegungswert
    = mittlere absolute Differenz zum Vorgänger (FrameAnalyzer)."""
    cap = cv2.VideoCapture(str(video_path))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frames = []
    t_next = 0.0
    idx = 0
    prev = None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t = idx / fps
        if t + 1e-9 >= t_next:
            h = int(frame.shape[0] * st.analysis_width / frame.shape[1])
            gray = cv2.cvtColor(cv2.resize(frame, (st.analysis_width, h), interpolation=cv2.INTER_AREA),
                                cv2.COLOR_BGR2GRAY)
            motion = 0.0 if prev is None else float(np.mean(np.abs(gray.astype(np.int16) - prev)))
            frames.append({"t": t, "motion": motion, "gray": gray})
            prev = gray.astype(np.int16)
            t_next += 1.0 / st.sampling_fps
        idx += 1
    cap.release()
    return frames


def select(video_path, st: Settings = Settings(), has_hand=None):
    """Liefert die gewählten Zeitpunkte plus Diagnose.

    has_hand(t) -> bool ersetzt Apples Handerkennung (ProcessingViewModel):
    fällt der schärfste Kandidat eines Fensters durch, kommt der nächstbeste
    dran; zeigen alle eine Hand, entfällt das Fenster. Ohne has_hand läuft
    die Auswahl wie mit ausgeschalteter Handerkennung."""
    frames = sample(video_path, st)
    if len(frames) < 3:
        return {"times": [], "threshold": 0, "windows": 0, "dupes": 0, "hand_rejects": 0, "motion": []}
    analyzed = frames[1:]
    scores = [f["motion"] for f in analyzed]
    thr = motion_threshold(scores, st.motion_percentile)
    min_frames = max(1, int(st.min_still_seconds * st.sampling_fps))

    windows, cur = [], []
    for f in analyzed:
        if f["motion"] <= thr:
            cur.append(f)
        else:
            if len(cur) >= min_frames:
                windows.append(cur)
            cur = []
    if len(cur) >= min_frames:
        windows.append(cur)

    chosen, hand_rejects = [], 0
    for w in windows:
        ranked = sorted(w, key=lambda f: laplacian_variance(f["gray"]), reverse=True)
        if has_hand is None:
            chosen.append(ranked[0])
            continue
        for f in ranked:
            if has_hand(f["t"]):
                hand_rejects += 1
                continue
            chosen.append(f)
            break

    times, last, dupes = [], None, 0
    for f in chosen:
        h = dhash(f["gray"])
        if last is not None and bin(h ^ last).count("1") < st.dedup_threshold:
            dupes += 1
            continue
        times.append(f["t"])
        last = h
    return {"times": times, "threshold": thr, "windows": len(windows), "dupes": dupes,
            "hand_rejects": hand_rejects,
            "motion": [(round(f["t"], 3), round(f["motion"], 3)) for f in analyzed]}
