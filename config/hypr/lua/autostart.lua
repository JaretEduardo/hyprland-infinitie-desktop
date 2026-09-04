-- lua/autostart.lua — only what is genuinely needed for a usable session now.
-- Wiki: Configuring/Basics/Autostart
--
-- NOT started here (added when their configs exist / by later stages):
--   hypridle, hyprlock, hyprpaper, any NVIDIA / GPU service.

hl.on("hyprland.start", function()
    -- Make the Wayland session visible to the systemd user session and D-Bus
    -- so xdg-desktop-portal and user services work.
    hl.exec_cmd("systemctl --user import-environment PATH WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE")

    -- polkit authentication agent (privilege prompts). Harmless if the unit is
    -- not installed; a later stage adds the package.
    hl.exec_cmd("systemctl --user start hyprpolkitagent.service")

    -- Quickshell (config/quickshell/, linked to ~/.config/quickshell/ by
    -- `install.sh dotfiles --apply`). Guarded so a Hyprland config reload (which
    -- re-fires this file's own module load, though NOT the hyprland.start event
    -- itself) or a stray extra run can never spawn a second bar instance.
    -- Harmless if `qs` is not installed yet.
    hl.exec_cmd("command -v qs >/dev/null 2>&1 && (pgrep -x qs >/dev/null || qs) || true")
end)
