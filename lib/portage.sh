# lib/portage.sh — Gentoo / Portage helpers (read-only).
#
# Sourced by the deps command and, later, by desktop / gpu / kernel-dev /
# doctor. Read-only: it queries Portage state, it never calls emerge, eselect,
# emaint or writes anything under /etc.
#
#   booleans   portage::is_gentoo, portage::has_emerge, portage::pkg_installed
#   queries    portage::repos_enabled, portage::repo_enabled, portage::repo_known
#   catalogue  portage::catalog [group]   -> "group|atom|repo|tier|note" lines
#              portage::catalog_groups / portage::catalog_repos

[ -n "${_LIB_PORTAGE_SH:-}" ] && return 0
_LIB_PORTAGE_SH=1

if [ -n "${INSTALL_REPO_DIR:-}" ]; then
    _portage_root="$INSTALL_REPO_DIR"
else
    _portage_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
PORTAGE_CATALOG="${PORTAGE_CATALOG:-$_portage_root/install/packages.gentoo}"

# --- environment -----------------------------------------------------------

portage::is_gentoo() {
    [ -f /etc/gentoo-release ] && return 0
    command -v emerge >/dev/null 2>&1 && return 0
    [ -r /etc/os-release ] && ( . /etc/os-release 2>/dev/null; [ "${ID:-}" = gentoo ] )
}

portage::has_emerge()   { command -v emerge   >/dev/null 2>&1; }
portage::has_eselect()  { command -v eselect  >/dev/null 2>&1; }
portage::has_portageq() { command -v portageq >/dev/null 2>&1; }

# portage::pkg_installed <cat/name>  -> 0 if some version is installed
portage::pkg_installed() {
    local atom="$1"
    if command -v portageq >/dev/null 2>&1; then
        portageq has_version / "$atom" >/dev/null 2>&1
        return
    fi
    local cat="${atom%/*}" name="${atom#*/}"
    compgen -G "/var/db/pkg/${cat}/${name}-[0-9]*" >/dev/null 2>&1
}

# --- overlays / repositories ---------------------------------------------

# One repository name per line, for the repos currently configured.
portage::repos_enabled() {
    if command -v portageq >/dev/null 2>&1; then
        portageq get_repos / 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
    elif [ -d /etc/portage/repos.conf ]; then
        grep -hoE '^\[[^]]+\]' /etc/portage/repos.conf/* /etc/portage/repos.conf 2>/dev/null \
            | tr -d '[]' | sed '/^DEFAULT$/d;/^$/d'
    fi
}

# Repositories eselect-repository knows about (enabled or not). Empty without it.
portage::repos_known() {
    command -v eselect >/dev/null 2>&1 || return 0
    eselect repository list 2>/dev/null \
        | sed -E 's/^[[:space:]]*\[[0-9]+\][[:space:]]*//' \
        | awk 'NF && $1 !~ /^Available/ {print $1}'
}

portage::repo_enabled() { portage::repos_enabled | grep -qxF "$1"; }
portage::repo_known()   { portage::repos_known   | grep -qxF "$1"; }

# --- package catalogue --------------------------------------------------

# portage::catalog [group]  -> normalised "group|atom|repo|tier|note" lines
portage::catalog() {
    [ -r "$PORTAGE_CATALOG" ] || return 0
    awk -F'|' -v want="${1:-}" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            for (i = 1; i <= NF; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
            if (want == "" || $1 == want)
                printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5
        }
    ' "$PORTAGE_CATALOG"
}

portage::catalog_groups() { portage::catalog | awk -F'|' '!seen[$1]++ {print $1}'; }
portage::catalog_repos()  { portage::catalog | awk -F'|' '$3 != "::gentoo" && !seen[$3]++ {print $3}'; }
