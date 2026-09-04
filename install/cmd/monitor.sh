#!/usr/bin/env bash
#
# install.sh monitor — detect the REAL connected monitors from a live
# Hyprland session and generate ~/.config/hypr/monitors.local.lua.
#
#   install.sh monitor            detect + show the plan (read-only)
#   install.sh monitor --apply    detect + show + confirm + write
#   install.sh monitor --dry-run  like the default (never writes)
#
# Needs a live Hyprland session to run at all — plan mode is not an exception
# to that, because there is nothing real to plan without one. No output name,
# resolution or refresh rate is ever guessed; every value below comes from
# `hyprctl -j monitors all` (the compositor's own live state). For which
# resolution is genuinely "native", this prefers a real EDID preferred/native
# timing via the optional `edid-decode` tool (never required — if it is not
# installed, or its output does not explicitly say "preferred"/"native", we
# do not guess), and otherwise clearly labels the fallback: the highest
# resolution Hyprland itself reports. The DRM sysfs "modes" file's line order
# is NOT used for this — it carries no DRM_MODE_TYPE_PREFERRED flag, so its
# first line is not a reliable stand-in for the real preferred timing.
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
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DEST="$CONFIG_HOME/hypr/monitors.local.lua"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "monitor: unknown option: $a"; exit 2 ;;
        *)  log::error "monitor: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

command -v jq >/dev/null 2>&1 || { log::error "jq is required (install.sh deps: app-misc/jq)"; exit 1; }

# ---- get the compositor's real, live monitor state -------------------
# TESTING ONLY: read JSON from a file instead of invoking hyprctl, so this
# stage's logic (parsing, mode selection, Lua generation) can be exercised
# from a machine with no Hyprland session. Never set this outside tests —
# real runs always come from the live `hyprctl -j monitors all`.
RAW_JSON=""
if [ -n "${MONITOR_HYPRCTL_JSON_FILE:-}" ]; then
    if [ ! -r "${MONITOR_HYPRCTL_JSON_FILE}" ]; then
        log::error "MONITOR_HYPRCTL_JSON_FILE set but not readable: $MONITOR_HYPRCTL_JSON_FILE"
        exit 1
    fi
    RAW_JSON="$(cat "$MONITOR_HYPRCTL_JSON_FILE")"
    log::warn "TESTING: reading monitor JSON from \$MONITOR_HYPRCTL_JSON_FILE, not hyprctl"
else
    if ! command -v hyprctl >/dev/null 2>&1; then
        log::error "hyprctl not found — this needs a live Hyprland session."
        log::error "Nothing was detected and nothing was written. Run this on the Gentoo target,"
        log::error "inside Hyprland."
        exit 1
    fi
    if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        log::warn "HYPRLAND_INSTANCE_SIGNATURE is not set — hyprctl likely cannot reach a compositor."
    fi
    if ! RAW_JSON="$(hyprctl -j monitors all 2>/dev/null)" || [ -z "$RAW_JSON" ]; then
        log::error "'hyprctl -j monitors all' failed or returned nothing — no active Hyprland session"
        log::error "reachable from here. Nothing was detected and nothing was written."
        exit 1
    fi
fi

if ! printf '%s' "$RAW_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log::error "hyprctl did not return a JSON array of monitors — cannot proceed safely."
    exit 1
fi

N_TOTAL=$(printf '%s' "$RAW_JSON" | jq 'length')
if [ "$N_TOTAL" = 0 ]; then
    log::error "Hyprland reports zero monitors. Nothing to do."
    exit 1
fi

# ---- real EDID preferred/native timing, optional and best-effort --------
# The DRM sysfs "modes" file (lib/hardware.sh's hw::drm_connectors) has NO
# guaranteed order: it prints connector->modes as text with no
# DRM_MODE_TYPE_PREFERRED flag exposed per line, so "first line" is NOT a
# reliable stand-in for the real EDID-preferred timing and is deliberately
# not used here for that purpose (it was in an earlier version of this
# file — that was wrong; see the stage's correction). What IS a real,
# spec-guaranteed source is the EDID itself, parsed with `edid-decode`
# (optional — never a required dependency of this repo, only used if it's
# already on PATH) reading each connector's own
# /sys/class/drm/<card>-<name>/edid. Trusted ONLY when edid-decode's own
# output explicitly calls a timing "preferred" or "native" — never assumed
# from position (e.g. "the first detailed timing") on our own authority.
declare -A CONNECTOR_CARD
while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    CONNECTOR_CARD["$k"]="$v"
done < <(hw::drm_connectors | awk -F= '
    $1 ~ /\.connector$/ { idx=$1; sub(/\.connector$/,"",idx); name[idx]=$2 }
    $1 ~ /\.card$/      { idx=$1; sub(/\.card$/,"",idx);      card[idx]=$2 }
    END { for (i in name) if (card[i] != "") print name[i] "=" card[i] }
')

# _edid_preferred_res <connector name> : "WxH" from a real EDID
# preferred/native timing via edid-decode, or empty (never guessed). Every
# grep below ends its pipeline with `|| true`: under this script's
# `set -eo pipefail`, a grep finding no match exits 1, and an unguarded
# `var=$(pipeline)` with that status would abort the whole script — this
# function must instead fail soft, into the fallback below.
_edid_preferred_res() {
    local name="$1" card="${CONNECTOR_CARD[$1]:-}" edid_path out dtd_num res
    [ -n "$card" ] || return 0
    command -v edid-decode >/dev/null 2>&1 || return 0
    edid_path="/sys/class/drm/$card-$name/edid"
    [ -r "$edid_path" ] || return 0
    out="$(edid-decode "$edid_path" 2>/dev/null)" || true
    [ -n "$out" ] || return 0

    # Real edid-decode output typically names the resolution on a
    # "DTD <N>: <W>x<H> ..." line and separately marks which DTD is
    # preferred/native (e.g. "Preferred/native timing: DTD 1") — the
    # resolution and the word "preferred"/"native" are usually NOT on the
    # same line, so resolve the DTD number first, then that DTD's own line.
    dtd_num=$(printf '%s\n' "$out" | grep -iE 'preferred|native' | grep -ioE 'dtd[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -n1) || true
    res=""
    if [ -n "$dtd_num" ]; then
        res=$(printf '%s\n' "$out" | grep -iE "dtd[[:space:]]+${dtd_num}[^0-9]" | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -n1) || true
    fi
    # Some edid-decode versions instead put the resolution and the word
    # "preferred"/"native" on the same line — try that too before giving up.
    if [ -z "$res" ]; then
        res=$(printf '%s\n' "$out" | grep -iE 'preferred|native' | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -n1) || true
    fi
    if [ -n "$res" ]; then
        printf '%s' "$res"
    fi
    return 0
}
command -v edid-decode >/dev/null 2>&1 \
    && log::info "edid-decode found — used as an optional, best-effort source of the real EDID preferred/native timing" \
    || log::info "edid-decode not found (optional, not required) — using the highest-resolution fallback for every monitor"

# ---- per-monitor: pick native-res + max-refresh-at-that-res -------------
# jq emits one TSV line per monitor: name \t description \t curW \t curH \t
# curHz \t disabled \t availableModes(comma-joined "WxH@Hz")
PLAN_FILE="$(mktemp)"
trap 'rm -f "$PLAN_FILE"' EXIT

N_ENABLED=0; N_DISABLED=0
INTERNAL_CANDIDATES=()
declare -A CHOSEN_MODE CHOSEN_METHOD MON_DESC MON_ALL_MODES MON_CUR

while IFS=$'\t' read -r name desc curw curh curhz disabled modes; do
    [ -n "$name" ] || continue
    if [ "$disabled" = "true" ]; then
        N_DISABLED=$((N_DISABLED + 1))
        log::info "seen but disabled, skipping: $name ($desc) — re-run after enabling it if that's wrong"
        continue
    fi
    N_ENABLED=$((N_ENABLED + 1))
    MON_DESC["$name"]="$desc"
    MON_CUR["$name"]="${curw}x${curh}@${curhz}"
    MON_ALL_MODES["$name"]="$modes"

    case "$name" in eDP*) INTERNAL_CANDIDATES+=("$name") ;; esac

    # target resolution: a real EDID preferred/native timing (edid-decode,
    # optional, only trusted when it says so itself — see above) if we have
    # one AND Hyprland actually offers that exact resolution too; otherwise
    # a clearly-labeled fallback: the highest resolution Hyprland itself
    # reports in availableModes. Either way, refresh is chosen separately,
    # below, as the max available at whichever resolution this picks.
    target_res=""
    method=""
    edid_res="$(_edid_preferred_res "$name")"
    if [ -n "$edid_res" ] && printf '%s' "$modes" | grep -qF "${edid_res}@"; then
        target_res="$edid_res"
        method="EDID preferred/native timing (edid-decode)"
    else
        target_res=$(printf '%s' "$modes" | tr ',' '\n' | awk -F'[x@]' '
            { w=$1+0; h=$2+0; a=w*h; if (a>best) { best=a; res=w"x"h } }
            END { print res }')
        method="fallback: highest resolution Hyprland reports (real EDID-preferred not determined)"
    fi
    [ -n "$target_res" ] || { target_res="${curw}x${curh}"; method="fallback: current mode (no availableModes reported)"; }

    best_hz=$(printf '%s' "$modes" | tr ',' '\n' | awk -F'[x@]' -v res="$target_res" '
        { w=$1+0; h=$2+0; if ((w"x"h) == res) { hz=$3+0; if (hz>bestHz) bestHz=hz } }
        END { if (bestHz>0) print bestHz }')
    [ -n "$best_hz" ] || best_hz="$curhz"

    # trim a whole-number refresh to a bare integer (165.00 -> 165), matching
    # the wiki's own mode-field examples (e.g. "1920x1080@144")
    best_hz_fmt=$(awk -v hz="$best_hz" 'BEGIN{ printf (hz == int(hz)) ? "%d" : "%.2f", hz }')

    CHOSEN_MODE["$name"]="${target_res}@${best_hz_fmt}"
    CHOSEN_METHOD["$name"]="$method"
done < <(printf '%s' "$RAW_JSON" | jq -r '
    .[] | [
        .name,
        (.description // ""),
        (.width // 0), (.height // 0), (.refreshRate // 0),
        (.disabled // false),
        ((.availableModes // []) | join(","))
    ] | @tsv
')

if [ "$N_ENABLED" = 0 ]; then
    log::error "every monitor Hyprland reports is disabled — nothing to configure."
    exit 1
fi

# ---- identify the internal panel ---------------------------------------
INTERNAL=""
case "${#INTERNAL_CANDIDATES[@]}" in
    1) INTERNAL="${INTERNAL_CANDIDATES[0]}" ;;
    0)
        log::warn "no output name starting with 'eDP' — no obvious internal panel."
        log::warn "every connected output will be treated the same (no internal/external distinction)."
        ;;
    *)
        log::warn "ambiguous: more than one eDP-* output (${INTERNAL_CANDIDATES[*]})."
        if [ "$APPLY" = 1 ] && [ -t 0 ]; then
            printf 'Which one is the physical internal panel? '
            read -r INTERNAL
            case " ${INTERNAL_CANDIDATES[*]} " in *" $INTERNAL "*) ;; *) log::warn "not one of the candidates — treating none as internal"; INTERNAL="" ;; esac
        else
            log::warn "plan mode / no terminal: not guessing. Re-run --apply interactively to choose."
        fi
        ;;
esac

# ---- show the plan, before writing anything -----------------------------
ui::header "Monitor detection"
ui::kv "Hyprland monitors seen" "$N_TOTAL   ($N_ENABLED enabled, $N_DISABLED disabled)"
[ -n "$INTERNAL" ] && ui::kv "internal panel (heuristic)" "$INTERNAL" || ui::kv "internal panel" "not determined"

for name in "${!CHOSEN_MODE[@]}"; do
    printf '\n%s%s%s%s\n' "${_C_CYAN:-}" "$name" "${_C_RESET:-}" "$([ "$name" = "$INTERNAL" ] && echo '  (internal)' || echo '  (external)')"
    [ -n "${MON_DESC[$name]:-}" ] && printf '  description: %s\n' "${MON_DESC[$name]}"
    printf '  current:     %s\n' "${MON_CUR[$name]}"
    printf '  all modes:   %s\n' "$(printf '%s' "${MON_ALL_MODES[$name]}" | tr ',' ' ')"
    printf '  chosen mode: %s   (%s)\n' "${CHOSEN_MODE[$name]}" "${CHOSEN_METHOD[$name]}"
    printf '  position:    auto   scale: auto\n'
done
printf '\n'

# ---- generate the Lua content -------------------------------------------
{
    printf -- '-- monitors.local.lua — MACHINE-LOCAL, GENERATED. Not tracked by git.\n'
    printf -- '-- Written by `install.sh monitor` from this machine'"'"'s real, live Hyprland\n'
    printf -- '-- monitor state (hyprctl -j monitors) on %s.\n' "$(date -Iseconds 2>/dev/null || date)"
    printf -- '-- Re-run `install.sh monitor --apply` after changing monitors; do not hand-edit\n'
    printf -- '-- unless you also stop running that command, since it will overwrite this file\n'
    printf -- '-- (with confirmation + backup) the next time it runs.\n'
    printf -- '--\n'
    printf -- '-- lua/monitors.lua'"'"'s generic fallback rule (mode=preferred for every output)\n'
    printf -- '-- still applies to any monitor NOT listed below — this file only pins the\n'
    printf -- '-- ones detected here to their real best mode.\n\n'
    for name in "${!CHOSEN_MODE[@]}"; do
        printf 'hl.monitor({\n'
        printf '    output   = "%s",\n' "$name"
        printf '    mode     = "%s",\n' "${CHOSEN_MODE[$name]}"
        printf '    position = "auto",\n'
        printf '    scale    = "auto",\n'
        printf '})\n\n'
    done
} > "$PLAN_FILE"

# ---- compare against the existing file, then detect -> explain -> confirm -> apply
ui::section "~/.config/hypr/monitors.local.lua"
if [ -f "$DEST" ] && cmp -s "$PLAN_FILE" "$DEST"; then
    log::ok "already up to date — no change"
    exit 0
fi

if [ -f "$DEST" ]; then
    log::info "existing file differs. Diff (current -> proposed):"
    diff -u "$DEST" "$PLAN_FILE" 2>/dev/null | sed 's/^/  /' || true
else
    log::info "no existing file. Proposed content:"
    sed 's/^/  /' "$PLAN_FILE"
fi

if [ "$APPLY" != 1 ]; then
    log::info "plan only — re-run with --apply to write $DEST"
    exit 0
fi

if [ -n "$DRY" ]; then
    log::info "dry-run: would write $DEST"
    exit 0
fi

ui::confirm "Write $DEST ?" || { log::warn "left as-is"; exit 0; }

if [ -f "$DEST" ]; then
    backup::save "$DEST" >/dev/null
fi
mkdir -p "$(dirname "$DEST")"
cp "$PLAN_FILE" "$DEST"
log::ok "wrote $DEST"
