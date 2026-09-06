# Session: launching Hyprland, environment, portals, audio

What a reconstructed minimal Gentoo needs for a *working* Hyprland session —
the pieces that used to depend on packages/config that happened to be installed
by hand. `install.sh doctor` has a section for each of these.

## Launching from a TTY

This repo targets the plain launch: log in on a TTY and run

```
Hyprland
```

(no display manager, no `uwsm` — `gui-wm/hyprland` is built `-uwsm`). `pam_systemd`
gives the login a `XDG_RUNTIME_DIR` and a D-Bus **session** bus; Hyprland then
sets `XDG_CURRENT_DESKTOP=Hyprland` and `XDG_SESSION_TYPE=wayland` itself.

## Session identity variables

`config/hypr/lua/env.lua` sets, before anything else runs:

| variable | value | why |
| --- | --- | --- |
| `XDG_CURRENT_DESKTOP` | `Hyprland` | picks the portal backend (`hyprland-portals.conf`) |
| `XDG_SESSION_TYPE` | `wayland` | apps choose their Wayland vs X11 path |
| `XDG_SESSION_DESKTOP` | `Hyprland` | session identity; nothing else sets it on a bare launch |

All three are the correct values for this compositor session however it was
launched, so re-affirming them is safe. `config/hypr/lua/autostart.lua` then
runs `systemctl --user import-environment …` and
`dbus-update-activation-environment --systemd …` for the same set plus
`WAYLAND_DISPLAY` / `PATH`, so D-Bus-activated services (xdg-desktop-portal,
mako, hyprpolkitagent) and the systemd user session see them.

## Xwayland (X11 apps)

`gui-wm/hyprland` must be built with **`USE="X"`** — that both compiles the
XWayland support into Hyprland and pulls `x11-base/xwayland`. It is default USE
on the `default/linux/amd64/23.0/desktop/systemd` profile this repo targets, so
a stock desktop/systemd install needs no `package.use` entry. `USE="systemd"`
(user-session integration) and `USE="dbus-session"` are likewise profile
defaults. `doctor`'s *Xwayland* section reads the built flags from the vdb and
warns if `X` is off. Hyprland starts the Xwayland server lazily, on the first
X11 client.

## Desktop portals and PipeWire screen sharing

```
app ──D-Bus──► xdg-desktop-portal ──picks a backend──► xdg-desktop-portal-hyprland   (ScreenCast, Screenshot, GlobalShortcuts)
                                                   └──► xdg-desktop-portal-gtk        (FileChooser, Settings)
                                        xdph captures via wlroots screencopy and
                                        streams the video over PipeWire
```

| package | tier | role |
| --- | --- | --- |
| `sys-apps/xdg-desktop-portal` | required | the frontend (`org.freedesktop.portal.Desktop`) |
| `gui-libs/xdg-desktop-portal-hyprland` | required | screencast / screenshot / global shortcuts, via `wlr-screencopy` + PipeWire |
| `sys-apps/xdg-desktop-portal-gtk` | required | the **file chooser** and the light/dark Setting — xdph does not implement these |
| `media-video/pipewire` | required | carries the screencast video streams |

Backend selection is pinned by `config/xdg-desktop-portal/hyprland-portals.conf`
(linked to `~/.config/xdg-desktop-portal/` by `install.sh dotfiles`): the
Hyprland backend first, GTK for the file chooser.

**Apps that need this:** Firefox / Chromium / Discord / OBS / Zoom / any Electron
app for *screen sharing*; Chromium / Electron / Flatpak apps for *"Open File"*
dialogs. Without the portal, "Share screen" shows nothing; without the GTK
backend, those file dialogs fail or fall back badly.

**Known limitations:** window-by-window picking and region selection in the
share dialog depend on the xdph version; a game or app that grabs DRM lease
output cannot be captured; the first screencast after login can take a second
while PipeWire spins up.

## Audio (PipeWire / WirePlumber)

`media-video/pipewire` + `media-video/wireplumber` are `required`, but their
**user units are socket-activated and not enabled by anything in this repo.**
Enable them once — no root, reversible:

```
systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
```

`install.sh first-run --apply` offers to run exactly this; `doctor`'s *Audio
session* section checks it and prints the command if the units are `disabled`.
`pipewire-pulse.socket` provides the PulseAudio API that Firefox / Discord / most
apps still use. `sys-auth/rtkit` (`recommended`) gives PipeWire realtime
scheduling.

## Power keys (logind drop-in)

`install.sh power --apply` writes
`/etc/systemd/logind.conf.d/50-hyprland-infinite-desktop.conf` (needs root).
Until it is applied, **a single Power-key press powers the machine off** instead
of locking (systemd's default `HandlePowerKey=poweroff`). `doctor` reads the
live values logind publishes over D-Bus and warns until the drop-in is in place.
Full matrix in [POWER.md](POWER.md).

## Fonts

No config names a font family — `mako` / `fuzzel` / `foot` / `hyprlock` /
Quickshell all use the fontconfig aliases `sans-serif` / `monospace`.
`media-fonts/dejavu` (`required`) backs those. `media-fonts/noto` +
`media-fonts/noto-emoji` (`recommended`, `~amd64`) add broad Unicode and colour
emoji. `doctor` runs `fc-match` to check the aliases resolve.
