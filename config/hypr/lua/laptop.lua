-- lua/laptop.lua — laptop-specific configuration. SEAM.
--
-- Touchpad settings are in lua/input.lua (they belong with input config).
--
-- Later stages add here:
--   - XF86 media / brightness / volume keybinds (a dedicated "laptop keybinds"
--     stage), e.g.
--       hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),  { locked = true, repeating = true })
--       hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume ..."),           { locked = true, repeating = true })
--   - any laptop-only misc tweaks
--
-- Nothing here yet on purpose — this stage only lays the modular skeleton.
-- Power / idle (hypridle, hyprlock, logind ownership) is a separate stage and
-- does NOT live here.

require("lua/util").load_optional("laptop.local.lua")
