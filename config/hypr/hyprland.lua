-- hyprland.lua — entrypoint. Loads the modules; keep this file tiny.
--
-- Modular Hyprland configuration for this workstation. Targets Hyprland >= 0.55
-- (modern Lua config; the old .conf format is not used).
--
-- Each module is loaded through pcall(require, ...) so a syntax error, a runtime
-- error, or a missing file in one module is reported to Hyprland's log but does
-- NOT stop the other modules from loading. (Plain require() propagates such
-- errors; Hyprland isolates runtime errors in existing files but still aborts on
-- a missing module — verified — so the wrapper is here, not in each module.)
--
-- Machine-local, git-ignored overrides live beside this file as
--   ~/.config/hypr/monitors.local.lua   (written by: install.sh first-run / monitor)
--   ~/.config/hypr/gpu.local.lua         (optional, hand-written — install.sh gpu
--                                          only prints the AQ_DRM_DEVICES line)
--   ~/.config/hypr/input.local.lua       (optional, hand-written)
--   ~/.config/hypr/laptop.local.lua      (optional, hand-written)
-- The relevant module loads them if present (see lua/util.lua).

local function load(mod)
    local ok, err = pcall(require, mod)
    if not ok then
        io.stderr:write("hyprland-infinitie: module '" .. mod ..
                        "' failed to load: " .. tostring(err) .. "\n")
    end
end

-- Deliberate order: environment first, monitors, input, appearance, binds,
-- laptop, then autostart, and Infinite Desktop last (it overrides some binds).
load("lua/env")
load("lua/monitors")
load("lua/input")
load("lua/appearance")
load("lua/bindings")
load("lua/laptop")
load("lua/autostart")
load("lua/infinite-desktop")
