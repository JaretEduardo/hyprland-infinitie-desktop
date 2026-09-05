-- lua/util.lua — small shared helpers for this config.

local M = {}

-- Load an optional machine-local file ~/.config/hypr/<rel> if it exists.
-- Used for git-ignored, per-machine overrides (monitors.local.lua, gpu.local.lua,
-- …). A missing file is silent; a broken file raises (Hyprland pops the error
-- for this module only). Returns true if a file was loaded.
function M.load_optional(rel)
    local base = os.getenv("XDG_CONFIG_HOME")
    if base == nil or base == "" then
        local home = os.getenv("HOME")
        if home == nil or home == "" then
            return false
        end
        base = home .. "/.config"
    end

    local path = base .. "/hypr/" .. rel
    local f = io.open(path, "r")
    if f == nil then
        return false
    end
    f:close()

    assert(loadfile(path))()
    return true
end

return M
