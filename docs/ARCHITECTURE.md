# Architecture (work in progress)

A reproducible, modular Gentoo + Hyprland workstation configuration. This
document is an initial sketch and grows with the implementation.

## Repository layout

```
install.sh                     entrypoint / thin dispatcher
install/
  common.sh                    bootstrap: repo root, libs, command registry, dispatch
  cmd/<name>.sh                one file per subcommand
  packages.gentoo              Gentoo package catalogue (data)
  dotfiles.manifest            which repo files are symlinked where (data)
lib/
  log.sh  ui.sh                logging + presentational helpers
  hardware.sh                  read-only hardware detection (PCI/sysfs, no cardN;
                                also CPU core count and RAM size, for kernel-dev)
  portage.sh                   read-only Portage / overlay / catalogue helpers
  nvidia.sh                    read-only, power-aware NVIDIA observation (no-wake)
  profile.sh                   read-only machine-profile detection/validation
  session.sh                   read-only user-session inspection (units, D-Bus,
                                USE flags, fonts) — TTY-safe, timeout-guarded
  backup.sh  symlink.sh        safe, non-destructive dotfile primitives
profiles/
  common/profile.conf          workstation defaults, matches no specific machine
  <machine-id>/profile.conf    DMI-matched, machine-specific expectations (see PROFILES.md)
bin/
  nvidia-offload                PRIME render-offload wrapper
  nvidia-compute-mode           NVIDIA compute-session backend (eco / compute / set-backend)
  nvidia-power-control-helper   the ONE privileged power/control write; NOT installed
                                 anywhere by any --apply flow — see HYBRID-GPU.md
config/
  gpu/                         modprobe.d + udev templates for the hybrid GPU
  udev/                        udev rule granting the Infinite Desktop daemon
                                 session-scoped input-device access (install.sh input)
  hypr/                        modular Hyprland Lua config (see below)
  hypridle/  hyprlock/         idle ladder + lock screen config (see POWER.md)
  logind/                      logind.conf.d drop-in for lid/power-key/idle-action
  mako/                        notification daemon config (linked by dotfiles)
  fuzzel/                      launcher config — fallback only (Super+Shift+Space)
  xdg-desktop-portal/          hyprland-portals.conf: portal backend order (linked by dotfiles)
  polkit/actions/              polkit policy for the helper above; also NOT installed
  quickshell/                  Quickshell shell: floating navbar island (Bar.qml)
                                 + PanelHost.qml (one contextual panel zone:
                                 panels/{Controls,Stats,Notifications}Panel.qml,
                                 panels/WallpaperPicker.qml)
                                 + Launcher.qml (Caelestia-style app launcher)
scripts/
  infinite-desktop/            the Infinite Desktop component (evdev daemon + IPC)
  desktop/                     small desktop helpers + tests: hypr-screenshot,
                                 hypr-wallpaper (static + animated), wallpaper-thumb,
                                 hypr-greeting, hypr-weather (linked to ~/.local/bin)
docs/                          per-topic documentation
```

## Installer

`install.sh` resolves its own location (following symlinks, ignoring the cwd)
and hands off to `install/common.sh`, which registers commands and dispatches to
`install/cmd/<name>.sh`. Read-only commands (`check`, `doctor`, `deps`, and the
plan mode of `gpu` / `dotfiles` / `power` / `input`) never change anything. Commands
that write follow **detect → explain → show the exact change → confirm →
apply**, honour `--dry-run`, never call `sudo` (they print the exact
command), and are idempotent. See [INSTALL.md](INSTALL.md).

`desktop` sits on top of all of them as a pure orchestrator: it calls
`check`/`deps`/`dotfiles`/`gpu`/`power`/`input`/`infinite-desktop`/`doctor` in
sequence, each exactly as `install.sh <cmd>` would run it (including its own
confirmations under `--apply`), and adds no detection or write logic of its
own. `install/cmd/desktop.sh` stops the sequence on the first step that fails
after `deps` (with `doctor` still run at the end as a read-only snapshot),
and keeps `gpu --apply` / `power --apply` / `input --apply` plan-only on a
non-Gentoo host — the steps that write real files under `/etc` are never
applied for real off the Gentoo target.

`profile` sits underneath `check`/`doctor`/`first-run`, not beside them in
the sequence: it detects which `profiles/<id>/` applies to the real machine
by DMI data alone (never the hostname), falling back to `profiles/common/`
with a warning if none match, and validates that profile's hardware
expectations against `lib/hardware.sh` (a mismatch is a warning, never
fatal). It is read-only — there is no `--apply`, since which profile applies
is a detected fact, not a decision to write. See [PROFILES.md](PROFILES.md).

`monitor` and `first-run` are the two commands for what genuinely cannot be
decided without a real Gentoo + Hyprland session: `monitor` reads
`hyprctl -j monitors all` (no live session, no plan — there is nothing real to
plan without one) and writes `~/.config/hypr/monitors.local.lua`; `first-run`
is a guided checklist that reuses `check`/`dotfiles`/`monitor`/`doctor` and
`nvidia-compute-mode` (never re-implementing their detection), adding only a
`wev`-guided XF86-key walkthrough and a guided, reversible NVIDIA
`compute_backend` test. See [FIRST-RUN.md](FIRST-RUN.md).

`full` sits above all of it as the top-level orchestrator, and is itself an
orchestrator of orchestrators, not a third implementation: it calls
`profile` once for context, `desktop` once (which already is check → the
deps gate → dotfiles → gpu → power → input → infinite-desktop → doctor, as
covered above), and `first-run` once — offered, never forced, only inside a live
Hyprland session and only after `desktop` succeeded. The intended sequence
for a brand new machine is:

```
Base Gentoo install (out of scope for this repo)
        |
        v
./install.sh full --apply        (dependencies -> dotfiles -> gpu -> power ->
        |                          Infinite Desktop; stops before any write
        |                          if required packages are missing)
        v
login to Hyprland
        |
        v
./install.sh first-run --apply   (real monitor detection, wev-guided keys,
                                   NVIDIA compute-backend guided test)
```

`full` never starts a Hyprland session itself and never claims the
workstation is fully set up unless first-run was actually run, in that same
invocation, and finished cleanly — see [INSTALL.md](INSTALL.md).

`kernel-dev` is a separate, standalone command — a readiness checker,
source-tree detector and reproducible-command generator for kernel
development on this workstation, not another workstation-bring-up step. It
is deliberately **not** called by `full`: kernel development is a distinct
activity that starts only when you choose it, not something a desktop
bring-up should ever assume you want. It reuses `lib/hardware.sh` (CPU core
count, RAM) and `install/packages.gentoo`'s `kernel-dev` group exactly like
every other command reuses shared detection — no new detection layer. See
[KERNEL-DEVELOPMENT.md](KERNEL-DEVELOPMENT.md).

## Hyprland configuration

Modern Lua config, targeting Hyprland ≥ 0.55. `config/hypr/hyprland.lua` is a
tiny entrypoint that loads ordered modules under `config/hypr/lua/`. Each module
is loaded via **`pcall(require, ...)`**, so a syntax error, runtime error, or
missing file in one module is logged but does not stop the others — verified;
plain `require()` propagates such errors. The individual modules stay
pcall-free.

| module | contents |
| --- | --- |
| `util.lua` | `load_optional()` — loads a machine-local file if present |
| `env.lua` | cursor size; loads `gpu.local.lua` (AQ_DRM_DEVICES) if present |
| `monitors.lua` | generic `output = ""` fallback rule (no `eDP-1`, no resolution); loads `monitors.local.lua` |
| `input.lua` | keyboard + touchpad base, 3-finger workspace swipe |
| `appearance.lua` | gaps / rounding / blur / shadow / animations (static); border + shadow **colours** come from `~/.config/hypr/colors.local.lua` (wallpaper-driven, with a built-in fallback) |
| `bindings.lua` | basic desktop keybinds; `Super+Return` → `$TERMINAL` (falls back to `foot`); **`Super` tap** and `Super+Space` → native Quickshell launcher (`qs ipc call launcher toggle`); `Super+Shift+Space` → `fuzzel` (fallback); `Super+W` → wallpaper picker; `Super+Tab` → World Map (`qs ipc call worldmap toggle`; Alt+Tab is not bound); `Super`+LMB/RMB drag → move/resize the floating window; `Print` / `Super+Print` / `Super+Shift+S` → `hypr-screenshot` (see README "Keybindings"). The `Super` tap is `release = true` on `Super_L`, so it does **not** fire when `Super` was part of a key combo; `lua/window-edit.lua` re-binds it with a guard so a `Super`+mouse drag doesn't fire it either. |
| `floating-world.lua` | the window model — every normal window opens **floating**, smart-sized, placed near the last-focused window (see below). Re-binds `Super+F` → pseudo-maximize; `Super+Shift+F` → real fullscreen. |
| `window-edit.lua` | `Super`+LMB/RMB move/resize coherence: the SUPER-tap-vs-launcher guard, dropping a window's pseudo-max restore state on a hand edit, `Super+M` (Viewport Mosaic), `Super+Alt+Tab` (individual-window nav / mosaic focus cycle), `Super+Alt+1..9` (navbar app groups), `Super+H` (Hand Control toggle). No class names in Lua. Loaded after `floating-world.lua`. |
| `laptop.lua` | XF86 volume/mic/brightness/media keybinds (`wpctl`/`brightnessctl`/`playerctl`) |
| `autostart.lua` | environment import; polkit agent (`hyprpolkitagent.service`, user unit); `mako` (notifications); Quickshell; `hypridle` — each guarded so a reload never double-spawns |
| `infinite-desktop.lua` | Infinite Desktop autostart + keybinds; the only seam to that component. Loaded last; `hl.unbind`s + rebinds `SUPER + arrows`. |

### Machine-local files

Per-entry symlinking keeps `~/.config/hypr/` and `~/.config/hypr/lua/` as real
directories, so generated, git-ignored, per-machine files sit beside the
symlinks and are never managed or deleted by `install.sh dotfiles`:

| file | written by |
| --- | --- |
| `~/.config/hypr/monitors.local.lua` | `install.sh first-run` / `monitor` (panel + real refresh) |
| `~/.config/hypr/gpu.local.lua` | optional, hand-written (see below) |
| `~/.config/hypr/*.local.lua` | optional, hand-written |
| `~/.config/hypr/colors.local.lua` | `hypr-wallpaper` (wallust) or `--seed` (fallback) |
| `~/.config/hypr/hyprlock-colors.local.conf` | `hypr-wallpaper` / `--seed` — `source`d by `hyprlock.conf` |
| `~/.config/hypr/hyprlock-image.local.conf` | `hypr-wallpaper` / `--seed` — `$lock_image` (still wallpaper or cached video frame), `source`d by `hyprlock.conf` |
| `~/.config/hypr/weather.conf` | you, optional — `LOCATION="…"` enables the lock-screen weather line (one opt-in wttr.in call) |
| `~/.config/mako/colors.local` | `hypr-wallpaper` / `--seed` — `include`d by `mako/config` |
| `~/.config/fuzzel/colors.local.ini` | `hypr-wallpaper` / `--seed` — `include`d by `fuzzel.ini` |
| `~/.cache/hyprland-infinitie-desktop/colors.json` | `hypr-wallpaper` / `--seed` — watched by Quickshell `Theme.qml` |
| `~/.cache/hyprland-infinitie-desktop/wallpaper.path` | `hypr-wallpaper` — the still/frame path, for hyprlock + other readers (Quickshell no longer reads it) |
| `~/.cache/hyprland-infinitie-desktop/wallpaper.state` | `hypr-wallpaper` (atomic temp+rename) — the one source of truth Quickshell reads: `type`/`path`(video)/`palette_source`(still)/`backend`/`pid`/`prev_pid`/`gen` |
| `~/.cache/hyprland-infinitie-desktop/wallpaper-{frames,thumbs}/` | `hypr-wallpaper` / `wallpaper-thumb` — cached video frames |

### Quickshell shell layout

`Bar.qml` is a **floating navbar island** — one `PanelWindow` per monitor,
anchored to the top edge only (so wlr-layer-shell centres it), ~48 % of the
monitor width (capped), ~28 px tall, rounded, translucent, **no exclusive
zone** (it floats over windows, like the reference rice). Contents are
deliberately minimal: four panel buttons + workspace indicators + the Viewport
Mosaic indicator (`modules/MosaicButton.qml`) (left), the **World Map ring**
(centre — the entry to the minimap, `modules/WorldButton.qml`), and open-app
icons (`modules/OpenApps.qml`) · network · audio · battery · clock (right).

`shell.qml` owns one string, `panel`
(`"" | controls | stats | notifications | wallpapers`).
`PanelHost.qml` is a single full-screen transparent overlay window that renders
whichever `panels/*Panel.qml` is selected, docked just under the island.
`HyprlandFocusGrab` closes it on click-outside / Escape (`keyboardFocus:
OnDemand`, so mouse-only panels are unaffected and `WallpaperPicker` can take
arrow keys / type-to-filter once clicked); a navbar button toggles it
(`qs ipc call panel toggle <name>`; the legacy `dashboard` target still maps to
`controls`). CPU / MEM / NVIDIA live in `StatsPanel` now, not the navbar;
`ControlsPanel` is the former `Dashboard.qml`.

`Launcher.qml` is separate — a **centred floating overlay**, not docked, with
exclusive keyboard focus and its own `quickshell:launcher` blur layer. It lists
apps from `DesktopEntries` (real icons, fuzzy search) and launches via
`Quickshell.execDetached`. `Super` tap / `Super+Space` toggle it
(`qs ipc call launcher toggle`); fuzzel is only the `Super+Shift+Space` fallback.

`WorldMap.qml` is likewise a separate overlay — the Infinite Desktop minimap,
toggled by the navbar's centre ring or `Super+Tab` (`worldmap` `IpcHandler`).
See [Infinite Navigation](#infinite-navigation--the-world-map).

`OpenAppsModel.qml` is a **singleton** — the single source of the navbar's
open-app list, so `modules/OpenApps.qml` (mouse) and the `openapps` `IpcHandler`
(`Super+Alt` keys) navigate the exact same groups in the same order.

### Wallpaper-driven theming

`hypr-wallpaper <file>` handles **static images** (jpg/jpeg/png/webp — drawn by
Quickshell `Wallpaper.qml`) and **animated wallpapers** (gif/mp4/webm/mkv —
played by `mpvpaper`). For a video it extracts a representative frame with
`ffmpeg`; wallust (`x11-misc/wallust`, guru) then derives the palette from that
frame (or from the image, for a static wallpaper).

**Two halves so it never looks frozen.** Under an `flock` (rapid clicks
serialise, newest wins) `hypr-wallpaper` writes `wallpaper.state` atomically
and nudges Quickshell — the *visual* change. Then, off the hot path, wallust
regenerates the palette; a `gen=` stamp lets a superseded run bow out.
`wallpaper.state` is the single source Quickshell reads (parsed in one pass, so
`type` / still / video path are always consistent).

**The diagonal wipe is one implementation for every transition** —
static↔static, static↔animated, animated↔animated.
`DiagonalWallpaperTransition.qml` renders the incoming still (image, or the
video frame) revealed through an animated ~45° mask — a `MultiEffect` whose
`maskThresholdMin` walks a corner-to-corner alpha gradient — sweeping from the
**top-right corner to the bottom-left** over `Theme.wallpaperTransitionDuration`
(800 ms, InOutCubic). No opacity mixing, no black gap. `Wallpaper.qml` sits on
`WlrLayer.Bottom` (always above mpvpaper, which is on `Background`), keeps **two
Image buffers with explicit per-buffer path tracking** (so switching back to a
previously-loaded wallpaper never stalls — `Image.source` equality is never the
sync mechanism), and drives the overlay. Rapid switches let the in-flight wipe
finish, skip intermediates, converge on the newest.

**mpvpaper lifecycle is Quickshell-timed.** While `qs` runs, `hypr-wallpaper`
does *not* start/stop mpvpaper — it records the target and the previous pid.
Quickshell starts the new one (`hypr-wallpaper --spawn-mpvpaper <video>`) as the
wipe covers the screen, waits `Theme.wallpaperAnimatedGrace` for it to present,
retires the old one by pid, dissolves the frame overlay into the live video,
then `hypr-wallpaper --reap` kills any mpvpaper carrying our launch signature
that is not the one in `wallpaper.state` — the "exactly 0 or 1 mpvpaper"
guarantee (never a blind `pkill`). `hypr-wallpaper` keeps a long safety-net
kill of the previous pid for the `qs`-not-running case. One dark scheme
(`palette = "harddark"`) keeps panels dark whatever the wallpaper's hue.
Regression test: `scripts/desktop/test_wallpaper_transition.sh`.

`panels/WallpaperPicker.qml` is the visual selector (grid of thumbnails from
`hypr-wallpaper --list-json`, which walks `<Pictures>/Wallpapers` recursively).
Applying always shells out to `hypr-wallpaper <path>` — no wallpaper logic is
duplicated in QML. `Super+W` or the navbar wallpaper button opens it.

`config/quickshell/Theme.qml` is **structure + a resolver**: geometry, type and
glyphs are static; colours come from `colors.json` via a watched `FileView` +
`JsonAdapter` and are mapped onto semantic tokens (`background`, `surface`,
`surfaceElevated`, `foreground`, `foregroundMuted`, `accent`, `accentSoft`,
`accentSecondary`, `positive`, `urgent`, `border`, …). Every token has a
baked-in fallback equal to `config/wallust/fallback/colors.json`, so Quickshell
starts fine with no palette. `hypr-wallpaper --seed` (run once per fresh
session by `autostart.lua`) copies that fallback into every target so the
`include` / `source` lines in the mako / fuzzel / hyprlock configs always
resolve. `hypr-wallpaper --reset` returns to the fallback and drops the image.

The relevant module loads its `*.local.lua` after its own defaults, so the
local file wins. `gpu.local.lua` specifically is never generated by anything
today: `install.sh gpu` only *prints* the `hl.env("AQ_DRM_DEVICES", ...)`
line for you to copy in by hand if you ever need to override the default —
without one, Aquamarine already auto-selects the `boot_vga` GPU (AMD on this
laptop), which is the desired result anyway.

## Dotfiles model

`install/dotfiles.manifest` lists `base | source | dest` entries. `install.sh
dotfiles` links each **file** individually (never a whole directory), backing up
anything pre-existing via a `mv` (never `rm`) before replacing it, and only
after confirmation. See [the dotfiles section of INSTALL.md](INSTALL.md).

## Hybrid GPU

AMD iGPU is the compositor GPU; the NVIDIA dGPU is on-demand (render offload via
`bin/nvidia-offload`, or CUDA directly). RTD3 power management, the ECO/COMPUTE
policy (`bin/nvidia-compute-mode`), and the permanent config are covered in
[HYBRID-GPU.md](HYBRID-GPU.md).

## Power: idle, lock, suspend, lid

Every power event has exactly one owner — `hypridle` (idle timers, locking,
DPMS, suspend-by-inactivity) or `logind` (lid switch, power key, idle-action),
never both. `install.sh power` writes the one file that needs root
(`config/logind/50-hyprland-infinite-desktop.conf`, a `logind.conf.d`
drop-in); `hypridle.conf` / `hyprlock.conf` need no privilege and are linked
by `dotfiles` like every other managed config. Full matrix and reasoning in
[POWER.md](POWER.md).

## Session services

User-session services the desktop needs, all `required` in
`install/packages.gentoo`, all reported by `doctor`. The autostarted ones are
started guarded (no double-spawn) by `lua/autostart.lua`. Full narrative in
[SESSION.md](SESSION.md).

| service | package(s) | how it starts | notes |
| --- | --- | --- | --- |
| notifications | `gui-apps/mako` | `mako` as a guarded bare process; also D-Bus-activatable | owns `org.freedesktop.Notifications`; config `config/mako/config` linked by `dotfiles` |
| battery / power | `sys-power/upower` | D-Bus system activation (on first query) | backs Quickshell `modules/Battery.qml`; `upower.service` idle until queried is normal |
| polkit agent | `sys-auth/hyprpolkitagent` | `systemctl --user start hyprpolkitagent.service` | renders `pkexec` prompts. Replaces a manual `polkit-gnome`/`-kde` agent — this repo never depends on one. `systemctl --user daemon-reload` (or re-login) after first install. |
| portals | `xdg-desktop-portal` + `-hyprland` + `-gtk` | D-Bus-activated; `xdg-desktop-portal-hyprland.service` is socket/bus-activated | screen sharing (Firefox/Chromium/OBS/…) + file pickers. Backend order pinned by `config/xdg-desktop-portal/hyprland-portals.conf` (linked by `dotfiles`). |
| audio | `media-video/pipewire` + `wireplumber` | **socket units, NOT enabled by this repo** — `systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service` | `first-run --apply` offers to run it; `doctor` prints the command. `pipewire-pulse.socket` = the PulseAudio API most apps use. |

Also session-scoped: `lua/env.lua` sets `XDG_CURRENT_DESKTOP` /
`XDG_SESSION_DESKTOP` / `XDG_SESSION_TYPE`; `gui-wm/hyprland` needs
`USE="X systemd dbus-session"` (profile defaults on `desktop/systemd`) for
Xwayland + user-session integration. `doctor` has *Session environment*,
*Xwayland*, *Desktop portals*, *Audio session*, *Idle / lock*, *logind
drop-in*, *Fonts* and *Dotfile integrity* sections — all read-only, all
degrade cleanly from a TTY with no session bus.

## Desktop utilities

The `desktop-utils` group in `install/packages.gentoo` (all `required`):
`gui-apps/fuzzel` (launcher, `guru` overlay — needs a per-package `~amd64`
keyword, which `deps` prints), `gui-apps/wl-clipboard`, `gui-apps/grim`,
`gui-apps/slurp`. `x11-libs/libnotify` (`recommended`) gives `notify-send`.

- **Launcher** — the native Quickshell `config/quickshell/Launcher.qml`
  (Caelestia-style: centred overlay, real `.desktop` icons, fuzzy search),
  toggled by a `Super` tap or `Super+Space`. `fuzzel` stays installed as the
  `Super+Shift+Space` fallback (config `config/fuzzel/fuzzel.ini`, linked by
  `dotfiles`) in case Quickshell is not running.
- **Wallpapers** — `scripts/desktop/hypr-wallpaper <file>` sets a static image
  (Quickshell) or a video/GIF (`mpvpaper`), derives the palette from the image
  or a `ffmpeg`-extracted frame, and stores one state file. Visual picker:
  `config/quickshell/panels/WallpaperPicker.qml` (`Super+W`). Library:
  `$HYPR_WALLPAPER_DIR`, else `<Pictures>/Wallpapers` (recursive). Backends:
  `gui-apps/mpvpaper` + `media-video/ffmpeg` (`recommended`; static-only setups
  can skip both).
- **Screenshots** — `scripts/desktop/hypr-screenshot` (`full` / `region`, with
  `--copy`), linked to `~/.local/bin` by `dotfiles` and called from
  `lua/bindings.lua` (`Print` / `Super+Print` / `Super+Shift+S`). It writes
  `<pictures>/Screenshots/Screenshot_<timestamp>.png` — `<pictures>` is
  `$XDG_PICTURES_DIR`, else `xdg-user-dir PICTURES`, else `~/Pictures`, dir
  created if missing. `region` and `--copy` also `wl-copy` the PNG. A cancelled
  region select exits `0` and leaves nothing behind. `bin/`-style helper, not a
  pipeline inside the Hyprland config. Tests: `scripts/desktop/test_hypr_screenshot.sh`
  (grim/slurp/wl-copy mocked).
- **Clipboard** — `wl-clipboard` (`wl-copy` / `wl-paste`); the region
  screenshot depends on `wl-copy`.

`doctor`'s *Desktop utilities* section checks each binary, the package, and the
`hypr-screenshot` symlink — read-only, it never takes a screenshot.

## Infinite Desktop

An isolated component (`scripts/infinite-desktop/`) — an evdev daemon that pans
floating windows, talking to Hyprland through a single compatibility layer
(`hypr_ipc.py`). Its integration with Hyprland is **declarative**:
`config/hypr/lua/infinite-desktop.lua` holds the autostart + keybinds, linked in
by `dotfiles`. `install.sh infinite-desktop` only installs the runtime scripts
to `~/scripts/` — it does not edit the Hyprland config, install packages, or run
`sudo`. (The old `patch_hyprland.py`, which appended to and remapped
`hyprland.lua`, has been removed.)

The daemon reads `/dev/input/event*` directly (read-only, no `grab()`) — a REL
mouse **or** an ABS/ABS_MT touchpad for pointer motion (validated on the Lenovo
82SC's Precision Touchpad), keyboards for modifier state. Access is the second
file that needs root: `install.sh input` writes
`config/udev/72-hypr-infinite-input.rules` to `/etc/udev/rules.d/`, tagging
keyboard + mouse + touchpad nodes with `uaccess` so systemd-logind grants a
**session-scoped** ACL — not the account-wide `input` group. Same root policy as
`gpu` / `power` (detect → explain → show → confirm; prints the privileged
commands rather than failing a write as a non-root user); on this host the
`udevadm control --reload` + `trigger` applied the ACL live, no logout. The
keystroke-exposure risk and a stricter privileged-broker alternative are in
[INFINITE-DESKTOP.md](INFINITE-DESKTOP.md#26-input-device-access).

### Floating World — the window model

`config/hypr/lua/floating-world.lua`. The desktop is a floating canvas, not a
tiling grid — and the Infinite Desktop daemon only pans *floating* windows, so
this is what makes the whole workspace pannable.

- **Float by default.** `hl.window_rule{ match = { float = false }, float =
  true, tag = "+fworld" }` floats every would-be-tiled window **at map time**
  (no tile→float flash) and tags it. Windows Hyprland already floats (dialogs,
  modals, transient tool windows, non-resizable windows) don't match the rule
  and are left completely alone. Layer surfaces (Quickshell, fuzzel, hyprlock)
  aren't windows — untouched by definition.
- **Smart initial size.** `hl.on("window.open")` → `hl.timer` (event-driven, no
  polling) → once mapped, a generic algorithm: respect a requested size that is
  already reasonable (≥260×200, ≤85 % of the usable area); otherwise fall to a
  per-class fraction (`fw.class_defaults`: terminal ~0.60, browser ~0.76×0.82,
  file-manager/editor ~0.68, Blender/IDE ~0.82–0.85; generic 0.66×0.62), always
  clamped to 85 %. A window that opened small and deliberate (≤52 % in both
  dims) is treated as a dialog/tool/PiP — kept at its size, Hyprland's centred
  placement untouched.
- **Smart placement.** Anchor on `hl.get_last_window()` (the window focused
  *before* this one opened), else the cursor, else centre. Try centred-on-anchor,
  then a gentle down-right cascade, then an expanding 8-direction ring; score =
  overlap area (px²) + a mild pull toward the anchor. Lands near the context
  with little intersection, never exactly stacked. Not a perfect packer — fast
  and natural.
- **`Super+F` pseudo-maximize.** Toggle: save `{x,y,w,h}` (in memory + a file
  under `$XDG_RUNTIME_DIR/hypr-fworld/` so it survives a `hyprctl reload`),
  resize to ~96 % of the usable area, stay **floating**. `Super+F` again →
  restore the exact saved geometry. Works indefinitely without drift. In real
  fullscreen, `Super+F` drops out of it first. `Super+Shift+F` is real
  fullscreen. A pseudo-maximized window is still a floating object on the
  canvas and pans with Infinite Desktop.

`hl.dsp.*` returns a dispatcher; a standalone call must go through
`hl.dispatch(...)` (only `hl.bind` auto-executes). Loaded after `bindings.lua`
(re-binds `Super+F`), before `infinite-desktop.lua`.

### Infinite Navigation — the World Map

A minimap of the whole floating canvas and a way to fly the camera to any
window. No screenshots, no extra daemon, no continuous polling.

- **World coordinates.** The Infinite Desktop daemon pans by *physically moving
  every floating window*, so a stable coordinate needs a camera offset:
  `worldX = window.at.x + camera.x` (`window.at` from Hyprland is already
  **global** logical space — the monitor's layout offset is baked in).
  `scripts/infinite-desktop/world.py` owns `camera.json` (per workspace, under
  `$XDG_RUNTIME_DIR/infinite-desktop/`, `flock` + atomic `os.replace`, no reboot
  persistence). Every code path that pans — the daemon's `pan_other_windows` and
  main loop, `move_window.py`'s edge-push, `navigate_windows.py`,
  `world_navigate.py` — calls `world.bump_camera(ws, -dx, -dy)` right after
  moving windows, so world positions stay put while the viewport slides.
- **Multi-monitor.** The monitors are **not** independent desktops — they are
  physical viewports onto the *same* world. Each monitor shows its own active
  workspace and each workspace keeps its own camera, but because `at` is global
  and the map composes `at + camera[window's ws]`, windows from every monitor
  land on one map in one coordinate space. Nothing is per-monitor: no per-monitor
  camera, no per-monitor hand control. (Pan behaviour is unchanged.)
- **Adaptive displays / hotplug** (`scripts/infinite-desktop/display_manager.py`,
  wired from `config/hypr/lua/display.lua`). A workspace does not belong to a
  monitor. When a workspace changes monitor — Hyprland's auto-relocation on
  unplug, or an explicit `hl.dsp.workspace.move` — Hyprland **translates that
  workspace's windows by the monitor-origin delta** (verified), so they stay
  viewport-consistent on the new screen; but `worldX = at.x + camera.x` then
  drifts by that delta because `camera.json` was not touched. On
  `monitor.removed` → `display_manager.py sync` bumps `camera.json` by the
  inverse of the delta for every workspace now on a different monitor (and forces
  a truly-orphaned workspace onto a survivor first — `hl.dsp.workspace.move`;
  `hyprctl keyword` is rejected by the Lua parser). On `monitor.added` →
  `restore` moves a workspace back to its saved *home* output and realigns the
  same way. State (per-output geometry kept even when absent, each workspace's
  home output and coordinate `frame`) lives in
  `~/.cache/hyprland-infinitie-desktop/display-state.json`; `frame[ws]` makes
  `sync` idempotent. The camera realign (`_recam`) runs **only** inside
  `sync` / `restore` — only when a hotplug actually moved a workspace; never on a
  plain reload, never for workspace navigation, never by any position policy. It
  never moves a window itself (Hyprland does the translation), never resets
  `camera.json`, never deletes a workspace, never changes a
  mode/scale/position/workspace-assignment (that is Settings, later). The
  physical layout itself is pinned in `~/.config/hypr/monitors.local.lua` so it
  survives `hyprctl reload` (the generic `position = "auto"` in `monitors.lua`
  reshuffles outputs otherwise) — that file pins geometry only, not which
  workspace shows where.
- **`world_navigate.py {address|class} <value>`.** Computes the delta that puts
  the target's centre on the usable centre of **the monitor that shows the
  target's workspace** (`_monitor_for_ws`, falls back to the focused monitor),
  then steps *every* floating window on the workspace by that delta
  (`_smoothstep`, 11 frames) — the exact pan mechanism, whole layout preserved —
  then focuses the target, then bumps the camera. `class` mode cycles a
  multi-window app on repeated calls (`cycle.json`, 3 s window). An `flock`
  (`.navigate.lock`) serialises concurrent invocations so a burst of clicks each
  lands in turn.
- **`config/quickshell/WorldMap.qml`.** A `Top`-layer overlay (namespace
  `quickshell:worldmap`, blurred via a layer rule in `appearance.lua`). Reads
  window geometry from `Hyprland.toplevels[].lastIpcObject` + `refreshToplevels()`
  (on `rawEvent` open/close/move/title/focus/float, debounced; plus a 130 ms
  timer *only while open* — and paused mid-edit — that refreshes and rebuilds,
  so pan / pseudo-maximize / hand-edit geometry that emits no event still shows,
  trailing reality by ≈one tick) and the cameras from `camera.json` (`FileView`,
  watched). It reads **all** enabled monitors (`Hyprland.monitors`, `x`/`y` from
  `lastIpcObject`, `refreshMonitors()` on monitor/workspace events + a 1 s beat)
  and shows the union of every monitor's active workspace — a window is drawn iff
  its workspace is live on *some* monitor, at `at + camera[its ws]`. Draws each
  window as a proportional rectangle (DesktopEntry icon + class), the focused one
  accented, and one subtle **viewport rectangle per monitor** (its logical
  `width/scale × height/scale` at `monitor.xy + camera`, labelled with the output
  name when there are several). Auto-fits every viewport ∪ every window with a
  margin — a global bounding box that handles negative `x`, stacked monitors and
  mixed scales. Wheel = zoom 0.15×–4× of the fit, drag empty space = pan the
  *map view* (never the real desktop). Toggled from the navbar's centre ring or
  `Super+Tab` (`worldmap` `IpcHandler` in `shell.qml`).
- **Editing windows from the map.** A short click on a window still navigates
  (`world_navigate.py`, map closes). A **drag past ~6 px on the body** moves it;
  selecting a window shows small accent **resize handles** (4 corners + 4 edge
  midpoints). Both preview live in QML (`ewx/ewy/ew/eh` in world coords, the
  refresh loop paused so the delegate is not torn down under the cursor) and
  apply once on release via **`scripts/infinite-desktop/world_edit.py geometry
  <addr> <worldX> <worldY> <w> <h>`** — which reads `camera.json`, converts
  `screen = world − camera`, moves+resizes in one `hyprctl` batch, leaves the
  camera alone, and deletes the window's pseudo-maximize restore file. Minimum
  220×140; no maximum (a window may be larger than the viewport); Hyprland still
  applies the client's own size hints.
- **Navbar.** `modules/WorldButton.qml` is the centre ring (active while the map
  is open, tooltip "World Map"). `modules/OpenApps.qml` is a compact row of
  open-app icons — a thin renderer over **`OpenAppsModel.qml`** (a singleton:
  the one list of app groups, class-grouped, Quickshell / launcher / hyprlock
  excluded, sorted, one entry per app with a multi-window count badge). Click,
  and the keyboard shortcuts, both call `OpenAppsModel.activate(n)` /
  `.step(±1)`, which run `world_navigate.py class <cls>` — camera flight, window
  cycling on repeat. `shell.qml`'s `openapps` `IpcHandler` exposes
  `next` / `prev` / `activate <n>`; `lua/window-edit.lua` binds
  `Super+Alt+Tab` / `Super+Alt+Shift+Tab` / `Super+Alt+1..9` to it (no class
  names in Lua — the number always matches the visible icon).

### `lua/window-edit.lua` — desktop-side manipulation + the SUPER-tap guard

`SUPER + LMB` drag moves a floating window and `SUPER + RMB` drag resizes it —
the plain Hyprland interactive-drag binds (`hl.dsp.window.drag` / `.resize` with
`{ mouse = true }`, in `lua/bindings.lua`, same as the stock config). This module
adds the coherence around them:

- **SUPER-tap guard.** A bare `SUPER` tap opens the launcher (release bind on
  `Super_L`). Hyprland suppresses that after a `SUPER` + key combo but not
  reliably after a `SUPER` + mouse drag, so `SUPER` + LMB/RMB *release*
  (non-consuming) sets a "used with the mouse" flag that the re-bound `Super_L`
  release swallows; the flag self-clears 700 ms after the gesture.
- **Pseudo-maximize coherence.** `SUPER` + mouse press deletes the pseudo-max
  restore file (`$XDG_RUNTIME_DIR/hypr-fworld/<addr>`) for the window under the
  cursor — same as `world_edit.py` does for a map edit. `floating-world.lua`
  reads that file fresh on every `SUPER + F`, so a hand-placed geometry becomes
  the window's new "normal" instead of a stale box it snaps back to. Only the
  edited window is affected.
- **Keyboard window navigation.** `Super+Alt+Tab` / `Super+Alt+Shift+Tab` →
  `world_navigate.py next-window` / `prev-window`: the next/previous *individual*
  window (each Foot is its own stop), spatial navigation (camera flight). While
  a Viewport Mosaic is up it instead moves focus across the mosaic windows —
  no camera, no move. `Super+Alt+1..9` stays app-level (`qs ipc call openapps
  activate N`, `OpenAppsModel` singleton, no class names in Lua). `Super+M`
  toggles the mosaic. Each bind arms the tap guard.

### Viewport Mosaic — `scripts/infinite-desktop/viewport_mosaic.py`

A temporary tidy layout of the windows in the viewport. **Nothing is tiled** —
every window stays floating, inside the Infinite Desktop, panned by the daemon;
`Super+M` just does a batch of move+resize, and again to undo.

- **Which windows.** Current workspace, floating, mapped, not fullscreen, not a
  tiny dialog / PiP / portal, **and a real (≥80 px each axis) intersection with
  the monitor** — far-off windows never get pulled in.
- **Snapshot.** Before arranging, each window's `{worldX, worldY, width,
  height}` (world = `at` + camera) is written atomically to
  `$XDG_RUNTIME_DIR/infinite-desktop/viewport-mosaic-<ws>.json` (`.mosaic.lock`
  flock, temp + `os.replace`). World coordinates, so panning the camera while
  the mosaic is up doesn't move the restore target.
- **Layout.** 1 → ~94 % centred; 2 → 50/50; 3 → one big left + two stacked
  right; 4 → 2×2; 5–6 → 3×2; 7–9 → 3×3; more → `ceil(√n)` rows. 10 px gaps,
  10 px outer margin, 44 px reserved at the top for the navbar island.
- **Restore.** `Super+M` again → each still-living window back to its snapshot
  world geometry (converted through the *current* camera), then the file is
  deleted. Closed windows are skipped; windows opened after are left alone; a
  window edited by hand meanwhile still restores to its pre-mosaic geometry
  (the mosaic is a temporary mode).
- **Pseudo-maximize** is a separate store (`hypr-fworld/<addr>`) and is never
  touched — a pseudo-maximized window survives a mosaic round-trip.
- The navbar's `modules/MosaicButton.qml` (a 2×2 grid glyph, left group) lights
  up while a mosaic is active — it watches the snapshot file. The World Map
  naturally shows the mosaic positions while active and the original spread
  after restore (it reads live geometry; nothing special needed).

### Hand Control — `scripts/hand-control/` (opt-in experiment)

Optional webcam gesture control, **off by default**, a separate process (no
computer vision near the evdev daemon). `hand-control {start|stop|toggle|
status|debug}` — the camera is opened only while `hand_control.py` runs;
`Super+H` and the navbar `modules/HandButton.qml` toggle it.

All reusing existing pieces. Gesture vocabulary (priority high→low:
shutter-closed → **pinch grab** → fist → partial-hand → pan → tilt):

- **open palm + translate** → pan (`world.py` camera + `hypr_ipc` batch, same
  as touchpad/keyboard). Tracks the palm *base* (wrist + two MCPs) so a tilt
  doesn't jerk it.
- **pinch (thumb + index tip)** → grab the **focused** floating window and move
  **only it** — `PinchGrab`: `idle → pending → grabbed → released`,
  `pinch_ratio = dist(4,8) / palm_scale` with hysteresis (`close_ratio` /
  `open_ratio`) + `confirm_seconds`, and a fist can never arm it. On grab it ends
  the pan, snapshots the window's screen position and moves it to
  `base + smoothed_hand_delta × sensitivity` in a one-window `hyprctl` batch —
  **the camera is never bumped**, nothing else pans, and because `at` is global
  logical space the window follows across monitors / mixed scales unchanged.
  Release drops it and invalidates the pseudo-max restore file (same policy as
  `world_edit.py` / a World Map drag). Spike-rejected (`pan.max_tracking_speed`);
  a real landmark loss > `grace_seconds` ends the grab cleanly and a new pinch is
  required. v1 always takes the focused window — no pointing / hit-test yet.
- **fist → CLUTCH** (priority below pinch): ends the pan now, cancels the tilt
  candidate, and on release the current hand position becomes the new pan
  baseline — the physical "clutch" to recolocate the hand without moving the
  desktop.
- **fist → thumbs-up** → `viewport_mosaic.py toggle` — a state machine
  `idle → fist_armed → thumbs_pending → fired → wait_reset`: only a *stable*
  fist that then becomes a clear thumbs-up (four fingers curled, thumb extended
  and pointing up) fires; holding it never re-toggles; a bare thumbs-up with no
  fist does nothing.
- **palm tilt L/R** → `world_navigate.py prev-window`/`next-window` — own state
  machine, **only evaluated while the palm is stationary** (pan has priority; a
  natural wrist tilt during a pan never navigates). On fire it ends the pan,
  suppresses it for `nav_block_seconds` while `world_navigate` moves, then
  re-baselines — the two never move the camera at once. Angle auto-zeroed to a
  near-upright rest pose; `confirm` + `cooldown` + return-to-neutral.

**No gesture uses finger count** (a finger leaving the frame at an edge makes
false triggers); tilt uses stable wrist/MCP landmarks, the mosaic needs the
deliberate fist→thumbs sequence, and the pinch uses a scale-normalised thumb/
index distance. A **partial hand** (a palm landmark off-frame) blocks all
discrete actions but not the pan or the clutch; while a pinch grab is active pan,
tilt, mosaic and clutch are all suppressed. The pan uses an adaptive EMA +
isolated-spike rejection (`max_tracking_speed`) and rides out a 1–2 frame
dropout. All timings are in **seconds** (real rate ~15–18 fps). Mirror is applied
exactly once.

**Shutter-aware.** The privacy shutter has no signal on Linux, so it is inferred
from the stream — low variance + low texture + temporal stability, multi-metric
with hysteresis so a dark room does not flip it. While CLOSED: no MediaPipe, no
actions, gestures cleared, loop drops to ~4 FPS; on reopen the smoothing resets
so nothing jumps or replays. `$XDG_RUNTIME_DIR/hand-control/state`
(`running=`/`shutter=`/`tracking=`) drives the navbar HandButton's three states
(OFF / shutter-CLOSED / ACTIVE).

Config: `~/.config/hand-control/config.toml` (thresholds, cooldowns, shutter
delays — nothing hard-coded). Deps (mediapipe + opencv) live in
`$XDG_DATA_HOME/hand-control/venv`, created by `setup-venv.sh` by hand — never
system-wide, CPU model only (does not wake the RTX). See
[hand-control/README.md](../scripts/hand-control/README.md).
