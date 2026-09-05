# lib/log.sh — logging primitives for the installer.
#
# Sourced (never executed) by install/common.sh. Environment it honours:
#   LOG_NO_COLOR=1   disable ANSI colour (also auto-off when stderr is not a TTY)
#   LOG_VERBOSE=1    enable log::debug output
#   LOG_FILE=<path>  also append plain, timestamped lines to this file
#
# Public functions: log::info  log::ok  log::warn  log::error  log::debug

[ -n "${_LIB_LOG_SH:-}" ] && return 0
_LIB_LOG_SH=1

if [ -z "${LOG_NO_COLOR:-}" ] && [ -t 2 ]; then
    _C_RESET=$'\033[0m'; _C_DIM=$'\033[2m'
    _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_CYAN=$'\033[36m'
else
    _C_RESET=''; _C_DIM=''
    _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_CYAN=''
fi

# _log::emit <level> <colour> <message...>
_log::emit() {
    local level="$1" colour="$2"; shift 2
    printf '%s[%s]%s %s\n' "$colour" "$level" "$_C_RESET" "$*" >&2
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s [%-5s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

log::info()  { _log::emit "INFO"  "$_C_CYAN"   "$@"; }
log::ok()    { _log::emit "OK"    "$_C_GREEN"  "$@"; }
log::warn()  { _log::emit "WARN"  "$_C_YELLOW" "$@"; }
log::error() { _log::emit "ERROR" "$_C_RED"    "$@"; }
log::debug() { [ -n "${LOG_VERBOSE:-}" ] || return 0; _log::emit "DEBUG" "$_C_DIM" "$@"; }
