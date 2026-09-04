-- lua/env.lua — environment variables (evaluated once at config load).
-- Wiki: Configuring/Advanced-and-Cool/Environment-variables

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- ~/.local/bin on PATH — not guaranteed otherwise. Hyprland's own PATH is
-- whatever launched it (tty/greeter), with no login shell profile in between
-- on most setups; Quickshell (autostart.lua) and everything it spawns (e.g.
-- modules/NvidiaGpu.qml calling nvidia-compute-mode / nvidia-offload by name,
-- both linked into ~/.local/bin by install.sh dotfiles) inherit that PATH
-- unchanged. Set it here, before autostart.lua runs, rather than relying on a
-- shell profile. Guarded so reloading the config does not keep re-prepending.
do
    local home = os.getenv("HOME")
    if home ~= nil and home ~= "" then
        local localBin = home .. "/.local/bin"
        local current = os.getenv("PATH") or ""
        if not string.find(":" .. current .. ":", ":" .. localBin .. ":", 1, true) then
            hl.env("PATH", localBin .. ":" .. current)
        end
    end
end

-- GPU: the AMD Radeon 680M iGPU must stay Hyprland's compositor GPU, so the
-- NVIDIA dGPU remains on-demand (docs/HYBRID-GPU.md). Aquamarine chooses its
-- render GPU from AQ_DRM_DEVICES — a ':'-separated priority list; the first
-- device is the primary renderer.
--
-- The correct value depends on this machine's PCI addresses / the stable
-- /dev/dri/hypr-primary and /dev/dri/hypr-secondary symlinks that
-- `install.sh gpu` creates, so it is NOT hardcoded here (no card0/card1).
-- `install.sh desktop` writes it to ~/.config/hypr/gpu.local.lua as e.g.
--     hl.env("AQ_DRM_DEVICES", "/dev/dri/hypr-primary:/dev/dri/hypr-secondary")
-- Until then, Aquamarine auto-selects the boot_vga GPU (the AMD iGPU on this
-- laptop), which is the desired result anyway.
require("lua/util").load_optional("gpu.local.lua")
