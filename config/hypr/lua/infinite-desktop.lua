-- lua/infinite-desktop.lua — the ONLY seam between Infinite Desktop and the
-- rest of the Hyprland config. Loaded last (after lua/bindings.lua).
--
-- Infinite Desktop is a Python/evdev component installed to ~/scripts by
-- `install.sh infinite-desktop`:
--   infinite_desktop_core.py  evdev daemon: pans all floating windows on
--                             SUPER + ALT + mouse, drives the keybinds below,
--                             optional Quickshell frame hint (qs ipc call frame)
--   navigate_windows.py       focus / centre the next window
--   move_window.py            move the active floating window (edge-pushes others)
--   move_window_tiled.py      move a tiled window
--   resize_window.py          resize the active floating window
--   floating_tile_toggle.py   toggle floating/tiled for the whole workspace
--   hypr_ipc.py               the single place all hyprctl dispatch calls are built
-- See docs/INFINITE-DESKTOP.md.

local mod = "SUPER"

-- Autostart the evdev daemon. "1.6" is the pan-speed multiplier (its only arg).
-- The daemon owns its own lifecycle (scripts/infinite-desktop/session_lock.py):
-- exactly one instance per Hyprland session, self-exiting when THIS session
-- ends, logging to $XDG_RUNTIME_DIR/infinite-desktop/<signature>.log. So this
-- line deliberately does NOT redirect output and does NOT `pgrep`-guard — a
-- pgrep guard would risk keeping a previous session's instance alive.
hl.on("hyprland.start", function()
    hl.exec_cmd("python3 ~/scripts/infinite_desktop_core.py 1.6")
end)

-- SUPER + arrows: Infinite Desktop's navigate replaces the plain "move focus"
-- binds from lua/bindings.lua (same keys, richer behaviour). Unbind first — a
-- second hl.bind on the same key would add a handler, not replace it.
for _, d in ipairs({ "left", "right", "up", "down" }) do
    hl.unbind(mod .. " + " .. d)

    hl.bind(mod .. " + " .. d,
        hl.dsp.exec_cmd("python3 ~/scripts/navigate_windows.py " .. d))

    hl.bind(mod .. " + SHIFT + " .. d,
        hl.dsp.exec_cmd("python3 ~/scripts/move_window.py " .. d), { repeating = true })

    hl.bind(mod .. " + ALT + " .. d,
        hl.dsp.exec_cmd("python3 ~/scripts/move_window_tiled.py " .. d))

    hl.bind(mod .. " + CTRL + " .. d,
        hl.dsp.exec_cmd("python3 ~/scripts/resize_window.py " .. d), { repeating = true })
end

-- SUPER + D: toggle floating / tiled for every window on the workspace.
hl.bind(mod .. " + D", hl.dsp.exec_cmd("python3 ~/scripts/floating_tile_toggle.py"))

-- SUPER + Z / X: previous / next workspace ; + SHIFT: move the active window there.
hl.bind(mod .. " + Z",         hl.dsp.focus({ workspace = "-1" }))
hl.bind(mod .. " + X",         hl.dsp.focus({ workspace = "+1" }))
hl.bind(mod .. " + SHIFT + Z", hl.dsp.window.move({ workspace = "-1" }))
hl.bind(mod .. " + SHIFT + X", hl.dsp.window.move({ workspace = "+1" }))
