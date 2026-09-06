#!/usr/bin/env bash
#
# test_hypr_screenshot.sh — offline tests for scripts/desktop/hypr-screenshot.
#
# grim / slurp / wl-copy / hyprctl / notify-send are replaced by mocks on PATH,
# so nothing is really captured. jq is used for real (it is a repo dependency).
# Run:  bash test_hypr_screenshot.sh
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/hypr-screenshot"

pass=0; fail=0
ok()    { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (want [$3] got [$2])"; fi; }

_mock() {  # <name> <literal-body>
    local name="$1" body="$2"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s" %q >> "$MOCKLOG"; for a in "$@"; do printf " <%%s>" "$a" >> "$MOCKLOG"; done; printf "\\n" >> "$MOCKLOG"\n' "$name"
        printf '%s\n' "$body"
    } > "$BIN/$name"
    chmod +x "$BIN/$name"
}

setup() {
    ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hss.XXXXXX")"
    HOME_DIR="$ROOT/home dir"                     # deliberate space in $HOME
    BIN="$ROOT/bin"
    mkdir -p "$HOME_DIR" "$BIN"
    export MOCKLOG="$ROOT/calls.log"; : > "$MOCKLOG"

    _mock grim        'printf PNGDATA > "${@: -1}"; exit 0'
    _mock slurp       'printf "10,20 300x400\n"; exit 0'
    _mock wl-copy     'cat >/dev/null; exit 0'
    _mock hyprctl     'printf "%s" "${HCJSON:-[]}"'
    _mock notify-send 'exit 0'

    export HOME="$HOME_DIR"
    export PATH="$BIN:/usr/bin:/bin"
    unset XDG_PICTURES_DIR
    export HCJSON='[{"name":"DP-1","focused":false},{"name":"eDP-1","focused":true}]'
}
teardown() { rm -rf "$ROOT"; }
last_shot() { ls "$HOME_DIR/Pictures/Screenshots/"Screenshot_*.png 2>/dev/null | head -n1; }
in_log()   { grep -qF "$1" "$MOCKLOG"; }

echo "hypr-screenshot tests"

# 1. usage
setup
"$SUT" >/dev/null 2>&1;            check "no args -> exit 2"    "$?" 2
"$SUT" full extra >/dev/null 2>&1; check "two modes -> exit 2"  "$?" 2
"$SUT" --copy >/dev/null 2>&1;     check "flag only -> exit 2"  "$?" 2
teardown

# 2. full: makes the dir under a spaced $HOME, writes a timestamped PNG
setup
out="$("$SUT" full)"; rc=$?
check "full -> exit 0" "$rc" 0
f="$(last_shot)"
{ [ -n "$f" ] && [ -s "$f" ]; } && ok "full -> non-empty PNG exists" || bad "full -> screenshot file"
check "full -> prints the path" "$out" "$f"
case "$f" in "$HOME_DIR/Pictures/Screenshots/Screenshot_"*.png) ok "full -> path shape (spaces ok)" ;; *) bad "full -> path shape: $f" ;; esac
in_log "grim <-o> <eDP-1>" && ok "full -> grim -o <focused output>" || bad "full -> grim focused-output"
in_log "wl-copy" && bad "full -> must NOT touch the clipboard" || ok "full -> clipboard untouched"
teardown

# 3. full --copy: also copies the image
setup
"$SUT" full --copy >/dev/null; check "full --copy -> exit 0" "$?" 0
in_log "wl-copy <--type> <image/png>" && ok "full --copy -> wl-copy --type image/png" || bad "full --copy -> wl-copy call"
teardown

# 4. region: slurp geometry -> grim -g -> file + clipboard
setup
"$SUT" region >/dev/null; check "region -> exit 0" "$?" 0
[ -s "$(last_shot)" ] && ok "region -> file written" || bad "region -> file"
in_log "grim <-g> <10,20 300x400>" && ok "region -> grim -g <geometry>" || bad "region -> grim -g"
in_log "wl-copy <--type> <image/png>" && ok "region -> copies image to clipboard" || bad "region -> wl-copy"
teardown

# 5. region cancelled (slurp exits non-zero) -> quiet success, no file, no grim
setup
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/slurp"
err="$("$SUT" region 2>&1)"; rc=$?
check "region cancel -> exit 0" "$rc" 0
[ -z "$err" ] && ok "region cancel -> no stderr noise" || bad "region cancel -> stderr: $err"
[ -z "$(last_shot)" ] && ok "region cancel -> no file" || bad "region cancel -> leftover file"
in_log "grim" && bad "region cancel -> grim must not run" || ok "region cancel -> grim not run"
teardown

# 6. region: slurp exits 0 but prints nothing -> still a cancel
setup
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/slurp"
"$SUT" region >/dev/null; check "region empty-geom -> exit 0" "$?" 0
[ -z "$(last_shot)" ] && ok "region empty-geom -> no file" || bad "region empty-geom -> leftover file"
teardown

# 7. grim missing -> exit 1 with an explanation
setup
rm "$BIN/grim"
err="$("$SUT" full 2>&1)"; check "grim missing -> exit 1" "$?" 1
case "$err" in *grim*) ok "grim missing -> names the tool" ;; *) bad "grim missing -> message: $err" ;; esac
teardown

# 8. grim fails -> exit 1
setup
printf '#!/usr/bin/env bash\nexit 3\n' > "$BIN/grim"
"$SUT" full >/dev/null 2>&1; check "grim fails -> exit 1" "$?" 1
teardown

# 9. no wl-copy on a copy path -> file still saved, soft warning, exit 0
setup
rm "$BIN/wl-copy"
err="$("$SUT" full --copy 2>&1)"; check "no wl-copy -> exit 0" "$?" 0
[ -s "$(last_shot)" ] && ok "no wl-copy -> file still saved" || bad "no wl-copy -> file"
case "$err" in *wl-copy*) ok "no wl-copy -> warns" ;; *) bad "no wl-copy -> warning" ;; esac
teardown

# 10. full: whole-screen grim when no output can be named (no focused monitor)
setup
export HCJSON='[{"name":"DP-1","focused":false}]'
"$SUT" full >/dev/null; check "no focused output -> exit 0" "$?" 0
in_log "grim <$HOME_DIR/Pictures/Screenshots/Screenshot_" && ok "fallback -> plain grim <file>" || bad "fallback -> plain grim"
in_log "grim <-o>" && bad "fallback -> must not pass -o" || ok "fallback -> no -o"
teardown

# 11. XDG_PICTURES_DIR honoured (also spaced)
setup
export XDG_PICTURES_DIR="$ROOT/my pics"
out="$("$SUT" full)"
case "$out" in "$ROOT/my pics/Screenshots/"*) ok "XDG_PICTURES_DIR honoured" ;; *) bad "XDG_PICTURES_DIR: $out" ;; esac
teardown

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
