# lib/symlink.sh — per-entry symlink management for dotfiles.
#
# Low-level and side-effect-free except for the explicit create/replace calls.
# It never removes a real file or directory: replacing anything goes through
# lib/backup.sh (a `mv`, never an `rm`).
#
#   symlink::state <link> <target>   -> one token:
#       absent      nothing at <link>
#       correct     <link> is a symlink already resolving to <target>
#       broken      <link> is a symlink whose destination is missing
#       wrong-link  <link> is a symlink to something else
#       real-file   <link> is a regular file (not a symlink)
#       real-dir    <link> is a directory (not a symlink)
#       unknown     something else (socket, device, …)
#   symlink::describe <state>         -> human phrase
#   symlink::create <link> <target>   -> mkdir -p parent, ln -s; fails if <link> exists
#   symlink::replace <link> <target>  -> backup::save the existing <link>, then create
#   symlink::verify <link> <target>   -> 0 if state is now 'correct'

[ -n "${_LIB_SYMLINK_SH:-}" ] && return 0
_LIB_SYMLINK_SH=1

if [ -z "${_LIB_BACKUP_SH:-}" ]; then
    if [ -n "${INSTALL_REPO_DIR:-}" ]; then
        # shellcheck source=lib/backup.sh
        . "$INSTALL_REPO_DIR/lib/backup.sh"
    else
        # shellcheck source=lib/backup.sh
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup.sh"
    fi
fi

symlink::state() {
    local link="$1" target="$2" cur
    if [ -L "$link" ]; then
        cur="$(readlink "$link")"
        # match either the literal target or the fully-resolved path
        if [ "$cur" = "$target" ] || { [ -e "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")" ]; }; then
            printf 'correct'
        elif [ ! -e "$link" ]; then
            printf 'broken'
        else
            printf 'wrong-link'
        fi
        return 0
    fi
    if [ ! -e "$link" ]; then printf 'absent'; return 0; fi
    if [ -d "$link" ]; then printf 'real-dir'; return 0; fi
    if [ -f "$link" ]; then printf 'real-file'; return 0; fi
    printf 'unknown'
}

symlink::describe() {
    case "$1" in
        absent)     printf 'nothing there' ;;
        correct)    printf 'already linked correctly' ;;
        broken)     printf 'a broken symlink' ;;
        wrong-link) printf 'a symlink to a different location' ;;
        real-file)  printf 'a real file' ;;
        real-dir)   printf 'a real directory' ;;
        *)          printf 'something unexpected' ;;
    esac
}

# what a symlink currently points at (raw), or nothing
symlink::current_target() { [ -L "$1" ] && readlink "$1" || true; }

symlink::create() {
    local link="$1" target="$2"
    if [ -e "$link" ] || [ -L "$link" ]; then
        printf 'symlink::create: %s already exists\n' "$link" >&2
        return 1
    fi
    mkdir -p -- "$(dirname -- "$link")" || return 1
    ln -s -- "$target" "$link"
}

symlink::replace() {
    local link="$1" target="$2"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        symlink::create "$link" "$target"
        return
    fi
    backup::save "$link" >/dev/null || return 1
    symlink::create "$link" "$target"
}

symlink::verify() {
    [ "$(symlink::state "$1" "$2")" = correct ]
}
