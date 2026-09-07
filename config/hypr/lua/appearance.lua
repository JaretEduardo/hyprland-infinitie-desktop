-- lua/appearance.lua — look & feel, reconstructed toward the @gentoolarp rice:
-- warm dark-plum / dusty-mauve, soft borders, gentle blur + shadow, fluid
-- (not flashy) animations. Quickshell owns the bar/panels; this owns
-- Hyprland's own decoration. Targets Hyprland 0.56 Lua config (no legacy syntax).
--
-- COLOURS are wallpaper-driven: `hypr-wallpaper` (wallust) regenerates
--   ~/.config/hypr/colors.local.lua
-- from config/wallust/templates/hyprland-colors.lua. Only the three colour
-- values below come from there; gaps / rounding / blur / animations are static.
-- If that file is absent or broken, the built-in fallback is used.

local C = (function()
    local fallback = {
        active_border   = { "rgba(e6c4d8ff)", "rgba(c79db4dd)" },
        inactive_border = "rgba(2e2230aa)",
        shadow          = 0xcc1c1119,
    }
    local home = os.getenv("HOME")
    if not home then return fallback end
    local ok, gen = pcall(dofile, home .. "/.config/hypr/colors.local.lua")
    if not ok or type(gen) ~= "table" then return fallback end
    return {
        active_border   = (type(gen.active_border) == "table" and #gen.active_border == 2)
                           and gen.active_border or fallback.active_border,
        inactive_border = gen.inactive_border or fallback.inactive_border,
        shadow          = gen.shadow or fallback.shadow,
    }
end)()

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 12,
        border_size = 2,
        layout = "dwindle",
        resize_on_border = true,

        col = {
            -- accent -> darker accent, 40°. Subtle, only the focused window.
            -- Values from C (wallpaper-driven, see top of file).
            active_border   = { colors = C.active_border, angle = 40 },
            inactive_border = C.inactive_border,
        },
    },

    decoration = {
        rounding       = 8,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 0.94,

        blur = {
            enabled           = true,
            size              = 6,
            passes            = 2,
            vibrancy          = 0.15,
            vibrancy_darkness  = 0.05,
            noise             = 0.015,
            contrast          = 1.0,
            brightness        = 0.92,
            new_optimizations = true,
            ignore_opacity    = true,
            popups            = true,
            xray              = false,
        },

        shadow = {
            enabled      = true,
            range        = 16,
            render_power = 3,
            color        = C.shadow,
        },
    },

    animations = { enabled = true },

    dwindle = { preserve_split = true },

    misc = {
        -- We draw our own wallpaper in Quickshell; keep Hyprland's off.
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
    },
})

-- ---- curves + animations (gentle) ----------------------------------------
hl.curve("easeOut",   { type = "bezier", points = { {0.16, 1.0}, {0.30, 1.0} } })
hl.curve("easeInOut", { type = "bezier", points = { {0.42, 0.0}, {0.20, 1.0} } })
hl.curve("snappy",    { type = "bezier", points = { {0.20, 0.9}, {0.10, 1.0} } })

hl.animation({ leaf = "global",     enabled = true, speed = 7,    bezier = "easeOut"    })
hl.animation({ leaf = "windows",    enabled = true, speed = 5.0,  bezier = "easeOut",   style = "popin 92%" })
hl.animation({ leaf = "windowsIn",  enabled = true, speed = 4.6,  bezier = "easeOut",   style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 3.6,  bezier = "easeInOut", style = "popin 92%" })
hl.animation({ leaf = "border",     enabled = true, speed = 6.0,  bezier = "easeOut"    })
hl.animation({ leaf = "fade",       enabled = true, speed = 5.0,  bezier = "easeOut"    })
hl.animation({ leaf = "fadeIn",     enabled = true, speed = 5.0,  bezier = "easeOut"    })
hl.animation({ leaf = "fadeOut",    enabled = true, speed = 5.0,  bezier = "easeOut"    })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4.0,  bezier = "easeInOut", style = "slidefade" })
hl.animation({ leaf = "layers",     enabled = true, speed = 4.2,  bezier = "easeOut",   style = "fade" })
hl.animation({ leaf = "layersIn",   enabled = true, speed = 4.2,  bezier = "easeOut",   style = "fade" })
hl.animation({ leaf = "layersOut",  enabled = true, speed = 3.2,  bezier = "easeInOut", style = "fade" })

-- ---- frost the Quickshell bar + panels + launcher (not the wallpaper layer) --
-- PanelHost reuses the "quickshell:dashboard" namespace, so the WallpaperPicker
-- is covered by qs-dash-blur too. The launcher is its own centred overlay.
hl.layer_rule({ name = "qs-bar-blur",  match = { namespace = "quickshell:bar" },       blur = true, ignore_alpha = 0.30 })
hl.layer_rule({ name = "qs-dash-blur", match = { namespace = "quickshell:dashboard" }, blur = true, ignore_alpha = 0.20 })
hl.layer_rule({ name = "qs-launch-blur", match = { namespace = "quickshell:launcher" }, blur = true, ignore_alpha = 0.16 })
hl.layer_rule({ name = "qs-worldmap-blur", match = { namespace = "quickshell:worldmap" }, blur = true, ignore_alpha = 0.16 })
