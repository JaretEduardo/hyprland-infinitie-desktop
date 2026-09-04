# lib/backup.sh — move an existing path out of the way, safely.
#
# Reusable by dotfiles and later by the Hyprland / Quickshell / hypridle /
# hyprlock config steps. It NEVER deletes anything: a "backup" is a `mv` of the
# existing file/dir/symlink to a timestamped sibling that does not already exist.
#
#   backup::name <target>   -> a free backup path for <target> (does not create it)
#   backup::save <target>   -> mv <target> to that path; prints the path; 1 if
#                              <target> does not exist

[ -n "${_LIB_BACKUP_SH:-}" ] && return 0
_LIB_BACKUP_SH=1

# backup::name <target>
#   <target>.backup-YYYYmmdd-HHMMSS , with -2, -3, … if that already exists.
backup::name() {
    local target="$1" base stamp cand n
    base="${target}.backup-$(date +%Y%m%d-%H%M%S)"
    cand="$base"
    n=2
    while [ -e "$cand" ] || [ -L "$cand" ]; do
        cand="${base}-${n}"
        n=$((n + 1))
    done
    printf '%s' "$cand"
}

# backup::save <target>  -> prints the backup path on stdout, notes on stderr
backup::save() {
    local target="$1" dest
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        printf 'backup::save: nothing at %s\n' "$target" >&2
        return 1
    fi
    dest="$(backup::name "$target")"
    mv -- "$target" "$dest" || { printf 'backup::save: mv %s failed\n' "$target" >&2; return 1; }
    printf '%s\n' "backup: $target -> $dest" >&2
    printf '%s' "$dest"
}
