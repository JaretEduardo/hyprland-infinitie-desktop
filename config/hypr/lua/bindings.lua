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
hl.bind(mod .. " + F",      hl.dsp.window.fullscreen({ action = "toggle" }))
hl.bind(mod .. " + P",      hl.dsp.window.pseudo())
hl.bind(mod .. " + T",      hl.dsp.layout("togglesplit"))     -- dwindle

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
