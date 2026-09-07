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


def main():
    if len(sys.argv) < 3:
        print("usage: world_navigate.py {address|class} <value>", file=sys.stderr)
        return 2
    mode, value = sys.argv[1], sys.argv[2]
    if mode not in ("address", "class"):
        print("unknown mode: " + mode, file=sys.stderr)
        return 2
    with _NavLock():
        if mode == "address":
            _navigate_address(value)
        else:
            _navigate_class(value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
