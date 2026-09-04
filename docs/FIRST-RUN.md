# First run

This is not the `install.sh first-run` command yet (not built — see
[INSTALL.md](INSTALL.md)). For now it covers one thing: verifying the laptop's
real hardware keys once Hyprland is actually running on this machine.

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

## Volume / mic mute reflected in the bar

`modules/Audio.qml` reads PipeWire's own state directly
(`Quickshell.Services.Pipewire`), so a volume or mute change from the
keyboard shows up in the bar with no extra step to verify.

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

## Brightness reflected in the bar

`modules/Brightness.qml` re-queries `brightnessctl` after the
`XF86MonBrightness{Up,Down}` binds run it, via `qs ipc call brightness
refresh` (see the comment in `laptop.lua`). If the bar's brightness reading
looks stale after a key press, confirm `qs` (Quickshell) was already running
when the key was pressed — `qs ipc call` has nothing to reach otherwise.
