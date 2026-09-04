#!/usr/bin/env bash
#
# install.sh power — idle / lock / suspend / lid power-event ownership.
#
#   install.sh power              detect + explain + show the proposed change (read-only)
#   install.sh power --apply      apply, after confirmation, with a backup of anything replaced
#   install.sh power --dry-run    like the default (never writes)
#
# This command's ONLY job is the one event this repo cannot own from
# userspace: the lid switch / power key / idle-action handling systemd-logind
# itself performs, via a single logind.conf.d drop-in
# (config/logind/50-hyprland-infinite-desktop.conf). Everything else in the
# power ownership matrix — idle timers, locking, DPMS, suspend-by-inactivity —
# is `hypridle.conf` / `hyprlock.conf`, linked in by `install.sh dotfiles
# --apply`, and needs no privilege. See docs/POWER.md for the full matrix and
# why each event has exactly one owner.
#
# Never touches NVIDIA: the nvidia-suspend/resume/hibernate services are
# reported by `install.sh gpu`, not duplicated here.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"

TPL="$REPO_DIR/config/logind/50-hyprland-infinite-desktop.conf"
# POWER_SYSROOT redirects the file this command WRITES, for testing against a
# simulated /etc. Detection always reads the real system unless it too is
# redirected the same way (both are just SYSROOT below).
SYSROOT="${POWER_SYSROOT:-}"
DEST_D="$SYSROOT/etc/systemd/logind.conf.d"
DEST="$DEST_D/50-hyprland-infinite-desktop.conf"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "power: unknown option: $a"; exit 2 ;;
        *)  log::error "power: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

CHANGES=0

# ---- read-only detection of the CURRENT logind config ---------------------
# Best-effort textual scan of the real config chain (main file, then conf.d/
# drop-ins in sorted order — later wins, same as logind itself). This is not
# an authoritative runtime query: logind does not publish these settings over
# D-Bus, only its own parsed config decides them.
_logind_files() {
    [ -r "$SYSROOT/etc/systemd/logind.conf" ] && printf '%s\n' "$SYSROOT/etc/systemd/logind.conf"
    local f
    for f in "$SYSROOT"/etc/systemd/logind.conf.d/*.conf; do
        [ -e "$f" ] && [ -r "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# _logind_value <key> : last assignment across the chain above, or empty
_logind_value() {
    local key="$1" f v=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local m
        m=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null | tail -n1 \
            | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*\$//")
        [ -n "$m" ] && v="$m"
    done < <(_logind_files)
    printf '%s' "$v"
}

# _install_file <rendered-tmp> <dest> <human description> — same
# detect -> explain -> show -> confirm -> apply -> backup pattern as
# install.sh gpu, adapted for a single static file (no substitution needed).
_ours() { [ -r "$1" ] && head -n1 "$1" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop'; }

_install_file() {
    local src="$1" dest="$2" desc="$3"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        ui::kv "$desc" "already applied"
        return 0
    fi
    CHANGES=$((CHANGES + 1))
    printf '\n'
    if [ -f "$dest" ] && ! _ours "$dest"; then
        log::warn "$dest exists and was NOT created by this installer."
        printf '  proposed replacement (a .bak backup would be kept):\n'
    elif [ -f "$dest" ]; then
        log::info "$desc: updating our managed file $dest"
        printf '  diff (current -> proposed):\n'
        diff -u "$dest" "$src" 2>/dev/null | sed 's/^/    /' || true
    else
        log::info "$desc: new file $dest"
    fi
    printf '  --- %s ---\n' "$dest"
    sed 's/^/  /' "$src"
    printf '  ------------------------------------------------\n'

    if [ "$APPLY" != 1 ]; then
        return 0
    fi
    if [ -f "$dest" ] && ! _ours "$dest"; then
        ui::confirm "Back up $dest and replace it?" || { log::warn "skipped $dest"; return 0; }
    else
        ui::confirm "Write $dest ?" || { log::warn "skipped $dest"; return 0; }
    fi
    if [ -f "$dest" ] && ! _ours "$dest"; then
        cp -a "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    if ! install -D -m 0644 "$src" "$dest" 2>/dev/null; then
        log::error "could not write $dest (need root?)"
        printf '    sudo install -D -m 0644 %s %s\n' "$src" "$dest" >&2
        return 2
    fi
    log::ok "wrote $dest"
}

# ---------------------------------------------------------------------------
ui::header "Power (idle / lock / suspend / lid)"
[ "$APPLY" = 1 ] && log::info "--apply: the change will be offered, then confirmed before writing" \
                 || log::info "read-only plan. Re-run with --apply to write it."

ui::section "Ownership matrix (see docs/POWER.md for the full explanation)"
cat <<'EOF'
  idle timers (dim/lock/dpms-off/suspend thresholds)  hypridle.conf
  lock the screen, whatever triggered it               hypridle -> hyprlock
  lock BEFORE suspend (race-free)                       hypridle before_sleep_cmd + inhibit_sleep
  suspend by inactivity                                 hypridle (deepest listener)
  lid close, no external monitor                        logind: HandleLidSwitch=suspend
  lid close, docked / external monitor active            logind: HandleLidSwitchDocked=ignore
  DPMS off / restore                                     hypridle (all monitors, no eDP-1 assumption)
  power button                                           logind: HandlePowerKey=lock
  NVIDIA state across suspend/resume                     nvidia-suspend/resume/hibernate.service
                                                          (driver-shipped; reported by install.sh gpu,
                                                           never touched here)
EOF

ui::section "logind — current vs. proposed"
_keys="HandleLidSwitch HandleLidSwitchDocked HandleLidSwitchExternalPower HandlePowerKey IdleAction"
_want() {
    case "$1" in
        HandleLidSwitch) printf 'suspend' ;;
        HandleLidSwitchDocked) printf 'ignore' ;;
        HandleLidSwitchExternalPower) printf 'suspend' ;;
        HandlePowerKey) printf 'lock' ;;
        IdleAction) printf 'ignore' ;;
    esac
}
_systemd_default() {
    case "$1" in
        HandleLidSwitch) printf 'suspend' ;;
        HandleLidSwitchDocked) printf 'ignore' ;;
        HandleLidSwitchExternalPower) printf '(ignored unless set)' ;;
        HandlePowerKey) printf 'poweroff' ;;
        IdleAction) printf 'ignore' ;;
    esac
}
for k in $_keys; do
    cur=$(_logind_value "$k")
    want=$(_want "$k")
    if [ -n "$cur" ]; then
        if [ "$cur" = "$want" ]; then
            ui::kv "$k" "$cur (already matches)"
        else
            ui::kv "$k" "$cur -> wants $want"
        fi
    else
        ui::kv "$k" "unset (systemd default: $(_systemd_default "$k")) -> wants $want"
    fi
done
printf '\n'
log::info "detection is a best-effort scan of $SYSROOT/etc/systemd/logind.conf{,.d/*.conf} —"
log::info "logind does not publish these settings over D-Bus, so this is not a live runtime query."

_install_file "$TPL" "$DEST" "logind lid/power-key/idle-action policy"

# ---- summary ---------------------------------------------------------
ui::header "Summary"
ui::kv "proposed changes" "$CHANGES"
printf '\n'
cat <<'EOF'
Not this command's job — handled elsewhere:
  - hypridle.conf / hyprlock.conf are linked by `install.sh dotfiles --apply`
    (per-file, like every other managed config in this repo).
  - hypridle is autostarted by config/hypr/lua/autostart.lua; hyprlock is
    NOT autostarted, only launched by hypridle's own lock_cmd.
  - NVIDIA suspend/resume service status is reported by `install.sh gpu`.

If the drop-in above changed:
  - `systemctl restart systemd-logind` applies it immediately (can briefly
    disturb active sessions on some systemd versions) — this command does
    NOT run that for you.
  - otherwise it takes effect at the next login or reboot.

Requires validation on Gentoo first-run (see docs/FIRST-RUN.md):
  - the lid switch device is reported as expected by `hyprctl devices`
  - lid close with no external monitor actually suspends
  - lid close with an external monitor connected does NOT suspend
  - the power key locks rather than powering off
  - a real suspend/resume cycle: lock fires once before sleep, DPMS comes
    back exactly once after resume, and NVIDIA policy (eco/compute) is
    unchanged by `nvidia-compute-mode status` before and after
EOF
if [ "$APPLY" != 1 ]; then
    [ "$CHANGES" -gt 0 ] && log::info "re-run with --apply to make the $CHANGES change(s) above"
    log::ok "power (plan) complete — nothing was changed"
else
    log::ok "power --apply complete"
fi
