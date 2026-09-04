# Installing

The installer is `./install.sh`, a thin dispatcher. Run it from a checkout of
this repository; it resolves its own location, so the working directory does not
matter.

```
./install.sh help
```

This document covers the commands that exist today. It will grow as the
remaining commands (`desktop`, `power`, `first-run`, `full`) land.

## Global options

| Option | Effect |
| --- | --- |
| `--dry-run` | print intended actions, change nothing. Read-only commands accept it and behave identically; commands that are not dry-run-aware refuse it rather than mislead you. |
| `--verbose`, `-v` | extra detail |
| `--no-color` | disable coloured output |

## Commands

### `check` — read-only system report

```
./install.sh check
```

Prints OS / kernel / init, machine model, CPU, every GPU (driver, PCI IDs,
`/dev/dri/by-path`) and the primary GPU, network interfaces, power supplies,
backlight, DRM connectors, and which base tools are installed. Works on any
distribution — it is a useful pre-check on Fedora before switching to Gentoo.
Never runs `nvidia-smi`; never changes anything.

### `deps` — Gentoo package plan

```
./install.sh deps            # show the plan
./install.sh deps            # (on Gentoo) also shows installed vs missing
```

Reads `install/packages.gentoo` and reports what is needed, grouped into base /
Hyprland / Quickshell / audio / network / power / NVIDIA / kernel-dev. On Gentoo
it checks overlay status and each atom, then prints the exact
`eselect repository enable` / `emaint sync` / `emerge --ask` commands — it never
runs them. `--install` is refused (not implemented). Off Gentoo it prints the
plan and says the installed state is not verifiable.

### `gpu` — hybrid AMD/NVIDIA + RTD3

```
./install.sh gpu             # detect + explain + show proposed changes (read-only)
./install.sh gpu --apply     # apply, one change at a time, after confirmation
```

Configures only what the NVIDIA driver package does not already provide: stable
`/dev/dri/hypr-{primary,secondary}` symlinks for `AQ_DRM_DEVICES`, `nvidia_drm
modeset=1` if it is off, and an RTD3 udev rule if the driver ships none. Never
touches the initramfs or the bootloader, never calls `sudo` (it prints the exact
command), backs up any pre-existing file before replacing it, and is idempotent.
See [HYBRID-GPU.md](HYBRID-GPU.md).

### `doctor` — read-only diagnostics

```
./install.sh doctor
./install.sh doctor --nvidia-deep
./install.sh doctor --verbose
```

Evaluates the workstation and marks each check `[OK]` / `[WARN]` / `[ERROR]` /
`[INFO]`: system, distro, hardware and drivers, AMD-as-primary, NVIDIA power
state, `nvidia-compute-mode` policy, the stage-`gpu` config, NVIDIA sleep
services, Gentoo overlays and required packages, NetworkManager, PipeWire,
Hyprland/Quickshell tools (and Hyprland version — flags `< 0.55`), battery,
backlight, and the `input` group / `evdev` needed by Infinite Desktop.

It fixes nothing. NVIDIA checks use only the no-wake probe — `doctor` never runs
`nvidia-smi` and will not be what keeps the GPU awake. `--nvidia-deep` opts into
`nvidia-smi` metrics (temperature, VRAM, utilisation, clocks) and prints a
warning first. On Fedora, Gentoo-specific checks are `INFO`/`WARN`, not failures.

Exit codes: `0` = no errors (warnings alone are fine), `1` = one or more
`[ERROR]` checks, `2` = bad arguments.

### `infinite-desktop` — the Infinite Desktop component

```
./install.sh infinite-desktop
```

Installs `python-evdev`, adds your user to the `input` group, copies the
Infinite Desktop scripts to `~/scripts/`, and adds the autostart + keybinds to
`~/.config/hypr/hyprland.lua`. `./install-hyprland-infinite-desktop.sh` is a
compatibility wrapper for this command. See
[INFINITE-DESKTOP.md](INFINITE-DESKTOP.md).
