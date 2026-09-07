#!/usr/bin/env bash
#
# test_wallpaper_transition.sh — regression test for the wallpaper transition
# state machine (config/quickshell/Wallpaper.qml + hypr-wallpaper).
#
# Needs a live Wayland session with Quickshell running (it drives the REAL
# `qs` via `qs ipc call wallpaper status` and watches `wallpaper.state` /
# mpvpaper). Skips cleanly with exit 0 when that is not available, so it is
# safe to run from CI.
#
# Covers, in particular:
#   * BUG: switching BACK to a previously-loaded static wallpaper
#     (A -> B -> A -> B -> A) must never get stuck — the two Image buffers
#     track their own paths and re-assigning the same source does not stall
#     the machine.
#   * static <-> animated <-> animated: the diagonal wipe runs for every
#     combination and there is always exactly 0 or 1 mpvpaper.
#   * rapid switching: the newest request wins; no orphan mpvpaper; the final
#     wallpaper.state matches the last request.
#
# No root. No network.
set -u

REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/hyprland-infinitie-desktop/wallpaper.state"

PASS=0 FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; exit 0; }

command -v hypr-wallpaper >/dev/null 2>&1 || skip "hypr-wallpaper not on PATH"
command -v qs >/dev/null 2>&1 || skip "qs not installed"
[ -n "${WAYLAND_DISPLAY:-}" ] || skip "no Wayland session"
pgrep -x qs >/dev/null 2>&1 || skip "Quickshell not running"
qs ipc call wallpaper status >/dev/null 2>&1 || skip "wallpaper IPC unavailable (old Wallpaper.qml?)"

WPDIR="$(hypr-wallpaper --status 2>/dev/null | sed -n 's/^wallpaper_dir=//p')"
[ -n "$WPDIR" ] && [ -d "$WPDIR" ] || skip "no wallpaper dir"

# need two static images + two clips
mapfile -t IMGS < <(find -L "$WPDIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | sort | head -2)
mapfile -t VIDS < <(find -L "$WPDIR" -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.gif' \) 2>/dev/null | sort | head -2)
[ "${#IMGS[@]}" -ge 2 ] || skip "need >=2 static wallpapers in $WPDIR"
A="${IMGS[0]}"; B="${IMGS[1]}"

mpvn() { pgrep -x mpvpaper | wc -l; }
mpv()  { pgrep -x mpvpaper | tr '\n' ' '; }
# poll `status` until it reports not-busy on <substr>
settle() { # <substr> <timeout-s>
    local want="$1" to="${2:-10}" i=0 s
    while [ "$i" -lt $((to*5)) ]; do
        s="$(qs ipc call wallpaper status 2>/dev/null)"
        case "$s" in *"$want"*"|-") return 0 ;; esac
        sleep 0.2; i=$((i+1))
    done
    echo "      (timeout; status=$(qs ipc call wallpaper status 2>/dev/null))"
    return 1
}
statekv() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n1; }

START="$(qs ipc call wallpaper status 2>/dev/null)"   # to restore at the end

echo "A -> B -> A -> B -> A  (must never get stuck)"
hypr-wallpaper "$A" >/dev/null 2>&1; settle "$(basename "$A")" 10 || bad "settle on A"
for step in "$B" "$A" "$B" "$A"; do
    hypr-wallpaper "$step" >/dev/null 2>&1
    if settle "$(basename "$step")" 10; then ok "reached $(basename "$step")"
    else bad "STUCK before $(basename "$step")"; fi
done
[ "$(mpvn)" -eq 0 ] && ok "no mpvpaper after static run" || bad "mpvpaper leaked: $(mpv)"

if [ "${#VIDS[@]}" -ge 2 ]; then
    V1="${VIDS[0]}"; V2="${VIDS[1]}"

    echo "static -> animated"
    hypr-wallpaper "$A" >/dev/null 2>&1; settle "$(basename "$A")" 10
    hypr-wallpaper "$V1" >/dev/null 2>&1; sleep 5
    grep -q '^type=animated' "$STATE" && ok "state animated" || bad "state not animated"
    [ "$(mpvn)" -eq 1 ] && ok "exactly 1 mpvpaper" || bad "mpvpaper count = $(mpvn)"

    echo "animated -> static"
    hypr-wallpaper "$A" >/dev/null 2>&1
    settle "$(basename "$A")" 10 && ok "settled back on static" || bad "did not settle"
    sleep 3
    [ "$(mpvn)" -eq 0 ] && ok "0 mpvpaper after -> static" || bad "mpvpaper leaked: $(mpv)"

    echo "animated -> animated"
    hypr-wallpaper "$V1" >/dev/null 2>&1; sleep 5
    hypr-wallpaper "$V2" >/dev/null 2>&1; sleep 6
    [ "$(statekv path)" = "$V2" ] && ok "state = video2" || bad "state path = $(statekv path)"
    [ "$(mpvn)" -eq 1 ] && ok "exactly 1 mpvpaper" || bad "mpvpaper count = $(mpvn) ($(mpv))"

    echo "rapid: A B V1 B A V2 (~60ms apart) — newest wins, no orphans"
    hypr-wallpaper "$A" >/dev/null 2>&1; settle "$(basename "$A")" 8
    for w in "$B" "$V1" "$B" "$A" "$V2"; do hypr-wallpaper "$w" >/dev/null 2>&1 & sleep 0.06; done
    wait; sleep 10
    [ "$(statekv path)" = "$V2" ] && ok "final state = last request" || bad "final path = $(statekv path)"
    if grep -q '^type=animated' "$STATE"; then
        [ "$(mpvn)" -eq 1 ] && ok "exactly 1 mpvpaper" || bad "mpvpaper count = $(mpvn)"
    else
        [ "$(mpvn)" -eq 0 ] && ok "0 mpvpaper" || bad "mpvpaper count = $(mpvn)"
    fi

    hypr-wallpaper --reset >/dev/null 2>&1
    for i in $(seq 1 20); do [ "$(mpvn)" -eq 0 ] && break; sleep 0.4; done
    [ "$(mpvn)" -eq 0 ] && ok "reset -> 0 mpvpaper" || bad "reset left mpvpaper: $(mpv)"
else
    skip_note="only $((${#VIDS[@]})) clip(s) in $WPDIR — animated cases skipped"
    printf '  \033[33mskip\033[0m %s\n' "$skip_note"
fi

# restore the wallpaper that was active before the test
case "$START" in
    /*) hypr-wallpaper "${START%%|*}" >/dev/null 2>&1 || true ;;
esac

echo
echo "pass $PASS  fail $FAIL"
[ "$FAIL" -eq 0 ]
