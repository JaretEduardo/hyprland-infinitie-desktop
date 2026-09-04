#!/usr/bin/env bash
#
# install.sh dotfiles — link the repo's config files into place, per entry.
#
#   install.sh dotfiles              detect + show what would happen (read-only)
#   install.sh dotfiles --apply      per entry: show src -> dest, confirm, apply
#   install.sh --dry-run dotfiles --apply    show the actions, write nothing
#
# One symlink PER FILE, never a whole directory, so machine-local files
# (e.g. ~/.config/hypr/monitors.local.lua) can sit beside the managed symlinks
# untouched. Nothing is ever deleted: replacing an existing file/dir/symlink
# goes through lib/backup.sh (a mv). No sudo, no /etc, only paths under
# $HOME / $XDG_CONFIG_HOME.
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
# shellcheck source=lib/symlink.sh
. "$REPO_DIR/lib/symlink.sh"

# --- config -------------------------------------------------------------
SRC_ROOT="${DOTFILES_SRC_ROOT:-$REPO_DIR}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
HOME_ROOT="${HOME:?}"
MANIFEST="${DOTFILES_MANIFEST:-$REPO_DIR/install/dotfiles.manifest}"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "dotfiles: unknown option: $a"; exit 2 ;;
        *)  log::error "dotfiles: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

N_OK=0; N_LINK=0; N_SKIP=0; N_CONFLICT=0

# _dest_root <base>
_dest_root() { case "$1" in config) printf '%s' "$CONFIG_HOME" ;; home) printf '%s' "$HOME_ROOT" ;; *) return 1 ;; esac; }

# _safe <path> <allowed-root> : 0 if <path>'s location stays inside <root>
_safe() {
    local p="$1" root="$2" dir
    case "$p" in *../*|*/..|..) return 1 ;; esac
    dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd || true)"
    # parent may not exist yet: walk up to the nearest existing ancestor
    if [ -z "$dir" ]; then
        dir="$p"
        while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir="$(dirname "$dir")"; done
        dir="$(cd "$dir" 2>/dev/null && pwd || echo /)"
    fi
    case "$dir/" in "$root"/*) return 0 ;; *) return 1 ;; esac
}

_would() { printf '  %s[dry-run]%s %s\n' "${_C_DIM:-}" "${_C_RESET:-}" "$*"; }

# _apply_entry <src> <dest> : do backup(if needed) -> symlink -> verify
_apply_entry() {
    local src="$1" dest="$2" st
    st="$(symlink::state "$dest" "$src")"
    case "$st" in
        absent)
            if [ -n "$DRY" ]; then _would "ln -s $src $dest"; return 0; fi
            symlink::create "$dest" "$src" && log::ok "linked $dest" || { log::error "failed to link $dest"; return 1; }
            ;;
        broken|wrong-link|real-file|real-dir)
            printf '  will move %s to a .backup-* sibling, then link it\n' "$dest"
            [ "$st" = wrong-link ] && printf '    (currently points to: %s)\n' "$(symlink::current_target "$dest")"
            ui::confirm "Back up $dest and replace it with a link to the repo copy?" || {
                log::warn "kept $dest as-is"; N_CONFLICT=$((N_CONFLICT + 1)); return 0; }
            if [ -n "$DRY" ]; then _would "backup $dest ; ln -s $src $dest"; return 0; fi
            symlink::replace "$dest" "$src" && log::ok "backed up + linked $dest" || { log::error "failed on $dest"; return 1; }
            ;;
    esac
    if [ -z "$DRY" ] && ! symlink::verify "$dest" "$src"; then
        log::error "verification failed: $dest is not a correct symlink"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
ui::header "Dotfiles"
[ "$APPLY" = 1 ] && log::info "--apply: each entry is shown and confirmed before any change" \
                 || log::info "read-only plan. Re-run with --apply to link them."
log::debug "manifest:  $MANIFEST"
log::debug "src root:  $SRC_ROOT"
log::debug "config:    $CONFIG_HOME"

if [ ! -r "$MANIFEST" ]; then
    log::error "manifest not readable: $MANIFEST"
    exit 1
fi

entries=0
while IFS='|' read -r base src dest note; do
    base="${base#"${base%%[![:space:]]*}"}"; base="${base%"${base##*[![:space:]]}"}"
    [ -z "$base" ] && continue
    case "$base" in \#*) continue ;; esac
    src="${src#"${src%%[![:space:]]*}"}";   src="${src%"${src##*[![:space:]]}"}"
    dest="${dest#"${dest%%[![:space:]]*}"}"; dest="${dest%"${dest##*[![:space:]]}"}"
    note="${note#"${note%%[![:space:]]*}"}"; note="${note%"${note##*[![:space:]]}"}"
    entries=$((entries + 1))

    droot="$(_dest_root "$base")" || { log::error "entry $entries: bad base '$base'"; N_CONFLICT=$((N_CONFLICT+1)); continue; }
    case "$src" in /*|*..*) log::error "entry $entries: source must be a relative in-repo path"; N_CONFLICT=$((N_CONFLICT+1)); continue ;; esac
    case "$dest" in /*) log::error "entry $entries: dest must be relative"; N_CONFLICT=$((N_CONFLICT+1)); continue ;; esac
    abs_src="$SRC_ROOT/$src"
    abs_dest="$droot/$dest"

    printf '\n%s%s%s\n' "${_C_CYAN:-}" "$dest" "${_C_RESET:-}"
    printf '  source: %s\n' "$abs_src"
    printf '  dest:   %s\n' "$abs_dest"
    [ -n "$note" ] && printf '  note:   %s\n' "$note"

    if ! _safe "$abs_dest" "$droot"; then
        log::error "destination escapes $droot — refusing"
        N_CONFLICT=$((N_CONFLICT + 1)); continue
    fi
    if [ ! -e "$abs_src" ]; then
        log::warn "source not in the repo yet — skipping (a later stage adds it)"
        N_SKIP=$((N_SKIP + 1)); continue
    fi

    st="$(symlink::state "$abs_dest" "$abs_src")"
    case "$st" in
        correct)
            log::ok "already linked"
            N_OK=$((N_OK + 1)) ;;
        absent)
            log::info "would create symlink"
            N_LINK=$((N_LINK + 1))
            [ "$APPLY" = 1 ] && { _apply_entry "$abs_src" "$abs_dest" || true; } ;;
        *)
            log::warn "conflict: $abs_dest is $(symlink::describe "$st")"
            if [ "$APPLY" = 1 ]; then
                _apply_entry "$abs_src" "$abs_dest" || true
            else
                N_CONFLICT=$((N_CONFLICT + 1))
                printf '  --apply will offer to back it up and replace it.\n'
            fi ;;
    esac
done < "$MANIFEST"

# ---- summary ---------------------------------------------------------
ui::header "Summary"
if [ "$entries" = 0 ]; then
    log::info "no managed dotfile entries yet — nothing to do."
    log::info "The desktop / power stages will populate $MANIFEST."
    exit 0
fi
ui::kv "already linked" "$N_OK"
ui::kv "to link / linked" "$N_LINK"
ui::kv "skipped (no source yet)" "$N_SKIP"
ui::kv "conflicts" "$N_CONFLICT"
printf '\n'
if [ "$N_CONFLICT" -gt 0 ]; then
    log::warn "$N_CONFLICT unresolved — nothing of yours was deleted. Re-run with --apply to handle them."
    exit 1
fi
[ "$APPLY" = 1 ] && log::ok "dotfiles --apply complete" || log::ok "dotfiles (plan) complete — nothing was changed"
exit 0
