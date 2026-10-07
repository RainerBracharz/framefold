#!/usr/bin/env python3
"""
Nachbau des Auto-Auslösers aus FrameFold/LiveCaptureController.swift –
Zeile für Zeile der Zustandsautomat aus `analyze`, das Schärfe-Tor, der
Fokus-Wächter und der Fokuslauf (`waitUntilFocusIsGood`), dazu ein kleines
Kameramodell, das auf Fixieren und Freigeben reagiert.

Nicht nachgebaut: Intervallmodus, manueller Auslöser, Statusanzeige,
Belichtung (gilt als fixiert), Erkennung Stativ/Hand über den Sensor (die
Aufnahmeart gibt das Szenario vor).

Die Uhr ist simuliert: `now` ersetzt `Date()`, Tasks sind Generatoren, die
ihre Schlafzeit abgeben.
"""
import math
from dataclasses import dataclass

import cv2
import numpy as np

BLUR_PX_PER_UNIT = 3.2      # Unschärfe im 640er-Bild je Einheit Fehlfokus


@dataclass
class Tunables:
    """Stellschrauben. Standard = Verhalten der App (Stand 2.0.2)."""
    stable_seconds: float = 0.8
    handheld_extra: float = 0.4
    min_meaningful: float = 15.0
    lock_ratio: float = 0.88
    capture_ratio: float = 0.72
    watchdog_ratio: float = 0.55
    reference_decay: float = 0.998
    gate_timeout: float = 8.0
    watchdog_seconds: float = 4.0
    motif_change: int = 1        # 1 = Motivwechsel-Abkürzung aus 2.0.1, 0 = wie 2.0
    gain_comp: int = 0           # Bewegung ohne globalen Helligkeitsanteil messen
    dedup_factor: float = 0.0    # > 0: kein Bild, wenn es dem letzten gleicht (× Schwelle)
    dedup_grid: int = 8
    acutance: int = 0            # 1 = Motivwechsel nur, wenn die Kanten scharf geblieben sind
    acutance_ratio: float = 0.8
    motif_updates_lock: int = 0  # 1 = Motivwechsel setzt auch die Messlatte des Wächters neu
    block_motion: int = 0        # 1 = am Stativ: Bewegung im stärksten von 8 × 8 Feldern statt im Bildmittel
    threshold_cap: float = 8.0    # Obergrenze der eingemessenen Schwelle
    calib_factor: float = 3.0    # Schwelle = Faktor × Grundrauschen
    rearm_factor: float = 0.0    # > 0: neu scharf schalten, wenn das ruhige Bild vom letzten abweicht
    adaptive_threshold: int = 0  # 1 = Bewegungsschwelle sinkt mit dem ruhigsten Zehntel der letzten 10 s


def swift_round(x):
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def laplacian_variance(gray):
    g = gray.astype(np.float64)
    lap = -4 * g[1:-1, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:] + g[:-2, 1:-1] + g[2:, 1:-1]
    return float(max(0.0, lap.var()))


def edge_acutance(gray, top=0.005):
    """Kantenschärfe unabhängig von Kontrast und Strukturmenge: An den
    stärksten Kanten das Verhältnis von Krümmung (Laplace) zu Steigung
    (Gradient). Eine scharfe Kante ist steil UND schmal; Unschärfe macht sie
    breiter, das Verhältnis sinkt. Ein glatteres Motiv hat weniger und
    schwächere Kanten, aber gleich schmale – das Verhältnis bleibt."""
    g = gray.astype(np.float32)
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3) / 8
    gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3) / 8
    grad = np.hypot(gx, gy).ravel()
    lap = cv2.dilate(np.abs(cv2.Laplacian(g, cv2.CV_32F, ksize=1)), np.ones((3, 3), np.uint8)).ravel()
    n = max(8, int(grad.size * top))
    idx = np.argpartition(grad, -n)[-n:]
    return float(np.median(lap[idx] / np.maximum(grad[idx], 1e-3)))


def max_block_diff(a, b, grid):
    diff = a.astype(np.float32) - b.astype(np.float32)
    diff -= float(np.median(diff))
    d = np.abs(diff)
    h, w = d.shape
    return max(float(d[gy * h // grid:(gy + 1) * h // grid, gx * w // grid:(gx + 1) * w // grid].mean())
               for gy in range(grid) for gx in range(grid))


class Camera:
    """Linse mit Autofokus. Dauerbetrieb: folgt dem Ziel nach kurzer
    Reaktionszeit; meldet währenddessen `adjusting`. Fixiert: bleibt stehen."""
    REACTION = 0.35
    SPEED = 2.0      # Einheiten pro Sekunde

    def __init__(self, sess, can_lock=True):
        self.s = sess
        self.lens = sess.subject_d(0) + 0.5      # Start: noch nicht scharf
        self.locked = False
        self.can_lock = can_lock
        self.adjusting = False
        self._off_since = None
        self._kicks = list(sess.kicks)

    def target(self, t):
        if self.s.p.af_hand and self.s.hand_visible(t):
            return self.s.subject_d(t) + 1.0
        return self.s.subject_d(t)

    def step(self, t, dt):
        while self._kicks and self._kicks[0] <= t:
            self._kicks.pop(0)
            if not self.locked:
                self.lens += self.s.p.af_pump
        if self.locked:
            self.adjusting = False
            return
        err = self.target(t) - self.lens
        if abs(err) < 0.03:
            self.adjusting = False
            self._off_since = None
            return
        if self._off_since is None:
            self._off_since = t
        if t - self._off_since < self.REACTION:
            self.adjusting = False       # hat noch gar nicht begonnen zu suchen
            return
        self.adjusting = True
        self.lens += math.copysign(min(abs(err), self.SPEED * dt), err)

    def blur_px(self, t):
        return BLUR_PX_PER_UNIT * abs(self.lens - self.s.subject_d(t))


class LiveController:
    def __init__(self, cam: Camera, rig: str, tun: Tunables, has_hand):
        self.cam, self.rig, self.k, self.has_hand = cam, rig, tun, has_hand
        self.now = 0.0
        self.motion_threshold = 2.0
        self.current_motion = 0.0
        self.sharp_raw = self.sharp_reference = self.sharp_at_lock = 0.0
        self.acut_raw = self.acut_reference = 0.0
        self.gate_blocked_since = None
        self.blurry_since = None
        self.last_auto_refocus = -math.inf
        self.auto_refocus_count = 0
        self.focus_is_locked = False
        self.focus_lock_unavailable = False
        self.previous = None
        self.stable_since = None
        self.armed = False
        self.calibration = []
        self.calibration_start = 0.0
        self.focus_task = None      # (Generator, Weckzeit)
        self.calibrated_threshold = None
        self.recent_motion = []
        self.captures = []          # (t, Analysebild)
        self.last_captured = None
        self.log = []
        cam.locked = False

    # -- Eigenschaften wie in Swift ----------------------------------------
    @property
    def locks_focus(self):
        return self.rig == "tripod"

    @property
    def effective_stable(self):
        return self.k.stable_seconds + (0 if self.rig == "tripod" else self.k.handheld_extra)

    @property
    def meaningful(self):
        return self.sharp_reference >= self.k.min_meaningful

    @property
    def is_sharp_enough(self):
        if not self.meaningful:
            return True
        return self.sharp_raw >= self.sharp_reference * self.k.capture_ratio

    # -- Fokus --------------------------------------------------------------
    def _lock_focus_only(self):
        if not self.locks_focus:
            return
        if not self.cam.can_lock:
            self.focus_lock_unavailable = True
            return
        self.cam.locked = True
        self.focus_is_locked = True
        self.sharp_at_lock = self.sharp_raw
        self.blurry_since = None
        self.log.append((self.now, "fixiert"))

    def _release_focus_only(self):
        self.focus_is_locked = False
        self.blurry_since = None
        self.cam.locked = False

    def _relock_focus_only(self):
        self._release_focus_only()
        self.focus_task = (self._focus_run(), self.now)
        self.log.append((self.now, "fokuslauf"))

    def _focus_run(self):
        yield 0.8
        deadline = self.now + 8.0
        good = False
        while self.now < deadline:
            searching = self.cam.adjusting
            busy = self.current_motion > max(self.motion_threshold, 2.0)
            if not searching and not busy:
                if not self.meaningful:
                    good = True
                    break
                if self.sharp_raw >= self.sharp_reference * self.k.lock_ratio:
                    yield 0.3
                    if self.cam.adjusting:
                        continue
                    if self.sharp_raw >= self.sharp_reference * self.k.lock_ratio:
                        good = True
                        break
            yield 0.12
        if good:
            self._lock_focus_only()
        elif self.locks_focus:
            self.focus_is_locked = False
            self.log.append((self.now, "fokus findet nichts"))

    def run_tasks(self):
        while self.focus_task and self.focus_task[1] <= self.now + 1e-9:
            gen, _ = self.focus_task
            try:
                delay = next(gen)
            except StopIteration:
                if self.focus_task and self.focus_task[0] is gen:
                    self.focus_task = None
                return
            if self.focus_task and self.focus_task[0] is gen:
                self.focus_task = (gen, self.now + delay)

    def _auto_refocus(self):
        if not self.locks_focus or self.focus_task is not None or self.focus_lock_unavailable:
            return
        interval = 10 if self.auto_refocus_count < 4 else 20
        if not self.now - self.last_auto_refocus > interval:
            return
        self.last_auto_refocus = self.now
        self.auto_refocus_count += 1
        self.blurry_since = None
        self._relock_focus_only()

    def _check_focus_watchdog(self, motion):
        if motion > self.motion_threshold:
            self.blurry_since = None
            return
        if (self.locks_focus and not self.focus_is_locked and not self.focus_lock_unavailable
                and self.calibration is None and self.focus_task is None):
            self.blurry_since = None
            self._auto_refocus()
            return
        if not (self.focus_is_locked and self.sharp_at_lock >= self.k.min_meaningful):
            self.blurry_since = None
            return
        if not self.sharp_raw < self.sharp_at_lock * self.k.watchdog_ratio:
            self.blurry_since = None
            return
        if self.blurry_since is None:
            self.blurry_since = self.now
        elif self.now - self.blurry_since > self.k.watchdog_seconds:
            self._auto_refocus()

    # -- Schärfe ------------------------------------------------------------
    def _note_sharpness(self, value, acut, calm):
        self.sharp_raw = value
        self.acut_raw = acut
        if not calm or self.is_sharp_enough:
            self.gate_blocked_since = None
        if not calm:
            return
        self.sharp_reference = max(self.sharp_reference * self.k.reference_decay, value)
        self.acut_reference = max(self.acut_reference * self.k.reference_decay, acut)

    def _accept_motif_change(self):
        if not self.k.motif_change:
            return False
        if not (self.focus_is_locked or self.focus_lock_unavailable):
            return False
        if self.focus_task is not None:
            return False
        if self.k.acutance and self.acut_raw < self.acut_reference * self.k.acutance_ratio:
            return False        # Kanten sind flach geworden: das ist Unschärfe
        self.sharp_reference = self.sharp_raw
        self.gate_blocked_since = None
        if self.k.motif_updates_lock:
            self.sharp_at_lock = self.sharp_raw
            self.blurry_since = None
        if self.k.acutance:
            self.acut_reference = max(self.acut_raw, 1e-6)
        self.log.append((self.now, "motivwechsel"))
        return True

    def _release_gate_if_stuck(self):
        if self.gate_blocked_since is None:
            self.gate_blocked_since = self.now
        if not self.now - self.gate_blocked_since > self.k.gate_timeout:
            return False
        self.sharp_reference = self.sharp_raw
        self.gate_blocked_since = None
        self.log.append((self.now, "tor-notausstieg"))
        return True

    # -- ein Analysebild ----------------------------------------------------
    def analyze(self, gray):
        motion = 0.0
        had_previous = self.previous is not None
        if had_previous:
            diff = gray.astype(np.float32) - self.previous.astype(np.float32)
            if self.k.gain_comp:
                diff -= float(np.median(diff))
            if self.k.block_motion and self.rig == "tripod":
                d = np.abs(diff)
                h, w = d.shape
                g = self.k.dedup_grid
                motion = max(float(d[gy * h // g:(gy + 1) * h // g, gx * w // g:(gx + 1) * w // g].mean())
                             for gy in range(g) for gx in range(g))
            else:
                motion = float(np.abs(diff).mean())
        self.previous = gray
        rounded = swift_round(motion * 10) / 10
        if abs(rounded - self.current_motion) > 0.05:
            self.current_motion = rounded

        calm = had_previous and motion <= self.motion_threshold
        self._note_sharpness(laplacian_variance(gray),
                             edge_acutance(gray) if self.k.acutance else 0.0, calm)
        self._check_focus_watchdog(motion)

        if self.calibration is not None:
            if had_previous:
                self.calibration.append(motion)
            if len(self.calibration) >= 20 or self.now - self.calibration_start > 4.0:
                samples = sorted(self.calibration)
                median = samples[len(samples) // 2] if samples else 1.0
                self.motion_threshold = min(self.k.threshold_cap, max(1.0, swift_round(median * self.k.calib_factor * 2) / 2))
                self.calibrated_threshold = self.motion_threshold
                self.calibration = None
                self.armed = True
                self._relock_focus_only()
            return

        if self.k.adaptive_threshold:
            # War schon beim Einmessen Bewegung im Bild, steht die Schwelle zu
            # hoch. Das ruhigste Zehntel der letzten zehn Sekunden ist das
            # Grundrauschen – die Schwelle darf darauf absinken, nie steigen.
            self.recent_motion = (self.recent_motion + [motion])[-100:]
            if len(self.recent_motion) >= 30:
                floor = sorted(self.recent_motion)[len(self.recent_motion) // 10]
                self.motion_threshold = min(self.calibrated_threshold,
                                            max(1.0, swift_round(floor * self.k.calib_factor * 2) / 2))

        if motion > self.motion_threshold:
            self.armed = True
            self.stable_since = None
            return
        if not self.armed and self.k.rearm_factor > 0 and self.last_captured is not None \
                and max_block_diff(gray, self.last_captured, self.k.dedup_grid) \
                >= self.k.rearm_factor * self.motion_threshold:
            self.armed = True       # Bild hat sich seit dem Klick verändert, ohne dass es „Bewegung" gab
        if not self.armed:
            return
        if self.stable_since is None:
            self.stable_since = self.now
        if self.now - self.stable_since < self.effective_stable - 1e-9:
            return
        if self.has_hand is not None and self.has_hand(self.now):
            self.stable_since = self.now
            return
        if (not self.is_sharp_enough and not self._accept_motif_change()
                and not self._release_gate_if_stuck()):
            self.stable_since = self.now
            if self.locks_focus:
                self._auto_refocus()
            return
        self.gate_blocked_since = None

        # Zusatz (nicht in der App): Gleicht das Bild dem zuletzt abgelegten,
        # war die Bewegung kein Arbeitsschritt.
        if self.k.dedup_factor > 0 and self.last_captured is not None:
            if max_block_diff(gray, self.last_captured, self.k.dedup_grid) \
                    < self.k.dedup_factor * self.motion_threshold:
                self.armed = False
                self.stable_since = None
                self.log.append((self.now, "duplikat verworfen"))
                return

        self.armed = False
        self.stable_since = None
        self.captures.append((self.now, gray))
        self.last_captured = gray
        self.log.append((self.now, "klick"))


def simulate(sess, tun: Tunables = Tunables(), hands="ideal", can_lock=True):
    """Spielt eine Sitzung durch. Liefert Aufnahmen mit Unschärfe zum
    Aufnahmezeitpunkt, das Protokoll und die eingemessene Schwelle."""
    from live_scenarios import TICK
    rng = np.random.default_rng(sess.seed * 104729 + 17)
    cam = Camera(sess, can_lock=can_lock)
    has_hand = {"ideal": sess.hand_visible, "teil": sess.palm_visible, "aus": None}[hands]
    ctl = LiveController(cam, sess.p.rig, tun, has_hand)
    dt, steps_per_tick = 0.01, int(round(TICK / 0.01))
    n = int(sess.duration / dt)
    shots, trace = [], []
    for step in range(n):
        t = step * dt
        ctl.now = t
        cam.step(t, dt)
        if step % steps_per_tick == 0:
            i = step // steps_per_tick
            img = sess.clean(i)
            blur = cam.blur_px(t)
            if blur > 0.05:
                img = cv2.GaussianBlur(img, (0, 0), blur)
            jx, jy = sess.shifts[min(i, len(sess.shifts) - 1)]
            if jx or jy:
                img = cv2.warpAffine(img, np.float32([[1, 0, jx], [0, 1, jy]]), (img.shape[1], img.shape[0]),
                                     borderMode=cv2.BORDER_REFLECT)
            small = cv2.resize(img, (160, 90), interpolation=cv2.INTER_AREA) * sess.gains[min(i, len(sess.gains) - 1)]
            small += rng.normal(0, sess.p.noise, small.shape).astype(np.float32)
            gray = np.clip(small, 0, 255).astype(np.uint8)
            before = len(ctl.captures)
            ctl.analyze(gray)
            trace.append((t, ctl.current_motion, ctl.sharp_raw, ctl.sharp_reference, blur))
            if len(ctl.captures) > before:
                shots.append({"t": t, "blur_px": blur, "gray": gray})
        ctl.run_tasks()
    return {"shots": shots, "log": ctl.log, "threshold": ctl.motion_threshold, "trace": trace}
