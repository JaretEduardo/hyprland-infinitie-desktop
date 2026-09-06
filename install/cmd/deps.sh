#!/usr/bin/env bash
#
# install.sh deps — detect Gentoo dependencies and print the plan.
#
# Read-only. It NEVER runs emerge / eselect / emaint and never writes /etc.
# Its whole job is: figure out what is missing and print the exact commands a
# human would run. `--install` is parsed but deliberately not implemented.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then
    REPO_DIR="$INSTALL_REPO_DIR"
else
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"
# shellcheck source=lib/portage.sh
. "$REPO_DIR/lib/portage.sh"

VERBOSE="${INSTALL_VERBOSE:-${LOG_VERBOSE:-}}"
MODE=plan
for a in "$@"; do
    case "$a" in
        --install) MODE=install ;;
        -*) log::error "deps: unknown option: $a"; exit 2 ;;
        *)  log::error "deps: unexpected argument: $a"; exit 2 ;;
    esac
done

# collected missing atoms, by tier
MISSING_REQUIRED=()
MISSING_RECOMMENDED=()
MISSING_OPTIONAL=()
# missing atoms from overlays that need a PER-PACKAGE ~amd64 accept_keywords
# (guru; hyproverlay is covered by the blanket '*/*::hyproverlay' rule)
MISSING_KEYWORDS=()
NOT_VERIFIABLE=0

# _repo_hint <repo>  -> one-line "why / how" for an overlay
_repo_hint() {
    case "$1" in
        hyproverlay) echo "Hyprland stack — codeberg.org/hyproverlay/hyproverlay" ;;
        guru)        echo "Quickshell, brightnessctl, wev — github.com/gentoo/guru" ;;
        *)           echo "overlay" ;;
    esac
}

_field() { cut -d'|' -f"$1"; }

# ---------------------------------------------------------------------------
ui::header "Gentoo dependencies"

groups=$(portage::catalog_groups)
repos=$(portage::catalog_repos)

if [ -z "$groups" ]; then
    log::error "package catalogue not found or empty: $PORTAGE_CATALOG"
    exit 1
fi

# ===========================================================================
# Off Gentoo: show the plan, do not pretend to verify install state.
# ===========================================================================
if ! portage::is_gentoo; then
    log::warn "deps targets Gentoo — this system is $(hw::os_pretty || echo 'not Gentoo')."
    log::info "Showing the dependency plan. Installed / missing state is NOT verifiable here."
    printf '\n'

    ui::section "Overlays to enable (run as root on Gentoo)"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        ui::kv "$r" "$(_repo_hint "$r")"
        printf '      eselect repository enable %s && emaint sync -r %s\n' "$r" "$r"
    done <<<"$repos"
    printf '      # hyproverlay is ~amd64-wide:\n'
    printf "      # echo '*/*::hyproverlay' > /etc/portage/package.accept_keywords/hyproverlay\n"

    while IFS= read -r g; do
        [ -n "$g" ] || continue
        ui::section "$g"
        while IFS='|' read -r _g atom repo tier note; do
            printf '  %-37s %-12s %-11s %s\n' "$atom" "$repo" "$tier" "${note:+# $note}"
        done < <(portage::catalog "$g")
    done <<<"$groups"

    printf '\n'
    log::info "on Gentoo, re-run: ./install.sh deps   (adds installed/missing per atom)"
    log::ok "deps (plan only) complete — nothing was changed"
    exit 0
fi

# ===========================================================================
# On Gentoo: verify tools, overlays, packages.
# ===========================================================================
ui::section "Portage tools"
_tool_ok=1
for t in emerge portageq; do
    if command -v "$t" >/dev/null 2>&1; then
        ui::kv "$t" "$(command -v "$t")"
    else
        ui::kv "$t" "MISSING"
        _tool_ok=0
    fi
done
if command -v eselect >/dev/null 2>&1 && eselect repository list >/dev/null 2>&1; then
    ui::kv "eselect repository" "available"
else
    ui::kv "eselect repository" "not available — emerge --ask app-eselect/eselect-repository"
fi
[ "$_tool_ok" = 1 ] || log::warn "core Portage tools missing; results below may be incomplete"

# ---- overlays -------------------------------------------------------------
ui::section "Overlays"
OVERLAY_TODO=()
while IFS= read -r r; do
    [ -n "$r" ] || continue
    if portage::repo_enabled "$r"; then
        ui::kv "$r" "enabled"
    elif portage::repo_known "$r"; then
        ui::kv "$r" "available, NOT enabled  ($(_repo_hint "$r"))"
        OVERLAY_TODO+=("$r")
    else
        ui::kv "$r" "not enabled; eselect cannot see it yet  ($(_repo_hint "$r"))"
        OVERLAY_TODO+=("$r")
    fi
done <<<"$repos"

# ---- packages by group -------------------------------------------------
while IFS= read -r g; do
    [ -n "$g" ] || continue
    ui::section "$g"
    while IFS='|' read -r _g atom repo tier note; do
        if portage::pkg_installed "$atom"; then
            [ -n "$VERBOSE" ] && printf '  %-37s %-11s %-9s %s\n' "$atom" "$tier" "installed" "$repo"
        else
            case "$tier" in
                required)    MISSING_REQUIRED+=("$atom") ;;
                recommended) MISSING_RECOMMENDED+=("$atom") ;;
                *)           MISSING_OPTIONAL+=("$atom") ;;
            esac
            # guru packages always need ~amd64; other atoms flag it in their note.
            case "$repo:$note" in guru:*|*~amd64*) MISSING_KEYWORDS+=("$atom") ;; esac
            printf '  %-37s %-11s %-9s %s%s\n' \
                "$atom" "$tier" "MISSING" "$repo" "${note:+   # $note}"
        fi
    done < <(portage::catalog "$g")
done <<<"$groups"

# ---- summary / commands --------------------------------------------------
ui::header "Plan"

ui::kv "missing required"    "${#MISSING_REQUIRED[@]}"
ui::kv "missing recommended" "${#MISSING_RECOMMENDED[@]}"
ui::kv "missing optional"    "${#MISSING_OPTIONAL[@]}"

if [ "${#OVERLAY_TODO[@]}" -gt 0 ]; then
    printf '\n'
    ui::section "1. Enable overlays (as root)"
    printf '   eselect repository enable %s\n' "${OVERLAY_TODO[*]}"
    _sync=""; for _r in "${OVERLAY_TODO[@]}"; do _sync="${_sync:+$_sync }-r $_r"; done
    printf '   emaint sync %s\n' "$_sync"
    if printf '%s\n' "${OVERLAY_TODO[@]}" | grep -qx hyproverlay; then
        printf "   echo '*/*::hyproverlay' > /etc/portage/package.accept_keywords/hyproverlay\n"
    fi
    if printf '%s\n' "${OVERLAY_TODO[@]}" | grep -qx guru; then
        printf '   # guru: accept ~amd64 per package as emerge reports it needed\n'
    fi
fi

_emerge_line() {  # <title> <atoms...>
    local title="$1"; shift
    [ "$#" -gt 0 ] || return 0
    printf '\n'
    ui::section "$title"
    printf '   emerge --ask'
    printf ' %s' "$@"
    printf '\n'
}
if [ "${#MISSING_KEYWORDS[@]}" -gt 0 ]; then
    printf '\n'
    ui::section "Accept ~amd64 for these packages (as root, before emerge)"
    for _a in "${MISSING_KEYWORDS[@]}"; do
        printf "   echo '%s ~amd64' >> /etc/portage/package.accept_keywords/%s\n" "$_a" "${_a#*/}"
    done
fi

_emerge_line "2. Install required"    "${MISSING_REQUIRED[@]}"
_emerge_line "3. Install recommended" "${MISSING_RECOMMENDED[@]}"
_emerge_line "4. Optional (pick what you need)" "${MISSING_OPTIONAL[@]}"

printf '\n'
if [ "$MODE" = install ]; then
    log::warn "--install is not implemented: deps only detects and plans."
    log::warn "Review the commands above and run them yourself."
    exit 3
fi

total_missing=$(( ${#MISSING_REQUIRED[@]} + ${#MISSING_RECOMMENDED[@]} + ${#MISSING_OPTIONAL[@]} ))
if [ "$total_missing" -eq 0 ] && [ "${#OVERLAY_TODO[@]}" -eq 0 ]; then
    log::ok "all catalogued dependencies are already satisfied"
else
    log::ok "deps complete — read-only, nothing was changed. Run the commands above as root."
fi
