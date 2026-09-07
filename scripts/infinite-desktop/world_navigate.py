#!/usr/bin/env python3
"""world_navigate.py — fly the Infinite Desktop camera to a window.

Called by Quickshell (the World Map and the navbar app-icon zone). It does NOT
bring a single window to the viewport — it pans EVERY floating window on the
workspace by the same delta (the exact Infinite Desktop pan mechanism), so the
relative layout of the whole canvas is preserved, and updates the camera offset
(world.py) so world coordinates stay stable.

    world_navigate.py address 0x559...        pan to that window, focus it
    world_navigate.py class    firefox        pan to a window of that class;
                                              repeated calls cycle its windows
    world_navigate.py next-window             focus+centre the next individual
    world_navigate.py prev-window             window on the workspace (each Foot
                                              is its own destination). While a
                                              Viewport Mosaic is active this
                                              instead just moves focus between
                                              the mosaic windows — no camera,
                                              no window move (viewport_mosaic.py).

No root, no polling. Installed to ~/scripts by `install.sh infinite-desktop`.
"""

import fcntl
import json
import subprocess
import sys
import time
import os

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hypr_ipc import move_window_exact_lua, batch, focus_window_lua, dispatch
import world

_RUN_DIR = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "infinite-desktop")
_CYCLE_FILE = os.path.join(_RUN_DIR, "cycle.json")
_NAV_LOCK = os.path.join(_RUN_DIR, ".navigate.lock")


class _NavLock:
    """Serialise concurrent navigations so the pan + camera bump stay a unit.

    A single click never contends; this only matters when the user hammers the
    map / navbar. Blocking (not drop) so every click still lands, just in turn.
    Auto-released when the process exits.
    """

    def __enter__(self):
        os.makedirs(_RUN_DIR, exist_ok=True)
        self._fd = os.open(_NAV_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
        return False

STEPS = 11
STEP_SLEEP = 0.018


def _clients():
    r = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=1)
    return json.loads(r.stdout)


def _focused_monitor():
    r = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True, timeout=1)
    mons = json.loads(r.stdout)
    for m in mons:
        if m.get("focused"):
            return m
    return mons[0] if mons else {"x": 0, "y": 0, "width": 1920, "height": 1080,
                                 "scale": 1.0, "reserved": [0, 0, 0, 0]}


def _usable_center(mon):
    s = mon.get("scale", 1.0) or 1.0
    w = mon["width"] / s
    h = mon["height"] / s
    r = mon.get("reserved", [0, 0, 0, 0])
    rl, rt, rr, rb = (r + [0, 0, 0, 0])[:4]
    return (mon["x"] + rl + (w - rl - rr) / 2.0,
            mon["y"] + rt + (h - rt - rb) / 2.0)


def _smoothstep(t):
    return t * t * (3.0 - 2.0 * t)


def _pan_to(target, clients):
    ws = target.get("workspace", {}).get("id")
    if ws is None:
        return
    mon = _focused_monitor()
    cx, cy = _usable_center(mon)
    tx = target["at"][0] + target["size"][0] / 2.0
    ty = target["at"][1] + target["size"][1] / 2.0
    dx = cx - tx
    dy = cy - ty
    if abs(dx) < 2 and abs(dy) < 2:
        return

    floating = [w for w in clients
                if w.get("floating") and w.get("workspace", {}).get("id") == ws]
    base = [(w["address"], w["at"][0], w["at"][1]) for w in floating]

    for i in range(1, STEPS + 1):
        e = _smoothstep(i / STEPS)
        ox, oy = dx * e, dy * e
        exprs = [move_window_exact_lua(round(bx + ox), round(by + oy), a)
                 for a, bx, by in base]
        if exprs:
            batch(exprs, timeout=2)
        if i < STEPS:
            time.sleep(STEP_SLEEP)

    world.bump_camera(ws, -dx, -dy)


def _navigate_address(addr):
    clients = _clients()
    a = addr if addr.startswith("0x") else "0x" + addr
    tgt = next((w for w in clients if w["address"] == a), None)
    if not tgt:
        return
    _pan_to(tgt, clients)
    dispatch(focus_window_lua(a))


def _load_cycle():
    try:
        with open(_CYCLE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_cycle(d):
    try:
        os.makedirs(os.path.dirname(_CYCLE_FILE), exist_ok=True)
        tmp = _CYCLE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, _CYCLE_FILE)
    except Exception:
        pass


def _navigate_class(cls):
    clients = _clients()
    cl = cls.lower()
    matches = sorted(
        (w for w in clients
         if (w.get("initialClass") or w.get("class") or "").lower() == cl
         or (w.get("class") or "").lower() == cl),
        key=lambda w: w["address"])
    if not matches:
        return
    if len(matches) == 1:
        _pan_to(matches[0], clients)
        dispatch(focus_window_lua(matches[0]["address"]))
        return

    # multiple windows of this class: cycle. Advance only if the previous
    # navigate for this class was recent AND we are already focused on one of
    # them; otherwise start from the focused/first one.
    cyc = _load_cycle()
    prev = cyc.get(cl, {})
    now = time.time()
    active = subprocess.run(["hyprctl", "activewindow", "-j"],
                            capture_output=True, text=True, timeout=1)
    try:
        cur_addr = json.loads(active.stdout).get("address")
    except Exception:
        cur_addr = None

    addrs = [w["address"] for w in matches]
    if cur_addr in addrs and now - prev.get("ts", 0) < 3.0:
        idx = (addrs.index(cur_addr) + 1) % len(addrs)
    elif cur_addr in addrs:
        idx = addrs.index(cur_addr)
    else:
        idx = 0
    tgt = matches[idx]
    _pan_to(tgt, clients)
    dispatch(focus_window_lua(tgt["address"]))
    cyc[cl] = {"ts": now, "addr": tgt["address"]}
    _save_cycle(cyc)


_MOSAIC_DIR = _RUN_DIR
_SKIP_TITLE = ("Picture-in-Picture", "Picture in Picture", "Sharing Indicator")


def _current_ws():
    try:
        r = subprocess.run(["hyprctl", "activewindow", "-j"],
                           capture_output=True, text=True, timeout=1)
        w = json.loads(r.stdout)
        ws = (w.get("workspace") or {}).get("id")
        if ws:
            return ws
    except Exception:
        pass
    try:
        mons = json.loads(subprocess.run(["hyprctl", "monitors", "-j"],
                          capture_output=True, text=True, timeout=1).stdout)
        m = next((x for x in mons if x.get("focused")), mons[0])
        return (m.get("activeWorkspace") or {}).get("id", 1)
    except Exception:
        return 1


def _individual_windows(ws):
    """Every 'normal' floating window on `ws`, in stable world reading order."""
    cam = world.read_camera(ws)
    cx, cy = cam.get("x", 0.0), cam.get("y", 0.0)
    out = []
    for c in _clients():
        if (c.get("workspace") or {}).get("id") != ws:
            continue
        if not c.get("mapped") or not c.get("floating") or c.get("fullscreen"):
            continue
        title = c.get("title") or ""
        cls = (c.get("initialClass") or c.get("class") or "")
        if any(t in title for t in _SKIP_TITLE):
            continue
        if cls.startswith("xdg-desktop-portal") or cls.startswith("org.freedesktop.impl.portal"):
            continue
        aw, ah = c["size"]
        if aw < 200 or ah < 150:
            continue
        out.append((c, c["at"][0] + cx, c["at"][1] + cy))
    out.sort(key=lambda e: (round(e[2] / 120.0), e[1]))   # world reading order
    return [e[0] for e in out]


def _navigate_window_cycle(direction):
    ws = _current_ws()
    snap = os.path.join(_MOSAIC_DIR, "viewport-mosaic-%s.json" % ws)
    if os.path.exists(snap):
        # mosaic mode: pure focus move, keep the whole mosaic on screen
        here = os.path.dirname(os.path.realpath(__file__))
        subprocess.run(["python3", os.path.join(here, "viewport_mosaic.py"),
                        "next" if direction > 0 else "prev"], timeout=4)
        return
    # normal mode: spatial navigation over individual windows
    clients = _clients()
    wins = _individual_windows(ws)
    if not wins:
        return
    try:
        cur = json.loads(subprocess.run(["hyprctl", "activewindow", "-j"],
                         capture_output=True, text=True, timeout=1).stdout).get("address")
    except Exception:
        cur = None
    addrs = [w["address"] for w in wins]
    idx = addrs.index(cur) if cur in addrs else (0 if direction > 0 else -1)
    tgt = wins[(idx + direction) % len(wins)]
    with _NavLock():
        _pan_to(tgt, clients)
        dispatch(focus_window_lua(tgt["address"]))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode in ("next-window", "prev-window"):
        _navigate_window_cycle(1 if mode == "next-window" else -1)
        return 0
    if len(sys.argv) < 3 or mode not in ("address", "class"):
        print("usage: world_navigate.py {address <addr>|class <name>|"
              "next-window|prev-window}", file=sys.stderr)
        return 2
    value = sys.argv[2]
    with _NavLock():
        if mode == "address":
            _navigate_address(value)
        else:
            _navigate_class(value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
