#!/usr/bin/env bash
#
# install.sh desktop — orchestrates the pieces already built by the other
# subcommands into one coherent workstation bring-up flow.
#
# This is an ORCHESTRATOR, not a reimplementation. Every real check or write
# below is a direct call to an existing install.sh <cmd>, with the exact same
# stdin/stdout/stderr it would have if you ran it yourself — including its own
# interactive confirmations. desktop.sh's own code only sequences those calls
# and stops the sequence when one of them fails or reports something that
# makes the next step unsafe or pointless. It re-detects nothing that deps /
# dotfiles / gpu / power / infinite-desktop / doctor already detect.
#
#   install.sh desktop              plan: every step in read-only/plan mode
#   install.sh desktop --apply      the real sequence — each step still
#                                    confirms interactively before writing,
#                                    exactly like calling it directly
#   install.sh --dry-run desktop --apply
#                                    like --apply, but INSTALL_DRY_RUN is
#                                    exported (common.sh already does this),
#                                    so every step it reaches writes nothing
#
# Sequence: check -> deps -> dotfiles -> gpu -> power -> infinite-desktop ->
# doctor. doctor is also where "network/audio services present" is verified
# and where the final readiness summary comes from — it already checks both,
# so this is the one place, not two.
#
# NEVER done here, no matter what: emerge, eselect, sudo, systemctl
# enable/start, usermod, or a silent /etc write — those stay exactly as
# gated as they are inside each individual subcommand. This script adds no
# new privileged action of its own.
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

CMD_DIR="$REPO_DIR/install/cmd"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "desktop: unknown option: $a"; exit 2 ;;
        *)  log::error "desktop: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

IS_GENTOO=0
portage::is_gentoo && IS_GENTOO=1

# TESTING ONLY, hardened. DESKTOP_ASSUME_GENTOO / DESKTOP_ASSUME_DEPS_OK exist
# only so this stage's own test suite can drive the gpu/power --apply path
# against GPU_SYSROOT/POWER_SYSROOT instead of a real machine's /etc. Both are
# refused unless ALL of this holds:
#   - DESKTOP_TEST_MODE=1 is also set (using either hook without it is a hard
#     error, never a silent no-op — a stray env var must fail loudly, not
#     quietly change behaviour)
#   - GPU_SYSROOT and POWER_SYSROOT are both set, both exist, and both
#     resolve (symlinks included) to somewhere other than the real /etc
# Only then can IS_GENTOO / the deps gate be overridden — and only ever
# pointed at the simulated roots the test itself set up, never at this host's
# real /etc.
if [ -n "${DESKTOP_ASSUME_GENTOO:-}" ] || [ -n "${DESKTOP_ASSUME_DEPS_OK:-}" ]; then
    if [ "${DESKTOP_TEST_MODE:-}" != 1 ]; then
        log::error "DESKTOP_ASSUME_GENTOO / DESKTOP_ASSUME_DEPS_OK require DESKTOP_TEST_MODE=1."
        log::error "These are testing-only hooks — refusing to run with either set outside test mode."
        exit 2
    fi
    # realpath -m (not string concatenation, not a bare `cd`+pwd) so that e.g.
    # GPU_SYSROOT=/ canonicalizes to /etc and is caught — a naive "$sysroot/etc"
    # string compare missed exactly that case (it produced "//etc" != "/etc"
    # and let a real write through, caught only by this host lacking root).
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

# _missing_required : count of catalogue atoms tagged "required" that are not
# installed. Same lib::portage primitives deps.sh/doctor.sh already use for
# their own reports — this does not re-detect anything, it only decides
# whether desktop's --apply should stop before writing anything real.
_missing_required() {
    # See the guarded block above: this hook is already unusable unless
    # DESKTOP_TEST_MODE=1 passed the simulated-sysroot check.
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

STEP_N=0
# _step <label> <script> [args...] — run one subcommand with full terminal
# passthrough (so its own confirmations work exactly as a direct call would),
# print a header, and return its real exit code without killing desktop.sh.
_step() {
    local label="$1" script="$2"; shift 2
    STEP_N=$((STEP_N + 1))
    ui::header "$STEP_N. $label"
    local ec=0
    bash "$CMD_DIR/$script" "$@" || ec=$?
    return "$ec"
}

FAILED=0
FAIL_STEP=""

ui::header "Desktop orchestration"
if [ "$APPLY" = 1 ]; then
    log::info "--apply: each step below runs for real and still confirms itself before writing"
else
    log::info "plan / read-only: every step below runs in its own plan mode. Re-run with --apply."
fi
if [ "$IS_GENTOO" = 1 ]; then
    log::info "target: Gentoo"
else
    log::warn "this system is not Gentoo ($(command -v hostnamectl >/dev/null 2>&1 && hostnamectl 2>/dev/null | awk -F': ' '/Operating System/{print $2; exit}' || echo 'unknown'))."
    log::info "the target for this repo is Gentoo. This is a preflight: plan steps run normally;"
    log::info "the two /etc-writing steps (gpu, power) stay plan-only here even under --apply —"
    log::info "this host is not used as a stand-in for applying real Gentoo-specific system changes."
fi

# ---- 1. preflight/check (always; read-only; never blocks) -----------------
_step "Preflight (install.sh check)" check.sh || true

# ---- 2. dependencies (always; read-only; never blocks by itself) ---------
_step "Dependencies (install.sh deps)" deps.sh || true
missing_req=$(_missing_required)
if [ "$IS_GENTOO" = 1 ] && [ "$missing_req" -gt 0 ]; then
    log::warn "$missing_req required package(s) missing (see the deps plan above)."
fi

if [ "$APPLY" = 1 ] && [ "$IS_GENTOO" = 1 ] && [ "$missing_req" -gt 0 ]; then
    log::error "stopping before any write: $missing_req required package(s) are missing."
    log::error "run the emerge command(s) install.sh deps printed above, then re-run install.sh desktop --apply."
    FAILED=1
    FAIL_STEP="deps"
fi

# ---- 3. dotfiles ------------------------------------------------------
if [ "$FAILED" = 0 ]; then
    if [ "$APPLY" = 1 ]; then _step "Dotfiles (install.sh dotfiles --apply)" dotfiles.sh --apply
    else                      _step "Dotfiles (install.sh dotfiles)"         dotfiles.sh
    fi || { FAILED=1; FAIL_STEP="dotfiles"; }
fi

# ---- 4. GPU config (Gentoo-/etc-specific — conservative off Gentoo) -------
if [ "$FAILED" = 0 ]; then
    if [ "$APPLY" = 1 ] && [ "$IS_GENTOO" = 1 ]; then
        _step "GPU config (install.sh gpu --apply)" gpu.sh --apply || { FAILED=1; FAIL_STEP="gpu"; }
    else
        [ "$APPLY" = 1 ] && log::info "GPU config: plan only (not Gentoo) — see above for why"
        _step "GPU config (install.sh gpu)" gpu.sh || true
    fi
fi

# ---- 5. power config (Gentoo-/etc-specific — conservative off Gentoo) -----
if [ "$FAILED" = 0 ]; then
    if [ "$APPLY" = 1 ] && [ "$IS_GENTOO" = 1 ]; then
        _step "Power config (install.sh power --apply)" power.sh --apply || { FAILED=1; FAIL_STEP="power"; }
    else
        [ "$APPLY" = 1 ] && log::info "Power config: plan only (not Gentoo) — see above for why"
        _step "Power config (install.sh power)" power.sh || true
    fi
fi

# ---- 6. Infinite Desktop runtime -------------------------------------
# infinite-desktop.sh has no separate --apply flag: it always attempts the
# real install (confirming per conflict) unless --dry-run is passed, so plan
# mode here means passing --dry-run explicitly, not omitting a flag.
if [ "$FAILED" = 0 ]; then
    if [ "$APPLY" = 1 ]; then _step "Infinite Desktop (install.sh infinite-desktop)"           infinite-desktop.sh
    else                      _step "Infinite Desktop (install.sh infinite-desktop --dry-run)" infinite-desktop.sh --dry-run
    fi || { FAILED=1; FAIL_STEP="infinite-desktop"; }
fi

# ---- 7 + 8. network/audio verification + final summary --------------
# doctor already checks NetworkManager and PipeWire/WirePlumber (along with
# everything else in the "Desktop readiness" style summary below) — this is
# the one place that happens, not a second network/audio check plus a
# separate summary. Always runs, even after a failure above, since it writes
# nothing and a post-failure snapshot is exactly what's useful right now.
_step "Readiness summary (install.sh doctor)" doctor.sh || true

# ---------------------------------------------------------------------------
ui::header "Desktop orchestration — result"
if [ "$FAILED" = 1 ]; then
    log::error "stopped at step: $FAIL_STEP. Nothing after it ran. See that step's output above."
    exit 1
fi
if [ "$APPLY" = 1 ]; then
    log::ok "desktop --apply complete — see the readiness summary above for what's left, if anything"
else
    log::ok "desktop (plan) complete — nothing was changed. Re-run with --apply."
fi
