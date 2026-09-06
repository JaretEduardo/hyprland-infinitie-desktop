#!/usr/bin/env bash
#
# install.sh first-run — guided checklist for the things that can only be
# decided correctly while actually running this workstation on Gentoo +
# Hyprland: the real monitor configuration, and the real NVIDIA compute
# backend. Everything else here is reused, not reimplemented — see the
# "reuses" note before each section below.
#
#   install.sh first-run            read-only checklist (no writes, no prompts)
#   install.sh first-run --apply    the same checklist, but each pending item
#                                    offers to actually resolve it (monitor
#                                    --apply, the NVIDIA backend guided test),
#                                    each with its own confirmation
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/portage.sh
. "$REPO_DIR/lib/portage.sh"
# shellcheck source=lib/nvidia.sh
. "$REPO_DIR/lib/nvidia.sh"

CMD_DIR="$REPO_DIR/install/cmd"
NVCM="$REPO_DIR/bin/nvidia-compute-mode"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "first-run: unknown option: $a"; exit 2 ;;
        *)  log::error "first-run: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

IS_GENTOO=0
portage::is_gentoo && IS_GENTOO=1

STEP_N=0
_section() { STEP_N=$((STEP_N + 1)); ui::header "$STEP_N. $1"; }

# _ask <question> : y on explicit yes; n (no prompt, no hang) without a tty
# or without --apply. Same convention as ui::confirm, used explicitly here
# (rather than for a file write) to gate an interactive guided test.
_ask() {
    [ "$APPLY" = 1 ] || return 1
    ui::confirm "$1"
}

ui::header "First run"
if [ "$IS_GENTOO" = 1 ]; then
    log::info "target: Gentoo"
else
    log::warn "this is not Gentoo. Sections below that need Gentoo (or a live Hyprland"
    log::warn "session, which this host also does not have) report what they can and say"
    log::warn "clearly what can only be checked on the real target — this is informational,"
    log::warn "not a failure."
fi
[ "$APPLY" = 1 ] && log::info "--apply: each pending item below offers to resolve it, with its own confirmation" \
                 || log::info "read-only checklist. Re-run with --apply to work through pending items."

# ============================================================================
# 1. Baseline: machine profile, Gentoo, Hyprland >=0.55, Quickshell,
#    dotfiles, AMD/NVIDIA
# ============================================================================
# Reuses: install.sh profile + install.sh check + install.sh dotfiles (plan).
# None of these are reimplemented here — their own output already answers
# every item in this section (which machine profile applies and whether its
# hardware expectations hold, Gentoo, Hyprland version, qs,
# AMD-primary/NVIDIA-secondary, dotfiles linked,
# NetworkManager, PipeWire/WirePlumber, hypridle/hyprlock/brightnessctl
# binaries). doctor (the final section) repeats the [OK]/[WARN] verdict on all
# of it; profile/check/dotfiles here are the detail.
_section "Baseline (install.sh profile, install.sh check, install.sh dotfiles)"
bash "$CMD_DIR/profile.sh" || true
printf '\n'
bash "$CMD_DIR/check.sh" || true
printf '\n'
if [ "$APPLY" = 1 ]; then bash "$CMD_DIR/dotfiles.sh" --apply || true
else                      bash "$CMD_DIR/dotfiles.sh"         || true
fi

# ============================================================================
# 2. Monitor configuration (165 Hz / real max refresh)
# ============================================================================
# Reuses: install.sh monitor entirely — this section does not re-detect
# anything, it only calls it.
_section "Monitor configuration (install.sh monitor)"
if [ "$APPLY" = 1 ]; then bash "$CMD_DIR/monitor.sh" --apply || true
else                      bash "$CMD_DIR/monitor.sh"         || true
fi

# ============================================================================
# 3. Infinite Desktop input access (udev uaccess)
# ============================================================================
# Reuses: install.sh input entirely. The evdev daemon can read your keyboard and
# pointer (a REL mouse OR an ABS/ABS_MT touchpad) once the udev `uaccess` rule is
# installed and udev is reloaded. Under --apply this offers to write the rule
# (root only — as a normal user it prints the exact privileged commands instead
# of failing a write).
#
# VERIFIED on this host (Lenovo 82SC): `sudo udevadm control --reload` +
# `sudo udevadm trigger --subsystem-match=input --action=change` applied the ACL
# to the already-existing event nodes immediately, with NO logout — getfacl
# showed `user:<you>:rw` and the running daemon picked the devices up on its
# next rescan. Re-login / reboot stays the fallback if the ACL does not appear.
_section "Infinite Desktop input access (install.sh input)"
if [ "$APPLY" = 1 ]; then bash "$CMD_DIR/input.sh" --apply || true
else                      bash "$CMD_DIR/input.sh"         || true
fi
cat <<'EOF'

  Still to validate here, for real, after applying the rule + reload + trigger:
    - `getfacl /dev/input/event* | grep "user:$(id -un)"` shows a `:rw` entry on
      your keyboard and pointer (mouse/touchpad) nodes. If it does NOT, log out
      and back in (or reboot) and re-check.
    - Infinite Desktop pans on SUPER+ALT + mouse OR one finger on the touchpad,
      and this session's daemon log shows "Teclado detectado" +
      "Mouse detectado" / "Touchpad detectado". The log is
      "$XDG_RUNTIME_DIR/infinite-desktop/$HYPRLAND_INSTANCE_SIGNATURE.log"
      (or the ".../infinite-desktop/current.log" symlink).
    - REVERT behaviour: after `sudo rm` of the rule + `udevadm control --reload`
      + `udevadm trigger`, check whether the ACL is gone WITHOUT logging out.
      Whether the trigger alone revokes it was not tested here — if it survives,
      a re-login (or reboot) is the guaranteed way to drop it. Record what you saw.
EOF
if _ask "Has the udev rule been applied, udev reloaded, and the checks above verified?"; then
    log::ok "Infinite Desktop input access confirmed"
else
    log::info "pending — run ./install.sh input (as root), reload udev + trigger, then re-check"
fi

# ============================================================================
# 4. Hardware keys — wev-guided checklist
# ============================================================================
# No automation: physically pressing keys cannot be simulated, and this
# project's own rule (docs/FIRST-RUN.md, written in the laptop-keys stage) is
# not to guess extra keysyms beyond what wev actually reports. This section
# only shows the same expectation table and lets the user confirm or note
# what they actually saw.
_section "Hardware keys (wev)"
if command -v wev >/dev/null 2>&1; then
    log::info "wev is installed. Run it in a terminal inside Hyprland, press each key below,"
    log::info "and compare the keysym it prints against config/hypr/lua/laptop.lua."
else
    log::info "wev not installed (install.sh deps: gui-apps/wev, guru, optional) — install it"
    log::info "to actually verify the keysyms below on this hardware."
fi
cat <<'EOF'
  Key              Expected XF86 keysym
  ---------------  ------------------------------
  Volume up        XF86AudioRaiseVolume
  Volume down      XF86AudioLowerVolume
  Mute              XF86AudioMute
  Mic mute          XF86AudioMicMute
  Brightness up     XF86MonBrightnessUp
  Brightness down   XF86MonBrightnessDown
  Play/pause        XF86AudioPlay / XF86AudioPause
  Next track        XF86AudioNext
  Previous track    XF86AudioPrev
EOF
if _ask "Did every key above report exactly its expected keysym (no surprises)?"; then
    log::ok "hardware keys confirmed matching config/hypr/lua/laptop.lua"
else
    if [ "$APPLY" = 1 ]; then
        printf 'Note anything wev reported that is NOT in the table above (blank to skip): '
        read -r _extra_keys || true
        [ -n "${_extra_keys:-}" ] && log::info "noted for later: $_extra_keys — add it consciously to laptop.lua, do not guess more" \
                                   || log::info "nothing noted — re-run this section after checking wev"
    else
        log::info "unconfirmed — re-run with --apply after checking with wev"
    fi
fi

# ============================================================================
# 5. Session services — audio (user systemd) + logind drop-in
# ============================================================================
# The PipeWire user units are socket-activated but NOT enabled by anything in
# this repo. Enabling them is a per-user, no-root, reversible action, so under
# --apply this offers to do it. The logind drop-in needs root — this only
# reports it and points at `install.sh power`.
_section "Session services (audio, logind)"
_pw_units="pipewire.socket pipewire-pulse.socket wireplumber.service"
_pw_enabled=1
for _u in $_pw_units; do
    systemctl --user is-enabled --quiet "$_u" 2>/dev/null || _pw_enabled=0
done
if [ "$_pw_enabled" = 1 ]; then
    log::ok "PipeWire user units already enabled ($_pw_units)"
else
    log::warn "PipeWire user units are not enabled — this session has no audio until they are."
    printf '    systemctl --user enable --now %s\n' "$_pw_units"
    if _ask "Enable them now (user scope, no root, reversible)?"; then
        if [ -n "$DRY" ]; then
            log::info "dry-run: would run: systemctl --user enable --now $_pw_units"
        elif systemctl --user enable --now $_pw_units; then
            log::ok "PipeWire user units enabled + started"
        else
            log::error "could not enable the PipeWire units — run the command above by hand"
        fi
    else
        log::info "skipped — run the command above when ready"
    fi
fi
_ld=/etc/systemd/logind.conf.d/50-hyprland-infinite-desktop.conf
if [ -f "$_ld" ]; then
    log::ok "logind drop-in installed ($_ld)"
else
    log::warn "logind drop-in NOT installed — a single Power-key press powers the machine OFF."
    log::info "Fix (needs root): ./install.sh power --apply"
fi

# ============================================================================
# 6. Lid / power-button behaviour — physical test still pending
# ============================================================================
# Reuses: docs/FIRST-RUN.md's own lid/suspend checklist (written in the
# power stage) — this just points at it and asks for confirmation, it does
# not re-implement or re-test any of it (that needs a real lid close /
# suspend cycle, which nothing here can do for you).
_section "Lid / power button (physical test — see docs/FIRST-RUN.md)"
cat <<'EOF'
  1. Battery, no external monitor, close the lid -> should suspend
  2. AC power, no external monitor, close the lid -> should ALSO suspend
  3. External monitor connected, close the lid -> should NOT suspend
  4. Power button, single press -> should lock, not power off
  5. Full idle ladder: dim -> lock -> DPMS off -> suspend, in order
EOF
if _ask "Have all 5 of the above actually been tested on this hardware?"; then
    log::ok "lid / power button behaviour confirmed"
else
    log::info "pending — see docs/FIRST-RUN.md 'Lid, lock, suspend' for the full checklist"
fi

# ============================================================================
# 7. NVIDIA compute backend
# ============================================================================
_section "NVIDIA compute backend"
if ! nvidia::present; then
    log::info "no NVIDIA GPU present — nothing to resolve"
else
    "$NVCM" status || true
    backend="$("$NVCM" status --json 2>/dev/null | grep -o '"backend":"[^"]*"' | cut -d'"' -f4)"
    backend="${backend:-auto}"
    if [ "$backend" != auto ]; then
        log::info "backend already resolved: $backend — nothing to test"
    else
        printf '\n'
        log::info "Candidates for compute_backend, in priority order (stability, low ECO"
        log::info "consumption, fast switch, minimal privilege — see docs/HYBRID-GPU.md):"
        printf '\n'
        printf '  power-control  write power/control auto<->on directly (already implemented,\n'
        printf '                 already the exact mechanism ECO already relies on in reverse).\n'
        printf '                 One sysfs write, one owner, instantly reversible.\n'
        printf '  persistenced   a permanent daemon context. NVIDIA'"'"'s own docs confirm it\n'
        printf '                 prevents D3cold the same way power-control=on does, but adds a\n'
        printf '                 service lifecycle to manage (start on COMPUTE, stop on ECO) and\n'
        printf '                 is NOT verified on this exact driver/GPU. Not implemented as a\n'
        printf '                 real backend yet — needs that verification on Gentoo first.\n'
        printf '  none           record intent only; no keep-awake mechanism.\n'
        printf '\n'
        log::warn "NVIDIA driver >=570 has documented reports of RTD3/D3cold regressions on some"
        log::warn "hardware — this laptop's driver qualifies. Whether D3cold is even reachable"
        log::warn "here at all needs to be observed for real, not assumed."
        printf '\n'
        log::info "Recommendation: test 'power-control'. It is the already-implemented,"
        log::info "single-owner, minimal-privilege candidate — prefer it over persistenced"
        log::info "unless a real test here shows it does not achieve the goal."

        if _ask "Test candidate 'power-control' now? (COMPUTE, verify, then back to ECO — never kills anything, never unloads modules)"; then
            # `compute` only exercises the power-control code path when the
            # recorded backend already says power-control (see cmd_compute) —
            # so the test itself has to set that first. It is only ever kept
            # if every step below succeeds; any failure reverts it to 'auto'
            # before this section ends, so nothing is left half-recorded.
            "$NVCM" set-backend power-control
            printf '\n'; log::info "-> COMPUTE (power/control: auto -> on)"
            if "$NVCM" compute; then
                printf '\n'; log::info "-> back to ECO (power/control: on -> auto)"
                if "$NVCM" eco; then
                    now_pc="$(nvidia::power_control)"
                    now_rpm="$(nvidia::runtime_pm_state)"
                    if [ "$now_pc" = auto ]; then
                        log::ok "power/control correctly restored to auto"
                        log::info "runtime PM reports '$now_rpm' right now — whether it can still reach"
                        log::info "D3cold is NOT claimed here; that only shows up after real idle time."
                        log::info "Check again later with: nvidia-compute-mode status"
                        log::ok "both directions worked — compute_backend=power-control recorded"
                    else
                        log::error "power/control did not return to 'auto' (reports '$now_pc')."
                        log::error "reverting backend to 'auto'. Investigate before trusting this mechanism."
                        "$NVCM" set-backend auto
                    fi
                else
                    log::error "reverting to ECO failed — reverting backend to 'auto'. See the error above"
                    log::error "(likely the same privilege boundary as the COMPUTE write)."
                    "$NVCM" set-backend auto
                fi
            else
                log::error "COMPUTE write failed or needs privilege — reverting backend to 'auto'."
                log::error "See docs/HYBRID-GPU.md 'Privilege boundary' for the (not yet installed)"
                log::error "polkit helper that would let this run without a terminal sudo prompt."
                "$NVCM" set-backend auto
            fi
        else
            log::info "skipped — backend stays 'auto'. The UI already shows this as unresolved."
        fi
    fi
fi

# ============================================================================
# 8. Final summary
# ============================================================================
# Reuses: install.sh doctor entirely.
_section "Final summary (install.sh doctor)"
bash "$CMD_DIR/doctor.sh" || true

ui::header "First run — result"
log::ok "checklist complete. Re-run any time — nothing here is destructive to re-check."
