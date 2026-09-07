#!/usr/bin/env python3
"""hand_control.py — optional webcam hand-gesture control for the Infinite Desktop.

All processing is 100% local (nothing leaves the machine; the camera is opened
only while this process runs). Gestures, highest priority first:

  1. shutter closed     -> nothing (see the Shutter class)
  2. PINCH (thumb+index) -> grab the FOCUSED floating window and move ONLY it
                           with the hand; the camera and every other window stay
                           put. Release drops it there; pseudo-max restore is
                           invalidated exactly like a World Map drag. v1 always
                           takes the focused window — no pointing / hit-test yet.
  3. FIST               -> CLUTCH: end the pan now, hold still, recolocate the
                           hand freely; on re-open the current hand position is
                           the new pan baseline (no jump).
  4. FIST then THUMBS-UP -> toggle Viewport Mosaic (viewport_mosaic.py). A bare
                           thumbs-up does nothing; holding it never re-toggles.
  5. OPEN PALM + move   -> pan the Infinite Desktop (smoothed relative delta of
                           the palm base; the same camera mechanism the touchpad
                           and keyboard use — move every floating window, bump
                           world.py's camera the other way)
  6. OPEN PALM held still + tilt L/R -> previous / next window (world_navigate.py;
                           focus-only while a Viewport Mosaic is active). Only
                           evaluated while the palm is stationary, so a natural
                           wrist tilt during a pan never navigates.

Every threshold and every timing lives in the config (seconds, not frame
counts — the real frame rate is ~15 fps, not 24). SHUTTER-AWARE: see the
Shutter class; that part and the webcam lifecycle are NOT touched here.

Run via the `hand-control` CLI (start / stop / toggle / status / debug).
Config: ~/.config/hand-control/config.toml (created from config.toml.example on
first run / by setup-venv.sh). Deps: a venv, never system-wide.
"""

import json
import math
import os
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.realpath(__file__))
for _p in (os.path.expanduser("~/scripts"),
           os.path.join(_HERE, "..", "infinite-desktop"),
           os.path.join(_HERE, "..")):
    if os.path.isfile(os.path.join(_p, "hypr_ipc.py")):
        sys.path.insert(0, _p)
        break

try:
    from hypr_ipc import move_window_exact_lua, batch
    import world
except Exception as e:                       # pragma: no cover
    print("hand_control: cannot import Infinite Desktop helpers "
          "(hypr_ipc/world): %s" % e, file=sys.stderr)
    sys.exit(3)

_RUN_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hand-control")
_STATE = os.path.join(_RUN_DIR, "state")
_PIDF = os.path.join(_RUN_DIR, "hand.pid")
# pseudo-maximize restore store (lua/floating-world.lua). A manual edit — World
# Map drag, SUPER+mouse, and now a pinch move — removes the window's file so
# SUPER+F does not snap the hand-placed geometry back. Same policy as world_edit.py.
_PMAX_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hypr-fworld")
DEBUG = os.environ.get("HAND_CONTROL_DEBUG") == "1"


# =========================================================================
# config
# =========================================================================
_DEFAULTS = {
    "camera":   {"index": 0, "mirror": True, "width": 640, "height": 480, "fps": 24},
    "tracking": {"min_detection_confidence": 0.6, "min_tracking_confidence": 0.5,
                 "model_complexity": 0},
    "pan":      {"sensitivity": 1600.0, "smoothing": 0.35, "smoothing_fast": 0.35,
                 "speed_ref": 1.2, "deadzone": 0.005, "max_delta_per_frame": 55,
                 "confirm_seconds": 0.06, "grace_seconds": 0.22,
                 "max_tracking_speed": 4.0},
    "tilt":     {"angle_threshold": 0.45, "confirm_seconds": 0.18,
                 "cooldown_seconds": 0.6, "neutral_threshold": 0.20,
                 "max_translation_speed": 0.12, "stationary_seconds": 0.15,
                 "nav_block_seconds": 0.5},
    "pinch":    {"close_ratio": 0.35, "open_ratio": 0.55, "confirm_seconds": 0.12,
                 "grace_seconds": 0.20, "move_smoothing": 0.5, "deadzone": 0.004,
                 "sensitivity": 1400.0, "max_delta": 90.0},
    "mosaic_gesture": {"fist_arm_seconds": 0.18, "thumb_hold_seconds": 0.25,
                       "cooldown_seconds": 0.8, "reset_seconds": 0.15,
                       "thumb_direction_threshold": 0.035},
    "shutter":  {"enabled": True, "sample_width": 128,
                 "lofi_std_open": 18.0, "lofi_std_closed": 10.0,
                 "stddev_open": 12.0, "stddev_closed": 9.0,
                 "texture_open": 1.5, "temporal_open": 1.0,
                 "close_delay": 0.65, "open_delay": 0.30, "closed_fps": 4},
    "debug":    {"show_preview": False, "log_every": 60},
}


def _config_path():
    return os.path.join(os.environ.get("XDG_CONFIG_HOME",
                        os.path.expanduser("~/.config")),
                        "hand-control", "config.toml")


def _load_config():
    cfg = {k: dict(v) for k, v in _DEFAULTS.items()}
    path = _config_path()
    example = os.path.join(_HERE, "config.toml.example")
    if not os.path.exists(path) and os.path.isfile(example):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(example) as s, open(path, "w") as d:
                d.write(s.read())
            print("hand_control: created %s from config.toml.example" % path)
        except Exception as e:
            print("hand_control: could not create %s (%s)" % (path, e),
                  file=sys.stderr)
    try:
        import tomllib
        with open(path, "rb") as f:
            user = tomllib.load(f)
        for sec, vals in (user or {}).items():
            cfg.setdefault(sec, {}).update(vals or {})
        print("config: %s" % path)
    except FileNotFoundError:
        print("config: (none — using built-in defaults)")
    except Exception as e:
        print("hand_control: bad config (%s), using defaults" % e, file=sys.stderr)
        print("config: (defaults)")
    return cfg


def _print_thresholds(cfg):
    p, ti, mg, sh = cfg["pan"], cfg["tilt"], cfg["mosaic_gesture"], cfg["shutter"]
    pn = cfg["pinch"]
    print("thresholds:")
    print("  pan     sensitivity=%s smoothing=%s/%s speed_ref=%s deadzone=%s "
          "cap=%s confirm=%ss grace=%ss max_track=%s"
          % (p["sensitivity"], p["smoothing"], p.get("smoothing_fast"),
             p.get("speed_ref"), p["deadzone"], p["max_delta_per_frame"],
             p["confirm_seconds"], p["grace_seconds"], p.get("max_tracking_speed")))
    print("  pinch   close=%s open=%s confirm=%ss grace=%ss move_smoothing=%s "
          "deadzone=%s sensitivity=%s max_delta=%s"
          % (pn["close_ratio"], pn["open_ratio"], pn["confirm_seconds"],
             pn["grace_seconds"], pn["move_smoothing"], pn["deadzone"],
             pn["sensitivity"], pn["max_delta"]))
    print("  tilt    angle=%s confirm=%ss cooldown=%ss neutral=%s "
          "max_speed=%s stationary=%ss nav_block=%ss"
          % (ti["angle_threshold"], ti["confirm_seconds"],
             ti["cooldown_seconds"], ti["neutral_threshold"],
             ti.get("max_translation_speed"), ti.get("stationary_seconds"),
             ti.get("nav_block_seconds")))
    print("  mosaic  fist_arm=%ss thumb_hold=%ss cooldown=%ss reset=%ss thumb_dir=%s"
          % (mg["fist_arm_seconds"], mg["thumb_hold_seconds"],
             mg["cooldown_seconds"], mg["reset_seconds"],
             mg["thumb_direction_threshold"]))
    print("  shutter lofi_open=%s lofi_closed=%s std_open=%s std_closed=%s "
          "close=%ss open=%ss"
          % (sh["lofi_std_open"], sh["lofi_std_closed"], sh["stddev_open"],
             sh["stddev_closed"], sh["close_delay"], sh["open_delay"]))


# =========================================================================
# runtime state file  (running= / shutter= / tracking=)  — read by HandButton
# =========================================================================
_state_cache = ""


def _write_state(shutter="open", tracking=0):
    global _state_cache
    s = "running=1\nshutter=%s\ntracking=%d\n" % (shutter, 1 if tracking else 0)
    if s == _state_cache:
        return
    _state_cache = s
    try:
        os.makedirs(_RUN_DIR, exist_ok=True)
        tmp = _STATE + ".tmp"
        with open(tmp, "w") as f:
            f.write(s)
        os.replace(tmp, _STATE)
    except Exception:
        pass


def _clear_state():
    for p in (_STATE, _PIDF):
        try:
            os.remove(p)
        except OSError:
            pass


def _write_pidfile():
    try:
        os.makedirs(_RUN_DIR, exist_ok=True)
        with open(_PIDF, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass


def _rss_mb():
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return round(int(line.split()[1]) / 1024)
    except Exception:
        pass
    return "?"


# =========================================================================
# Infinite Desktop actions (reuse the existing mechanism / scripts)
# =========================================================================
def _hjson(args):
    r = subprocess.run(["hyprctl"] + args + ["-j"],
                       capture_output=True, text=True, timeout=1)
    return json.loads(r.stdout) if r.stdout.strip() else None


def _current_ws():
    w = _hjson(["activewindow"]) or {}
    ws = (w.get("workspace") or {}).get("id")
    if ws:
        return ws
    mons = _hjson(["monitors"]) or []
    m = next((x for x in mons if x.get("focused")), mons[0] if mons else {})
    return (m.get("activeWorkspace") or {}).get("id", 1)


def _script(name):
    for p in (os.path.expanduser("~/scripts/%s" % name),
              os.path.join(_HERE, "..", "infinite-desktop", name)):
        if os.path.isfile(p):
            return p
    return None


class Panner:
    """OPEN PALM pan: snapshot the floating windows once, then move them from
    that base by the accumulated smoothed delta and bump the camera each step —
    what infinite_desktop_core.pan_other_windows does per evdev event."""

    def __init__(self):
        self.active = False
        self.ws = None
        self.base = {}
        self.ax = 0.0
        self.ay = 0.0

    def begin(self):
        self.ws = _current_ws()
        self.base = {}
        for c in (_hjson(["clients"]) or []):
            if c.get("floating") and (c.get("workspace") or {}).get("id") == self.ws:
                self.base[c["address"]] = (c["at"][0], c["at"][1])
        self.ax = self.ay = 0.0
        self.active = bool(self.base)

    def step(self, dx, dy):
        if not self.active:
            return
        self.ax += dx
        self.ay += dy
        exprs = [move_window_exact_lua(round(bx + self.ax), round(by + self.ay), a)
                 for a, (bx, by) in self.base.items()]
        if exprs:
            batch(exprs, timeout=2)
            try:
                world.bump_camera(self.ws, -dx, -dy)
            except Exception:
                pass

    def end(self):
        self.active = False
        self.base = {}
        self.ax = self.ay = 0.0


def _nav_window(direction):
    s = _script("world_navigate.py")
    if s:
        subprocess.Popen(["python3", s,
                          "next-window" if direction > 0 else "prev-window"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _toggle_mosaic():
    s = _script("viewport_mosaic.py")
    if s:
        subprocess.Popen(["python3", s, "toggle"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class PinchGrab:
    """PINCH GRAB v1: move ONLY the focused floating window with the hand.

    Snapshot the focused window's SCREEN position (`hyprctl clients` reports
    global logical coords — Hyprland bakes in each monitor's layout offset, so a
    window follows the hand across monitors and mixed scales with no special
    handling) and the hand anchor at grab time. Each step moves that one window
    to `base + smoothed_hand_delta * sensitivity` in a single `hyprctl` batch.

    The camera is NEVER touched (world.bump_camera is not called) — a pinch move
    changes where a window sits in the world, it does not pan the desktop. World
    coordinates stay consistent because `worldX = screenX + cameraX` and the
    camera is frozen. On release the pseudo-max restore file is dropped, exactly
    like world_edit.py / a World Map drag."""

    _SKIP_TITLE = ("Picture-in-Picture", "Picture in Picture")

    def __init__(self, cfg):
        pn = cfg["pinch"]
        self.move_smooth = float(pn["move_smoothing"])
        self.dz = float(pn["deadzone"])
        self.sens = float(pn["sensitivity"])
        self.max_delta = float(pn["max_delta"])
        self.max_track = float(cfg["pan"].get("max_tracking_speed", 4.0))
        self.active = False
        self.addr = None
        self.ws = None
        self.d_outlier = 0
        self.dx = self.dy = 0
        self.world_x = self.world_y = 0

    def begin(self, anchor, now):
        """Grab the focused window. False (no grab) if there is no valid target."""
        w = _hjson(["activewindow"]) or {}
        addr = w.get("address")
        title = w.get("title") or ""
        if (not addr
                or not w.get("mapped", True)
                or not w.get("floating")
                or w.get("fullscreen")
                or (w.get("workspace") or {}).get("id", 0) <= 0
                or any(t in title for t in self._SKIP_TITLE)
                or "at" not in w or "size" not in w):
            return False
        self.addr = addr
        self.ws = w["workspace"]["id"]
        self.base_x, self.base_y = float(w["at"][0]), float(w["at"][1])
        self.tx, self.ty = self.base_x, self.base_y
        self.anchor = (anchor[0], anchor[1])
        self.ema = (anchor[0], anchor[1])
        self.raw_prev = (anchor[0], anchor[1])
        self.raw_prev_t = now
        self.outlier_run = 0
        self.dx = self.dy = 0
        try:
            cam = world.read_camera(self.ws)
            self.cam_x = float(cam.get("x", 0.0))
            self.cam_y = float(cam.get("y", 0.0))
        except Exception:
            self.cam_x = self.cam_y = 0.0
        self.world_x = round(self.base_x + self.cam_x)
        self.world_y = round(self.base_y + self.cam_y)
        self.active = True
        return True

    def step(self, palm, now):
        if not self.active:
            return
        self.d_outlier = 0
        # reject an isolated impossible landmark jump (same idea as the pan);
        # keep the last good point, don't slow real movement
        dt = max(1e-3, now - self.raw_prev_t)
        spd = math.hypot(palm[0] - self.raw_prev[0],
                         palm[1] - self.raw_prev[1]) / dt
        if spd > self.max_track and self.outlier_run < 3:
            self.outlier_run += 1
            self.d_outlier = 1
            palm = self.raw_prev
        else:
            self.outlier_run = 0
        self.raw_prev = palm
        self.raw_prev_t = now

        a = self.move_smooth
        self.ema = (a * palm[0] + (1 - a) * self.ema[0],
                    a * palm[1] + (1 - a) * self.ema[1])
        ndx = self.ema[0] - self.anchor[0]
        ndy = self.ema[1] - self.anchor[1]
        ndx = math.copysign(max(0.0, abs(ndx) - self.dz), ndx)
        ndy = math.copysign(max(0.0, abs(ndy) - self.dz), ndy)
        want_x = self.base_x + ndx * self.sens
        want_y = self.base_y + ndy * self.sens
        # per-frame cap: a glitch that survives outlier reject still can't teleport
        want_x = min(self.tx + self.max_delta, max(self.tx - self.max_delta, want_x))
        want_y = min(self.ty + self.max_delta, max(self.ty - self.max_delta, want_y))
        self.tx, self.ty = want_x, want_y
        self.dx = round(self.tx - self.base_x)
        self.dy = round(self.ty - self.base_y)
        self.world_x = round(self.tx + self.cam_x)
        self.world_y = round(self.ty + self.cam_y)
        batch([move_window_exact_lua(round(self.tx), round(self.ty), self.addr)],
              timeout=2)

    def end(self):
        if self.active and self.addr:
            try:                       # same pseudo-max invalidation as world_edit.py
                os.remove(os.path.join(_PMAX_DIR, self.addr))
            except OSError:
                pass
        self.active = False
        self.addr = None
        self.ws = None


# =========================================================================
# shutter detector — NOT changed in this pass
# =========================================================================
class Shutter:
    def __init__(self, cfg, cv2, np):
        self.cv2 = cv2
        self.np = np
        self.on = bool(cfg["enabled"])
        self.lo_o = float(cfg["lofi_std_open"])
        self.lo_c = float(cfg["lofi_std_closed"])
        self.sd_o = float(cfg["stddev_open"])
        self.sd_c = float(cfg["stddev_closed"])
        self.tx_o = float(cfg["texture_open"])
        self.tp_o = float(cfg["temporal_open"])
        self.close_delay = float(cfg["close_delay"])
        self.open_delay = float(cfg["open_delay"])
        self.state = "open"
        self._blank_since = None
        self._valid_since = None
        self._prev = None
        self.lofi_std = self.stddev = self.texture = self.tdiff = 0.0

    def update(self, small, now):
        np = self.np
        f = small.astype(np.float32)
        lofi = self.cv2.resize(small, (16, 12),
                               interpolation=self.cv2.INTER_AREA).astype(np.float32)
        self.lofi_std = float(lofi.std())
        self.stddev = float(f.std())
        self.texture = float(
            (np.abs(np.diff(f, axis=0)).mean() + np.abs(np.diff(f, axis=1)).mean()) / 2.0)
        self.tdiff = 0.0 if self._prev is None else float(np.abs(f - self._prev).mean())
        self._prev = f
        if not self.on:
            self.state = "open"
            return "open"

        is_blank = self.lofi_std < self.lo_c and self.stddev < self.sd_c
        is_valid = (self.lofi_std > self.lo_o
                    or (self.stddev > self.sd_o
                        and (self.texture > self.tx_o or self.tdiff > self.tp_o)))

        if is_blank:
            self._valid_since = None
            if self._blank_since is None:
                self._blank_since = now
            if self.state == "open" and now - self._blank_since >= self.close_delay:
                self.state = "closed"
        elif is_valid:
            self._blank_since = None
            if self._valid_since is None:
                self._valid_since = now
            if self.state == "closed" and now - self._valid_since >= self.open_delay:
                self.state = "open"
        else:
            self._blank_since = self._valid_since = None
        return self.state


# =========================================================================
# hand tracking (mediapipe Tasks API preferred, legacy solutions fallback)
# =========================================================================
class Tracker:
    def __init__(self, cfg):
        tk = cfg["tracking"]
        try:
            import mediapipe as mp
        except Exception as e:
            raise RuntimeError("mediapipe not importable in this venv: %s" % e)
        self._mp = mp
        self._impl = None
        self.kind = None

        model = os.path.join(os.environ.get("XDG_DATA_HOME",
                             os.path.expanduser("~/.local/share")),
                             "hand-control", "hand_landmarker.task")
        try:
            from mediapipe.tasks import python as mp_python
            from mediapipe.tasks.python import vision
            if os.path.isfile(model):
                opts = vision.HandLandmarkerOptions(
                    base_options=mp_python.BaseOptions(model_asset_path=model),
                    num_hands=1,
                    min_hand_detection_confidence=tk["min_detection_confidence"],
                    min_tracking_confidence=tk["min_tracking_confidence"],
                    running_mode=vision.RunningMode.VIDEO)
                self._impl = vision.HandLandmarker.create_from_options(opts)
                self.kind = "tasks"
                return
        except Exception as e:                          # pragma: no cover
            print("hand_control: Tasks API unavailable (%s)" % e, file=sys.stderr)

        try:
            self._impl = mp.solutions.hands.Hands(
                static_image_mode=False, max_num_hands=1,
                model_complexity=int(tk["model_complexity"]),
                min_detection_confidence=tk["min_detection_confidence"],
                min_tracking_confidence=tk["min_tracking_confidence"])
            self.kind = "solutions"
        except Exception as e:
            raise RuntimeError(
                "no usable mediapipe hand API. For the Tasks API fetch the model:\n"
                "  curl -fL --create-dirs -o ~/.local/share/hand-control/"
                "hand_landmarker.task \\\n"
                "    https://storage.googleapis.com/mediapipe-models/hand_landmarker/"
                "hand_landmarker/float16/latest/hand_landmarker.task\n(%s)" % e)

    def process(self, frame_rgb, ts_ms):
        """-> list of 21 (x, y, z) in normalised image coords (z is relative
        depth, smaller = closer to the camera), or None."""
        if self.kind == "tasks":
            img = self._mp.Image(image_format=self._mp.ImageFormat.SRGB, data=frame_rgb)
            res = self._impl.detect_for_video(img, int(ts_ms))
            if not res.hand_landmarks:
                return None
            return [(p.x, p.y, p.z) for p in res.hand_landmarks[0]]
        res = self._impl.process(frame_rgb)
        if not res.multi_hand_landmarks:
            return None
        return [(p.x, p.y, p.z) for p in res.multi_hand_landmarks[0].landmark]

    def close(self):
        try:
            self._impl.close()
        except Exception:
            pass


# ---- landmark geometry -------------------------------------------------
_PALM_BASE = (0, 5, 17)     # wrist, index-MCP, pinky-MCP — the stable palm base


def _dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _finger_states(lm):
    """(thumb, index, middle, ring, pinky) extended booleans — DEBUG ONLY.
    NO action depends on these (a finger leaving the frame at a screen edge
    produces false states)."""
    w = lm[0]
    fingers = [_dist(lm[t], w) > _dist(lm[p], w)
               for t, p in ((8, 6), (12, 10), (16, 14), (20, 18))]
    thumb = _dist(lm[4], lm[9]) > _dist(lm[2], lm[9]) * 1.05
    return (thumb, fingers[0], fingers[1], fingers[2], fingers[3])


def _curled_count(lm):
    """How many of index/middle/ring/pinky are curled (tip nearer the wrist than
    its own PIP joint)."""
    w = lm[0]
    return sum(1 for t, p in ((8, 6), (12, 10), (16, 14), (20, 18))
               if _dist(lm[t], w) < _dist(lm[p], w) * 1.02)


def _is_fist(lm):
    """The main fingers are curled — a real fist OR fingers folded near a frame
    edge. Either way the safe response (stop the pan) is the same. UNCHANGED."""
    return _curled_count(lm) >= 3


def _thumbs_up(lm, dir_thr):
    """The THUMBS-UP pose: all four fingers curled, thumb clearly extended AND
    pointing up in camera space. Rejects a plain fist, a raised index finger, a
    sideways thumb, and (via the caller) a partial hand."""
    if _curled_count(lm) < 4:
        return False
    # thumb clearly extended: tip well away from the palm centre vs the thumb MCP
    if _dist(lm[4], lm[9]) <= _dist(lm[2], lm[9]) * 1.25:
        return False
    # thumb pointing up: MCP(2) -> tip(4) is clearly -y and more vertical than
    # horizontal
    vx = lm[4][0] - lm[2][0]
    vy = lm[4][1] - lm[2][1]
    return vy < -dir_thr and abs(vy) > abs(vx) * 0.9


def _palm_base(lm):
    xs = [lm[i][0] for i in _PALM_BASE]
    ys = [lm[i][1] for i in _PALM_BASE]
    return (sum(xs) / 3.0, sum(ys) / 3.0)


def _palm_scale(lm):
    """A hand-size reference that barely changes with pose: mean of wrist->
    middle-MCP and index-MCP->pinky-MCP. Used to normalise the pinch distance so
    it is independent of how near/far the hand is from the camera."""
    return max(1e-6, (_dist(lm[0], lm[9]) + _dist(lm[5], lm[17])) / 2.0)


def _pinch_ratio(lm):
    """distance(thumb_tip, index_tip) / palm_scale. ~0.15-0.30 when pinched,
    ~0.8-1.3 with the fingers apart."""
    return _dist(lm[4], lm[8]) / _palm_scale(lm)


def _tilt_angle(lm):
    """Signed angle (radians) of the palm from upright, in mirrored screen
    space: middle-finger MCP (9) relative to the palm base. Tilt the hand so 9
    swings to screen-right -> positive -> next; screen-left -> negative -> prev.
    Uses only wrist / MCP landmarks, which stay in frame."""
    bx, by = _palm_base(lm)
    mx, my = lm[9][0], lm[9][1]
    return math.atan2(mx - bx, by - my)      # 0 = pointing straight up


def _hand_bounds_ok(lm, margin=0.06):
    """False if a palm/base landmark has left the frame -> 'partial hand'."""
    for i in (0, 5, 9, 13, 17):
        x, y = lm[i][0], lm[i][1]
        if x < -margin or x > 1 + margin or y < -margin or y > 1 + margin:
            return False
    return True


def _label(lm, thumbs):
    if thumbs:
        return "thumbs_up"
    if _is_fist(lm):
        return "fist"
    if sum(_finger_states(lm)) >= 4:
        return "open_palm"
    return "other"


def _sign(v):
    return 1 if v > 1e-9 else (-1 if v < -1e-9 else 0)


# =========================================================================
# gesture engine
#
# Priority (highest first):
#   1. shutter closed    -> nothing (handled in the loop)
#   2. PINCH GRAB active  -> exclusive control of the focused window; pan / tilt /
#                            mosaic / clutch are all suppressed while it runs
#   3. FIST / THUMBS-UP  -> CLUTCH: end the pan now, cancel tilt, re-baseline the
#                            pan on release. (thumbs-up is still a curled fist, so
#                            it also clutches — see the mosaic state machine)
#   4. partial hand      -> no discrete actions; pan may continue; clutch works
#   5. OPEN PALM X/Y     -> smooth PAN (no arming, no suspension, no decision wait)
#   6. palm tilt (still) -> prev / next window  (own state machine, own channel)
#   The mosaic state machine (fist -> thumbs-up) runs alongside, from a stable fist.
# =========================================================================
class GestureEngine:
    def __init__(self, cfg, panner, pinchgrab):
        p, ti, mg = cfg["pan"], cfg["tilt"], cfg["mosaic_gesture"]
        pn = cfg["pinch"]
        self.pan_sens = float(p["sensitivity"])
        self.pan_smooth = float(p["smoothing"])
        self.pan_smooth_fast = float(p.get("smoothing_fast", p["smoothing"]))
        self.pan_speed_ref = float(p.get("speed_ref", 1.2))
        self.pan_dz = float(p["deadzone"])
        self.pan_cap = float(p["max_delta_per_frame"])
        self.pan_confirm = float(p["confirm_seconds"])
        self.pan_grace = float(p["grace_seconds"])
        self.pan_max_track = float(p.get("max_tracking_speed", 4.0))
        self.ti_thr = float(ti["angle_threshold"])
        self.ti_confirm = float(ti["confirm_seconds"])
        self.ti_cd = float(ti["cooldown_seconds"])
        self.ti_neutral = float(ti["neutral_threshold"])
        self.ti_max_speed = float(ti.get("max_translation_speed", 0.12))
        self.ti_still = float(ti.get("stationary_seconds", 0.15))
        self.ti_nav_block = float(ti.get("nav_block_seconds", 0.5))
        self.mg_fist_arm = float(mg["fist_arm_seconds"])
        self.mg_thumb_hold = float(mg["thumb_hold_seconds"])
        self.mg_cd = float(mg["cooldown_seconds"])
        self.mg_reset = float(mg["reset_seconds"])
        self.mg_thumb_dir = float(mg["thumb_direction_threshold"])
        self.pn_close = float(pn["close_ratio"])
        self.pn_open = float(pn["open_ratio"])
        self.pn_confirm = float(pn["confirm_seconds"])
        self.pn_grace = float(pn["grace_seconds"])
        self.panner = panner
        self.pinchgrab = pinchgrab
        self.last_tilt = 0.0
        self.last_mosaic = 0.0
        self.last_lm_ts = 0.0
        self.tilt_baseline = None       # auto-zero for however the hand is held
        self.soft_reset()
        self.d_gesture = "None"
        self.d_partial = 0
        self.d_pan = 0
        self.d_clutch = 0
        self.d_tilt_angle = 0.0
        self.d_tilt_state = "neutral"
        self.d_mosaic_state = "idle"
        self.d_thumb = 0
        self.d_thumb_hold = 0.0
        self.d_action = ""
        self.d_speed = 0.0
        self.d_still = 0
        self.d_raw = (0.0, 0.0)
        self.d_filt = (0.0, 0.0)
        self.d_dx = 0
        self.d_dy = 0
        self.d_outlier = 0
        self.d_pinch_ratio = 0.0
        self.d_pinch_state = "idle"
        self.d_pinch_addr = ""
        self.d_grab_dx = 0
        self.d_grab_dy = 0
        self.d_grab_wx = 0
        self.d_grab_wy = 0

    def soft_reset(self):
        """On shutter close/open and on real landmark loss. Cooldowns kept."""
        self.ema_ref = None            # smoothed palm-base position (for pan)
        self.prev_ref = None
        self.raw_prev = None           # last accepted raw palm-base (outliers)
        self.raw_prev_t = 0.0
        self.outlier_run = 0
        self.vel_hist = []             # (t, x, y) raw palm-base for speed
        self.still_since = None
        self.nav_block_until = 0.0
        self.last_open_ts = 0.0
        self.clutched = False
        self.tilt_state = "neutral"    # neutral | pending | fired
        self.tilt_dir = 0
        self.tilt_since = 0.0
        # pinch grab SM: idle -> pending -> grabbed -> released -> idle (blocked =
        # confirmed but no valid focused window; clears when the pinch opens)
        self.pinch_state = "idle"
        self.pinch_since = 0.0
        self.pinch_open_since = None
        # mosaic gesture SM: idle -> fist_armed -> thumbs_pending -> fired -> wait_reset
        self.mg_state = "idle"
        self.mg_fist_since = None
        self.mg_thumb_since = 0.0
        self.mg_reset_since = None
        if self.panner.active:
            self.panner.end()
        if self.pinchgrab.active:
            self.pinchgrab.end()

    def _palm_speed(self, now):
        h = [e for e in self.vel_hist if now - e[0] <= 0.15]
        if len(h) < 2 or h[-1][0] <= h[0][0]:
            return 0.0
        return (math.hypot(h[-1][1] - h[0][1], h[-1][2] - h[0][2])
                / (h[-1][0] - h[0][0]))

    # ------------------------------------------------------------------
    def _pinch_sm(self, now, ratio, partial, fist):
        """idle -> pending -> grabbed -> released -> idle. Hysteresis on the
        ratio (close_ratio to enter, open_ratio to leave), `confirm_seconds`
        before it grabs, `grace_seconds` of tolerance for opened/bad frames mid
        grab. A pinch can only ARM when the hand is not a fist (so a deliberate
        clutch is never mistaken for a pinch); once grabbed a fist is tolerated."""
        st = self.pinch_state
        if st == "idle":
            if ratio < self.pn_close and not partial and not fist:
                self.pinch_state = "pending"
                self.pinch_since = now
        elif st == "pending":
            if partial or fist or ratio > self.pn_open:
                self.pinch_state = "idle"
            elif now - self.pinch_since >= self.pn_confirm:
                self.pinch_state = "grabbed"
                self.pinch_open_since = None
        elif st == "grabbed":
            if ratio > self.pn_open:
                if self.pinch_open_since is None:
                    self.pinch_open_since = now
                elif now - self.pinch_open_since >= self.pn_grace:
                    self.pinch_state = "released"
            else:
                self.pinch_open_since = None
        elif st == "released":
            self.pinch_state = "idle"
        elif st == "blocked":
            if ratio > self.pn_open:
                self.pinch_state = "idle"

    # ------------------------------------------------------------------
    def _mosaic_sm(self, now, mkind, partial):
        """mkind: 'thumbs' | 'fist' | 'open' | 'other'. Runs every frame,
        independent of pan/tilt. A mosaic can ONLY fire from
        fist_armed -> thumbs_pending -> fired (never a bare thumbs-up)."""
        # a partial hand cancels a pending candidate and blocks arming
        if partial and self.mg_state in ("thumbs_pending",):
            self.mg_state = "fist_armed"

        if mkind == "fist":
            if self.mg_fist_since is None:
                self.mg_fist_since = now
        else:
            self.mg_fist_since = None

        st = self.mg_state
        if st == "idle":
            if (not partial and mkind == "fist" and self.mg_fist_since is not None
                    and now - self.mg_fist_since >= self.mg_fist_arm):
                self.mg_state = "fist_armed"
        elif st == "fist_armed":
            if partial:
                pass                                   # hold; can't advance
            elif mkind == "thumbs":
                self.mg_state = "thumbs_pending"
                self.mg_thumb_since = now
            elif mkind not in ("fist",):
                self.mg_state = "idle"                  # hand left the fist
        elif st == "thumbs_pending":
            self.d_thumb_hold = now - self.mg_thumb_since
            if partial:
                self.mg_state = "fist_armed"
            elif mkind == "thumbs":
                if (self.d_thumb_hold >= self.mg_thumb_hold
                        and now - self.last_mosaic > self.mg_cd):
                    _toggle_mosaic()
                    self.last_mosaic = now
                    self.mg_state = "fired"
                    self.d_action = "mosaic"
            elif mkind == "fist":
                self.mg_state = "fist_armed"            # thumb went back down
            else:
                self.mg_state = "idle"
        elif st == "fired":
            self.mg_state = "wait_reset"
        elif st == "wait_reset":
            # holding thumbs-up must NOT re-fire; re-arm needs a fist or an open
            # palm held for reset_seconds
            if mkind in ("fist", "open"):
                if self.mg_reset_since is None:
                    self.mg_reset_since = now
                elif now - self.mg_reset_since >= self.mg_reset:
                    self.mg_state = "idle"
                    self.mg_reset_since = None
            else:
                self.mg_reset_since = None

        if self.mg_state != "thumbs_pending":
            self.d_thumb_hold = 0.0
        self.d_mosaic_state = self.mg_state

    # ------------------------------------------------------------------
    def update(self, lm, now):
        self.d_action = ""

        # ---- brief tracking dropout: hold, do not reset (grace_seconds) ----
        if lm is None:
            if self.last_lm_ts and now - self.last_lm_ts <= self.pan_grace:
                self.d_gesture, self.d_pan = "None", 1 if self.panner.active else 0
                return
            self.soft_reset()          # real loss -> stop; rebaseline on return
            self.d_gesture, self.d_partial, self.d_pan, self.d_clutch = "None", 0, 0, 0
            self.d_tilt_state, self.d_mosaic_state = "neutral", "idle"
            self.d_tilt_angle, self.d_thumb, self.d_thumb_hold = 0.0, 0, 0.0
            self.d_speed, self.d_still, self.d_outlier = 0.0, 0, 0
            self.d_pinch_state, self.d_pinch_ratio, self.d_pinch_addr = "idle", 0.0, ""
            self.d_grab_dx = self.d_grab_dy = 0
            return
        self.last_lm_ts = now

        thumbs = _thumbs_up(lm, self.mg_thumb_dir)
        fist = _is_fist(lm)                          # true for a fist AND thumbs-up
        partial = not _hand_bounds_ok(lm)
        self.d_gesture = _label(lm, thumbs)
        self.d_partial = 1 if partial else 0
        self.d_thumb = 1 if thumbs else 0
        open_hand = self.d_gesture == "open_palm"

        # ================= 2. PINCH GRAB — exclusive window control ======
        pinch_ratio = _pinch_ratio(lm)
        self.d_pinch_ratio = round(pinch_ratio, 3)
        self._pinch_sm(now, pinch_ratio, partial, fist)
        grabbed = self.pinch_state == "grabbed"

        mkind = ("thumbs" if (thumbs and not partial) else "fist" if fist
                 else "open" if open_hand else "other")
        if not grabbed:
            self._mosaic_sm(now, mkind, partial)      # never advances during a grab

        if grabbed:
            if not self.pinchgrab.active and not self.pinchgrab.begin(_palm_base(lm), now):
                self.pinch_state = "blocked"          # no valid focused window
            if self.pinchgrab.active:
                if self.panner.active:
                    self.panner.end()
                self.prev_ref = None
                self.ema_ref = None
                self.tilt_state = "neutral"
                self.tilt_dir = 0
                self.clutched = True                 # pan re-baselines on release
                self.pinchgrab.step(_palm_base(lm), now)
                self.d_gesture = "pinch"
                self.d_pinch_state = "grabbed"
                self.d_pinch_addr = self.pinchgrab.addr or ""
                self.d_grab_dx, self.d_grab_dy = self.pinchgrab.dx, self.pinchgrab.dy
                self.d_grab_wx, self.d_grab_wy = self.pinchgrab.world_x, self.pinchgrab.world_y
                self.d_outlier = self.pinchgrab.d_outlier
                self.d_pan = self.d_clutch = 0
                self.d_tilt_state, self.d_tilt_angle = "neutral", 0.0
                self.d_mosaic_state = self.mg_state
                self.d_speed, self.d_still = 0.0, 0
                return
        elif self.pinchgrab.active:                   # left grab -> release cleanly
            self.pinchgrab.end()                      # window stays where it is
            self.clutched = True
            self.prev_ref = None
            self.ema_ref = None
        self.d_pinch_state = self.pinch_state
        self.d_pinch_addr = ""
        self.d_grab_dx = self.d_grab_dy = 0

        # ================= 3. FIST / THUMBS-UP -> CLUTCH ================
        if fist:
            if self.panner.active:
                self.panner.end()
            self.clutched = True
            self.prev_ref = None
            self.tilt_state = "neutral"
            self.tilt_dir = 0
            self.d_pan = 0
            self.d_clutch = 1
            self.d_tilt_state = "neutral"
            self.d_tilt_angle = 0.0
            self.d_speed, self.d_still = 0.0, 0
            return
        self.d_clutch = 0

        # ---- raw palm base + outlier rejection (isolated landmark spikes) ----
        raw_ref = _palm_base(lm)
        self.d_raw = (round(raw_ref[0], 3), round(raw_ref[1], 3))
        self.d_outlier = 0
        if self.raw_prev is not None:
            dt = max(1e-3, now - self.raw_prev_t)
            spd = math.hypot(raw_ref[0] - self.raw_prev[0],
                             raw_ref[1] - self.raw_prev[1]) / dt
            if spd > self.pan_max_track and self.outlier_run < 3:
                self.outlier_run += 1
                self.d_outlier = 1
                raw_ref = self.raw_prev            # keep the last good sample
            else:
                self.outlier_run = 0
        self.raw_prev = raw_ref
        self.raw_prev_t = now

        # ---- real translational speed of the palm (for tilt gating) ----
        self.vel_hist.append((now, raw_ref[0], raw_ref[1]))
        while self.vel_hist and now - self.vel_hist[0][0] > 0.4:
            self.vel_hist.pop(0)
        speed = self._palm_speed(now)
        self.d_speed = round(speed, 2)
        if speed < self.ti_max_speed:
            if self.still_since is None:
                self.still_since = now
        else:
            self.still_since = None
        stationary = (self.still_since is not None
                      and now - self.still_since >= self.ti_still)
        self.d_still = 1 if stationary else 0

        # fist/thumbs -> open: current position becomes the new pan baseline
        if self.clutched:
            self.clutched = False
            self.prev_ref = None
            self.ema_ref = None

        # ---- adaptive EMA: more smoothing when slow, more response when fast ----
        frac = min(1.0, speed / self.pan_speed_ref) if self.pan_speed_ref > 0 else 0.0
        a = self.pan_smooth + (self.pan_smooth_fast - self.pan_smooth) * frac
        self.ema_ref = raw_ref if self.ema_ref is None else (
            a * raw_ref[0] + (1 - a) * self.ema_ref[0],
            a * raw_ref[1] + (1 - a) * self.ema_ref[1])
        self.d_filt = (round(self.ema_ref[0], 3), round(self.ema_ref[1], 3))

        if open_hand:
            self.last_open_ts = now
        pan_ok = (now - self.last_open_ts) <= self.pan_grace
        nav_block = now < self.nav_block_until

        # ================= 5. PAN (translation X/Y) — priority over tilt ==
        self.d_dx = self.d_dy = 0
        if nav_block:
            if self.panner.active:
                self.panner.end()
            self.prev_ref = None                  # rebaseline once nav finishes
            self.d_pan = 0
        elif pan_ok:
            if not self.panner.active:
                self.panner.begin()
                self.prev_ref = self.ema_ref      # no step this frame -> no jump
            elif self.prev_ref is not None:
                dnx = self.ema_ref[0] - self.prev_ref[0]
                dny = self.ema_ref[1] - self.prev_ref[1]
                if abs(dnx) < self.pan_dz:
                    dnx = 0.0
                if abs(dny) < self.pan_dz:
                    dny = 0.0
                dxp = max(-self.pan_cap, min(self.pan_cap, dnx * self.pan_sens))
                dyp = max(-self.pan_cap, min(self.pan_cap, dny * self.pan_sens))
                self.d_dx, self.d_dy = round(dxp), round(dyp)
                if dxp or dyp:
                    self.panner.step(dxp, dyp)
            self.d_pan = 1 if self.panner.active else 0
        else:
            if self.panner.active:
                self.panner.end()
            self.d_pan = 0
        self.prev_ref = self.ema_ref

        # ================= 4. partial hand -> no discrete actions =======
        if partial:
            if self.tilt_state != "fired":
                self.tilt_state = "neutral"
            self.d_tilt_state = self.tilt_state
            return

        # ================= 6. palm TILT -> prev / next =================
        # ONLY while the palm is stationary (pan has priority). Auto-zeroed to
        # however the hand rests; the baseline only moves while near-neutral and
        # stationary, so a wild angle during a fast pan never poisons it.
        raw_a = _tilt_angle(lm)
        # seed the rest angle only when the hand is upright-ish AND still — never
        # zero out a hand that is already deliberately tilted
        if self.tilt_baseline is None:
            if open_hand and stationary and abs(raw_a) < self.ti_thr:
                self.tilt_baseline = raw_a
            ang = raw_a if self.tilt_baseline is None else 0.0
        else:
            if open_hand and stationary and abs(raw_a - self.tilt_baseline) < self.ti_neutral:
                self.tilt_baseline = 0.06 * raw_a + 0.94 * self.tilt_baseline
            ang = raw_a - self.tilt_baseline
        self.d_tilt_angle = ang

        if self.tilt_state == "fired":
            if abs(ang) < self.ti_neutral and now - self.last_tilt > self.ti_cd:
                self.tilt_state = "neutral"
        elif self.tilt_state == "pending":
            if (not stationary or abs(ang) < self.ti_neutral
                    or _sign(ang) != self.tilt_dir):
                self.tilt_state = "neutral"          # moved / straightened / reversed
            elif now - self.tilt_since >= self.ti_confirm:
                d = 1 if self.tilt_dir > 0 else -1   # mirrored: +x = screen right
                if self.panner.active:
                    self.panner.end()               # hand pan + world_navigate
                self.prev_ref = None                # never run at the same time
                self.nav_block_until = now + self.ti_nav_block
                _nav_window(d)
                self.last_tilt = now
                self.tilt_state = "fired"
                self.d_action = "next" if d > 0 else "prev"
        else:   # neutral -> pending ONLY when the hand is held still
            if (stationary and open_hand and abs(ang) > self.ti_thr
                    and now - self.last_tilt > self.ti_cd):
                self.tilt_state = "pending"
                self.tilt_dir = _sign(ang)
                self.tilt_since = now
        self.d_tilt_state = ("fired-right" if (self.tilt_state == "fired" and self.d_action == "next")
                             else "fired-left" if (self.tilt_state == "fired" and self.d_action == "prev")
                             else "fired" if self.tilt_state == "fired"
                             else self.tilt_state)


# =========================================================================
# preview / debug
# =========================================================================
def _dbg_line(sh, ge):
    pinch = "pinch=%-7s r=%.2f" % (ge.d_pinch_state, ge.d_pinch_ratio)
    if ge.d_pinch_state == "grabbed":
        pinch += (" addr=%s gxy=%+d,%+d wxy=%d,%d"
                  % ((ge.d_pinch_addr or "?")[-6:], ge.d_grab_dx, ge.d_grab_dy,
                     ge.d_grab_wx, ge.d_grab_wy))
    return ("dbg shutter=%-6s lofi=%4.1f | gesture=%-9s pan=%d clutch=%d "
            "partial=%d speed=%.2f stat=%d tilt=%+.2f tilt_state=%-11s "
            "mosaic=%-13s thumb=%d th=%.2f | raw=%.3f,%.3f filt=%.3f,%.3f "
            "dxy=%+d,%+d outl=%d | %s%s"
            % (sh.state, sh.lofi_std, ge.d_gesture, ge.d_pan, ge.d_clutch,
               ge.d_partial, ge.d_speed, ge.d_still, ge.d_tilt_angle,
               ge.d_tilt_state, ge.d_mosaic_state, ge.d_thumb, ge.d_thumb_hold,
               ge.d_raw[0], ge.d_raw[1], ge.d_filt[0], ge.d_filt[1],
               ge.d_dx, ge.d_dy, ge.d_outlier, pinch,
               (" action=%s" % ge.d_action) if ge.d_action else ""))


def _draw(cv2, frame, lm, ge, sh):
    h, w = frame.shape[:2]
    if lm:
        for p in lm:
            cv2.circle(frame, (int(p[0] * w), int(p[1] * h)), 3, (0, 255, 0), -1)
    col = (0, 200, 255) if sh.state == "open" else (0, 120, 255)
    cv2.putText(frame, "shutter %s  lofi %.1f" % (sh.state.upper(), sh.lofi_std),
                (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, col, 1)
    cv2.putText(frame, "%s p%d clutch%d spd %.2f stat%d  tilt %+.2f %s  mosaic %s%s"
                % (ge.d_gesture, ge.d_pan, ge.d_clutch, ge.d_speed, ge.d_still,
                   ge.d_tilt_angle, ge.d_tilt_state, ge.d_mosaic_state,
                   ("  ->%s" % ge.d_action) if ge.d_action else ""),
                (8, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1)
    cv2.putText(frame, "pinch %s r %.2f  grab %+d,%+d"
                % (ge.d_pinch_state, ge.d_pinch_ratio, ge.d_grab_dx, ge.d_grab_dy),
                (8, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                (0, 255, 120) if ge.d_pinch_state == "grabbed" else (180, 180, 180), 1)


def _try_show(cv2, frame):
    try:
        cv2.imshow("hand-control", frame)
        cv2.waitKey(1)
        return True
    except Exception as e:
        print("hand_control: preview window unavailable (%s) — metrics only"
              % e, file=sys.stderr)
        return False


# =========================================================================
# main loop
# =========================================================================
def run():
    _write_pidfile()
    cfg = _load_config()
    cam, dbg, shcfg = cfg["camera"], cfg["debug"], cfg["shutter"]
    show_preview = DEBUG or bool(dbg.get("show_preview"))
    if DEBUG:
        _print_thresholds(cfg)

    if show_preview:
        os.environ.setdefault("QT_QPA_PLATFORM", "xcb")

    try:
        import cv2
        import numpy as np
    except Exception as e:
        print("hand_control: opencv/numpy not importable: %s" % e, file=sys.stderr)
        _clear_state()
        return 3
    try:
        tracker = Tracker(cfg)
    except RuntimeError as e:
        print("hand_control: %s" % e, file=sys.stderr)
        _clear_state()
        return 3

    import signal
    _stop = {"v": False}
    signal.signal(signal.SIGTERM, lambda *_a: _stop.__setitem__("v", True))
    signal.signal(signal.SIGINT, lambda *_a: _stop.__setitem__("v", True))

    capture = cv2.VideoCapture(int(cam["index"]), cv2.CAP_V4L2)
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, int(cam["width"]))
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, int(cam["height"]))
    capture.set(cv2.CAP_PROP_FPS, int(cam["fps"]))
    try:
        capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    except Exception:
        pass
    if not capture.isOpened():
        print("hand_control: cannot open camera %s" % cam["index"], file=sys.stderr)
        tracker.close()
        _clear_state()
        return 3

    _write_state("open", 0)
    print("hand_control: tracking (%s API) — camera %s, mirror=%s, shutter-aware=%s"
          % (tracker.kind, cam["index"], bool(cam["mirror"]), bool(shcfg["enabled"])))

    mirror = bool(cam["mirror"])
    sample_w = int(shcfg["sample_width"])
    grab_period = 1.0 / max(1, int(cam["fps"]))
    closed_period = 1.0 / max(1, int(shcfg["closed_fps"]))

    shutter = Shutter(shcfg, cv2, np)
    panner = Panner()
    pinchgrab = PinchGrab(cfg)
    ge = GestureEngine(cfg, panner, pinchgrab)
    frame_no = 0
    t_start = time.monotonic()
    ms_acc = 0.0
    prev_shutter = "open"
    next_check = 0.0

    try:
        while not _stop["v"]:
            t0 = time.monotonic()
            label = "None"
            lm = None

            if prev_shutter == "closed" and t0 < next_check:
                capture.grab()
                slack = grab_period - (time.monotonic() - t0)
                if slack > 0:
                    time.sleep(slack)
                continue

            ok, frame = capture.read()
            if not ok:
                ge.soft_reset()
                time.sleep(closed_period)
                continue

            if mirror:
                frame = cv2.flip(frame, 1)

            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            h0, w0 = gray.shape
            small = cv2.resize(gray, (sample_w, max(1, sample_w * h0 // w0)),
                               interpolation=cv2.INTER_AREA)
            sstate = shutter.update(small, t0)
            if sstate == "closed":
                next_check = t0 + closed_period

            if sstate != prev_shutter:
                ge.soft_reset()
                print("hand_control: shutter %s -> %s (lofi %.1f std %.1f)"
                      % (prev_shutter.upper(), sstate.upper(),
                         shutter.lofi_std, shutter.stddev))
                prev_shutter = sstate

            if sstate == "closed":
                _write_state("closed", 0)
                if DEBUG:
                    print("dbg shutter=closed lofi=%4.1f std=%4.1f  (tracking off)"
                          % (shutter.lofi_std, shutter.stddev), flush=True)
                if show_preview:
                    _draw(cv2, frame, None, ge, shutter)
                    show_preview = _try_show(cv2, frame)
                slack = grab_period - (time.monotonic() - t0)
                if slack > 0:
                    time.sleep(slack)
                continue

            # ================= shutter OPEN: full tracking =================
            _write_state("open", 1)
            lm = tracker.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB), t0 * 1000.0)
            now = time.monotonic()
            ge.update(lm, now)

            if DEBUG:
                print(_dbg_line(shutter, ge), flush=True)
            if show_preview:
                _draw(cv2, frame, lm, ge, shutter)
                show_preview = _try_show(cv2, frame)

            ms_acc += (time.monotonic() - t0) * 1000.0
            frame_no += 1
            if frame_no % max(1, int(dbg.get("log_every", 60))) == 0:
                dt = time.monotonic() - t_start
                print("hand_control: %.1f fps, %.1f ms/frame, rss %s MB, shutter %s"
                      % (frame_no / dt if dt else 0.0, ms_acc / frame_no,
                         _rss_mb(), shutter.state))
            slack = grab_period - (time.monotonic() - t0)
            if slack > 0:
                time.sleep(slack)
    except KeyboardInterrupt:
        pass
    finally:
        if panner.active:
            panner.end()
        if pinchgrab.active:
            pinchgrab.end()
        capture.release()
        tracker.close()
        if show_preview:
            try:
                cv2.destroyAllWindows()
            except Exception:
                pass
        _clear_state()
        print("hand_control: stopped, camera released")
    return 0


if __name__ == "__main__":
    sys.exit(run())
