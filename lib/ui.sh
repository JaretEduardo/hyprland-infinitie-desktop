# lib/ui.sh — presentational helpers (headers, rules, confirm prompts).
#
# Sourced (never executed) by install/common.sh, after lib/log.sh (it reuses the
# _C_* colour variables defined there).
#
# Public functions: ui::hr  ui::header  ui::section  ui::kv  ui::confirm

[ -n "${_LIB_UI_SH:-}" ] && return 0
_LIB_UI_SH=1

ui::hr() {
    printf '%s\n' "────────────────────────────────────────────────────────────"
}

# ui::header <title>  — blank line, coloured title, rule under it
ui::header() {
    printf '\n%s%s%s\n' "${_C_CYAN:-}" "$*" "${_C_RESET:-}"
    ui::hr
}

# ui::section <title>  — a lighter in-command subheading
ui::section() {
    printf '\n%s▸ %s%s\n' "${_C_CYAN:-}" "$*" "${_C_RESET:-}"
}

# ui::kv <key> <value...>  — aligned "key : value" line for reports
ui::kv() {
    local k="$1"; shift
    printf '  %-22s %s\n' "$k" "$*"
}

# ui::confirm <question>  — returns 0 on yes.
#   INSTALL_ASSUME_YES=1  -> always yes, no prompt
#   no TTY on stdin       -> warn and return 1 (treated as no)
ui::confirm() {
    local q="$1" ans
    if [ -n "${INSTALL_ASSUME_YES:-}" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        log::warn "no interactive terminal; assuming \"no\" for: $q"
        return 1
    fi
    read -r -p "$q [y/N] " ans || return 1
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
