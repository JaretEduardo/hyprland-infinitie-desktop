#!/usr/bin/env python3
"""world_edit.py — apply a World Map edit to a real window.

    world_edit.py geometry <address> <worldX> <worldY> <width> <height>
    world_edit.py move     <address> <worldX> <worldY>
    world_edit.py resize   <address> <width> <height>

The World Map works in WORLD coordinates (see world.py). This converts a target
world geometry to SCREEN coordinates for the window's workspace —

    screenX = worldX - cameraX
    screenY = worldY - cameraY

— and moves / resizes the window by address in ONE hyprctl batch. It does NOT
touch the camera (editing a window changes where it sits in the world, it does
not navigate the viewport) and does NOT start a daemon.

A manual edit also drops the window's pseudo-maximize restore state
($XDG_RUNTIME_DIR/hypr-fworld/<addr>, written by lua/floating-world.lua) so a
later SUPER + F does not snap it back to a stale geometry — the edited geometry
becomes its new normal size.

Quickshell only ever needs `geometry`; it passes the unchanged axis through, so
a move-only or resize-only edit still goes through one call. Installed to
~/scripts by `install.sh infinite-desktop`.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hypr_ipc import move_window_exact_lua, resize_window_exact_lua, batch
import world

# A floating window may be smaller than nothing useful; keep a sane floor but
# never clamp to the monitor — the Infinite Desktop canvas is unbounded and a
# window is allowed to be larger than the viewport. Hyprland still applies the
# client's own size hints on top of whatever we ask for.
MIN_W, MIN_H = 220, 140

_PMAX_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hypr-fworld")


def _clients():
    r = subprocess.run(["hyprctl", "clients", "-j"],
                       capture_output=True, text=True, timeout=2)
    return json.loads(r.stdout)


def _find(addr):
    a = addr if addr.startswith("0x") else "0x" + addr
    for c in _clients():
        if c.get("address") == a:
            return c
    return None


def _drop_pmax(addr):
    try:
        os.remove(os.path.join(_PMAX_DIR, addr))
    except OSError:
        pass


def _f(v):
    return float(v)


def main():
    if len(sys.argv) < 3:
        print("usage: world_edit.py {geometry|move|resize} <address> ...",
              file=sys.stderr)
        return 2

    mode, addr = sys.argv[1], sys.argv[2]
    win = _find(addr)
    if not win:
        return 1
    a = win["address"]
    ws = (win.get("workspace") or {}).get("id")
    cam = world.read_camera(ws) if ws is not None else {"x": 0.0, "y": 0.0}
    cx, cy = cam.get("x", 0.0), cam.get("y", 0.0)

    cur_x, cur_y = int(win["at"][0]), int(win["at"][1])
    cur_w, cur_h = int(win["size"][0]), int(win["size"][1])

    want_resize = mode in ("geometry", "resize")
    want_move = mode in ("geometry", "move")

    try:
        if mode == "geometry":
            wx, wy = _f(sys.argv[3]), _f(sys.argv[4])
            w, h = _f(sys.argv[5]), _f(sys.argv[6])
        elif mode == "move":
            wx, wy = _f(sys.argv[3]), _f(sys.argv[4])
            w = h = 0.0
        elif mode == "resize":
            w, h = _f(sys.argv[3]), _f(sys.argv[4])
            wx = wy = 0.0
        else:
            print("unknown mode: " + mode, file=sys.stderr)
            return 2
    except (IndexError, ValueError):
        print("bad arguments", file=sys.stderr)
        return 2

    exprs = []

    if want_resize:
        nw = max(MIN_W, int(round(w)))
        nh = max(MIN_H, int(round(h)))
        if nw != cur_w or nh != cur_h:
            exprs.append(resize_window_exact_lua(nw, nh, a))

    if want_move:
        sx = int(round(wx - cx))
        sy = int(round(wy - cy))
        if sx != cur_x or sy != cur_y:
            exprs.append(move_window_exact_lua(sx, sy, a))

    if exprs:
        # resize before move: resizewindow keeps the top-left anchored, so the
        # final movewindow lands the corner exactly where the map dropped it.
        batch(exprs, timeout=3)

    _drop_pmax(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
