# First run

`install.sh first-run` walks through everything below in order (plan mode is
read-only; `--apply` offers to resolve each pending item, with its own
confirmation). It does not reimplement any of these checks — it calls
`install.sh profile` / `check` / `dotfiles` / `monitor` / `doctor` and
`nvidia-compute-mode` directly; this document is the detail behind each
section, and the reference `wev` table it shows verbatim.

`install.sh full --apply` (see [INSTALL.md](INSTALL.md#full--top-level-workstation-orchestration))
already calls this command for you — offered, never forced — once it
detects a live Hyprland session and its own `desktop` phase has succeeded.
Running `first-run` directly, as documented below, is for whenever you want
to work through this checklist on its own: right after logging into
Hyprland for the first time, or any time later to re-check something.

## Machine profile (`install.sh profile`)

The first thing first-run shows is which [machine profile](PROFILES.md)
applies — detected from real DMI data, never the hostname — and whether its
declared hardware expectations hold. This is purely informational context
for everything that follows; it changes nothing and is not itself a pending
item to resolve.

## Monitor configuration (`install.sh monitor`)

```
install.sh monitor            # detect + show the plan (read-only)
install.sh monitor --apply    # detect + show + confirm + write
```

Needs a live Hyprland session — it reads `hyprctl -j monitors all` (never
guesses an output if that fails) and cross-checks each connector's real
EDID-preferred resolution via `lib/hardware.sh`'s DRM/sysfs reading, then
picks the **highest refresh rate available at that native resolution** —
never a lower resolution just because it advertises more Hz. It shows every
detected monitor (internal panel identified by an `eDP-*` name, external
monitors preserved, never disabled), its full mode list, and the chosen mode
for each, before writing anything. Generates
`~/.config/hypr/monitors.local.lua` — machine-local, not tracked by git — and
is idempotent: an identical file is a no-op, a differing one is diffed,
confirmed, and backed up (`lib/backup.sh`) before being replaced.

This can only be validated for real on Gentoo: whether `eDP-1` really is the
name Hyprland reports for the internal panel on this hardware, and whether
`1920x1200@165` (or whatever the driver actually offers) is really what comes
back — see the stage's commit message for the exact plan this repo's own
data produced.

## Verifying the Fn-row / media keys

`config/hypr/lua/laptop.lua` binds the standard XF86 keysyms (volume, mic
mute, brightness, play/pause, next/previous). Standard keysyms are common
across laptops, but this has not been confirmed against the real keyboard's
key events yet, and this Lenovo may also send extra, model-specific keys
(airplane mode, keyboard backlight, a dedicated mic-mute key, etc.) that are
deliberately **not** guessed at in `laptop.lua`.

To check what a key actually sends, install `wev` (`install/packages.gentoo`,
`power` group, optional — it's a one-time diagnostic, not a runtime
dependency of any keybind) and run it from a terminal inside the Hyprland
session:

```
wev
```

Press each Fn-row key. `wev` prints the keysym for every press — compare it
against what `laptop.lua` binds:

| Key | Expected XF86 keysym |
| --- | --- |
| Volume up | `XF86AudioRaiseVolume` |
| Volume down | `XF86AudioLowerVolume` |
| Mute | `XF86AudioMute` |
| Mic mute | `XF86AudioMicMute` |
| Brightness up | `XF86MonBrightnessUp` |
| Brightness down | `XF86MonBrightnessDown` |
| Play/pause | `XF86AudioPlay` / `XF86AudioPause` |
| Next track | `XF86AudioNext` |
| Previous track | `XF86AudioPrev` |

If a key reports a different keysym than expected, or a key not in this list
sends a real, usable keysym you want bound, add it as a normal `hl.bind(...)`
in `laptop.lua` (or in a machine-local `laptop.local.lua`, loaded
automatically and never tracked by git — see `lua/util.lua`). Do not add
speculative binds for keysyms you have not actually seen `wev` report on this
hardware.

## Session services — audio + logind (`install.sh first-run`, section 5)

The PipeWire user units are socket-activated but **not enabled by anything in
this repo**. `first-run --apply` offers to run, once:

```
systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
```

`doctor`'s *Audio session* section prints the same command if the units are
`disabled`. The section also reminds you to run `install.sh power --apply` (root)
for the logind drop-in — without it a single Power-key press powers the machine
off. See [SESSION.md](SESSION.md).

## Volume / mic mute reflected in the bar

`modules/Audio.qml` reads PipeWire's own state directly
(`Quickshell.Services.Pipewire`), so a volume or mute change from the
keyboard shows up in the bar with no extra step to verify (once PipeWire is
running — see above).

## Lid, lock, suspend (docs/POWER.md)

None of this can be validated from a machine without Hyprland/`systemd-logind`
actually running the session (this repo was developed on Fedora without
Hyprland running), so it needs a real pass on Gentoo:

1. `hyprctl devices` — confirm the lid switch is listed (name expected
   around `Lid Switch`; `config/logind/50-hyprland-infinite-desktop.conf`
   does not itself depend on the exact name, since logind — not a Hyprland
   `switch:` bind — owns the lid, but it's worth confirming the device is
   seen at all).
2. Close the lid **on battery**, no external monitor connected → the laptop
   should suspend (`HandleLidSwitch=suspend`).
3. Close the lid **on AC power**, no external monitor connected → the laptop
   should **also** suspend (`HandleLidSwitchExternalPower=suspend`). This is
   the case a plain `HandleLidSwitch=` alone would miss, since logind checks
   external-power before falling back to it — worth checking on its own, not
   just assuming it behaves like case 2.
4. Connect an external monitor (either power source), close the lid → it
   should **not** suspend (`HandleLidSwitchDocked=ignore`, since logind then
   sees more than one display connected — checked before either of the two
   cases above). Keep working on the external monitor; reopening the lid
   should just make the internal panel available again, with no extra
   suspend/resume cycle.
5. Press the power button once, briefly → the session should lock
   (`HandlePowerKey=lock`), not power off.
6. Let the machine sit idle and confirm the ladder in order: dim (~2.5 min) →
   lock (~5 min) → DPMS off (~5.5 min) → suspend (~30 min). Wake it and
   confirm the screen locks exactly once and DPMS comes back exactly once.
7. Run `nvidia-compute-mode status` before and after a suspend/resume cycle,
   in both `eco` and (if a real `compute_backend` is set up) `compute` — the
   reported policy must be identical before and after.

## NVIDIA compute backend (`install.sh first-run`, section 5)

Guided resolution of `compute_backend=auto` — see
[HYBRID-GPU.md](HYBRID-GPU.md) "Resolving compute_backend" and "Privilege
boundary" for the full design. In short: `install.sh first-run --apply` can
test the `power-control` candidate for real (COMPUTE, verify, back to ECO —
never kills a process, never unloads a module, never PCI remove/rescan), and
only records it as the backend if both directions succeed; any failure
reverts to `auto`. This needs the real Gentoo/NVIDIA driver combination to
mean anything — on Fedora it correctly stops at "needs root" and leaves
`auto` in place, since the polkit helper (`bin/nvidia-power-control-helper`)
is prepared infrastructure, not installed by anything yet.

## Brightness reflected in the bar

`modules/Brightness.qml` re-queries `brightnessctl` after the
`XF86MonBrightness{Up,Down}` binds run it, via `qs ipc call brightness
refresh` (see the comment in `laptop.lua`). If the bar's brightness reading
looks stale after a key press, confirm `qs` (Quickshell) was already running
when the key was pressed — `qs ipc call` has nothing to reach otherwise.
