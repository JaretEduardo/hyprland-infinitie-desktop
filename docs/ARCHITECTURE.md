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
  fuzzel/                      app-launcher config (linked by dotfiles)
  xdg-desktop-portal/          hyprland-portals.conf: portal backend order (linked by dotfiles)
  polkit/actions/              polkit policy for the helper above; also NOT installed
  quickshell/                  modular Quickshell bar
scripts/
  infinite-desktop/            the Infinite Desktop component (evdev daemon + IPC)
  desktop/                     small desktop helpers + tests: hypr-screenshot
                                 (grim/slurp/wl-copy; linked to ~/.local/bin by dotfiles)
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
| `appearance.lua` | minimal gaps / borders / layout; Quickshell owns the visuals later |
| `bindings.lua` | basic desktop keybinds; `Super+Return` → `$TERMINAL` (falls back to `foot`), `Super+Space` → `fuzzel`, `Print` / `Super+Print` / `Super+Shift+S` → `hypr-screenshot` (see README "Keybindings") |
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

- **Launcher** — `fuzzel`, bound to `Super+Space` in `lua/bindings.lua`.
  Config `config/fuzzel/fuzzel.ini`, linked by `dotfiles`.
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
