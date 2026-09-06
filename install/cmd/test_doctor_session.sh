#!/usr/bin/env bash
#
# test_doctor_session.sh — integration test for doctor's session-hardening
# sections (Session environment, Xwayland, Desktop portals, Audio session,
# Idle/lock, logind drop-in, Dotfile integrity).
#
# The real `./install.sh doctor` is run with busctl / systemctl / pgrep /
# Xwayland mocked on PATH and a throwaway $HOME, three times (no bus / healthy /
# broken), then the output is grepped. No root, nothing is started, no
# screenshot, no lock. ~40s. Run:  bash install/cmd/test_doctor_session.sh
#
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
has()   { grep -qF -- "$2" "$O" && ok "$1" || bad "$1"; }
hasre() { grep -qE -- "$2" "$O" && ok "$1" || bad "$1"; }
hasnt() { grep -qF -- "$2" "$O" && bad "$1" || ok "$1"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/doc.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; HOME_="$ROOT/home"; CFG="$HOME_/.config"; O="$ROOT/out"
mkdir -p "$BIN" "$CFG" "$HOME_/.local/bin" "$ROOT/run"

cat > "$BIN/busctl" <<'EOF'
#!/usr/bin/env bash
a=(); for x in "$@"; do case "$x" in --system|--user|--no-pager) ;; *) a+=("$x");; esac; done
case "${a[0]:-}" in
  status) case " ${MOCK_OWNED:-} " in *" ${a[1]:-} "*) exit 0;; *) exit 1;; esac ;;
  list) echo "NAME PID"; for n in ${MOCK_OWNED:-} ${MOCK_KNOWN:-}; do echo "$n 1"; done ;;
  get-property) echo "s \"${MOCK_POWERKEY:-lock}\"" ;;
esac
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  is-active)  case " ${MOCK_ACTIVE:-} "  in *" ${3:-} "*) echo active; exit 0;; *) echo inactive; exit 3;; esac ;;
  is-enabled) case " ${MOCK_ENABLED:-} " in *" ${3:-} "*) echo enabled; exit 0;; *) echo disabled; exit 1;; esac ;;
esac
EOF
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do p="$a"; done
case " ${MOCK_PROCS:-} " in *" $p "*) echo 1; exit 0;; *) exit 1;; esac
EOF
printf '#!/usr/bin/env bash\ntrue\n' > "$BIN/Xwayland"
chmod +x "$BIN"/*

run() {   # run <dbus-addr> [wayland-display] ; env: MOCK_*
    PATH="$BIN:/usr/bin:/bin" HOME="$HOME_" XDG_CONFIG_HOME="$CFG" \
    XDG_RUNTIME_DIR="$ROOT/run" DBUS_SESSION_BUS_ADDRESS="${1:-}" WAYLAND_DISPLAY="${2:-}" \
    INSTALL_REPO_DIR="$REPO" \
        timeout 90 bash "$REPO/install/cmd/doctor.sh" > "$O" 2>&1 || true
}

echo "doctor session-hardening tests"

# ---------- 1. plain TTY: no session bus, no Wayland display ----------
rm -f "$ROOT/run/bus"
export MOCK_OWNED="" MOCK_KNOWN="" MOCK_ENABLED="" MOCK_ACTIVE="" MOCK_PROCS="" MOCK_POWERKEY="lock"
run "" ""
has  "tty: Session environment section present"          "Session environment"
has  "tty: reports no session bus"                       "no user session bus here"
has  "tty: portal runtime check skipped, not failed"     "portal runtime state not checked (no session bus here)"
has  "tty: audio session state not falsely failed"       "session state not checked (no user bus here)"
has  "tty: hypridle runtime not checked from a TTY"      "hypridle runtime state not checked"
hasnt "tty: never falsely claims hypridle down"          "hypridle is NOT running"
grep -qF "doctor: " "$O" && ok "tty: doctor ran to the end (no hang / crash)" || bad "tty: doctor finished"

# ---------- 2. healthy session ----------
export MOCK_OWNED="org.freedesktop.portal.Desktop org.freedesktop.ScreenSaver"
export MOCK_KNOWN="org.freedesktop.impl.portal.desktop.hyprland"
export MOCK_ENABLED="pipewire.socket wireplumber.service"
export MOCK_ACTIVE="pipewire.socket wireplumber.service"
export MOCK_PROCS="hypridle Xwayland"
: > "$ROOT/run/bus"
mkdir -p "$CFG/hypr"
ln -sfn "$REPO/config/hypr/hyprland.lua" "$CFG/hypr/hyprland.lua"   # one correct link
run "unix:path=$ROOT/run/bus" "wayland-9"
has "healthy: portal frontend served"           "org.freedesktop.portal.Desktop is being served"
has "healthy: hyprland portal backend present"  "Hyprland portal backend is registered"
has "healthy: pipewire units enabled"           "pipewire.socket + wireplumber.service are enabled"
has "healthy: hypridle running"                 "hypridle is running in this session"
has "healthy: Xwayland builtin"                 "gui-wm/hyprland was built with USE=X"
has "healthy: dotfile section present"          "Dotfile integrity"

# ---------- 3. broken: portal down, units off, hypridle down, broken symlink ----------
export MOCK_OWNED="" MOCK_KNOWN="" MOCK_ENABLED="" MOCK_ACTIVE="" MOCK_PROCS=""
export MOCK_POWERKEY="poweroff"
mkdir -p "$CFG/mako"
ln -sfn /nonexistent-target "$CFG/mako/config"                     # a broken managed link
run "unix:path=$ROOT/run/bus" "wayland-9"
has "broken: portal frontend missing -> WARN"   "has no owner and is not activatable"
has "broken: hyprland backend missing -> WARN"  "the Hyprland portal backend is not registered"
has "broken: pipewire units disabled -> WARN"   "PipeWire user units are not enabled"
has "broken: prints the exact fix command"      "systemctl --user enable --now pipewire.socket"
has "broken: hypridle down -> WARN"             "hypridle is NOT running"
has "broken: logind live value read"            "live: HandlePowerKey=poweroff"
has "broken: broken dotfile symlink flagged"    "mako/config is a broken symlink"
grep -qF "doctor: " "$O" && ok "broken: doctor still ran to the end" || bad "broken: doctor finished"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
