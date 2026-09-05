#!/usr/bin/env bash
#
# install.sh infinite-desktop — install / verify the Infinite Desktop runtime
# component (the Python/evdev daemon + its helper scripts).
#
# It does NOT touch the Hyprland config. The keybinds and autostart are declared
# in config/hypr/lua/infinite-desktop.lua and linked into place by
# `install.sh dotfiles --apply`.
#
# It also does NOT install packages, call sudo, run usermod, or touch
# /dev/input permissions. Missing dependencies are reported (fix with
# `install.sh deps`); input-device access is reported here and configured by
# `install.sh input` (a udev `uaccess` rule, not the `input` group).
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
    # The repo's model is a udev `uaccess` rule (install.sh input), which gives
    # ONLY the active local session a temporary ACL — not the account-wide
    # 'input' group. This stage only reports; it changes no /dev/input perms and
    # never runs sudo/udevadm/usermod.
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then
        log::warn "your user is in the 'input' group — broader than needed."
        log::warn "  'install.sh input' installs a udev uaccess rule that replaces it; you can then"
        log::warn "  remove yourself from 'input' (sudo gpasswd -d \"\$USER\" input) if you want."
    fi
    local rule=/etc/udev/rules.d/72-hypr-infinite-input.rules
    if [ -f "$rule" ] && head -n1 "$rule" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop'; then
        log::ok "udev uaccess rule installed ($rule)"
    else
        log::warn "udev uaccess rule not installed — run:  ./install.sh input   (needs root; then reload udev + trigger)"
    fi
    # The real test: can this user read a keyboard AND a pointer (a REL mouse OR
    # an ABS touchpad) right now?  A laptop often has only a touchpad.
    local kbd_ok=0 mouse_ok=0 tp_ok=0 d props
    for d in /dev/input/event*; do
        [ -e "$d" ] || continue
        props="$(udevadm info -q property -n "$d" 2>/dev/null || true)"
        case "$props" in *"ID_INPUT_KEYBOARD=1"*) [ -r "$d" ] && kbd_ok=1 ;; esac
        case "$props" in *"ID_INPUT_MOUSE=1"*)    [ -r "$d" ] && mouse_ok=1 ;; esac
        case "$props" in *"ID_INPUT_TOUCHPAD=1"*) [ -r "$d" ] && tp_ok=1 ;; esac
    done
    local ptr_ok=0 via=""; { [ "$mouse_ok" = 1 ] || [ "$tp_ok" = 1 ]; } && ptr_ok=1
    [ "$mouse_ok" = 1 ] && via="mouse"
    [ "$tp_ok" = 1 ] && via="${via:+$via + }touchpad"
    if [ "$kbd_ok" = 1 ] && [ "$ptr_ok" = 1 ]; then
        log::ok "a keyboard and a usable pointer ($via) are readable by this user now"
    else
        local miss=""
        [ "$kbd_ok" = 0 ] && miss="a keyboard"
        [ "$ptr_ok" = 0 ] && miss="${miss:+$miss and }a pointer (mouse or touchpad)"
        log::warn "the daemon cannot read $miss yet"
        log::warn "  run  ./install.sh input  (reload + trigger; re-login/reboot only if getfacl still shows no ACL)"
    fi
    cat <<'EOF'
  RISK: a `uaccess` ACL on keyboard nodes lets any process in your active
  graphical session read every keystroke (passwords included) — and every
  touchpad/mouse motion — while that session is active. This is inherent to
  evdev; `uaccess` bounds it to the active local session and drops it when the
  session ends. See docs/INFINITE-DESKTOP.md "Input device access" for the
  stricter privileged-broker design.
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
# Ship the runtime .py/.sh flat; test_*.py are unit tests, not runtime — skip.
while IFS= read -r -d '' f; do
    _install_script "$f"
done < <(find "$SRC_DIR" -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) \
             ! -name 'test_*.py' -print0)

# --- summary --------------------------------------------------------
ui::header "Summary"
ui::kv "installed / updated" "$N_COPIED"
ui::kv "already up to date"   "$N_UPTODATE"
ui::kv "conflicts kept"       "$N_CONFLICT"
printf '\n'
log::info "Keybinds + autostart are declared in config/hypr/lua/infinite-desktop.lua."
log::info "Apply them with:  ./install.sh dotfiles --apply"
log::info "Grant the daemon input-device access with:  ./install.sh input   (then reload udev + trigger)"

if [ "$HARD_FAIL" = 1 ]; then
    log::error "a hard requirement is missing (see above)"
    exit 1
fi
[ -n "$DRY" ] && log::ok "infinite-desktop (dry-run) complete" \
             || log::ok "infinite-desktop complete — Hyprland config was NOT touched"
exit 0
