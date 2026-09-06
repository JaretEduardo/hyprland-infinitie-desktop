# lib/session.sh — read-only helpers for inspecting the running user session.
#
# STRICTLY READ-ONLY. Nothing here starts, enables, or restarts a unit, opens a
# screencast, launches an X11 app, or writes anything. Every function degrades
# to a clear "unknown"/"no-bus" answer when run outside a session (e.g. a plain
# TTY, ssh, or a test) instead of emitting a false negative.
#
# Consumed by install/cmd/doctor.sh; unit-tested by lib/test_session.sh with
# mock `busctl` / `systemctl` on PATH.

[ -n "${_LIB_SESSION_SH:-}" ] && return 0
_LIB_SESSION_SH=1

session::have() { command -v "$1" >/dev/null 2>&1; }

# 0 if a D-Bus *session* bus is reachable from here WITHOUT autolaunching one.
# Requires either an explicit address or XDG_RUNTIME_DIR + its bus socket — a
# stripped env (e.g. `env -i`, some cron) correctly reports "no bus" instead of
# making `busctl --user` block trying to start one.
session::user_bus() {
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && return 0
    [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]
}

# run a bus/unit query with a hard timeout so a wedged D-Bus can never hang the
# whole read-only report.
session::_q() { timeout 5 "$@" 2>/dev/null; }

# session::unit_state <--user|--system> <unit>  -> active|inactive|failed|not-found|unknown
session::unit_state() {
    local scope="$1" unit="$2" out
    session::have systemctl || { printf 'unknown'; return 0; }
    if [ "$scope" = --user ] && ! session::user_bus; then printf 'unknown'; return 0; fi
    out="$(session::_q systemctl "$scope" is-active "$unit" || true)"
    case "$out" in
        active|inactive|failed|activating|deactivating) printf '%s' "$out" ;;
        "") printf 'not-found' ;;
        *)  printf '%s' "$out" ;;
    esac
}

# session::unit_enabled <--user|--system> <unit>  -> enabled|disabled|static|not-found|unknown
session::unit_enabled() {
    local scope="$1" unit="$2" out
    session::have systemctl || { printf 'unknown'; return 0; }
    if [ "$scope" = --user ] && ! session::user_bus; then printf 'unknown'; return 0; fi
    out="$(session::_q systemctl "$scope" is-enabled "$unit" || true)"
    case "$out" in
        enabled|enabled-runtime) printf 'enabled' ;;
        disabled)                printf 'disabled' ;;
        static|indirect|alias|generated|transient) printf 'static' ;;
        "")                      printf 'not-found' ;;
        *)                       printf '%s' "$out" ;;
    esac
}

# 0 if <name> currently has an owner on the given bus.
session::dbus_owned() {
    local scope="$1" name="$2"
    session::have busctl || return 2
    if [ "$scope" = --user ] && ! session::user_bus; then return 2; fi
    session::_q busctl "$scope" --no-pager status "$name" >/dev/null
}

# 0 if <name> is known to the bus (owned OR activatable).
session::dbus_known() {
    local scope="$1" name="$2"
    session::have busctl || return 2
    if [ "$scope" = --user ] && ! session::user_bus; then return 2; fi
    session::_q busctl "$scope" --no-pager list \
        | awk 'NR>1{print $1}' | grep -qxF "$name"
}

# session::pkg_use_has <cat/name> <flag>  -> 0 if the installed build has USE=flag.
# Reads the portage vdb directly (no emerge, no network). "unknown" -> return 2.
# $_SESSION_VDB overrides the vdb root (tests only).
session::pkg_use_has() {
    local atom="$1" flag="$2" d use
    for d in "${_SESSION_VDB:-/var/db/pkg}/$atom"-[0-9]*; do
        [ -d "$d" ] || continue
        [ -r "$d/USE" ] || return 2
        use=" $(cat "$d/USE") "
        case "$use" in *" $flag "*) return 0 ;; *) return 1 ;; esac
    done
    return 2
}

# session::xwayland  -> builtin | binary-only | none | unknown
#   builtin      Xwayland binary present AND gui-wm/hyprland built with USE=X
#   binary-only  Xwayland present but the compositor USE flag is off/unknown
#   none         no Xwayland binary
session::xwayland() {
    session::have Xwayland || { printf 'none'; return 0; }
    case "$(session::pkg_use_has gui-wm/hyprland X; echo $?)" in
        0) printf 'builtin' ;;
        1) printf 'binary-only' ;;
        *) printf 'unknown' ;;
    esac
}

# 0 if a process with this exact comm is running for the current user.
session::proc_running() { pgrep -x -u "$(id -u)" "$1" >/dev/null 2>&1; }

# session::fc_family <generic>  -> the family fc-match resolves <generic> to,
# or empty. <generic> is "sans-serif" | "monospace" | "emoji".
session::fc_family() {
    session::have fc-match || return 0
    { fc-match -f '%{family}\n' "$1" 2>/dev/null | head -n1; } || true
}
