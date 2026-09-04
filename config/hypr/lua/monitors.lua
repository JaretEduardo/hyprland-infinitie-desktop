-- lua/monitors.lua — monitor layout.
-- Wiki: Configuring/Basics/Monitors
--
-- Generic, safe fallback: every output at its preferred mode, auto-placed,
-- auto-scaled. Enough to start Hyprland on any machine. NO output name is
-- hardcoded (no eDP-1) and no resolution / refresh rate is assumed here.
--
-- The specific panel + its max refresh (165 Hz) is resolved later by
-- `install.sh first-run` / `monitor`, which writes ~/.config/hypr/monitors.local.lua
-- (machine-local, git-ignored). It is loaded after this fallback so it wins.

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})

require("lua/util").load_optional("monitors.local.lua")
