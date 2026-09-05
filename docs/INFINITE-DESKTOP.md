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
| Pan the whole floating canvas | hold `SUPER + ALT` + move the mouse or drag one finger on the touchpad | `infinite_desktop_core.py` |
| Drag one window; push the rest at the screen edge | hold `SUPER` + left-drag | `infinite_desktop_core.py` |
| Navigate / focus the next window | `SUPER + ←/→/↑/↓` | `navigate_windows.py` |
| Move the active floating window (repeatable) | `SUPER + SHIFT + ←/→/↑/↓` | `move_window.py` |
| Move a tiled window (repeatable) | `SUPER + ALT + ←/→/↑/↓` | `move_window_tiled.py` |
| Resize the active window (repeatable) | `SUPER + CTRL + ←/→/↑/↓` | `resize_window.py` |
| Toggle floating/tiled for all windows on the workspace | `SUPER + D` | `floating_tile_toggle.py` |
| Previous / next workspace | `SUPER + Z` / `SUPER + X` | native `hl.dsp.focus` |
| Move window to previous / next workspace | `SUPER + SHIFT + Z/X` | native `hl.dsp.window.move` |

These binds are **declarative**: `config/hypr/lua/infinite-desktop.lua` (linked
into place by `install.sh dotfiles --apply`) is the single seam between Infinite
Desktop and the Hyprland config. It is loaded last and `hl.unbind`s the four
`SUPER + arrow` "move focus" binds from `lua/bindings.lua` before rebinding them
to `navigate_windows.py` — the only overlap, resolved explicitly. Everything
else is on keys `lua/bindings.lua` does not use.

The old approach — an installer that parsed `hyprland.lua` and remapped
colliding binds through fallback ladders (`Z → COMMA → MINUS → F13`) — is gone.
`install.sh infinite-desktop` no longer touches the Hyprland config at all.

---

## 2. Architecture

```
/dev/input/event*  ──►  infinite_desktop_core.py  ──►  hypr_ipc.py  ──►  hyprctl  ──►  Hyprland
   (evdev)               (daemon, autostarted)         (compat layer)
                                │
                                └──►  qs ipc call frame …   (optional Quickshell frame hint)
```

### 2.1 Autostart

`config/hypr/lua/infinite-desktop.lua` starts the daemon on session start:

```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("python3 ~/scripts/infinite_desktop_core.py 1.6 > /tmp/infinite-desktop.log 2>&1")
end)
```

`infinite_desktop_core.py` reads **only `sys.argv[1]`** — a floating-point
**pan-speed multiplier** (`1.6` above; default `1.0`). It takes no device
arguments; devices are auto-detected (see 2.3).

### 2.2 evdev → core

- The daemon opens input devices directly (`/dev/input/event*`, read-only — it
  does **not** `grab()` them). Access is granted by **`install.sh input`**, not
  the `input` group — see [Input device access](#26-input-device-access) below.
- A `device_manager` thread rescans for new/reconnected keyboards, mice **and
  touchpads** (every 0.5 s for the first 20 s to let wireless dongles finish
  enumerating, then every 3 s). One reader thread is spawned per device, keyed
  by path so a device is never double-read; a disconnected device's thread ends
  by itself when the read fails.
- `classify_device()` decides *mouse* vs *touchpad* vs *keyboard* from **evdev
  capabilities + input properties, not device names or node numbers**:
  - **mouse** — `REL_X + REL_Y + BTN_LEFT` (unchanged).
  - **touchpad** — an absolute X/Y pair (`ABS_MT_POSITION_X/Y`, or `ABS_X/Y` as
    a fallback) **and** `INPUT_PROP_POINTER` **and not** `INPUT_PROP_DIRECT`
    (that last exclusion keeps a touchscreen or a graphics tablet from being
    treated as a touchpad) **and** `BTN_TOUCH`.
  - **keyboard** — the full `A…Z` range, `LEFTSHIFT` and a Meta key (excludes
    the "Consumer Control" / "System Control" sub-interfaces 2.4 GHz receivers
    also expose).
- A **touchpad reports finger position, not motion.** `touchpad_reader_device()`
  feeds events to `abs_delta.AbsDeltaTracker` (a pure, unit-tested transform),
  which returns the per-`SYN_REPORT` change in position in device units; the
  reader scales that to pixels with the axis' own `AbsInfo.resolution`
  (units/mm) and two model-independent constants (`TOUCHPAD_PIXELS_PER_MM`,
  `TOUCHPAD_FALLBACK_UNITS_PER_MM`), then accumulates into the **same
  `acc_x`/`acc_y`** the REL-mouse path uses, under the same lock and the same
  `Super+Alt` gate. The first sample of each contact only sets a baseline (no
  jump on finger-down); a finger lift resets it (a new contact never inherits
  the old position); 2+ fingers are ignored (scroll/palm); a per-frame delta
  larger than half the axis range is dropped (slot-switch guard). Details and
  the synthetic tests: `abs_delta.py` / `test_abs_delta.py`.
- Reader threads update shared modifier / pointer state under a single
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

### 2.6 Input device access

The daemon reads `/dev/input/event*` directly (keyboards for Super/Alt/Ctrl
state, a REL mouse **or** an ABS/ABS_MT touchpad for pointer motion +
`BTN_LEFT`). By default those nodes are `crw-rw---- root input`, so a normal
user cannot open them and the daemon sits idle — it now prints a clear
diagnostic and points at `install.sh input` when that happens
(`evdev.list_devices()` silently hides nodes it cannot read, so the daemon also
scans `/dev/input/event*` itself to notice them).

**The model is a udev `uaccess` rule, not the `input` group.**
`config/udev/72-hypr-infinite-input.rules` tags keyboard, mouse **and touchpad**
event nodes with `TAG+="uaccess"`; systemd-logind then grants a POSIX ACL
(`user:<you>:rw`) on them **only to the user owning the currently active local
session on the seat**, and drops it when that session is no longer active or
ends. It is not an account-wide grant and never applies to SSH / remote
sessions.

| | `input` group | this repo: udev `uaccess` |
| --- | --- | --- |
| scope in time | permanent, until removed + re-login | only while your session is the active one |
| scope by session | every session incl. TTY / SSH | active local seat session only |
| devices | all input devices, present and future | keyboards + mice + touchpads only |
| revert | `gpasswd -d`, then re-login | `rm` the rule + `udevadm` reload/trigger |

Install it with:

```bash
sudo ./install.sh input --apply      # or: ./install.sh input   (plan only)
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=input --action=change
getfacl /dev/input/event* | grep "user:$(id -un)"   # verify the ACL is there
```

On the machine this was developed on (Lenovo 82SC — see [§ 2.7](#27-validated-on-real-hardware))
the `reload` + `trigger` applied the ACL to the already-existing event nodes
**immediately, with no logout**, and the running daemon picked the devices up on
its next rescan. That is not guaranteed everywhere: **if `getfacl` shows no
`user:<you>` entry after the trigger, log out and back in (or reboot)** — that
always works.

`install.sh input` follows the same root policy as `install.sh gpu` /
`install.sh power`: read-only by default, and under `--apply` it detects,
explains, shows the exact file and asks before writing. Run as a normal user it
does **not** attempt a doomed write — it prints the exact privileged commands
and exits. It never runs `sudo`, `udevadm` or `usermod`. `INPUT_SYSROOT=<dir>`
redirects the write for testing the whole flow without touching `/etc`.

**Risk — read this.** A `uaccess` ACL on keyboard nodes means **any process
running in your active graphical session can read every keystroke** (passwords
included), plus every touchpad/mouse motion, for as long as that session is
active. This is inherent to any evdev consumer that is not a privileged broker;
`uaccess` bounds the exposure to the active local session but does not remove
it.

**Stricter alternative (not implemented).** The exposure can be removed
entirely by splitting the daemon: a tiny privileged *reader* unit (a
hard-sandboxed systemd service — `ProtectSystem=strict`, `PrivateNetwork=yes`,
`SystemCallFilter=`, `NoNewPrivileges=`) that opens the evdev nodes and
publishes only the distilled state (three modifier booleans + mouse deltas +
`BTN_LEFT`) over a unix socket in `$XDG_RUNTIME_DIR`; the in-session daemon
consumes that and never opens `/dev/input`. This adds a second process, an IPC
protocol and new failure modes to a component that must not break Infinite
Desktop, Quickshell or the current binds, so it is deliberately left as a future
option rather than the default.

### 2.7 Validated on real hardware

End-to-end, on real hardware, on **Lenovo 82SC** (Ideapad, AMD; `profiles/lenovo-82sc/`):

- **Touchpad:** `MSFT0001:00 06CB:CE78 Touchpad` — a Windows **Precision
  Touchpad** driven by `hid-multitouch`, exposing a dual node (a relative
  "Mouse" node that stays silent in PTP mode, and this absolute `ABS_MT` node).
  `classify_device()` tags it `touchpad`; `touchpad_reader_device()` +
  `abs_delta.AbsDeltaTracker` turn its `ABS_MT_POSITION_X/Y` frames into pixel
  deltas.
- **uaccess:** the udev rule's `ID_INPUT_TOUCHPAD` line gave the touchpad node
  `user:<you>:rw` via logind; `udevadm control --reload && udevadm trigger
  --subsystem-match=input --action=change` applied it live, no logout.
- **Result:** with a terminal set floating (`hl.dsp.window.float({ action =
  "toggle" })`), holding `SUPER+ALT` and dragging one finger on the touchpad
  panned the window correctly — so the full **`ABS/ABS_MT` → delta →
  `acc_x`/`acc_y` → `hyprctl` IPC** path works. No `Traceback` / `ERROR` in
  `/tmp/infinite-desktop.log`; the daemon logged `[+] Touchpad detectado`
  alongside the two keyboards and the pointing-stick "Mouse" node.
- **REL mouse:** still supported unchanged — `classify_device()` returns
  `mouse` first (`REL_X + REL_Y + BTN_LEFT`), and `mouse_reader_device()` is
  untouched. Both sources feed the same accumulator.
- **Scope:** Infinite Desktop currently pans **only floating windows** on the
  active workspace. An all-tiled workspace has nothing to pan (the daemon says
  so, rate-limited). Tiled-window behaviour is intentionally unchanged and is a
  separate decision.

Node numbers are not stable — this same laptop enumerated the touchpad as
`event6` on one boot and `event9` on another, and the "Mouse" node as `event5`
then `event8`. Everything matches by `ID_INPUT_*` / evdev capability, never by
node number or device name.

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

- **`patch_hyprland.py`** — a Python script the installer used to emit as a
  heredoc and run against `~/.config/hypr/hyprland.lua`, appending an autostart
  block + 21 keybinds and remapping any that collided with existing binds
  through fallback ladders. Retired: the repo now owns the whole Hyprland config
  (`config/hypr/`), so the integration is declarative
  (`config/hypr/lua/infinite-desktop.lua`) and `install.sh infinite-desktop`
  installs only the runtime scripts. Recoverable from git history.

- The detailed rationale in this document was reconstructed from the
  `LEEME.md` inside `scripts/files.zip` and the docstring of
  `scripts/hypr_ipc.py`, both as they stood at commit `7436233` (the docstring
  was later trimmed by `c2174db` and `de31547`), plus the current implementation.

---

## 7. Files

All of these live in `scripts/infinite-desktop/` in the repository.
`install.sh infinite-desktop` copies the runtime `*.py`/`*.sh` **flat** into
`~/scripts/` (identical files are a no-op; a locally modified one is backed up
via `mv` and replaced only after you confirm; `test_*.py` are **not** copied),
which is why the Hyprland binds and the autostart line refer to `~/scripts/<name>`
and the scripts locate each other with `os.path.dirname(__file__)` rather than a
fixed path. The command does not touch the Hyprland config, install packages, or
run `sudo`/`usermod`.

| File (under `scripts/infinite-desktop/`) | Role |
| --- | --- |
| `infinite_desktop_core.py` | evdev daemon: panning, edge-push drag, keyboard move, Quickshell hint |
| `abs_delta.py` | pure ABS/ABS_MT-position → per-frame relative-delta transform for touchpads (no I/O) |
| `test_abs_delta.py` | synthetic-sequence unit tests for `abs_delta.py` (not deployed) |
| `hypr_ipc.py` | the only place `hyprctl` calls are built; Hyprland-version compat layer |
| `navigate_windows.py` | `SUPER + arrows` — focus/center the next window (floating vs master vs dwindle) |
| `move_window.py` | `SUPER + SHIFT + arrows` — move the active floating window, push others at the edge |
| `move_window_tiled.py` | `SUPER + ALT + arrows` — move a tiled window (delegates to `move_window.py` when floating) |
| `resize_window.py` | `SUPER + CTRL + arrows` — resize the active floating window |
| `floating_tile_toggle.py` | `SUPER + D` — toggle floating/tiled for the whole workspace, remembering geometry |
| `discover_hyprland_api.sh` | diagnostic/probing script for the `hl.dsp.window.*` API — moves/resizes the focused window (section 5) |
