#!/usr/bin/env python3
"""display_manager.py — adaptive monitor / workspace handling for the Infinite
Desktop. STAGE 1: hotplug survival only (no UI, no mode changes).

THE RULE (docs/INFINITE-DESKTOP.md "Adaptive displays"):
    Monitors are physical viewports onto ONE Infinite Desktop. A workspace does
    NOT permanently belong to a monitor. It must survive connect / disconnect /
    re-arrange without losing windows, world coordinates, or reachability.

When a workspace changes monitor — Hyprland's auto-relocation on unplug, or an
explicit `hl.dsp.workspace.move` — Hyprland **translates the workspace's windows
by the monitor-origin delta** (verified), keeping them viewport-consistent on the
new screen. But each monitor has a different global-logical origin (HDMI-A-1 at
x=0, eDP-1 at x=1920 here), so `worldX = at.x + camera.x` drifts by that delta:
`at.x` moved, `camera.json` did not. The World Map then misplaces the workspace
and the Infinite Desktop pan math is off by one monitor width.

This script fixes exactly that, event-driven from config/hypr/lua/display.lua:

    display_manager.py sync       a monitor was removed — for every workspace now
                                  on a different monitor, bump camera.json by the
                                  inverse of the origin delta so world positions
                                  stay put; force a truly-orphaned workspace onto
                                  a survivor first.
    display_manager.py restore    a monitor was (re)connected — move a workspace
                                  back to its saved HOME output and realign its
                                  camera the same way.
    display_manager.py snapshot   record the current topology + each workspace's
                                  home output + coordinate frame to
                                  display-state.json — what sync / restore read.
    display_manager.py status     read-only JSON dump (for Settings / perf-audit).

Camera compensation (`_recam`) runs ONLY inside sync / restore, i.e. only when a
workspace was actually moved between monitors by a hotplug event — never on a
plain reload, never for workspace navigation, never by any physical-position
policy. It never moves a window itself (Hyprland does the window translation),
never resets camera.json, never deletes a workspace, never touches monitor
modes / scale / positions / workspace assignment (that is Stage 2 / Settings),
never restarts anything. All hyprctl dispatch goes through the Lua API form;
`hyprctl keyword` is rejected under the Lua parser and is not used.
"""

import fcntl
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hypr_ipc import hyprctl_json  # noqa: E402
import world  # noqa: E402

_CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "hyprland-infinitie-desktop")
_STATE = os.path.join(_CACHE, "display-state.json")
_LOG = os.path.join(_CACHE, "display-manager.log")
_LOCK = os.path.join(_CACHE, ".display-manager.lock")

# monitor.layout_changed / workspace.move_to_monitor can fire in bursts; a
# snapshot written < this many seconds ago is left alone (unless --force).
_SNAP_DEBOUNCE = 1.0
_SEP = "\x1f"                       # identity field separator (opaque key)


def _ensure_cache():
    try:
        os.makedirs(_CACHE, exist_ok=True)
    except Exception:
        pass


def _log(msg):
    _ensure_cache()
    line = "%s  %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(_LOG, "a") as f:
            f.write(line)
    except Exception:
        pass
    print("display_manager: " + msg, file=sys.stderr)


class _Lock:
    """Serialise sync / restore / snapshot so a rapid unplug-replug cannot race."""

    def __enter__(self):
        _ensure_cache()
        self._fd = os.open(_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
        return False


# --------------------------------------------------------------------------
# hyprland reads
# --------------------------------------------------------------------------
def _monitors():
    return hyprctl_json(["monitors"]) or []


def _workspaces():
    return hyprctl_json(["workspaces"]) or []


def _identity(mon):
    """Stable-ish output identity: connector name + EDID description + serial.
    `serial` is frequently empty (it is on this Lenovo panel), so it is only a
    tie-breaker; name + description is what actually distinguishes outputs."""
    return _SEP.join((
        mon.get("name") or "?",
        (mon.get("description") or "").strip(),
        (mon.get("serial") or "").strip(),
    ))


def _logical_size(mon):
    s = mon.get("scale") or 1.0
    s = s if s > 0 else 1.0
    return (mon.get("width", 0) / s, mon.get("height", 0) / s)


def _pick_survivor(mons):
    """When a workspace is on a monitor that is simply GONE (Hyprland has not
    yet relocated it), choose where to put it: the focused monitor, else the
    lowest-id one. (Position is not used — a workspace is not owned by a spot.)"""
    if not mons:
        return None
    for m in mons:
        if m.get("focused"):
            return m
    return sorted(mons, key=lambda m: m.get("id", 0))[0]


# --------------------------------------------------------------------------
# workspace move (Lua API — `hyprctl keyword` does not work under the Lua parser)
# --------------------------------------------------------------------------
def _move_workspace(ws_id, mon_name):
    expr = ('hl.dsp.workspace.move({ workspace = %d, monitor = "%s" })'
            % (int(ws_id), mon_name))
    r = subprocess.run(["hyprctl", "dispatch", expr],
                       capture_output=True, text=True, timeout=2)
    ok = (r.returncode == 0 and "ok" in (r.stdout or "").lower())
    if not ok:
        _log("workspace.move(%s -> %s) failed: %s %s"
             % (ws_id, mon_name, (r.stdout or "").strip(), (r.stderr or "").strip()))
    return ok


def _recam(ws_id, dmx, dmy):
    """A workspace moved between monitors whose global origins differ by
    (dmx, dmy). Hyprland ALREADY translates the workspace's windows by that
    delta (verified: `hl.dsp.workspace.move` and the auto-relocation on unplug
    both do), so the windows are already correct *within the new viewport*.
    Only `camera.json` needs fixing: `worldX = at.x + camera.x`, `at.x` moved by
    +dm, so `camera.x` must move by -dm to keep world positions stable."""
    dmx, dmy = int(round(dmx)), int(round(dmy))
    if dmx == 0 and dmy == 0:
        return
    try:
        world.bump_camera(ws_id, -dmx, -dmy)
    except Exception as e:
        _log("camera compensate ws %s failed: %s" % (ws_id, e))
    _log("ws %s crossed monitors by (%+d,%+d) -> camera %+d,%+d (windows already "
         "translated by Hyprland)" % (ws_id, dmx, dmy, -dmx, -dmy))


# --------------------------------------------------------------------------
# state file
#   outputs[ident]  last-known geometry per output, kept even when absent
#   workspaces[ws]  live topology (monitor name / origin / window count)
#   home[ws]        output identity the workspace BELONGS to (for `restore`)
#   frame[ws]       [x,y] global-logical origin the ws's window `at` coords are
#                   currently expressed relative to — the single source of truth
#                   for "does this workspace need re-anchoring?"
# --------------------------------------------------------------------------
def _load_state():
    try:
        with open(_STATE) as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _write_state(d):
    _ensure_cache()
    d["_ts"] = round(time.time(), 3)
    tmp = _STATE + ".tmp.%d" % os.getpid()
    try:
        with open(tmp, "w") as f:
            json.dump(d, f, indent=2)
        os.replace(tmp, _STATE)
    except Exception as e:
        _log("state write failed: %s" % e)
        try:
            os.unlink(tmp)
        except Exception:
            pass


def _set_frame(ws_id, x, y):
    """Record that ws `ws_id`'s window coordinates are now relative to (x, y).
    Called by sync/restore right after a re-anchor (they already hold the lock)."""
    st = _load_state()
    st.setdefault("frame", {})[str(ws_id)] = [int(x), int(y)]
    _write_state(st)


def _snapshot(force=False, update_home=True):
    """Record the live topology. `outputs` is MERGED — an absent output keeps its
    last-known geometry (flagged present=False) so sync/restore know the frame of
    an unplugged monitor. `home`/`frame` are updated to the live monitor ONLY for
    an *organic* placement: skipped for any workspace whose recorded home output
    is currently absent (that ws is displaced; sync/restore own it)."""
    prev = _load_state()
    if not force and prev.get("_ts") and time.time() - prev["_ts"] < _SNAP_DEBOUNCE:
        return prev

    mons = _monitors()
    live_idents = {_identity(m) for m in mons}
    by_name = {m["name"]: m for m in mons}

    outputs = dict(prev.get("outputs", {}))
    for m in mons:
        lw, lh = _logical_size(m)
        outputs[_identity(m)] = {
            "name": m["name"],
            "description": m.get("description", ""),
            "x": m.get("x", 0), "y": m.get("y", 0),
            "scale": m.get("scale", 1.0),
            "logical_w": round(lw), "logical_h": round(lh),
            "mode": "%dx%d@%.2f" % (m.get("width", 0), m.get("height", 0),
                                    m.get("refreshRate", 0.0)),
            "transform": m.get("transform", 0),
            "present": True,
        }
    for ident, o in outputs.items():
        if ident not in live_idents:
            o["present"] = False

    workspaces = {}
    home = dict(prev.get("home", {}))
    frame = dict(prev.get("frame", {}))
    for w in _workspaces():
        if w.get("id", 0) <= 0:
            continue
        mon = by_name.get(w.get("monitor"))
        if not mon:
            continue
        wid = str(w["id"])
        ident = _identity(mon)
        workspaces[wid] = {
            "monitor_name": mon["name"],
            "monitor_identity": ident,
            "monitor_x": mon.get("x", 0),
            "monitor_y": mon.get("y", 0),
            "windows": w.get("windows", 0),
        }
        displaced = home.get(wid) and home[wid] not in live_idents
        if update_home and not displaced:
            home[wid] = ident                       # organic -> new home
            frame[wid] = [mon.get("x", 0), mon.get("y", 0)]

    _write_state({"outputs": outputs, "workspaces": workspaces,
                  "home": home, "frame": frame})
    return _load_state()


# --------------------------------------------------------------------------
# the two hotplug reactions
# --------------------------------------------------------------------------
def _frame_of(state, wid, fallback_xy):
    fr = state.get("frame", {}).get(str(wid))
    if isinstance(fr, list) and len(fr) == 2:
        return int(fr[0]), int(fr[1])
    return int(fallback_xy[0]), int(fallback_xy[1])


def _sync():
    """A monitor was removed. Make every workspace reachable and its camera
    frame consistent with the monitor it now sits on. Hyprland has already
    relocated the workspace and translated its windows; we only realign
    `camera.json`. Idempotent — `frame[ws]` records the last origin handled."""
    time.sleep(0.25)                       # let Hyprland finish relocating
    state = _load_state()
    mons = _monitors()
    if not mons:
        _log("sync: no monitors present, nothing to do")
        return
    present = {m["name"]: m for m in mons}
    survivor = _pick_survivor(mons)
    touched = 0

    for w in _workspaces():
        wid = w.get("id", 0)
        if wid <= 0:
            continue
        cur_mon = present.get(w.get("monitor"))

        if cur_mon is None:                # Hyprland has not relocated it — do so
            if not survivor:
                continue
            if _move_workspace(wid, survivor["name"]):
                _log("sync: ws %s orphaned on '%s' -> '%s'"
                     % (wid, w.get("monitor"), survivor["name"]))
                cur_mon = survivor
            else:
                continue

        mx, my = cur_mon.get("x", 0), cur_mon.get("y", 0)
        fx, fy = _frame_of(state, wid, (mx, my))
        if (mx - fx) or (my - fy):
            _recam(wid, mx - fx, my - fy)
            _set_frame(wid, mx, my)
            touched += 1

    _log("sync: done (%d workspace(s) realigned)" % touched)
    _snapshot(force=True, update_home=False)


def _restore():
    """A monitor was (re)connected. If it is the saved HOME of a workspace that
    currently sits elsewhere, move it back (Hyprland translates the windows) and
    realign that workspace's camera frame."""
    time.sleep(0.4)                        # let the output come fully up
    state = _load_state()
    mons = _monitors()
    present = {m["name"]: m for m in mons}
    present_by_ident = {_identity(m): m for m in mons}
    moved = 0

    for wid_s, home_ident in dict(state.get("home", {})).items():
        wid = int(wid_s)
        target = present_by_ident.get(home_ident)
        if target is None:
            continue                       # this ws's home output is still absent

        cur = next((w for w in _workspaces() if w.get("id") == wid), None)
        if cur is None:
            continue                       # workspace gone — nothing to do
        cur_mon = present.get(cur.get("monitor"))
        if cur_mon is None or cur_mon["name"] == target["name"]:
            continue                       # already home

        cx, cy = cur_mon.get("x", 0), cur_mon.get("y", 0)
        if not _move_workspace(wid, target["name"]):
            continue
        tx, ty = target.get("x", 0), target.get("y", 0)
        _log("restore: ws %s -> '%s' (home output is back)" % (wid, target["name"]))
        _recam(wid, tx - cx, ty - cy)
        _set_frame(wid, tx, ty)
        moved += 1

    _log("restore: done (%d workspace(s) returned)" % moved)
    _snapshot(force=True, update_home=False)


def _status():
    mons = _monitors()
    live = {m["name"] for m in mons}
    st = _load_state()
    out = {
        "monitors": [
            {"name": m["name"], "identity": _identity(m),
             "x": m.get("x"), "y": m.get("y"), "scale": m.get("scale"),
             "logical": [round(v) for v in _logical_size(m)],
             "mode": "%dx%d@%.2f" % (m.get("width", 0), m.get("height", 0),
                                     m.get("refreshRate", 0.0)),
             "focused": bool(m.get("focused")),
             "activeWorkspace": (m.get("activeWorkspace") or {}).get("id")}
            for m in mons
        ],
        "workspaces": [
            {"id": w["id"], "monitor": w.get("monitor"),
             "windows": w.get("windows", 0),
             "reachable": w.get("monitor") in live,
             "home": st.get("home", {}).get(str(w["id"]))}
            for w in _workspaces() if w.get("id", 0) > 0
        ],
        "camera": world.read_camera(),
        "state_file": _STATE if os.path.exists(_STATE) else None,
    }
    print(json.dumps(out, indent=2))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        _status()
        return 0
    with _Lock():
        if cmd == "sync":
            _sync()
        elif cmd == "restore":
            _restore()
        elif cmd == "snapshot":
            _snapshot(force="--force" in sys.argv)
        else:
            print("usage: display_manager.py {sync|restore|snapshot|status}",
                  file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
