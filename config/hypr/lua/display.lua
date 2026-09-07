-- lua/display.lua — adaptive monitor / workspace handling (STAGE 1).
--
-- Monitors are physical viewports onto ONE Infinite Desktop; a workspace does
-- not belong to a monitor. When a workspace changes monitor (Hyprland's
-- auto-relocate on unplug, or hl.dsp.workspace.move) Hyprland translates its
-- windows by the monitor-origin delta, so `worldX = at.x + camera.x` drifts.
-- scripts/infinite-desktop/display_manager.py realigns camera.json (world
-- coordinates never move). See docs/INFINITE-DESKTOP.md "Adaptive displays".
--
-- Nothing here changes modes / scale / positions / workspace assignment — that
-- is Stage 2 (Settings). Loaded after lua/infinite-desktop (it reuses
-- ~/scripts/world.py + hypr_ipc.py).

-- `hyprctl reload` may re-run this file. Harmless: every reaction is idempotent
-- (`sync` no-ops once a workspace's `frame` matches, `snapshot` self-debounces),
-- and none of them run without an actual hotplug event.

local PY = "python3 ~/scripts/display_manager.py "

local function later(ms, arg)          -- settle, so Hyprland reacts to the event first
    hl.timer(function() hl.exec_cmd(PY .. arg) end,
             { timeout = ms, type = "oneshot" })
end

hl.on("monitor.removed",           function() later(250, "sync") end)
hl.on("monitor.added",             function() later(400, "restore") end)
hl.on("monitor.layout_changed",    function() later(150, "snapshot") end)
hl.on("workspace.move_to_monitor", function() later(150, "snapshot") end)

-- on config load (session start OR `hyprctl reload`): re-learn topology only.
-- This records; it never moves a window or a workspace or the camera.
later(1500, "snapshot --force")
