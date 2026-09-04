-- lua/laptop.lua — laptop hardware keys: volume, mic, brightness, media.
--
-- Touchpad settings are in lua/input.lua (they belong with input config).
-- Power / idle (hypridle, hyprlock, logind ownership, lid, power button,
-- DPMS, suspend) is a separate later stage and does NOT live here.
--
-- Binds and flags below are the ones from Hyprland's own official example
-- config (example/hyprland.lua in hyprwm/Hyprland, fetched and confirmed
-- during this project's Lua-API research), with one deliberate change: the
-- upstream example also sets `repeating = true` on the mute / mic-mute /
-- play-pause / next / previous binds. Repeat only makes sense for a value you
-- move incrementally (volume, brightness); it is dropped here for the
-- toggle/one-shot ones.
--
-- Only standard XF86 keysyms that a real keyboard/Fn-row is expected to send
-- are bound here. Any extra Lenovo-specific keys (e.g. airplane-mode,
-- keyboard-backlight, a dedicated mic-mute LED key) are NOT guessed — they
-- get identified with `wev` during first-run on the real hardware and added
-- then (see docs/FIRST-RUN.md).
--
-- `locked = true` lets these keep working while an input inhibitor (e.g. a
-- future hyprlock submap) is active — matches the upstream example; harmless
-- now since no lock screen exists yet.

-- ---- volume (wpctl — PipeWire/WirePlumber's own CLI, no PulseAudio) -------
-- "-l 1" caps XF86AudioRaiseVolume at 100% (limit factor 1.0) so holding the
-- key can't push the sink into >100% boost. Lowering needs no limit: wpctl
-- already clamps at 0%.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true })

-- modules/Audio.qml reflects these on its own: it binds the default sink /
-- source through PwObjectTracker, which is a live view of PipeWire's own
-- state (Quickshell.Services.Pipewire), not a Quickshell-owned copy — a
-- wpctl change made here shows up there with no extra wiring.

-- ---- brightness (brightnessctl — never write /sys/class/backlight/* here) -
-- "-n2" keeps a minimum brightness of 2 so holding the key down can't drive
-- the panel to a literally black, unreadable screen. No backlight device
-- name is passed: brightnessctl auto-detects it, same principle
-- modules/Brightness.qml already documents for its own `-m` query.
--
-- Unlike Audio.qml, modules/Brightness.qml is NOT reactive: it queries
-- brightnessctl once at startup and again only after its own click/scroll
-- handler runs a change, so a change made here (bypassing that handler)
-- would go stale in the bar. Fixed on the Quickshell side by chaining a
-- `qs ipc call brightness refresh` after brightnessctl — same IPC mechanism
-- Infinite Desktop already uses for services/Frame.qml, and it only asks the
-- widget to re-run the query it already has; the actual brightness change
-- still comes solely from brightnessctl, not from Quickshell.
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -n2 set 5%+ && qs ipc call brightness refresh"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -n2 set 5%- && qs ipc call brightness refresh"), { locked = true, repeating = true })

-- ---- media (playerctl — MPRIS; degrades to a no-op with no player running) -
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

require("lua/util").load_optional("laptop.local.lua")
