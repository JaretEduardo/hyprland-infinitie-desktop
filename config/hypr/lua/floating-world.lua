-- lua/floating-world.lua — the window model for this desktop.
--
-- Every NORMAL application window opens FLOATING, at a sensible size, placed
-- near whatever you were just looking at — the desktop is a floating canvas,
-- not a tiling grid. Dialogs / transients / non-resizable tool windows keep
-- their natural size and Hyprland's own placement (Hyprland already floats
-- those, so our rule never touches them). Shell surfaces (Quickshell, fuzzel,
-- hyprlock) are layer surfaces, not windows — untouched by definition.
--
-- Targets Hyprland 0.56.2 Lua config. Only modern rules / API:
--   * hl.window_rule{ match = { float = false }, float = true, tag = "+fworld" }
--     floats every would-be-tiled window AT MAP TIME (no tile→float flash) and
--     tags it so we know it is ours.
--   * hl.on("window.open") + hl.timer → once the window is mapped, apply the
--     smart initial size and the smart placement. Event-driven, no polling.
--   * SUPER + F  → pseudo-maximize toggle (stays floating; exact restore).
--
-- Infinite Desktop: unaffected. Its daemon pans *floating* windows, and now
-- the whole workspace is floating — a pseudo-maximized window is still just a
-- floating object on the canvas and pans with everything else. SUPER + arrows
-- / SUPER + ALT touchpad / session lock / workspaces are not touched here.
-- Loaded after lua/bindings.lua (it re-binds SUPER + F).

local fw = {}

-- keep in sync with lua/appearance.lua general:gaps_out
fw.gap = (function()
    local ok, g = pcall(hl.get_config, "general:gaps_out")
    if ok and type(g) == "number" then return g end
    if ok and type(g) == "table" then return g.top or g[1] or 12 end
    return 12
end)()

fw.max_frac  = 0.85   -- an opening window never exceeds this fraction of the usable area
fw.pmax_frac = 0.96   -- pseudo-maximize leaves a ~4% visual margin

-- per-class opening size (fraction of the usable area). First substring match
-- wins; `fw.generic` is the fallback so this is an algorithm + small
-- exceptions, not a hardcoded per-app list.
fw.generic = { w = 0.66, h = 0.62 }
fw.class_defaults = {
    { pat = "foot",      w = 0.60, h = 0.58 },
    { pat = "kitty",     w = 0.60, h = 0.58 },
    { pat = "alacritty", w = 0.60, h = 0.58 },
    { pat = "wezterm",   w = 0.60, h = 0.58 },
    { pat = "xterm",     w = 0.55, h = 0.55 },
    { pat = "term",      w = 0.60, h = 0.58 },   -- st, "terminal", …
    { pat = "console",   w = 0.60, h = 0.58 },
    { pat = "firefox",   w = 0.76, h = 0.82 },
    { pat = "librewolf", w = 0.76, h = 0.82 },
    { pat = "zen",       w = 0.76, h = 0.82 },
    { pat = "chrom",     w = 0.76, h = 0.82 },   -- chromium / chrome / *-chrome
    { pat = "brave",     w = 0.76, h = 0.82 },
    { pat = "mullvad-browser", w = 0.76, h = 0.82 },
    { pat = "thunar",    w = 0.66, h = 0.68 },
    { pat = "nautilus",  w = 0.66, h = 0.68 },
    { pat = "nemo",      w = 0.66, h = 0.68 },
    { pat = "dolphin",   w = 0.66, h = 0.68 },
    { pat = "pcmanfm",   w = 0.66, h = 0.68 },
    { pat = "org.gnome.nautilus", w = 0.66, h = 0.68 },
    { pat = "code",      w = 0.82, h = 0.82 },   -- vscode / vscodium
    { pat = "jetbrains", w = 0.82, h = 0.84 },
    { pat = "sublime",   w = 0.72, h = 0.76 },
    { pat = "blender",   w = 0.85, h = 0.85 },
    { pat = "gimp",      w = 0.80, h = 0.80 },
    { pat = "inkscape",  w = 0.80, h = 0.80 },
    { pat = "kdenlive",  w = 0.85, h = 0.85 },
    { pat = "obs",       w = 0.78, h = 0.80 },
    { pat = "krita",     w = 0.82, h = 0.82 },
}

-- windows we leave completely alone even though they float (keep natural size)
fw.skip_title = { "Picture[- ]in[- ][Pp]icture", "^Firefox .- Sharing Indicator$" }
fw.skip_class = { "^xdg%-desktop%-portal", "^org%.freedesktop%.impl%.portal" }

fw.TAG   = "fworld"
fw.sized = {}   -- addr -> true, once we have placed it
-- pseudo-maximize restore geometry lives ONLY in a file (see pmax_* below), so a
-- hand edit from the World Map (world_edit.py) or SUPER + mouse (lua/window-
-- edit.lua) can invalidate it by just deleting that file.

-- ---------------------------------------------------------------------------
local function has_tag(win)
    local t = win and win.tags
    if type(t) == "table" then
        for _, v in ipairs(t) do
            if tostring(v):find(fw.TAG, 1, true) then return true end
        end
    elseif type(t) == "string" then
        return t:find(fw.TAG, 1, true) ~= nil
    end
    return false
end

local function get_win(addr)
    for _, g in ipairs(hl.get_windows() or {}) do
        if g.address == addr then return g end
    end
    return nil
end

-- hl.dsp.* returns a dispatcher object; it only runs when executed. hl.bind
-- runs it on keypress, but a standalone call must go through hl.dispatch.
local function resize_win(addr, w, h)
    hl.dispatch(hl.dsp.window.resize({ window = "address:" .. addr, x = math.floor(w), y = math.floor(h), relative = false }))
end
local function move_win(addr, x, y)
    hl.dispatch(hl.dsp.window.move({ window = "address:" .. addr, x = math.floor(x), y = math.floor(y), relative = false }))
end
local function float_win(addr)
    hl.dispatch(hl.dsp.window.float({ window = "address:" .. addr, action = "enable" }))
end
local function unfullscreen(addr)
    hl.dispatch(hl.dsp.window.fullscreen({ window = "address:" .. addr, action = "disable" }))
end

local function is_skipped(win)
    local cls = (win.initial_class or win.class or "")
    local ttl = (win.title or "")
    for _, p in ipairs(fw.skip_class) do if cls:match(p) then return true end end
    for _, p in ipairs(fw.skip_title) do if ttl:match(p) then return true end end
    return false
end

-- usable area of a monitor, in LOGICAL pixels (window coords are logical).
-- mon.width/height are physical -> divide by scale. mon.x/y are the logical
-- layout position. reserved is 0 here (Quickshell bar has exclusiveZone 0).
function fw.usable_area(mon)
    mon = mon or hl.get_active_monitor()
    if not mon then return { x = 0, y = 0, w = 1280, h = 800 } end
    local s  = mon.scale or 1
    local mw = (mon.width  or 1920) / s
    local mh = (mon.height or 1200) / s
    local mx = mon.x or 0
    local my = mon.y or 0
    local r  = mon.reserved
    local rl, rt, rr, rb = 0, 0, 0, 0
    if type(r) == "table" then
        rl = r.left or r[1] or 0; rt = r.top or r[2] or 0
        rr = r.right or r[3] or 0; rb = r.bottom or r[4] or 0
    end
    return {
        x = mx + rl + fw.gap,
        y = my + rt + fw.gap,
        w = mw - rl - rr - 2 * fw.gap,
        h = mh - rt - rb - 2 * fw.gap,
    }
end

function fw.smart_size(win, area)
    local reqw = win.size and win.size.x or nil
    local reqh = win.size and win.size.y or nil
    local maxw = area.w * fw.max_frac
    local maxh = area.h * fw.max_frac

    local frac = fw.generic
    local cls  = (win.initial_class or win.class or ""):lower()
    for _, e in ipairs(fw.class_defaults) do
        if cls:find(e.pat, 1, true) then frac = e break end
    end
    local defw, defh = area.w * frac.w, area.h * frac.h

    -- respect a request that is already reasonable; otherwise use the default
    local tw = (reqw and reqw >= 260 and reqw <= maxw) and reqw or defw
    local th = (reqh and reqh >= 200 and reqh <= maxh) and reqh or defh
    return math.floor(math.min(tw, maxw)), math.floor(math.min(th, maxh))
end

-- ring/spiral search for a spot with little overlap, near the current context
function fw.smart_place(win, tw, th, area)
    local ws  = win.workspace and win.workspace.id
    local me  = win.address
    local others = {}
    for _, g in ipairs(hl.get_windows() or {}) do
        if g.address ~= me and g.mapped and g.size and g.size.x
           and (not ws or (g.workspace and g.workspace.id == ws)) then
            others[#others + 1] = { x = g.at.x, y = g.at.y, w = g.size.x, h = g.size.y }
        end
    end

    -- anchor: the window that had focus just before this one opened
    -- (get_last_window), else the still-focused one, else the cursor, else centre
    local ax, ay
    local f = hl.get_last_window()
    if not (f and f.address ~= me and f.size and f.size.x) then
        f = hl.get_active_window()
    end
    if f and f.address ~= me and f.size and f.size.x
       and f.workspace and (not ws or f.workspace.id == ws) then
        ax = f.at.x + f.size.x / 2
        ay = f.at.y + f.size.y / 2
    else
        local c = hl.get_cursor_pos()
        if c then ax, ay = c.x, c.y
        else ax, ay = area.x + area.w / 2, area.y + area.h / 2 end
    end

    local function clamp(x, y)
        x = math.max(area.x, math.min(x, area.x + area.w - tw))
        y = math.max(area.y, math.min(y, area.y + area.h - th))
        return x, y
    end
    -- lower is better: overlap area (px², dominant) + a mild pull toward the
    -- anchor so a new window lands NEAR its context, not in a far corner.
    local function score(x, y)
        local s = 0
        for _, o in ipairs(others) do
            local ix = math.max(0, math.min(x + tw, o.x + o.w) - math.max(x, o.x))
            local iy = math.max(0, math.min(y + th, o.y + o.h) - math.max(y, o.y))
            s = s + ix * iy
        end
        local dx = (x + tw / 2) - ax
        local dy = (y + th / 2) - ay
        return s + math.sqrt(dx * dx + dy * dy) * 90
    end

    local function consider(x, y)
        x, y = clamp(x, y)
        local s = score(x, y)
        if s < best then best, bx, by = s, x, y end
    end

    -- 1) centred on the anchor
    bx, by = clamp(ax - tw / 2, ay - th / 2)
    best   = score(bx, by)
    -- 2) gentle cascade down-right from the anchor (the "next window" feel)
    for i = 1, 5 do consider(ax - tw / 2 + i * 46, ay - th / 2 + i * 46) end
    -- 3) ring: right, br, bottom, bl, left, tl, top, tr — growing radius
    local dirs = { {1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1} }
    local step = math.max(48, math.floor(math.min(tw, th) * 0.30))
    for r = 1, 7 do
        for _, d in ipairs(dirs) do
            consider(ax + d[1] * (tw / 2 + step * r) - tw / 2,
                     ay + d[2] * (th / 2 + step * r) - th / 2)
        end
    end
    return bx, by
end

function fw.apply(addr, tries)
    local win = get_win(addr)
    if not win then return end                       -- already closed
    if not has_tag(win) or fw.sized[addr] then return end
    if is_skipped(win) then fw.sized[addr] = true; return end
    if (win.fullscreen or 0) ~= 0 then return end
    if not win.mapped or not win.size or win.size.x == nil then
        if (tries or 0) < 8 then
            hl.timer(function() fw.apply(addr, (tries or 0) + 1) end,
                     { timeout = 70, type = "oneshot" })
        end
        return
    end

    local area = fw.usable_area(win.monitor)

    -- A window that opened at a modest, deliberate size is a dialog / tool /
    -- palette / PiP that has no transient parent (so Hyprland tiled it and our
    -- rule floated it). Keep it floating, but leave its size and Hyprland's
    -- centred placement alone.
    local rw, rh = win.size.x, win.size.y
    if rw >= 120 and rh >= 90
       and rw <= area.w * 0.52 and rh <= area.h * 0.52 then
        fw.sized[addr] = true
        return
    end

    local tw, th = fw.smart_size(win, area)
    local x, y   = fw.smart_place(win, tw, th, area)

    resize_win(addr, tw, th)
    move_win(addr, x, y)
    fw.sized[addr] = true
end

-- ---- pseudo-maximize (SUPER + F) --------------------------------------------
fw.pmax_dir = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-fworld"
os.execute("mkdir -p '" .. fw.pmax_dir .. "' 2>/dev/null")

local function pmax_file(addr) return fw.pmax_dir .. "/" .. addr end

-- The file is the SINGLE source of truth (no in-memory cache): SUPER + F reads
-- it fresh every press, so an external `rm` of the file — how a hand edit
-- invalidates the restore state — takes effect immediately.
local function pmax_save(addr, g)
    local f = io.open(pmax_file(addr), "w")
    if f then f:write(("%d %d %d %d"):format(g.x, g.y, g.w, g.h)); f:close() end
end
local function pmax_load(addr)
    local f = io.open(pmax_file(addr), "r")
    if not f then return nil end
    local x, y, w, h = f:read("*a"):match("(-?%d+) (-?%d+) (%d+) (%d+)")
    f:close()
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
end
local function pmax_clear(addr)
    os.remove(pmax_file(addr))
end

function fw.toggle_pmax()
    local w = hl.get_active_window()
    if not w or not w.size or w.size.x == nil then return end
    local addr = w.address

    -- SUPER + F should always land on "maximized-looking": if the app is in
    -- REAL fullscreen, drop out of it first.
    if (w.fullscreen or 0) ~= 0 then
        unfullscreen(addr)
        return
    end
    if not w.floating then float_win(addr) end

    local saved = pmax_load(addr)
    if saved then
        resize_win(addr, saved.w, saved.h)
        move_win(addr, saved.x, saved.y)
        pmax_clear(addr)
        return
    end

    local area = fw.usable_area(w.monitor)
    local pw = math.floor(area.w * fw.pmax_frac)
    local ph = math.floor(area.h * fw.pmax_frac)
    local px = math.floor(area.x + (area.w - pw) / 2)
    local py = math.floor(area.y + (area.h - ph) / 2)
    pmax_save(addr, { x = math.floor(w.at.x), y = math.floor(w.at.y),
                      w = math.floor(w.size.x), h = math.floor(w.size.y) })
    resize_win(addr, pw, ph)
    move_win(addr, px, py)
end

-- ---- wiring ----------------------------------------------------------------
hl.window_rule({
    name  = "fworld-float-default",
    match = { float = false, fullscreen = false },
    float = true,
    tag   = "+" .. fw.TAG,
})

hl.on("window.open", function(w)
    if w and w.address then
        local addr = w.address
        hl.timer(function() fw.apply(addr, 0) end, { timeout = 90, type = "oneshot" })
    end
end)

hl.on("window.close", function(w)
    local addr = type(w) == "userdata" and w.address or (type(w) == "string" and w or nil)
    if addr then
        fw.sized[addr] = nil
        pmax_clear(addr)
    end
end)

hl.unbind("SUPER + F")
hl.bind("SUPER + F", function() fw.toggle_pmax() end)

-- keep real fullscreen reachable for apps that genuinely need it
hl.unbind("SUPER + SHIFT + F")
hl.bind("SUPER + SHIFT + F", hl.dsp.window.fullscreen({ action = "toggle" }))

return fw
