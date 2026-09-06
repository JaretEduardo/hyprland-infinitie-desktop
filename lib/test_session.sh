#!/usr/bin/env bash
#
# test_session.sh — unit tests for lib/session.sh (read-only session helpers).
#
# busctl / systemctl / pgrep / Xwayland / fc-match are replaced by mocks on
# PATH; the portage vdb is a temp dir. No root, no real session. Run:
#   bash lib/test_session.sh
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
ok()    { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (want [$3] got [$2])"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sess.XXXXXX")"
BIN="$ROOT/bin"; mkdir -p "$BIN"
trap 'rm -rf "$ROOT"' EXIT

# --- mocks -------------------------------------------------------------
# busctl: MOCK_BUS_OWNED / MOCK_BUS_KNOWN are space-lists of names.
cat > "$BIN/busctl" <<'EOF'
#!/usr/bin/env bash
args=(); for a in "$@"; do case "$a" in --system|--user|--no-pager) ;; *) args+=("$a") ;; esac; done
case "${args[0]:-}" in
  status)  name="${args[1]:-}"; case " ${MOCK_BUS_OWNED:-} " in *" $name "*) exit 0 ;; *) exit 1 ;; esac ;;
  list)    printf 'NAME PID\n'; for n in ${MOCK_BUS_OWNED:-} ${MOCK_BUS_KNOWN:-}; do printf '%s 1\n' "$n"; done ;;
  get-property) printf 's "%s"\n' "${MOCK_LOGIND_VAL:-lock}" ;;
esac
EOF
# systemctl: MOCK_UNIT_ACTIVE / MOCK_UNIT_ENABLED space-lists of units.
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
scope="$1"; verb="$2"; unit="${3:-}"
case "$verb" in
  is-active)  case " ${MOCK_UNIT_ACTIVE:-} " in *" $unit "*) echo active; exit 0 ;; *) echo inactive; exit 3 ;; esac ;;
  is-enabled) case " ${MOCK_UNIT_ENABLED:-} " in *" $unit "*) echo enabled; exit 0 ;; *) echo disabled; exit 1 ;; esac ;;
esac
EOF
# pgrep: MOCK_PROCS space-list of comms.
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do want="$a"; done   # last arg is the pattern
case " ${MOCK_PROCS:-} " in *" $want "*) echo 1234; exit 0 ;; *) exit 1 ;; esac
EOF
printf '#!/usr/bin/env bash\necho "Xwayland 24.1"\n' > "$BIN/Xwayland"
cat > "$BIN/fc-match" <<'EOF'
#!/usr/bin/env bash
gen="${@: -1}"
case "$gen" in
  sans-serif) echo "${MOCK_FC_SANS:-DejaVu Sans}" ;;
  monospace)  echo "${MOCK_FC_MONO:-DejaVu Sans Mono}" ;;
  emoji)      echo "${MOCK_FC_EMOJI:-DejaVu Sans}" ;;
esac
EOF
chmod +x "$BIN"/*
export PATH="$BIN:/usr/bin:/bin"

# fake vdb
export _SESSION_VDB="$ROOT/vdb"
mkdir -p "$_SESSION_VDB/gui-wm/hyprland-0.56.2"
echo "X systemd dbus-session guiutils" > "$_SESSION_VDB/gui-wm/hyprland-0.56.2/USE"

. "$HERE/session.sh"

echo "lib/session.sh tests"

# --- session bus present / absent -----------------------------------
DBUS_SESSION_BUS_ADDRESS="unix:path=/x/bus"
session::user_bus && ok "user_bus: true with DBUS_SESSION_BUS_ADDRESS" || bad "user_bus true"
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="$ROOT/norun"
session::user_bus && bad "user_bus: false when no bus" || ok "user_bus: false when no bus"

# with no bus, --user checks return non-committal, never a false 'inactive'
check "unit_state --user without bus -> unknown" "$(session::unit_state --user pipewire.socket)" "unknown"
check "unit_enabled --user without bus -> unknown" "$(session::unit_enabled --user pipewire.socket)" "unknown"
session::dbus_owned --user org.freedesktop.portal.Desktop; check "dbus_owned without bus -> rc 2" "$?" "2"

# --- restore a fake bus for the rest -------------------------------
export DBUS_SESSION_BUS_ADDRESS="unix:path=/x/bus"

# --- units --------------------------------------------------------
export MOCK_UNIT_ENABLED="wireplumber.service"
export MOCK_UNIT_ACTIVE="wireplumber.service"
check "unit_enabled: enabled"  "$(session::unit_enabled --user wireplumber.service)" "enabled"
check "unit_enabled: disabled" "$(session::unit_enabled --user pipewire.socket)"     "disabled"
check "unit_state: active"     "$(session::unit_state --user wireplumber.service)"   "active"
check "unit_state: inactive"   "$(session::unit_state --user pipewire.socket)"       "inactive"

# --- portal available / absent ----------------------------------
export MOCK_BUS_OWNED="org.freedesktop.portal.Desktop"
export MOCK_BUS_KNOWN="org.freedesktop.impl.portal.desktop.hyprland"
session::dbus_owned --user org.freedesktop.portal.Desktop && ok "portal available: dbus_owned" || bad "portal available"
session::dbus_known --user org.freedesktop.impl.portal.desktop.hyprland && ok "hyprland portal backend: dbus_known" || bad "portal backend known"
export MOCK_BUS_OWNED="" MOCK_BUS_KNOWN=""
session::dbus_owned --user org.freedesktop.portal.Desktop && bad "portal absent: still owned?" || ok "portal absent: dbus_owned false"
session::dbus_known --user org.freedesktop.portal.Desktop && bad "portal absent: still known?" || ok "portal absent: dbus_known false"

# --- Xwayland present / absent + USE flag --------------------
check "xwayland: builtin (binary + hyprland[X])" "$(session::xwayland)" "builtin"
echo "systemd dbus-session" > "$_SESSION_VDB/gui-wm/hyprland-0.56.2/USE"   # X off
check "xwayland: binary-only (X USE off)" "$(session::xwayland)" "binary-only"
echo "X systemd dbus-session" > "$_SESSION_VDB/gui-wm/hyprland-0.56.2/USE"
check "xwayland: none (no binary on PATH)" "$(PATH=/nonexistent-xxx; session::xwayland)" "none"
session::pkg_use_has gui-wm/hyprland X;        check "pkg_use_has X -> 0" "$?" "0"
session::pkg_use_has gui-wm/hyprland nonesuch; check "pkg_use_has missing flag -> 1" "$?" "1"
session::pkg_use_has cat/nothere X;            check "pkg_use_has missing pkg -> 2" "$?" "2"

# --- process running / not running ----------------------------
export MOCK_PROCS="hypridle Xwayland"
session::proc_running hypridle && ok "proc_running: hypridle yes" || bad "proc_running hypridle"
session::proc_running mako && bad "proc_running: mako should be no" || ok "proc_running: mako no"

# --- fonts ---------------------------------------------------
export MOCK_FC_SANS="Noto Sans" MOCK_FC_EMOJI="Noto Color Emoji"
check "fc_family sans"  "$(session::fc_family sans-serif)" "Noto Sans"
check "fc_family emoji" "$(session::fc_family emoji)"      "Noto Color Emoji"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
