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

## Brightness reflected in the bar

`modules/Brightness.qml` re-queries `brightnessctl` after the
`XF86MonBrightness{Up,Down}` binds run it, via `qs ipc call brightness
refresh` (see the comment in `laptop.lua`). If the bar's brightness reading
looks stale after a key press, confirm `qs` (Quickshell) was already running
when the key was pressed — `qs ipc call` has nothing to reach otherwise.
