# Infinite Desktop — technical documentation

Infinite Desktop turns a Hyprland session into an "infinite" canvas: all floating
windows on the active workspace can be panned together with the mouse, navigated
with the keyboard, and moved/resized without touching the mouse. It is a
self-contained component of this repository and does not depend on the rest of
the Gentoo/Hyprland workstation configuration.

This document records **why the component is built the way it is**, the Hyprland
API break that forced the current design, and exactly which parts of that API
are confirmed versus still unverified. It supersedes the older `LEEME.md` that
used to ship inside `scripts/files.zip` (parts of which are now obsolete — see
[History](#6-history-and-obsolete-notes)).

---

## 1. What it does

| Action | Default bind | Script |
| --- | --- | --- |
| Pan the whole floating canvas | hold `SUPER + ALT` + move mouse | `infinite_desktop_core.py` |
| Drag one window; push the rest at the screen edge | hold `SUPER` + left-drag | `infinite_desktop_core.py` |
| Navigate / focus the next window | `SUPER + ←/→/↑/↓` | `navigate_windows.py` |
| Move the active floating window (repeatable) | `SUPER + SHIFT + ←/→/↑/↓` | `move_window.py` |
| Move a tiled window (repeatable) | `SUPER + ALT + ←/→/↑/↓` | `move_window_tiled.py` |
| Resize the active window (repeatable) | `SUPER + CTRL + ←/→/↑/↓` | `resize_window.py` |
| Toggle floating/tiled for all windows on the workspace | `SUPER + D` | `floating_tile_toggle.py` |
| Previous / next workspace | `SUPER + Z` / `SUPER + X` | native `hl.dsp.focus` |
| Move window to previous / next workspace | `SUPER + SHIFT + Z/X` | native `hl.dsp.window.move` |

The installer remaps any bind whose key combination is already taken in
`hyprland.lua` (fallback ladders such as `Z → COMMA → MINUS → F13`), so the
exact keys can differ from the table above on a given machine.

---

## 2. Architecture

```
/dev/input/event*  ──►  infinite_desktop_core.py  ──►  hypr_ipc.py  ──►  hyprctl  ──►  Hyprland
   (evdev)               (daemon, autostarted)         (compat layer)
                                │
                                └──►  qs ipc call frame …   (optional Quickshell frame hint)
```

### 2.1 Autostart

Hyprland starts the daemon on session start:

```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("python3 ~/scripts/infinite_desktop_core.py 1.6 > /tmp/infinite-desktop.log 2>&1")
end)
```

`infinite_desktop_core.py` reads **only `sys.argv[1]`** — a floating-point
**pan-speed multiplier** (`1.6` above; default `1.0`). It takes no device
arguments; devices are auto-detected (see 2.3).

### 2.2 evdev → core

- The daemon opens input devices directly (`/dev/input/event*`), which is why the
  installing user must be in the **`input` group** (`sudo usermod -aG input $USER`,
  effective after re-login).
- A `device_manager` thread rescans for new/reconnected keyboards and mice
  (every 0.5 s for the first 20 s to let wireless dongles finish enumerating,
  then every 3 s). One reader thread is spawned per device; a disconnected
  device's thread ends by itself when `read()` fails.
- `classify_device()` decides *mouse* vs *keyboard* from **evdev capabilities,
  not device names**: a mouse has `REL_X + REL_Y + BTN_LEFT`; a "real" keyboard
  has the full `A…Z` range, `LEFTSHIFT`, and a Meta key (this deliberately
  excludes the "Consumer Control" / "System Control" sub-interfaces that 2.4 GHz
  receivers also expose).
- Reader threads update shared modifier/mouse state under a single
  `threading.Lock`. The main loop (16 ms tick) and a `monitor_window_drag`
  thread consume that state.

### 2.3 core → hypr_ipc → Hyprland

- **Read-only queries** go straight to `hyprctl … -j` (`clients`, `activewindow`,
  `monitors`, `activeworkspace`, `getoption`). These are **not** affected by the
  0.55 dispatch change (section 3) and are used as-is.
- **State-changing calls** are built as Lua expression strings by `hypr_ipc.py`
  and sent with `hyprctl dispatch '<expr>'` or, for bulk window moves,
  `hyprctl --batch 'dispatch <expr> ; dispatch <expr> ; …'` (async, so the pan
  loop never blocks).
- Panning builds one `move_window_exact_lua(x, y, address)` expression per
  floating window and dispatches them in a single batch each tick.

### 2.4 Optional Quickshell integration

When the `SUPER + ALT` pan combo is held, the core calls:

```
qs ipc call frame setHeldHidden true      # on press
qs ipc call frame setHeldHidden false     # on release
```

so a Quickshell shell with an `IpcHandler` named `frame` can hide its frame/border
overlay while the desktop is being dragged. Details:

- The call runs in its own short-lived thread, **outside** the state lock, so it
  never adds latency to input handling.
- It is wrapped in a bare `except` — if Quickshell is not running (e.g. during a
  reload) the daemon simply carries on.
- State is de-duplicated (`frame_held_hidden`) so the IPC call fires only on an
  actual transition, not on every mouse event.

This is a hint to an external shell and is **entirely optional**: Infinite Desktop
works with no Quickshell running.

---

## 3. Why `hypr_ipc.py` exists — the Hyprland 0.55 API break

### 3.1 What changed

Up to Hyprland 0.54, dispatchers used positional hyprlang syntax:

```
hyprctl dispatch togglefloating address:0x123
hyprctl dispatch movewindowpixel exact 100 100,address:0x123
```

From **Hyprland 0.55** (Lua configuration), `hyprctl dispatch` **parses its
argument as a real Lua expression** and evaluates it against the `hl.dsp.*`
namespace:

```
hyprctl dispatch 'hl.dsp.window.float({ action = "toggle", window = "address:0x123" })'
```

The old positional form no longer works, and there is **no backwards-compatibility
shim**. When this was reported upstream, the Hyprland maintainer (vaxerski)
answered that it is **expected behavior**.
Reference: `github.com/hyprwm/Hyprland/discussions/14255`
Wiki: `wiki.hypr.land/Configuring/Basics/Dispatchers`

### 3.2 The design response

Every `hyprctl dispatch` call in the component is generated in **one file**,
`scripts/infinite-desktop/hypr_ipc.py`. All the other scripts import it instead of assembling
command strings themselves. This API is `-git` and has changed more than once in
a matter of weeks, so when it changes again only `hypr_ipc.py` needs editing.

`hypr_ipc.py` exposes:

- `hyprctl_json(args)` — read-only `hyprctl … -j`, JSON-decoded.
- `dispatch(expr)` / `dispatch_async(expr)` — one dispatch call.
- `batch(exprs)` / `batch_async(exprs)` — many, via `hyprctl --batch`.
- `*_lua(...)` builders that return the Lua expression string, and thin wrappers
  that dispatch it.

---

## 4. API status

### 4.1 Confirmed — against the official wiki

| Purpose | Lua expression produced by `hypr_ipc.py` |
| --- | --- |
| Toggle floating | `hl.dsp.window.float({ action = "toggle"[, window = "address:ADDR"] })` |
| Focus a window | `hl.dsp.focus({ window = "address:ADDR" })` |
| Move focus by direction | `hl.dsp.focus({ direction = "l"\|"r"\|"u"\|"d" })` |
| Move a tiled window by direction | `hl.dsp.window.move({ direction = "l"\|"r"\|"u"\|"d" })` |
| Run a command | `hl.dsp.exec_cmd("…")` |

### 4.2 Confirmed — by error-probing + live test (2026-07-01)

The wiki does not publish the field name for exact pixel positioning/sizing.
It was found by deliberately firing a wrong call and reading Hyprland's error,
which lists the accepted arguments:

```
$ hyprctl dispatch 'hl.dsp.window.move({ window = "activewindow", coords = {100,100} })'
error: hl.window.move: unrecognized arguments.
       Expected one of: direction, x+y(+relative), workspace, into_group, out_of_group

$ hyprctl dispatch 'hl.dsp.window.resize({ window = "activewindow", x = 100, y = 100 })'
ok      # window resized to 100x100 px, confirmed visually
```

Result — **both** `window.move` and `window.resize` take **loose `x` / `y`
fields** (not a `coords`/`size` table), plus an optional `relative` that
defaults to absolute:

```python
# move to absolute pixel (x, y)
hl.dsp.window.move({ window = "address:ADDR", x = X, y = Y, relative = false })

# resize to absolute W x H  — note: resize reuses the x/y field names for W/H
hl.dsp.window.resize({ window = "address:ADDR", x = W, y = H, relative = false })
```

These are the current bodies of `move_window_exact_lua()` and
`resize_window_exact_lua()` in `scripts/infinite-desktop/hypr_ipc.py`. They replace the old
positional dispatchers `movewindowpixel exact X Y,address:ADDR` and
`resizewindowpixel exact W H,address:ADDR`.

### 4.3 Needs revalidation on Gentoo

The whole `hl.dsp.*` surface is from a fast-moving `-git` branch. **On the
Hyprland version we actually install on Gentoo, the exact-move/-resize field
names must be re-confirmed** before trusting the panning feature. Everything in
4.1 is low-risk (documented on the wiki); everything in 4.2 is the part most
likely to have drifted.

If the field names changed, **only two functions in
`scripts/infinite-desktop/hypr_ipc.py` need editing** —
`move_window_exact_lua()` and `resize_window_exact_lua()` — because
every other script routes exact moves through them.

---

## 5. `discover_hyprland_api.sh`

A diagnostic/probing script. Run it once, with **a floating window focused**:

```bash
bash ~/scripts/discover_hyprland_api.sh      # or scripts/infinite-desktop/discover_hyprland_api.sh from the repo
```

> **Warning:** this is not read-only. During its probes it actually moves the
> focused floating window to `(100, 100)` and resizes it to `800×600`. It only
> touches that one window and makes no permanent changes, but reposition the
> window afterwards if needed.

It:

1. prints `hyprctl version`;
2. lists the real method names under `hl.dsp.window.*` in the running Hyprland
   (`hyprctl repl 'for k in pairs(hl.dsp.window) …'`);
3. tries to move the focused window to `(100, 100)` and resize it to `800×600`,
   printing Hyprland's exact response;
4. on failure, prints 2–3 alternative field spellings to try by hand
   (`x`/`y` loose, `coords = {x=…, y=…}`, `position = {…}`, …).

> Note: the script's *first* probe still uses the historical
> `coords = {…}, mode = "exact"` spelling (see section 6). That is intentional —
> it is a probe that is *expected* to be able to fail and then suggest the
> working form. The value confirmed in 4.2 is `x`/`y`/`relative=false`.

Once the working spelling is known, edit only the two functions named in 4.3.

---

## 6. History and obsolete notes

- `scripts/files.zip` was an **older snapshot bundle** ("Add files via upload",
  commit `7436233`), removed in the cleanup commit that followed this document.
  Every script inside it was identical to, older than, or a superseded guess
  relative to the tracked `scripts/`. Its `hypr_ipc.py` and its `LEEME.md` still
  described the exact-move syntax as an **unconfirmed guess**:

  ```python
  # OBSOLETE — do not use
  hl.dsp.window.move({ window = "address:ADDR", coords = { X, Y }, mode = "exact" })
  hl.dsp.window.resize({ window = "address:ADDR", size = { W, H }, mode = "exact" })
  ```

  This was wrong: Hyprland rejects `coords`/`mode` (section 4.2). The tracked
  `scripts/infinite-desktop/hypr_ipc.py` already carries the corrected form. The
  bundle's contents remain recoverable from git history (`git show 7436233`).

- `scripts/infinite-desktop.sh` — a single file, not to be confused with the
  current `scripts/infinite-desktop/` directory — was a **legacy launcher**,
  removed in the same cleanup commit (recoverable from git history). It detected a keyboard and a
  mouse by `/sys/class/input/*/device/name` string matching and then ran
  `infinite_desktop_core.py "$KBD_DEV" "$MOUSE_DEV" "$SPEED"` — the old 3-argument
  convention. The current core auto-detects devices and reads only a speed
  argument, so passing a device path as `argv[1]` would raise `ValueError`.
  Nothing called it (autostart runs the core directly).

- The detailed rationale in this document was reconstructed from the
  `LEEME.md` inside `scripts/files.zip` and the docstring of
  `scripts/hypr_ipc.py`, both as they stood at commit `7436233` (the docstring
  was later trimmed by `c2174db` and `de31547`), plus the current implementation.

---

## 7. Files

All of these live in `scripts/infinite-desktop/` in the repository. The installer
copies them **flat** into `~/scripts/`, which is why the Hyprland binds and the
autostart line refer to `~/scripts/<name>` and the scripts locate each other with
`os.path.dirname(__file__)` rather than a fixed path.

| File (under `scripts/infinite-desktop/`) | Role |
| --- | --- |
| `infinite_desktop_core.py` | evdev daemon: panning, edge-push drag, keyboard move, Quickshell hint |
| `hypr_ipc.py` | the only place `hyprctl` calls are built; Hyprland-version compat layer |
| `navigate_windows.py` | `SUPER + arrows` — focus/center the next window (floating vs master vs dwindle) |
| `move_window.py` | `SUPER + SHIFT + arrows` — move the active floating window, push others at the edge |
| `move_window_tiled.py` | `SUPER + ALT + arrows` — move a tiled window (delegates to `move_window.py` when floating) |
| `resize_window.py` | `SUPER + CTRL + arrows` — resize the active floating window |
| `floating_tile_toggle.py` | `SUPER + D` — toggle floating/tiled for the whole workspace, remembering geometry |
| `discover_hyprland_api.sh` | diagnostic/probing script for the `hl.dsp.window.*` API — moves/resizes the focused window (section 5) |
