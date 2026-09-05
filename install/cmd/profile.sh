#!/usr/bin/env bash
#
# install.sh profile — detect which machine profile applies (read-only).
#
# Reuses lib/hardware.sh for every hardware fact and lib/profile.sh for
# profile matching/validation; this script only formats what those already
# produce. Matching is DMI-only (/sys/class/dmi/id/*), never the hostname.
#
# There is no --apply: which profile applies is a detected fact, not
# something to write. A missing/unmatched machine falls back to "common"
# with a warning, never a fatal error. A hardware-expectation mismatch is
# always a warning too — real hardware legitimately varies.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"
# shellcheck source=lib/profile.sh
. "$REPO_DIR/lib/profile.sh"

JSON=0
for a in "$@"; do
    case "$a" in
        --json)    JSON=1 ;;
        --dry-run) : ;;   # already read-only; nothing to skip
        -*) log::error "profile: unknown option: $a"; exit 2 ;;
        *)  log::error "profile: unexpected argument: $a"; exit 2 ;;
    esac
done

# _v <key> <block>  -> value of a "key=value" line
_v() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' <<<"${2:-}"; }

mvend="$(hw::machine_vendor)"
mprod="$(hw::machine_model)"
pid="$(profile::detect)"
pname="$(profile::get name "$pid")"
vblock="$(profile::validate "$pid")"

if [ "$JSON" = 1 ]; then
    n_ok=0 n_warn=0
    for i in $(awk -F. '/^validate\.[0-9]+\.status=/{print $2}' <<<"$vblock" | sort -nu); do
        case "$(_v "validate.$i.status" "$vblock")" in
            ok)   n_ok=$((n_ok + 1)) ;;
            warn) n_warn=$((n_warn + 1)) ;;
        esac
    done
    printf '{"vendor":"%s","product":"%s","profile":"%s","name":"%s","fallback":%s,"validate_ok":%d,"validate_warn":%d}\n' \
        "$mvend" "$mprod" "$pid" "$pname" \
        "$([ "$pid" = common ] && echo true || echo false)" "$n_ok" "$n_warn"
    exit 0
fi

ui::header "Machine profile"
ui::kv "Detected vendor"  "${mvend:-unknown}"
ui::kv "Detected product" "${mprod:-unknown}"
if [ "$pid" = common ]; then
    log::warn "no machine-specific profile matched — falling back to 'common'"
else
    log::ok "profile match: $pid"
fi
ui::kv "Profile" "$pid  (${pname:-$pid})"

if [ "$pid" != common ]; then
    printf '\n'
    ui::section "Hardware expectations ($pid)"
    idx=$(awk -F. '/^validate\.[0-9]+\.item=/{print $2}' <<<"$vblock" | sort -nu)
    if [ -z "$idx" ]; then
        log::info "this profile declares no hardware expectations to check"
    else
        for i in $idx; do
            item=$(_v "validate.$i.item" "$vblock")
            st=$(_v "validate.$i.status" "$vblock")
            det=$(_v "validate.$i.detail" "$vblock")
            if [ "$st" = ok ]; then
                printf '  %s[OK]%s    %s\n' "${_C_GREEN:-}" "${_C_RESET:-}" "$item"
            else
                printf '  %s[WARN]%s  %s%s\n' "${_C_YELLOW:-}" "${_C_RESET:-}" "$item" "${det:+  ($det)}"
            fi
        done
    fi

    nblock=$(profile::block "$pid")
    notes=$(awk -F= '/^note\./{print substr($0, index($0,"=")+1)}' <<<"$nblock")
    if [ -n "$notes" ]; then
        printf '\n'
        ui::section "Notes (informational only — never applied automatically)"
        while IFS= read -r n; do
            [ -n "$n" ] && printf '  - %s\n' "$n"
        done <<<"$notes"
    fi
fi

printf '\n'
log::ok "profile: read-only — nothing was changed"
