# Hyprland Infinite Desktop workstation

A reproducible **Gentoo + Hyprland** workstation configuration, built around
Hyprland's modern Lua config, Quickshell, and a hybrid AMD/NVIDIA GPU setup —
with **Infinite Desktop** (pan the whole floating canvas, keyboard-only
window navigation) as one modular feature of it, not the whole project.

This is **not a Linux distribution and not a Gentoo installer.** It is a
config repo plus a small, transparent `install.sh` that detects, explains,
and — only after you confirm — writes files. It never partitions a disk,
never touches EFI or a bootloader, and never installs Gentoo itself.

## What this is

- Gentoo + systemd
- Hyprland ≥ 0.55 (Lua config, `hl.dsp.*` dispatch API), Quickshell as the bar/shell
- NetworkManager, PipeWire + WirePlumber
- session services: `mako` (notifications), UPower (battery), `hyprpolkitagent`
  (polkit prompts) — autostarted, no manual polkit-gnome/-kde agent needed
- desktop utilities: `fuzzel` launcher (Super+Space), `grim`+`slurp` screenshots
  (Print / Super+Shift+S — see below), `wl-clipboard`
- Xwayland for X11 apps, xdg-desktop-portal (+ Hyprland & GTK backends) for
  screen sharing and file pickers, a `dejavu` font baseline — all in the
  catalogue so a clean rebuild has them (see [SESSION.md](docs/SESSION.md))
- AMD iGPU as the primary/compositor GPU, NVIDIA dGPU on-demand
  (ECO by default, COMPUTE on request — see [HYBRID-GPU.md](docs/HYBRID-GPU.md))
- `hypridle` + `hyprlock` for idle/lock/DPMS, `logind` for lid/power-key —
  each event owned by exactly one of the two (see [POWER.md](docs/POWER.md))
- Infinite Desktop — an isolated, optional evdev daemon
  (see [INFINITE-DESKTOP.md](docs/INFINITE-DESKTOP.md))
- machine profiles — declarative, DMI-matched hardware expectations
  (see [PROFILES.md](docs/PROFILES.md))
- a guided first-run for what only real hardware can decide
  (see [FIRST-RUN.md](docs/FIRST-RUN.md))
- an optional kernel development workflow
  (see [KERNEL-DEVELOPMENT.md](docs/KERNEL-DEVELOPMENT.md))

## Scope

This repo starts **after** you already have a working Gentoo base install —
booted, networked, with a regular user. Everything below is explicitly
**out of scope**, and nothing here ever touches it:

- disk partitioning, filesystem creation
- EFI, the bootloader (GRUB/systemd-boot/...)
- the Gentoo base installation itself (stage3, `emerge --sync`, a kernel you
  boot for the first time)

**Disk safety:** no script in this repo writes to a block device, a
partition, an EFI partition, or a bootloader configuration, ever. User-level
writes stay confined to `$HOME`/the relevant `$XDG_*` directory (dotfiles,
symlinks). The only system-level writes are to known `/etc` configuration
files that genuinely need root (a udev/modprobe rule for the hybrid GPU, a
`logind.conf.d` drop-in for lid/power-key) — always previously detected,
shown to you exactly, and applied only after confirmation, with a backup of
anything replaced — see [INSTALL.md](docs/INSTALL.md).

## Architecture, in short

```
Gentoo (already installed, already booted)
  |
  v
install.sh
  |-- check / profile        read-only detection (hardware, machine profile)
  |-- deps                   what's missing, the exact emerge/overlay commands
  |-- dotfiles                per-file symlinks into ~/.config
  |-- gpu / power             the few root-owned files this needs (shown, confirmed)
  |-- desktop                 orchestrates all of the above as one unit
  |-- first-run               guided: real monitor config, wev keys, NVIDIA backend
  `-- doctor                  read-only diagnostics, any time

Hyprland session
  |-- Quickshell               the bar (NOT Waybar)
  |-- mako / UPower / hyprpolkitagent   notifications, battery, polkit prompts
  |-- fuzzel / grim+slurp / wl-clipboard   launcher, screenshots, clipboard
  |-- Infinite Desktop         optional evdev pan/navigate daemon
  |-- hypridle / hyprlock      idle -> dim -> lock -> DPMS -> suspend
  `-- AMD primary + NVIDIA on-demand (ECO / COMPUTE)
```

### Keybindings (the ones this repo adds)

| keys | action |
| --- | --- |
| `Super + Return` | terminal (`$TERMINAL`, falls back to `foot`) |
| `Super + Space` | app launcher (`fuzzel`) |
| `Print` | screenshot of the focused output → `<Pictures>/Screenshots/` |
| `Super + Print` | same, **and** copy the image to the clipboard |
| `Super + Shift + S` | select a region → file **and** clipboard (Escape = cancel, silently) |
| `Super + Q` / `V` / `F` | close / toggle floating / fullscreen |
| `Super + 1…0` (`+ Shift`) | focus / move-to workspace |
| `Super + arrows` (`+ Shift` / `Ctrl` / `Alt`) | Infinite Desktop navigate / move / resize / tiled-move |
| `Super + D` | Infinite Desktop: toggle floating/tiled for the workspace |
| `XF86Audio*` / `XF86MonBrightness*` | volume / mic / brightness / media |

Screenshots use `bin` script `hypr-screenshot` (`scripts/desktop/hypr-screenshot`,
linked to `~/.local/bin`), never a shell pipeline inside the Hyprland config.

Every command that writes anything follows the same rule: **detect → explain
→ show the exact change → confirm → apply.** Nothing runs `sudo`,
`emerge`, or a service enable/start on its own — see
[INSTALL.md](docs/INSTALL.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the full picture.

## Quick start

```bash
# on an already-installed, already-booted Gentoo machine
git clone <this-repo> ~/hyprland-infinite-desktop
cd ~/hyprland-infinite-desktop

./install.sh check      # read-only system report — works on any distro
./install.sh profile    # which machine profile applies (read-only)
./install.sh deps       # what's missing — install it yourself with the
                         # exact emerge/overlay commands it prints
```

```bash
./install.sh full             # PLAN — the whole sequence, read-only, 0 writes
./install.sh full --apply     # APPLY — dotfiles, GPU config, power config,
                               # Infinite Desktop + its input-device access;
                               # stops before any write if required packages
                               # are still missing
```

```bash
# log into the Hyprland session you just configured (start it with: Hyprland), then:
./install.sh first-run --apply   # VALIDATE IN SESSION — real monitor
                                  # detection, wev-guided media keys, a guided
                                  # NVIDIA compute-backend test, AND it offers
                                  # to enable the PipeWire user units (audio)
./install.sh doctor               # read-only diagnostics, any time after
```

Two things `full --apply` cannot do for you (`doctor` and `first-run` flag both):

```bash
# audio — the PipeWire user units are socket-activated but not enabled by anyone
systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
# power key — without this drop-in a single Power press powers the machine OFF
./install.sh power --apply          # shows the drop-in + prints the `sudo install …`
                                    # command to run (install.sh never sudos itself)
```

`full` already calls `check`, `deps`'s own gate, `dotfiles`, `gpu`, `power`,
`infinite-desktop` and `doctor` for you as one unit — there is no separate
"now run desktop" step in between. `full --apply` outside a Hyprland session
completes everything it safely can and tells you plainly that first-run is
still pending; inside a live session it offers to run first-run for you.

**Optional**, any time, independent of the desktop being fully set up:

```bash
./install.sh kernel-dev   # kernel dev readiness + reproducible commands
                           # (read-only; not part of full — see below)
```

## CLI

```
./install.sh help
```

| Command | Writes? | Notes |
| --- | --- | --- |
| `check` | never | read-only system report, works on any distro |
| `profile` | never | which `profiles/<id>/` applies (DMI-matched) |
| `deps` | never | Gentoo package/overlay plan; never runs `emerge` |
| `dotfiles` | `--apply` | per-file symlinks into `~/.config` |
| `gpu` | `--apply` | the few `/etc` files the NVIDIA driver doesn't already provide |
| `power` | `--apply` | the one `logind.conf.d` drop-in this needs root for |
| `infinite-desktop` | yes (no separate flag; `--dry-run` to preview) | copies runtime scripts to `~/scripts/` |
| `input` | `--apply` | udev `uaccess` rule for the evdev daemon's device access — not the `input` group |
| `desktop` | `--apply` | orchestrates dotfiles/gpu/power/input/infinite-desktop/doctor |
| `monitor` | `--apply` | real monitor detection from a live Hyprland session |
| `first-run` | `--apply` | guided: monitor, wev keys, NVIDIA compute backend |
| `doctor` | never | read-only diagnostics; `--nvidia-deep` opts into `nvidia-smi` |
| `full` | `--apply` | top-level: profile + desktop + first-run, each reused as-is |
| `kernel-dev` | never | readiness + reproducible commands; **not** part of `full` |

Global flags:

| Flag | Effect |
| --- | --- |
| `--dry-run` | every write-capable command shows what it would do and writes nothing; read-only commands accept it as a no-op |
| `--verbose`, `-v` | extra diagnostic detail |
| `--no-color` | disable coloured output |

## What's still manual

- Installing whatever `install.sh deps` says is missing (this repo never
  runs `emerge`)
- Enabling/reviewing the `sudo`/`pkexec` commands `gpu`/`power` print, if you
  don't run `--apply` as root yourself
- The physical checks `first-run` walks you through (media keys against
  `wev`, a real lid-close/suspend cycle) — nothing can simulate a key press
  or a suspend for you
- Kernel development itself (`kernel-dev` only detects and suggests commands
  — it never runs `make`, never touches `/boot` or the bootloader)

## What needs a real Gentoo target to confirm

This repo was developed and tested from a Fedora host acting as a read-only
stand-in — every plan-mode and `--check`/`--env` command runs there
faithfully, and `--apply` flows are exercised against sandboxed
`HOME`/sysroots. What can only be confirmed on the real Gentoo target is
called out explicitly in each doc: real Hyprland/`hyprctl` behaviour
([FIRST-RUN.md](docs/FIRST-RUN.md)), the NVIDIA driver's actual RTD3/D3cold
behaviour ([HYBRID-GPU.md](docs/HYBRID-GPU.md)), and a real lid/suspend cycle
([POWER.md](docs/POWER.md)).

## Documentation

| Doc | Covers |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | repository layout, how every command fits together |
| [INSTALL.md](docs/INSTALL.md) | every command, in detail |
| [HYBRID-GPU.md](docs/HYBRID-GPU.md) | AMD primary / NVIDIA on-demand, ECO/COMPUTE, RTD3 |
| [POWER.md](docs/POWER.md) | idle/lock/DPMS/suspend/lid ownership matrix |
| [SESSION.md](docs/SESSION.md) | TTY launch, session env vars, portals + PipeWire, audio enable |
| [PROFILES.md](docs/PROFILES.md) | machine profiles: format, matching, validation |
| [FIRST-RUN.md](docs/FIRST-RUN.md) | the guided first-run checklist, in detail |
| [INFINITE-DESKTOP.md](docs/INFINITE-DESKTOP.md) | Infinite Desktop's own architecture |
| [KERNEL-DEVELOPMENT.md](docs/KERNEL-DEVELOPMENT.md) | the optional kernel-dev workflow |

## License

See [LICENSE](LICENSE).
