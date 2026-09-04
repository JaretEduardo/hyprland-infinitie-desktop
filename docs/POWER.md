# Power: idle, lock, suspend, lid

The rule this stage is built around: **every power event has exactly one
owner.** No event is watched by two of {logind, hypridle, Hyprland, a custom
script} at once — that's what causes double suspends, duplicate locks, or a
DPMS on/off race. This document is the matrix and the reasoning behind each
choice; `install/cmd/power.sh` prints a short version of the same table.

## Ownership matrix

| Event | Owner | Mechanism |
| --- | --- | --- |
| Idle timers (dim / lock / DPMS-off / suspend thresholds) | `hypridle` | `listener` blocks, `ext-idle-notify-v1` |
| Lock the screen, whatever triggered it | `hypridle` → `hyprlock` | `general.lock_cmd`, fired by any D-Bus `Lock` signal |
| Lock **before** suspend, race-free | `hypridle` | `general.before_sleep_cmd = loginctl lock-session` + `inhibit_sleep = 2` |
| Suspend by inactivity | `hypridle` | the deepest `listener`'s `on-timeout = systemctl suspend` |
| Lid close, no external monitor, on battery | `logind` | `HandleLidSwitch=suspend` |
| Lid close, no external monitor, on AC | `logind` | `HandleLidSwitchExternalPower=suspend` |
| Lid close, docked / external monitor active (either power source) | `logind` | `HandleLidSwitchDocked=ignore` |
| Restore DPMS once after resume | `hypridle` | `general.after_sleep_cmd` |
| DPMS off after prolonged idle | `hypridle` | a dedicated `listener` |
| Power button | `logind` | `HandlePowerKey=lock` |
| NVIDIA GPU state across suspend/resume | `nvidia-suspend.service` / `nvidia-resume.service` / `nvidia-hibernate.service` (driver-shipped) | untouched by this stage; reported by `install.sh gpu` |
| `nvidia-compute-mode` policy (eco/compute) | its own state file | untouched across suspend — nothing here writes it |

Config files: `config/hypridle/hypridle.conf`, `config/hyprlock/hyprlock.conf`
(linked by `install.sh dotfiles --apply`), `config/logind/50-hyprland-infinite-desktop.conf`
(written by `install.sh power --apply`).

## Why logind owns the lid, not Hyprland or a script

Hyprland *can* bind the lid directly (`hl.bind("switch:off:[Lid Switch]", ...)`
— see `wiki: Configuring/Core/Binds/Switches`), and its own wiki page for that
feature carries an explicit warning that doing so **conflicts** with logind's
own `HandleLidSwitch` unless one of the two is turned off. Rather than run
both and disable one at the config level (two competing mechanisms, one
silenced — still two things that *could* fire), this repo picks logind as the
single owner and adds nothing on the Hyprland side.

The reason logind can be trusted for the specific behaviour asked for here —
suspend when the lid closes alone, but *not* when an external monitor is in
use — is in systemd's own current documentation (`logind.conf(5)`,
`HandleLidSwitchDocked=`):

> If the system is inserted in a docking station, or if more than one display
> is connected, the action specified by `HandleLidSwitchDocked=` occurs; if
> the system is on external power the action (if any) specified by
> `HandleLidSwitchExternalPower=` occurs; otherwise the `HandleLidSwitch=`
> action occurs.

That "more than one display connected" check is exactly the condition this
project wants, it's evaluated by logind itself from the real dock/DRM state
(not something this repo has to poll or infer from `lib/hardware.sh`), and it
already ships a startup/resume grace period (`HoldoffTimeoutSec=`, 30s
default) specifically so a monitor that's still being hotplug-detected isn't
missed. Re-implementing that in a `lid.sh` polling script would be strictly
worse: slower, another thing to keep in sync with real hardware, and a second
handler exactly of the kind this stage's rule forbids.

The chain above is checked **in that order** — docked/multi-display first,
regardless of power source, then AC power, then plain `HandleLidSwitch=` —
which matters for `HandleLidSwitchExternalPower=`: whatever it names, if
anything, wins over `HandleLidSwitch=` whenever the laptop is on AC. An
earlier version of this file set it to `ignore`, on the assumption that
charger state alone shouldn't override the display-count check — true, but
that check already happens first via `HandleLidSwitchDocked=`, and
`HandleLidSwitchExternalPower=ignore` was instead silently overriding
`HandleLidSwitch=suspend` for the case that has no external display at all:
lid-close on AC did nothing. `config/logind/50-hyprland-infinite-desktop.conf`
now pins it to `suspend`, the same as `HandleLidSwitch=`, so it agrees with
rather than overrides it:

```ini
[Login]
HandleLidSwitch=suspend
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=suspend
HandlePowerKey=lock
IdleAction=ignore
```

`HandleLidSwitch=suspend` and `HandleLidSwitchDocked=ignore` are already
systemd's own defaults — they're written out explicitly anyway, so a distro or
systemd default change can't silently change this laptop's behaviour.
`HandleLidSwitchExternalPower=suspend` is not a default (systemd's own default
is "ignored unless set") — it has to be set explicitly, precisely so the
on-AC, no-external-display case keeps suspending instead of silently falling
through to nothing. `IdleAction=ignore` keeps logind from ever running its
own, separate idle-based action alongside hypridle's ladder.

The three cases this is meant to cover, all via logind alone:

| Power | External display | Result |
| --- | --- | --- |
| Battery | none | `HandleLidSwitch=suspend` → suspend |
| AC | none | `HandleLidSwitchExternalPower=suspend` → suspend |
| either | docked / external monitor active | `HandleLidSwitchDocked=ignore` → ignore (checked first, wins regardless of power source) |

**Lid open, no double resume:** re-showing the internal panel on lid open is
Hyprland/DRM's own hotplug handling (the connector goes `enabled` again) —
nothing in this repo watches for it, so there's nothing to duplicate.

## Idle ladder

```
activity        -> normal
150s (2.5 min)  -> dim the backlight (brightnessctl -s / -r, not to 0)
300s (5 min)    -> lock
330s (5.5 min)  -> DPMS off, all monitors
1800s (30 min)  -> suspend
```

The four timeouts live together at the top of `hypridle.conf` — change those
four numbers, nothing else duplicates them. They match hypridle's own current
reference example (battery-conscious for a laptop, not aggressive), rather
than an invented schedule.

## Lock, suspend and the race hypridle avoids

Two different things can ask for a lock: hypridle's own 300s listener, and
`before_sleep_cmd`, which fires on *any* real suspend — including one
triggered by the lid via logind, not just hypridle's own 1800s listener. Both
paths call the exact same `loginctl lock-session`, which hypridle's
`general.lock_cmd = pidof hyprlock || hyprlock` turns into "start hyprlock
unless it's already running" — so there is one lock command, reachable from
either trigger, and it's idempotent against both firing close together.

`inhibit_sleep = 2` (auto) is what makes "lock before suspend" a single
race-free route instead of a best-effort ordering: it holds a sleep inhibitor
until hyprlock reports itself actually locked (via the session-lock protocol)
before the real suspend is allowed to proceed, so the machine can't visibly
suspend-and-resume with the desktop still showing for a moment.

hyprlock itself is **only** ever started this way. It is not in
`autostart.lua`, and nothing else in this repo launches it.

## DPMS

`after_sleep_cmd` turns every monitor back on exactly once per resume;
the DPMS-off listener's own `on-resume` does the same on ordinary idle-resume
(mouse/keyboard activity, no suspend involved). Both use
`hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'` with no monitor
argument — Hyprland ≥0.55's Lua dispatcher syntax, confirmed against the
current `hypridle` wiki example during this stage's research — so neither
names `eDP-1`/`HDMI-A-1`/a card number, and neither turns DPMS off again right
after turning it on: the two triggers (real resume vs. ordinary idle-resume)
are mutually exclusive at any given moment, so they can't race each other.

## NVIDIA: policy is never touched here

Suspend/resume for the NVIDIA GPU itself is the driver's own job —
`nvidia-suspend.service` / `nvidia-resume.service` / `nvidia-hibernate.service`,
already detected and reported (enabled/disabled) by `install.sh gpu` since
stage 12. Nothing added in this stage calls `nvidia-smi`, writes
`power/control`, or touches `bin/nvidia-compute-mode`'s state file
(`$XDG_STATE_HOME/nvidia-compute-mode/`). The user's chosen policy — `eco` or
`compute` — is a file on disk; suspending and resuming the machine does not
run any code path that could change it, so a session left in `compute` before
suspending is still `compute` after resume. If policy is `compute` and the
backend is `power-control` (`power/control=on`), the NVIDIA sleep services
above are what save/restore its actual power state across the cycle — this
repo does not re-implement or second-guess that.

## Power button

`HandlePowerKey=lock` (logind) — a single stray press locks the session
instead of the systemd default (`poweroff`), which would shut the laptop down
immediately. No Hyprland bind, no script: logind already receives power-key
events natively and `lock` is a real, current `HandlePowerKey=` value
(`logind.conf(5)`: "If lock, all running sessions will be screen-locked").
A power menu is left for a later stage; nothing here blocks adding one.

## What still needs validation on real Gentoo hardware

See `docs/FIRST-RUN.md`. In short: the lid switch device name via
`hyprctl devices`, that lid-close-alone suspends and lid-close-with-external-
monitor does not, that the power key locks rather than powers off, and a real
suspend/resume cycle confirming DPMS restores once and `nvidia-compute-mode
status` reports an unchanged policy before and after.
