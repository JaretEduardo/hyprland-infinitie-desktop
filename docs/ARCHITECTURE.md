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
  hardware.sh                  read-only hardware detection (PCI/sysfs, no cardN)
  portage.sh                   read-only Portage / overlay / catalogue helpers
  nvidia.sh                    read-only, power-aware NVIDIA observation (no-wake)
  backup.sh  symlink.sh        safe, non-destructive dotfile primitives
bin/
  nvidia-offload               PRIME render-offload wrapper
  nvidia-compute-mode          NVIDIA compute-session backend (eco / compute)
config/
  gpu/                         modprobe.d + udev templates for the hybrid GPU
  hypr/                        modular Hyprland Lua config (see below)
scripts/
  infinite-desktop/            the Infinite Desktop component (evdev daemon + IPC)
docs/                          per-topic documentation
```

## Installer

`install.sh` resolves its own location (following symlinks, ignoring the cwd)
and hands off to `install/common.sh`, which registers commands and dispatches to
`install/cmd/<name>.sh`. Read-only commands (`check`, `doctor`, `deps`, and the
plan mode of `gpu` / `dotfiles`) never change anything. Commands that write
follow **detect → explain → show the exact change → confirm → apply**, honour
`--dry-run`, never call `sudo` (they print the exact command), and are
idempotent. See [INSTALL.md](INSTALL.md).

## Hyprland configuration

Modern Lua config, targeting Hyprland ≥ 0.55. `config/hypr/hyprland.lua` is a
tiny entrypoint that `require()`s ordered modules under `config/hypr/lua/`:

| module | contents |
| --- | --- |
| `util.lua` | `load_optional()` — loads a machine-local file if present |
| `env.lua` | cursor size; GPU note (AQ_DRM_DEVICES comes from a machine-local file) |
| `monitors.lua` | generic `output = ""` fallback rule (no `eDP-1`, no resolution) |
| `input.lua` | keyboard + touchpad base, 3-finger workspace swipe |
| `appearance.lua` | minimal gaps / borders / layout; Quickshell owns the visuals later |
| `bindings.lua` | basic desktop keybinds only |
| `laptop.lua` | seam — XF86 media/brightness binds land here later |
| `autostart.lua` | environment import + polkit agent only |
| `infinite-desktop.lua` | seam — Infinite Desktop wiring lands here in a later stage |

### Machine-local files

Per-entry symlinking keeps `~/.config/hypr/` and `~/.config/hypr/lua/` as real
directories, so generated, git-ignored, per-machine files sit beside the
symlinks and are never managed or deleted by `install.sh dotfiles`:

| file | written by |
| --- | --- |
| `~/.config/hypr/monitors.local.lua` | `install.sh first-run` / `monitor` (panel + 165 Hz) |
| `~/.config/hypr/gpu.local.lua` | `install.sh desktop` (`AQ_DRM_DEVICES`) |
| `~/.config/hypr/*.local.lua` | optional, hand-written |

The relevant module loads its `*.local.lua` after its own defaults, so the
local file wins.

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

## Infinite Desktop

An isolated component (`scripts/infinite-desktop/`) — an evdev daemon that pans
floating windows, talking to Hyprland through a single compatibility layer
(`hypr_ipc.py`). See [INFINITE-DESKTOP.md](INFINITE-DESKTOP.md).
