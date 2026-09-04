-- hyprland.lua — entrypoint. Keep this file tiny: it only loads the modules.
--
-- Modular Hyprland configuration for this workstation. Targets Hyprland >= 0.55
-- (modern Lua config; the old .conf format is not used).
--
-- Each require() is a separate Lua scope in Hyprland, so an error in one module
-- does not stop the others. Modules are loaded in a deliberate order:
-- environment first, then monitors, input, appearance, binds, and autostart last.
--
-- Machine-local, git-ignored overrides live beside this file as
--   ~/.config/hypr/monitors.local.lua   (written by: install.sh first-run / monitor)
--   ~/.config/hypr/gpu.local.lua         (written by: install.sh desktop)
--   ~/.config/hypr/input.local.lua       (optional, hand-written)
--   ~/.config/hypr/laptop.local.lua      (optional, hand-written)
-- The relevant module loads them if present (see lua/util.lua).

require("lua/env")
require("lua/monitors")
require("lua/input")
require("lua/appearance")
require("lua/bindings")
require("lua/laptop")
require("lua/autostart")
require("lua/infinite-desktop")
