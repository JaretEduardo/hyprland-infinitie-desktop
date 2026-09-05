-- lua/input.lua — input base for a laptop. No device names are assumed.
-- Wiki: Configuring/Basics/Variables (input.*), Configuring/Binds/Gestures
--
-- Touchpad option names (natural_scroll, tap_to_click, disable_while_typing)
-- are long-standing Hyprland input options; re-confirm against the installed
-- Hyprland on Gentoo if a reload complains.

hl.config({
    input = {
        -- latam: physical layout of this workstation. Validated live with
        --   hyprctl eval 'hl.config({ input = { kb_layout = "latam" } })'
        -- Override per-machine in ~/.config/hypr/input.local.lua if ever needed.
        kb_layout    = "latam",
        follow_mouse = 1,
        sensitivity  = 0,        -- -1.0 .. 1.0 ; 0 = unmodified

        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            disable_while_typing = true,
        },
    },
})

-- Three-finger horizontal swipe changes workspace.
hl.gesture({
    fingers   = 3,
    direction = "horizontal",
    action    = "workspace",
})

require("lua/util").load_optional("input.local.lua")
