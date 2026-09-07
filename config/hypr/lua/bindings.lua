-- lua/bindings.lua — basic desktop keybinds only.
-- Wiki: Configuring/Basics/Binds, Configuring/Core/Dispatchers
--
-- NOT here (added by later stages):
--   - XF86 media / brightness / volume keys
--   - the Infinite Desktop binds (SUPER + arrows navigate, SUPER + SHIFT +
--     arrows move, SUPER + ALT + arrows tiled-move, SUPER + CTRL + arrows
--     resize, SUPER + D toggle floating/tiled). Stage 16 replaces the plain
--     "move focus" binds on SUPER + arrows below with Infinite Desktop's
--     richer navigate handler.

local mod = "SUPER"

local terminal = os.getenv("TERMINAL")
if terminal == nil or terminal == "" then
    terminal = "foot"
end

hl.bind(mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + Q",      hl.dsp.window.close())
hl.bind(mod .. " + V",      hl.dsp.window.float({ action = "toggle" }))
-- SUPER + F is re-bound by lua/floating-world.lua to pseudo-maximize (real
-- fullscreen moves to SUPER + SHIFT + F). This line is the fallback if that
-- module fails to load.
hl.bind(mod .. " + F",      hl.dsp.window.fullscreen({ action = "toggle" }))
hl.bind(mod .. " + P",      hl.dsp.window.pseudo())
hl.bind(mod .. " + T",      hl.dsp.layout("togglesplit"))     -- dwindle

-- Launcher — the native Quickshell one (config/quickshell/Launcher.qml):
--   * a plain SUPER tap-and-release (release = true, so it does NOT fire when
--     SUPER was part of a combo like SUPER+W)
--   * SUPER + Space as well
-- fuzzel stays installed as a fallback: SUPER + SHIFT + Space, in case
-- Quickshell is not running.
hl.bind(mod .. " + Super_L", hl.dsp.exec_cmd("qs ipc call launcher toggle"), { release = true })
hl.bind(mod .. " + Space",         hl.dsp.exec_cmd("qs ipc call launcher toggle"))
hl.bind(mod .. " + SHIFT + Space", hl.dsp.exec_cmd("fuzzel"))

-- Wallpaper picker — the Quickshell panel docked under the navbar
-- (config/quickshell/panels/WallpaperPicker.qml). Same panel the navbar's
-- wallpaper button opens.
hl.bind(mod .. " + W", hl.dsp.exec_cmd("qs ipc call panel toggle wallpapers"))

-- World Map — the Infinite Desktop minimap (config/quickshell/WorldMap.qml).
-- Same overlay the navbar centre ring opens. (Alt+Tab is not bound.)
hl.bind(mod .. " + Tab", hl.dsp.exec_cmd("qs ipc call worldmap toggle"))

-- Screenshots -> ~/.local/bin/hypr-screenshot (scripts/desktop/hypr-screenshot,
-- linked by dotfiles). Files go to <Pictures>/Screenshots/, region + Super+Print
-- also copy the image to the clipboard. Cancelling the region select is silent.
hl.bind("Print",                hl.dsp.exec_cmd("hypr-screenshot full"))
hl.bind(mod .. " + Print",      hl.dsp.exec_cmd("hypr-screenshot full --copy"))
hl.bind(mod .. " + SHIFT + S",  hl.dsp.exec_cmd("hypr-screenshot region"))

-- Move focus
hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- Workspaces 1..10 ; SHIFT moves the active window there
for i = 1, 10 do
    local key = i % 10        -- 10 -> "0"
    hl.bind(mod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- Cycle through existing workspaces with the scroll wheel
hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Move / resize the window under the cursor
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
