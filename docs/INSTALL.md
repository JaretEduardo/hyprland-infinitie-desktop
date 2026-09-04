# Installing

The installer is `./install.sh`, a thin dispatcher. Run it from a checkout of
this repository; it resolves its own location, so the working directory does not
matter.

```
./install.sh help
```

This document covers the commands that exist today. It will grow as the
remaining commands (`first-run`, `full`) land.

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

### `infinite-desktop` — the Infinite Desktop runtime component

```
./install.sh infinite-desktop
./install.sh infinite-desktop --dry-run
```

Installs the Infinite Desktop scripts into `~/scripts/` (identical files are a
no-op; a locally modified one is backed up and replaced only after you confirm)
and reports on the runtime requirements: `python3` / `python-evdev` / `jq`
(install them with `install.sh deps`) and whether your user is in the `input`
group (it explains what to run — `sudo usermod -aG input "$USER"` — but **never
runs it**).

It does **not** touch the Hyprland config. The autostart and keybinds are
declared in `config/hypr/lua/infinite-desktop.lua`; link them in with
`./install.sh dotfiles --apply`. `./install-hyprland-infinite-desktop.sh` is a
compatibility wrapper for this command. See
[INFINITE-DESKTOP.md](INFINITE-DESKTOP.md).

### `power` — logind lid / power-key / idle-action policy

```
./install.sh power             # detect + explain + show the proposed change (read-only)
./install.sh power --apply     # apply, after confirmation, backing up anything replaced
```

Writes the single `/etc/systemd/logind.conf.d/` drop-in this project needs
root for (`HandleLidSwitch=suspend`, `HandleLidSwitchDocked=ignore`,
`HandleLidSwitchExternalPower=suspend`, `HandlePowerKey=lock`,
`IdleAction=ignore`) — the rest of the power ownership matrix (idle timers,
locking, DPMS, suspend-by-inactivity) is `hypridle.conf` / `hyprlock.conf`,
which need no privilege and are linked by `dotfiles`, not written by `power`.
Never calls `sudo` (prints the exact command if it can't write `/etc`
itself), never restarts `systemd-logind` for you, backs up any pre-existing
file it did not create, and is idempotent. See [POWER.md](POWER.md).

### `desktop` — orchestrates everything above

```
./install.sh desktop              # plan: every step below in its own plan mode (read-only)
./install.sh desktop --apply      # the real sequence — each step still confirms itself
./install.sh --dry-run desktop --apply   # like --apply, but every step writes nothing
```

An orchestrator, not a reimplementation: `desktop` calls `check`, `deps`,
`dotfiles`, `gpu`, `power`, `infinite-desktop` and `doctor` — in that order —
exactly as if you ran each one yourself, including its own interactive
confirmations under `--apply`. It adds no privileged action of its own: no
`emerge`, no `eselect`, no hidden `sudo`, no `systemctl enable/start`, no
`usermod`, no silent `/etc` write.

Sequence and why: `check` (preflight) → `deps` (read-only; **stops before any
write** if required packages are missing on Gentoo, so `--apply` never
touches config on top of a broken dependency set) → `dotfiles` → `gpu` →
`power` → `infinite-desktop` → `doctor` (this is also where NetworkManager /
PipeWire-WirePlumber presence and the overall readiness summary are checked —
already covered there, not duplicated here). If any step after `deps` fails,
the sequence stops at that step — nothing after it runs — but `doctor` still
runs at the end regardless, as a read-only snapshot of wherever things were
left.

**Not Gentoo (e.g. this repo developed on Fedora):** plan mode runs exactly
the same. Under `--apply`, `gpu` and `power` — the two steps that write real
files under `/etc` — stay plan-only even so; this repo's target is Gentoo,
and a non-Gentoo host is never used to apply those changes for real.
`dotfiles` and `infinite-desktop` (both user-space, under `$HOME`) still run
for real under `--apply` on any distro.

Idempotent the same way its steps already are: a second `--apply` run relinks
nothing that's already linked, rewrites nothing that already matches, and
creates no new backups — see each step's own section above.
