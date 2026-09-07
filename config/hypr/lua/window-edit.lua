-- lua/window-edit.lua — desktop-side window manipulation, and the guard that
-- keeps a SUPER tap from opening the launcher when SUPER was used with the mouse.
--
-- SUPER + LMB drag  → move a floating window   (hl.dsp.window.drag,  bindings.lua)
-- SUPER + RMB drag  → resize a floating window (hl.dsp.window.resize, bindings.lua)
-- Those are the plain Hyprland interactive-drag binds — the canonical
-- `{ mouse = true }` form, same as the stock config. This module does not
-- reimplement them; it adds two things around them:
--
--   1. SUPER-tap guard. A bare SUPER tap opens the Quickshell launcher
--      (lua/bindings.lua, release bind on Super_L). Hyprland suppresses that tap
--      after a SUPER + key combo, but not reliably after a SUPER + mouse drag —
--      so pressing SUPER, dragging a window and releasing SUPER would pop the
--      launcher. We track "SUPER touched the mouse" and swallow the next tap.
--
--   2. Pseudo-maximize coherence. Editing a window's geometry by hand (here, or
--      from the World Map) clears its pseudo-maximize restore file
--      ($XDG_RUNTIME_DIR/hypr-fworld/<addr>, lua/floating-world.lua). That file
--      is now the single source of truth for SUPER + F, so removing it makes the
--      hand-placed geometry the window's new "normal" — SUPER + F won't snap it
--      back to a stale box. Only the edited window is affected.
--
-- Loaded after lua/floating-world.lua.

local mod = "SUPER"

-- ---- SUPER-tap guard ----------------------------------------------------
local guard = { dirty = false, timer = nil }

local function guard_bump()
    guard.dirty = true
    if guard.timer then pcall(function() guard.timer:set_enabled(false) end) end
    -- clear a short moment after the gesture ends; re-armed on mouse release so
    -- even a long drag stays covered.
    guard.timer = hl.timer(function() guard.dirty = false end,
                           { timeout = 700, type = "oneshot" })
end

-- SUPER + LMB / RMB release marks the modifier as "used with the mouse".
-- non_consuming so the plain drag bind (lua/bindings.lua) still runs.
for _, btn in ipairs({ "mouse:272", "mouse:273" }) do
    hl.bind(mod .. " + " .. btn, function() guard_bump() end,
            { non_consuming = true, release = true })
end

-- Re-bind the SUPER tap with the guard in front. lua/bindings.lua keeps the
-- plain version, which stays active if this module fails to load.
hl.unbind(mod .. " + Super_L")
hl.bind(mod .. " + Super_L", function()
    if guard.dirty then
        guard.dirty = false
        return
    end
    hl.dispatch(hl.dsp.exec_cmd("qs ipc call launcher toggle"))
end, { release = true })

-- ---- pseudo-maximize coherence ---------------------------------------
local pmax_dir = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-fworld"

local function window_under_cursor()
    local c = hl.get_cursor_pos()
    if not c then return hl.get_active_window() end
    local hit
    for _, g in ipairs(hl.get_windows() or {}) do
        if g.mapped and g.at and g.size and g.size.x then
            if c.x >= g.at.x and c.x <= g.at.x + g.size.x
               and c.y >= g.at.y and c.y <= g.at.y + g.size.y then
                hit = g   -- last match ≈ topmost
            end
        end
    end
    return hit or hl.get_active_window()
end

local function drop_pmax_under_cursor()
    local w = window_under_cursor()
    if w and w.address then os.remove(pmax_dir .. "/" .. w.address) end
end

-- SUPER + mouse press: a hand edit is starting on the window under the cursor.
for _, btn in ipairs({ "mouse:272", "mouse:273" }) do
    hl.bind(mod .. " + " .. btn, function() drop_pmax_under_cursor() end,
            { non_consuming = true })
end

-- ---- Viewport Mosaic + keyboard window navigation -------------------
--   SUPER + M                  → toggle the Viewport Mosaic (a temporary tidy
--                                layout of the windows in the viewport;
--                                scripts/infinite-desktop/viewport_mosaic.py).
--                                Nothing is tiled, the camera never moves.
--   SUPER + ALT + Tab          → next individual WINDOW. While a mosaic is up:
--   SUPER + ALT + SHIFT + Tab  → prev — pure focus move across the mosaic, no
--                                camera. Otherwise: spatial navigation over
--                                every window (each Foot is its own stop).
--   SUPER + ALT + 1 .. 9       → the Nth navbar app icon (grouped by app;
--                                repeat cycles that app's windows). Quickshell
--                                owns that list (OpenAppsModel.qml) — NO class
--                                names here.
--
-- Every bind arms the SUPER-tap guard, so releasing SUPER after the combo
-- never opens the launcher.
local function guarded_exec(cmd)
    return function()
        guard_bump()
        hl.dispatch(hl.dsp.exec_cmd(cmd))
    end
end

hl.bind(mod .. " + M", guarded_exec("python3 ~/scripts/viewport_mosaic.py toggle"))

hl.bind(mod .. " + ALT + Tab",         guarded_exec("python3 ~/scripts/world_navigate.py next-window"))
hl.bind(mod .. " + ALT + SHIFT + Tab", guarded_exec("python3 ~/scripts/world_navigate.py prev-window"))
for i = 1, 9 do
    hl.bind(mod .. " + ALT + " .. i, guarded_exec("qs ipc call openapps activate " .. i))
end
