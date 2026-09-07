#!/usr/bin/env python3
"""world.py — the world-coordinate / camera layer for Infinite Desktop.

Infinite Desktop pans by physically moving every window. A minimap that used
`client.at` directly would see the whole world slide every time the camera
moves. This module separates the two:

    worldX = screenX + cameraX        (screenX == what `hyprctl clients` reports)
    worldY = screenY + cameraY

`cameraX/Y` is "the world coordinate currently under the top-left of the
screen". When a pan moves every window by (dx, dy), the camera moves by
(-dx, -dy) — so every window's *world* position stays put and only the viewport
moves.

State lives in ONE small file, per workspace, flock-protected so the daemon,
world_navigate.py and Quickshell never tear it:

    $XDG_RUNTIME_DIR/infinite-desktop/camera.json
      { "<ws id>": { "x": <float>, "y": <float> }, ..., "_ts": <epoch> }

Not persisted across reboot (runtime dir). No daemon of its own — the existing
Infinite Desktop daemon calls bump_camera() from its pan paths.
"""

import json
import os
import fcntl
import time

_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "infinite-desktop")
_CAM = os.path.join(_DIR, "camera.json")
_LOCK = os.path.join(_DIR, ".camera.lock")


def _ensure_dir():
    try:
        os.makedirs(_DIR, exist_ok=True)
    except Exception:
        pass


def _read_raw():
    try:
        with open(_CAM) as f:
            return json.load(f)
    except Exception:
        return {}


def _write_raw(d):
    d["_ts"] = round(time.time(), 3)
    tmp = _CAM + ".tmp.%d" % os.getpid()
    try:
        with open(tmp, "w") as f:
            json.dump(d, f, separators=(",", ":"))
        os.replace(tmp, _CAM)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


class _FileLock:
    def __enter__(self):
        _ensure_dir()
        self._f = open(_LOCK, "w")
        fcntl.flock(self._f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        try:
            fcntl.flock(self._f, fcntl.LOCK_UN)
            self._f.close()
        except Exception:
            pass


def read_camera(ws_id=None):
    """Return {ws: {x,y}} (ws_id None) or {x,y} for one workspace."""
    d = _read_raw()
    if ws_id is None:
        return {k: v for k, v in d.items() if not k.startswith("_")}
    v = d.get(str(ws_id))
    return {"x": float(v["x"]), "y": float(v["y"])} if v else {"x": 0.0, "y": 0.0}


def bump_camera(ws_id, dx, dy):
    """Add (dx, dy) to workspace `ws_id`'s camera offset. Pass the INVERSE of a
    pan delta: after moving every window by (pdx, pdy), call
    bump_camera(ws, -pdx, -pdy)."""
    if not dx and not dy:
        return
    k = str(ws_id)
    with _FileLock():
        d = _read_raw()
        cur = d.get(k) or {"x": 0.0, "y": 0.0}
        d[k] = {"x": round(float(cur["x"]) + dx, 1),
                "y": round(float(cur["y"]) + dy, 1)}
        _write_raw(d)


def set_camera(ws_id, x, y):
    with _FileLock():
        d = _read_raw()
        d[str(ws_id)] = {"x": round(float(x), 1), "y": round(float(y), 1)}
        _write_raw(d)


def reset(ws_id=None):
    with _FileLock():
        if ws_id is None:
            _write_raw({})
        else:
            d = _read_raw()
            d.pop(str(ws_id), None)
            _write_raw(d)


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 2 and sys.argv[1] == "reset":
        reset(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        print(json.dumps(read_camera(), indent=2))
