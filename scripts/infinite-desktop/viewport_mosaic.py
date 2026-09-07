#!/usr/bin/env python3
"""viewport_mosaic.py — a temporary tidy layout of the windows in the viewport.

    viewport_mosaic.py toggle    arrange the windows currently visible in the
                                 Infinite Desktop viewport into a mosaic; run
                                 again to restore every window to its EXACT
                                 previous world geometry, then forget the snapshot
    viewport_mosaic.py status    prints "active <n>" or "inactive"
    viewport_mosaic.py next      (mosaic active) focus the next mosaic window
    viewport_mosaic.py prev      (mosaic active) focus the previous one

Nothing is tiled: every window stays floating, inside the Infinite Desktop, with
world coordinates, panned by the daemon. The snapshot is stored per workspace as
WORLD coordinates (worldX = at.x + camera.x), so panning the camera while the
mosaic is up does not affect the restore. Pseudo-maximize state
(lua/floating-world.lua, $XDG_RUNTIME_DIR/hypr-fworld/) is a separate store and
is never touched here.

No root, no daemon. Installed to ~/scripts by `install.sh infinite-desktop`.
"""

import fcntl
import json
import math
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hypr_ipc import (move_window_exact_lua, resize_window_exact_lua, batch,
                      focus_window_lua, dispatch)
import world

_RUN_DIR = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "infinite-desktop")
_LOCK = os.path.join(_RUN_DIR, ".mosaic.lock")

GAP = 10          # logical px between mosaic tiles
OUTER = 10        # logical px margin to the monitor edges
NAV_RESERVE = 44  # logical px kept clear at the top for the navbar island
MIN_W, MIN_H = 200, 150   # smaller than this → treat as a dialog / picker
SLIVER = 80       # need at least this much of a window inside the viewport

_SKIP_TITLE = ("Picture-in-Picture", "Picture in Picture", "Sharing Indicator")
_SKIP_CLASS = ("xdg-desktop-portal", "org.freedesktop.impl.portal")


def snap_path(ws):
    return os.path.join(_RUN_DIR, "viewport-mosaic-%s.json" % ws)


class _Lock:
    def __enter__(self):
        os.makedirs(_RUN_DIR, exist_ok=True)
        self._fd = os.open(_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)


def _hjson(args):
    r = subprocess.run(["hyprctl"] + args + ["-j"],
                       capture_output=True, text=True, timeout=2)
    return json.loads(r.stdout) if r.stdout.strip() else None


def _ws_and_monitor():
    mons = _hjson(["monitors"]) or []
    mon = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
    if not mon:
        mon = {"x": 0, "y": 0, "width": 1920, "height": 1200, "scale": 1.0,
               "reserved": [0, 0, 0, 0], "activeWorkspace": {"id": 1}}
    ws = (mon.get("activeWorkspace") or {}).get("id", 1)
    return ws, mon


def _viewport_box(mon):
    """Monitor rectangle in the same logical coords windows use."""
    s = mon.get("scale", 1.0) or 1.0
    return (mon["x"], mon["y"], mon["width"] / s, mon["height"] / s)


def _usable(mon):
    s = mon.get("scale", 1.0) or 1.0
    w = mon["width"] / s
    h = mon["height"] / s
    r = ((mon.get("reserved") or [0, 0, 0, 0]) + [0, 0, 0, 0])[:4]
    rl, rt, rr, rb = r
    return {
        "x": mon["x"] + rl + OUTER,
        "y": mon["y"] + rt + OUTER + NAV_RESERVE,
        "w": w - rl - rr - 2 * OUTER,
        "h": h - rt - rb - 2 * OUTER - NAV_RESERVE,
    }


def _is_normal(c):
    if not c.get("mapped") or not c.get("floating") or c.get("fullscreen"):
        return False
    title = c.get("title") or ""
    cls = (c.get("initialClass") or c.get("class") or "")
    if any(t in title for t in _SKIP_TITLE):
        return False
    if any(cls.startswith(t) for t in _SKIP_CLASS):
        return False
    aw, ah = c["size"]
    return aw >= MIN_W and ah >= MIN_H


def _candidates(ws, mon):
    vx, vy, vw, vh = _viewport_box(mon)
    out = []
    for c in _hjson(["clients"]) or []:
        if (c.get("workspace") or {}).get("id") != ws:
            continue
        if not _is_normal(c):
            continue
        ax, ay = c["at"]
        aw, ah = c["size"]
        ix = max(0, min(ax + aw, vx + vw) - max(ax, vx))
        iy = max(0, min(ay + ah, vy + vh) - max(ay, vy))
        if ix < SLIVER or iy < SLIVER:      # only a sliver visible → skip
            continue
        out.append(c)
    # reading order (top-to-bottom, then left-to-right) for slot assignment
    out.sort(key=lambda c: (round(c["at"][1] / 120.0), c["at"][0]))
    return out


def _layout(n, a):
    g = GAP
    if n <= 0:
        return []
    if n == 1:
        w, h = a["w"] * 0.94, a["h"] * 0.94
        return [(a["x"] + (a["w"] - w) / 2, a["y"] + (a["h"] - h) / 2, w, h)]
    if n == 2:
        w = (a["w"] - g) / 2
        return [(a["x"], a["y"], w, a["h"]),
                (a["x"] + w + g, a["y"], w, a["h"])]
    if n == 3:
        w = (a["w"] - g) / 2
        h = (a["h"] - g) / 2
        return [(a["x"], a["y"], w, a["h"]),                    # big left
                (a["x"] + w + g, a["y"], w, h),                 # top right
                (a["x"] + w + g, a["y"] + h + g, w, h)]         # bottom right
    if n == 4 or n <= 6:
        rows = 2
    elif n <= 9:
        rows = 3
    else:
        rows = int(math.ceil(math.sqrt(n)))
    per = [n // rows] * rows
    for i in range(n % rows):
        per[i] += 1
    per = [p for p in per if p > 0]
    rows = len(per)
    ch = (a["h"] - g * (rows - 1)) / rows
    rects = []
    for r, k in enumerate(per):
        cw = (a["w"] - g * (k - 1)) / k
        for col in range(k):
            rects.append((a["x"] + col * (cw + g),
                          a["y"] + r * (ch + g), cw, ch))
    return rects


def _apply(pairs):
    """pairs: (address, x, y, w, h) — resize then move each, one batch."""
    exprs = []
    for addr, x, y, w, h in pairs:
        exprs.append(resize_window_exact_lua(int(round(w)), int(round(h)), addr))
        exprs.append(move_window_exact_lua(int(round(x)), int(round(y)), addr))
    if exprs:
        batch(exprs, timeout=5)


def _write_atomic(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, path)


def _rm(p):
    try:
        os.remove(p)
    except OSError:
        pass


def _toggle():
    ws, mon = _ws_and_monitor()
    snap = snap_path(ws)
    if os.path.exists(snap):
        _restore(ws, snap)
        return

    cands = _candidates(ws, mon)
    if not cands:
        return
    cam = world.read_camera(ws)
    cx, cy = cam.get("x", 0.0), cam.get("y", 0.0)
    rects = _layout(len(cands), _usable(mon))

    windows, pairs = [], []
    for c, (rx, ry, rw, rh) in zip(cands, rects):
        ax, ay = c["at"]
        aw, ah = c["size"]
        windows.append({"address": c["address"],
                        "worldX": ax + cx, "worldY": ay + cy,
                        "width": aw, "height": ah})
        pairs.append((c["address"], rx, ry, rw, rh))

    _write_atomic(snap, {"ws": ws, "ts": round(time.time(), 3),
                         "camera": {"x": cx, "y": cy}, "windows": windows})
    _apply(pairs)


def _restore(ws, snap):
    try:
        with open(snap) as f:
            data = json.load(f)
    except Exception:
        _rm(snap)
        return
    cam = world.read_camera(ws)
    cx, cy = cam.get("x", 0.0), cam.get("y", 0.0)
    live = {c["address"] for c in (_hjson(["clients"]) or [])}
    pairs = [(w["address"], w["worldX"] - cx, w["worldY"] - cy,
              w["width"], w["height"])
             for w in data.get("windows", []) if w["address"] in live]
    _apply(pairs)
    _rm(snap)


def _cycle(direction):
    ws, _ = _ws_and_monitor()
    try:
        with open(snap_path(ws)) as f:
            data = json.load(f)
    except Exception:
        return
    live = {c["address"] for c in (_hjson(["clients"]) or [])}
    order = [w["address"] for w in data.get("windows", []) if w["address"] in live]
    if not order:
        return
    cur = (_hjson(["activewindow"]) or {}).get("address")
    idx = order.index(cur) if cur in order else (0 if direction > 0 else -1)
    dispatch(focus_window_lua(order[(idx + direction) % len(order)]))


def _status():
    ws, _ = _ws_and_monitor()
    snap = snap_path(ws)
    if not os.path.exists(snap):
        print("inactive")
        return
    try:
        with open(snap) as f:
            print("active %d" % len(json.load(f).get("windows", [])))
    except Exception:
        print("active ?")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "status":
        _status()
    elif cmd == "toggle":
        with _Lock():
            _toggle()
    elif cmd in ("next", "prev"):
        _cycle(1 if cmd == "next" else -1)
    else:
        print("usage: viewport_mosaic.py {toggle|status|next|prev}",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
