#!/usr/bin/env bash
#
# install.sh full — top-level workstation orchestration.
#
# NOT a magic installer: it does not install Gentoo, partition disks, touch
# the bootloader/EFI, install packages automatically, or start a Hyprland
# session. It only sequences the subcommands that already exist, each called
# exactly once, with full terminal passthrough (so their own confirmations
# work exactly as a direct call would):
#
#   1. profile   — which profiles/<id>/ applies (read-only)
#   2. desktop   — check -> deps-gate -> dotfiles -> gpu -> power ->
#                  infinite-desktop -> doctor, as ONE unit (see desktop.sh)
#   3. first-run — monitor / wev / lid / NVIDIA-backend guidance, only when
#                  it can mean something (see "First-run" below)
#
# full.sh re-detects nothing that profile/check/deps/dotfiles/gpu/power/
# desktop/monitor/first-run/doctor already detect. Because desktop.sh already
# runs check + deps + doctor internally, full.sh does not call check.sh /
# deps.sh / doctor.sh a second time on top of it — that would just repeat
# output that already answered the question, not add information.  A doctor
# re-read only happens if first-run actually ran (state may genuinely have
# changed): see "Final readiness" below.
#
#   install.sh full              plan: profile + desktop (plan) + first-run
#                                 (plan). Strictly read-only.
#   install.sh full --apply      the real sequence. Stops before any write if
#                                 required Gentoo packages are missing (that
#                                 gate is desktop.sh's own, not reimplemented
#                                 here). Only offers first-run --apply inside
#                                 a live Hyprland session, and only after
#                                 asking — never forced.
#   install.sh --dry-run full --apply
#                                 like --apply, but every step it reaches
#                                 writes nothing (INSTALL_DRY_RUN, same as
#                                 every other command).
#
# NEVER done here: emerge, eselect, sudo, systemctl enable/start, usermod, a
# silent /etc write, or starting a Hyprland session. Those stay exactly as
# gated as they are inside each individual subcommand — full.sh adds no new
# privileged action, and no new confirmation bypass. It may ask ONE
# informational "proceed?" question before an --apply run; that never
# replaces gpu/power/etc.'s own per-write confirmations.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"
# shellcheck source=lib/portage.sh
. "$REPO_DIR/lib/portage.sh"
# shellcheck source=lib/profile.sh
. "$REPO_DIR/lib/profile.sh"

CMD_DIR="$REPO_DIR/install/cmd"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "full: unknown option: $a"; exit 2 ;;
        *)  log::error "full: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

IS_GENTOO=0
portage::is_gentoo && IS_GENTOO=1

# TESTING ONLY, hardened — identical mechanism to desktop.sh's own guard (not
# a new/weaker hook). full.sh needs to derive the same IS_GENTOO / missing-deps
# facts desktop.sh will independently re-derive when full.sh calls it, purely
# so full's OWN status lines stay consistent with what desktop.sh actually
# does. desktop.sh enforces this exact same guard again on its own when full
# invokes it — this is not a second, weaker path in, it is the same one.
if [ -n "${DESKTOP_ASSUME_GENTOO:-}" ] || [ -n "${DESKTOP_ASSUME_DEPS_OK:-}" ]; then
    if [ "${DESKTOP_TEST_MODE:-}" != 1 ]; then
        log::error "DESKTOP_ASSUME_GENTOO / DESKTOP_ASSUME_DEPS_OK require DESKTOP_TEST_MODE=1."
        log::error "These are testing-only hooks — refusing to run with either set outside test mode."
        exit 2
    fi
    _real_etc="$(realpath -m /etc 2>/dev/null || printf '/etc')"
    for _sr_name in GPU_SYSROOT POWER_SYSROOT; do
        _sr="${!_sr_name:-}"
        if [ -z "$_sr" ] || [ ! -d "$_sr" ]; then
            log::error "DESKTOP_TEST_MODE=1 requires $_sr_name to be set to an existing simulated root."
            exit 2
        fi
        _sr_etc="$(realpath -m "$_sr/etc" 2>/dev/null)"
        if [ -z "$_sr_etc" ] || [ "$_sr_etc" = "$_real_etc" ]; then
            log::error "DESKTOP_TEST_MODE=1: $_sr_name resolves to this host's REAL /etc ($_real_etc) — refusing."
            exit 2
        fi
    done
    [ -n "${DESKTOP_ASSUME_GENTOO:-}" ] && IS_GENTOO=1
fi

# _missing_required : same derivation desktop.sh's own gate uses (not a
# second call to deps.sh — deps.sh's own output is still shown for real,
# exactly once, inside desktop.sh's step 2). Used here only to label full's
# own status lines consistently with what desktop.sh is about to do.
_missing_required() {
    if [ "${DESKTOP_TEST_MODE:-}" = 1 ] && [ -n "${DESKTOP_ASSUME_DEPS_OK:-}" ]; then
        printf '0'; return 0
    fi
    [ "$IS_GENTOO" = 1 ] || { printf '0'; return 0; }
    local n=0 atom
    while IFS='|' read -r _g atom _repo tier _note; do
        [ "$tier" = required ] || continue
        portage::pkg_installed "$atom" || n=$((n + 1))
    done < <(portage::catalog)
    printf '%s' "$n"
}

# _hypr_session_present : is there a live Hyprland session to run first-run
# --apply against? MONITOR_HYPRCTL_JSON_FILE is monitor.sh's OWN existing
# testing-only hook (not a new one) — honoured here too so a test can
# simulate "inside Hyprland" for full's own offer/skip decision the same way
# it already does for monitor.sh's detection.
_hypr_session_present() {
    if [ -n "${MONITOR_HYPRCTL_JSON_FILE:-}" ] && [ -r "${MONITOR_HYPRCTL_JSON_FILE}" ]; then
        return 0
    fi
    command -v hyprctl >/dev/null 2>&1 || return 1
    hyprctl -j monitors all >/dev/null 2>&1
}

# _pf <key> : field from the detected profile, falling back to common's
# value if the specific profile doesn't declare it. Pure formatting over
# lib/profile.sh's own data — no new detection.
_pf() {
    local v
    v=$(profile::get "$1" "$PROFILE_ID")
    [ -n "$v" ] || v=$(profile::get "$1" common)
    printf '%s' "$v"
}
_cap() {
    case "$1" in
        hyprland)             printf 'Hyprland' ;;
        quickshell)           printf 'Quickshell' ;;
        networkmanager)       printf 'NetworkManager' ;;
        pipewire-wireplumber) printf 'PipeWire/WirePlumber' ;;
        amd)                  printf 'AMD' ;;
        nvidia)               printf 'NVIDIA' ;;
        *)                    printf '%s' "$1" ;;
    esac
}

PROFILE_ID="$(profile::detect)"
PROFILE_NAME="$(profile::get name "$PROFILE_ID")"

# ---------------------------------------------------------------------------
if [ "$APPLY" = 1 ]; then ui::header "Full workstation orchestration"
else                       ui::header "Full workstation plan"
fi

ui::section "Machine profile"
if [ "$PROFILE_ID" = common ]; then
    log::warn "no machine-specific profile matched — using 'common' (install.sh profile for detail)"
else
    printf '  %s\n' "$PROFILE_ID"
fi

ui::section "Target"
printf '  Gentoo + %s\n' "$(_pf init)"
printf '  %s\n' "$(_cap "$(_pf compositor)")"
printf '  %s\n' "$(_cap "$(_pf shell)")"
pg=$(_pf primary_gpu); [ -n "$pg" ] || pg=$(_pf primary_gpu_preference)
[ -n "$pg" ] && printf '  %s primary\n' "$(_cap "$pg")"
sg=$(_pf secondary_gpu)
[ -n "$sg" ] && printf '  %s %s\n' "$(_cap "$sg")" "$(_pf nvidia_role)"

if [ "$APPLY" = 1 ]; then
    log::info "--apply: runs install.sh desktop --apply (each of its own steps still confirms"
    log::info "itself before writing), then offers install.sh first-run --apply only if a live"
    log::info "Hyprland session is present."
    if ! ui::confirm "Proceed with the full workstation bring-up?"; then
        log::info "aborted — nothing was done."
        exit 0
    fi
else
    log::info "plan / read-only: every step below runs in its own plan mode. Re-run with --apply."
fi
if [ "$IS_GENTOO" != 1 ]; then
    log::warn "this system is not Gentoo — the /etc-writing steps inside desktop (gpu, power)"
    log::warn "stay plan-only even under --apply, exactly as desktop.sh already guarantees."
fi

# ---- Phase 1: desktop (check, deps-gate, dotfiles, gpu, power, ------------
#      infinite-desktop, doctor — as ONE reused unit) ----------------------
ui::header "Phase 1: Desktop configuration (install.sh desktop, includes dependencies)"
desktop_exit=0
if [ "$APPLY" = 1 ]; then bash "$CMD_DIR/desktop.sh" --apply || desktop_exit=$?
else                      bash "$CMD_DIR/desktop.sh"         || desktop_exit=$?
fi

missing_req=$(_missing_required)

# ---- Phase 2: first-run (only when it can mean something) ----------------
ui::header "Phase 2: First-run hardware validation (install.sh first-run)"
ran_first_run=0
first_run_exit=0
hypr_present=0
_hypr_session_present && hypr_present=1

if [ "$desktop_exit" != 0 ]; then
    log::warn "skipped — Phase 1 (desktop) did not complete. See its output above."
elif [ "$APPLY" != 1 ]; then
    # Plan mode is always read-only, so showing first-run's own plan is safe
    # and free of side effects regardless of Hyprland being present.
    bash "$CMD_DIR/first-run.sh" || true
elif [ "$hypr_present" != 1 ]; then
    log::info "no live Hyprland session detected — first-run needs one to detect real monitors"
    log::info "and validate hardware for real. Nothing here can start a session for you."
else
    if ui::confirm "Live Hyprland session detected. Run install.sh first-run --apply now?"; then
        bash "$CMD_DIR/first-run.sh" --apply || first_run_exit=$?
        ran_first_run=1
    else
        log::info "skipped — re-run any time: ./install.sh first-run --apply"
    fi
fi

# ---- Final readiness: only re-read doctor if first-run may have changed --
#      something. Otherwise desktop's own doctor step (just shown above) is
#      already the freshest read and repeating it would show nothing new.
doctor_exit=""
if [ "$ran_first_run" = 1 ]; then
    ui::header "Phase 3: Final readiness (install.sh doctor)"
    bash "$CMD_DIR/doctor.sh" || doctor_exit=$?
    doctor_exit="${doctor_exit:-0}"
fi

# ---------------------------------------------------------------------------
ui::header "Full workstation status"

if [ "$PROFILE_ID" = common ]; then
    printf '  %s%-10s%s Machine profile: common (no machine-specific profile matched)\n' \
        "${_C_YELLOW:-}" "[WARN]" "${_C_RESET:-}"
else
    printf '  %s%-10s%s Machine profile: %s\n' "${_C_GREEN:-}" "[COMPLETE]" "${_C_RESET:-}" "$PROFILE_ID"
fi

if [ "$IS_GENTOO" != 1 ]; then
    printf '  %s%-10s%s Dependencies: not verifiable off Gentoo\n' "${_C_CYAN:-}" "[PENDING]" "${_C_RESET:-}"
elif [ "$missing_req" -gt 0 ]; then
    printf '  %s%-10s%s Dependencies: %s required package(s) missing (see Phase 1 above)\n' \
        "${_C_RED:-}" "[BLOCKED]" "${_C_RESET:-}" "$missing_req"
else
    printf '  %s%-10s%s Dependencies\n' "${_C_GREEN:-}" "[COMPLETE]" "${_C_RESET:-}"
fi

if [ "$desktop_exit" != 0 ]; then
    printf '  %s%-10s%s Desktop configuration: see Phase 1 output above\n' "${_C_RED:-}" "[BLOCKED]" "${_C_RESET:-}"
elif [ "$APPLY" = 1 ]; then
    printf '  %s%-10s%s Desktop configuration\n' "${_C_GREEN:-}" "[COMPLETE]" "${_C_RESET:-}"
else
    printf '  %s%-10s%s Desktop configuration: plan shown above — re-run with --apply\n' "${_C_CYAN:-}" "[READY]" "${_C_RESET:-}"
fi

if [ "$desktop_exit" != 0 ]; then
    printf '  %s%-10s%s First-run: not attempted (Phase 1 did not complete)\n' "${_C_YELLOW:-}" "[PENDING]" "${_C_RESET:-}"
elif [ "$ran_first_run" = 1 ]; then
    if [ "$first_run_exit" = 0 ]; then
        printf '  %s%-10s%s First-run: ran this session — review its output above for any items\n' "${_C_GREEN:-}" "[OK]" "${_C_RESET:-}"
        printf '             still needing physical confirmation (wev keys, lid/suspend cycle)\n'
    else
        printf '  %s%-10s%s First-run: exited with an error — see its output above\n' "${_C_YELLOW:-}" "[WARN]" "${_C_RESET:-}"
    fi
elif [ "$APPLY" != 1 ]; then
    printf '  %s%-10s%s First-run: plan shown above\n' "${_C_CYAN:-}" "[PENDING]" "${_C_RESET:-}"
elif [ "$hypr_present" != 1 ]; then
    printf '  %s%-10s%s First-run: log into Hyprland\n' "${_C_YELLOW:-}" "[PENDING]" "${_C_RESET:-}"
else
    printf '  %s%-10s%s First-run: declined this session\n' "${_C_YELLOW:-}" "[PENDING]" "${_C_RESET:-}"
fi

if [ -n "$doctor_exit" ]; then
    if [ "$doctor_exit" = 0 ]; then
        printf '  %s%-10s%s Final readiness: doctor reported no errors (see Phase 3 above)\n' "${_C_GREEN:-}" "[OK]" "${_C_RESET:-}"
    else
        printf '  %s%-10s%s Final readiness: doctor reported errors (see Phase 3 above)\n' "${_C_RED:-}" "[WARN]" "${_C_RESET:-}"
    fi
fi

printf '\n'
if [ "$desktop_exit" != 0 ]; then
    log::error "stopped: Phase 1 (desktop) did not complete. Nothing after it was attempted."
    printf 'Next action:\n  Review the Desktop configuration output above, resolve it, then re-run:\n      ./install.sh full --apply\n'
    exit 1
elif [ "$ran_first_run" = 1 ] && [ "$first_run_exit" = 0 ] && [ "${doctor_exit:-0}" = 0 ]; then
    log::ok "Workstation setup complete."
elif [ "$APPLY" != 1 ]; then
    log::ok "full (plan) complete — nothing was changed. Re-run with --apply."
elif [ "$hypr_present" != 1 ]; then
    printf 'Desktop configuration complete.\nFirst-run is still pending.\n\n'
    printf 'Next action:\n  Log into Hyprland, then run:\n      ./install.sh first-run --apply\n'
else
    printf 'Next action:\n  Run when ready:\n      ./install.sh first-run --apply\n'
fi
