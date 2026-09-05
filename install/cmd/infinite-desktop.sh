#!/usr/bin/env bash
#
# install.sh infinite-desktop — install / verify the Infinite Desktop runtime
# component (the Python/evdev daemon + its helper scripts).
#
# It does NOT touch the Hyprland config. The keybinds and autostart are declared
# in config/hypr/lua/infinite-desktop.lua and linked into place by
# `install.sh dotfiles --apply`.
#
# It also does NOT install packages, call sudo, or run usermod. Missing
# dependencies are reported (fix with `install.sh deps`); the `input` group is
# checked and explained, never modified here.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/backup.sh
. "$REPO_DIR/lib/backup.sh"

SRC_DIR="$REPO_DIR/scripts/infinite-desktop"
DEST_DIR="${INFINITE_DESKTOP_DEST:-$HOME/scripts}"   # runtime location (kept as ~/scripts for now)
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        -*) log::error "infinite-desktop: unknown option: $a"; exit 2 ;;
        *)  log::error "infinite-desktop: unexpected argument: $a"; exit 2 ;;
    esac
done

N_COPIED=0; N_UPTODATE=0; N_CONFLICT=0
HARD_FAIL=0

# --- runtime scripts ------------------------------------------------------

_install_script() {
    local src="$1" name dest
    name="$(basename "$src")"
    dest="$DEST_DIR/$name"

    if [ ! -e "$dest" ]; then
        if [ -n "$DRY" ]; then log::info "would install $name"; N_COPIED=$((N_COPIED+1)); return 0; fi
        install -D -m 0644 "$src" "$dest"
        case "$name" in *.py|*.sh) chmod +x "$dest" ;; esac
        log::ok "installed $name"
        N_COPIED=$((N_COPIED+1))
        return 0
    fi
    if cmp -s "$src" "$dest"; then
        [ -n "${INSTALL_VERBOSE:-}" ] && log::info "$name already up to date"
        N_UPTODATE=$((N_UPTODATE+1))
        return 0
    fi

    # differs — never overwrite silently
    N_CONFLICT=$((N_CONFLICT+1))
    log::warn "$dest differs from the repo copy"
    if [ -n "${INSTALL_VERBOSE:-}" ]; then
        diff -u "$dest" "$src" 2>/dev/null | sed 's/^/    /' || true
    fi
    if [ -n "$DRY" ]; then log::info "would back up $dest and replace it"; return 0; fi
    if ! ui::confirm "Back up $dest and replace it with the repo copy?"; then
        log::warn "kept $dest as-is — Infinite Desktop may misbehave until it matches the repo"
        return 0
    fi
    backup::save "$dest" >/dev/null
    install -D -m 0644 "$src" "$dest"
    case "$name" in *.py|*.sh) chmod +x "$dest" ;; esac
    log::ok "backed up + installed $name"
    N_COPIED=$((N_COPIED+1))
}

# --- dependency + permission checks (report only) ---------------------

check_runtime() {
    ui::section "Runtime requirements"

    if command -v python3 >/dev/null 2>&1; then
        ui::kv "python3" "$(command -v python3)"
    else
        log::error "python3 not found — run: install.sh deps"
        HARD_FAIL=1
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import evdev' 2>/dev/null; then
        ui::kv "python evdev" "importable"
    else
        log::warn "python 'evdev' module not importable — the daemon will not start."
        log::warn "  Gentoo: emerge dev-python/evdev   (or: install.sh deps)"
    fi
    if command -v jq >/dev/null 2>&1; then
        ui::kv "jq" "$(command -v jq)"
    else
        log::warn "jq not found (used by parts of the component) — install.sh deps"
    fi
    if command -v hyprctl >/dev/null 2>&1; then
        ui::kv "hyprctl" "$(command -v hyprctl)"
    else
        log::info "hyprctl not found — expected until Hyprland is installed on Gentoo"
    fi
    if command -v qs >/dev/null 2>&1; then
        ui::kv "qs (Quickshell)" "present — the optional frame hint will work"
    else
        log::info "qs (Quickshell) not found — the optional 'qs ipc call frame' hint is skipped at runtime"
    fi
}

check_input_access() {
    ui::section "Input device access (evdev)"
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then
        log::ok "your user is in the 'input' group"
    else
        log::warn "your user is NOT in the 'input' group."
        log::warn "  The daemon reads /dev/input/event* directly and needs it. To grant it:"
        log::warn "      sudo usermod -aG input \"\$USER\"      then log out and back in"
        log::warn "  This installer will NOT run usermod for you."
    fi
    # can we actually open an event device right now?
    local readable=0 d
    for d in /dev/input/event*; do
        [ -e "$d" ] || continue
        if [ -r "$d" ]; then readable=1; break; fi
    done
    if [ "$readable" = 1 ]; then
        log::ok "at least one /dev/input/event* is readable by this user now"
    else
        log::warn "no /dev/input/event* is readable yet (group change needs a re-login)"
    fi
    cat <<'EOF'
  Note: membership in 'input' grants read access to ALL input events on the
  system (every keystroke, every mouse move) for any process you run. That is
  the trade-off evdev requires. A tighter permission model (an ACL or a small
  privileged helper) can be decided during first-run; this stage does not
  change /dev/input permissions.
EOF
}

# ---------------------------------------------------------------------------
ui::header "Infinite Desktop"
[ -n "$DRY" ] && log::info "dry-run: nothing will be written"

if [ ! -d "$SRC_DIR" ]; then
    log::error "component scripts not found in the repository: $SRC_DIR"
    exit 1
fi

check_runtime
check_input_access

ui::section "Runtime scripts  ->  $DEST_DIR"
[ -n "$DRY" ] || mkdir -p "$DEST_DIR"
while IFS= read -r -d '' f; do
    _install_script "$f"
done < <(find "$SRC_DIR" -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) -print0)

# --- summary --------------------------------------------------------
ui::header "Summary"
ui::kv "installed / updated" "$N_COPIED"
ui::kv "already up to date"   "$N_UPTODATE"
ui::kv "conflicts kept"       "$N_CONFLICT"
printf '\n'
log::info "Keybinds + autostart are declared in config/hypr/lua/infinite-desktop.lua."
log::info "Apply them with:  ./install.sh dotfiles --apply"

if [ "$HARD_FAIL" = 1 ]; then
    log::error "a hard requirement is missing (see above)"
    exit 1
fi
[ -n "$DRY" ] && log::ok "infinite-desktop (dry-run) complete" \
             || log::ok "infinite-desktop complete — Hyprland config was NOT touched"
exit 0
