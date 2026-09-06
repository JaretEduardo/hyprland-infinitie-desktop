-- lua/autostart.lua — only what is genuinely needed for a usable session now.
-- Wiki: Configuring/Basics/Autostart
--
-- NOT started here: hyprlock (only ever launched by hypridle's own
-- lock_cmd — see config/hypridle/hypridle.conf and docs/POWER.md), hyprpaper,
-- any NVIDIA / GPU service.

hl.on("hyprland.start", function()
    -- Make the Wayland session visible to the systemd user session and D-Bus
    -- so xdg-desktop-portal and user services work.
    hl.exec_cmd("systemctl --user import-environment PATH WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE")

    -- polkit authentication agent — the thing that renders privilege prompts.
    -- Repo standard: sys-auth/hyprpolkitagent (install/packages.gentoo), which
    -- ships the systemd *user* unit started here. `systemctl --user start` is
    -- idempotent (a no-op if already running). Harmless if not installed yet;
    -- needs `systemctl --user daemon-reload` once after first install (or a
    -- re-login) for the unit to be found.
    hl.exec_cmd("systemctl --user start hyprpolkitagent.service")

    -- mako: the notification daemon (owns org.freedesktop.Notifications).
    -- Guarded exactly like qs / hypridle below — a config reload or a stray
    -- extra run can never spawn a second instance. mako is also D-Bus
    -- activatable, so a notification sent before this runs still starts it;
    -- this only makes it come up with the session. Harmless if not installed.
    hl.exec_cmd("command -v mako >/dev/null 2>&1 && (pgrep -x mako >/dev/null || mako) || true")

    -- Quickshell (config/quickshell/, linked to ~/.config/quickshell/ by
    -- `install.sh dotfiles --apply`). Guarded so a Hyprland config reload (which
    -- re-fires this file's own module load, though NOT the hyprland.start event
    -- itself) or a stray extra run can never spawn a second bar instance.
    -- Harmless if `qs` is not installed yet.
    hl.exec_cmd("command -v qs >/dev/null 2>&1 && (pgrep -x qs >/dev/null || qs) || true")

    -- hypridle: the sole owner of idle timers / locking / DPMS / suspend-by-
    -- inactivity (docs/POWER.md). Guarded the same way as qs above, so a
    -- config reload (which re-fires this module's load, though not this
    -- hyprland.start event itself) can never spawn a second instance.
    -- Harmless if hypridle is not installed yet.
    hl.exec_cmd("command -v hypridle >/dev/null 2>&1 && (pgrep -x hypridle >/dev/null || hypridle) || true")
end)
