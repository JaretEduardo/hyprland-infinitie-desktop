-- lua/appearance.lua — a clean, minimal base. Quickshell owns the visual layer
-- (bar, widgets, theming) in a later stage; keep this restrained.
-- Wiki: Configuring/Basics/Variables

hl.config({
    general = {
        gaps_in          = 4,
        gaps_out         = 8,
        border_size      = 2,
        layout           = "dwindle",
        resize_on_border = true,
    },

    decoration = {
        rounding         = 6,
        active_opacity   = 1.0,
        inactive_opacity = 1.0,
        blur   = { enabled = false },
        shadow = { enabled = false },
    },

    animations = {
        enabled = true,       -- Hyprland's built-in defaults
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
    },
})
