#!/usr/bin/env bash
#
# install.sh input — give the Infinite Desktop evdev daemon session-scoped
# access to your keyboard and pointer (mouse or touchpad) event devices, via a
# udev `uaccess` rule.
#
#   install.sh input              detect + explain + show the proposed rule (read-only)
#   install.sh input --apply      apply it, after confirmation, with a backup of
#                                  anything replaced
#   install.sh input --dry-run    like the default (never writes)
#
# WHY this and not the `input` group: `TAG+="uaccess"` makes systemd-logind grant
# a POSIX ACL (user:<you>:rw) on the matched nodes ONLY to the user owning the
# currently ACTIVE local session on this seat, and drop it when that session is
# no longer active or ends. It is not account-wide and never applies to SSH.
# See config/udev/72-hypr-infinite-input.rules and docs/INFINITE-DESKTOP.md.
#
# RISK (documented, not hidden): a `uaccess` ACL on keyboard nodes means any
# process in your active graphical session can read all keystrokes while that
# session is active. That is inherent to evdev; `uaccess` only bounds it to the
# active local session. The stricter broker design is noted in the docs.
#
# ROOT POLICY — identical in spirit to `install.sh gpu` / `install.sh power`:
# detect, explain, show the exact file, ask, and only write after an explicit
# yes. This command NEVER runs sudo/udevadm/usermod. When --apply would write to
# the real /etc as a non-root user it does NOT attempt a doomed write — it prints
# the exact privileged commands for you to run and exits.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"

TPL="$REPO_DIR/config/udev/72-hypr-infinite-input.rules"
RULE_NAME="72-hypr-infinite-input.rules"

# INPUT_SYSROOT redirects the file this command WRITES, for testing the whole
# flow against a simulated /etc. Detection of the LIVE device state always reads
# the real system (there is no simulating /dev/input here).
SYSROOT="${INPUT_SYSROOT:-}"
DEST_D="$SYSROOT/etc/udev/rules.d"
DEST="$DEST_D/$RULE_NAME"

APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "input: unknown option: $a"; exit 2 ;;
        *)  log::error "input: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

CHANGES=0

# _ours <file> : 0 if it carries our managed-by marker
_ours() { [ -r "$1" ] && head -n1 "$1" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop'; }

# _writing_to_real_etc_as_non_root : true when --apply would need privilege we
# do not have. Mirrors the realpath-based check desktop.sh/full.sh use so that
# INPUT_SYSROOT pointing anywhere other than the real /etc is honoured (and a
# SYSROOT that canonicalises back to /etc is NOT treated as a sandbox).
_writing_to_real_etc_as_non_root() {
    [ "$(id -u)" != 0 ] || return 1
    local real_etc dest_etc
    real_etc="$(realpath -m /etc 2>/dev/null || printf '/etc')"
    dest_etc="$(realpath -m "$SYSROOT/etc" 2>/dev/null || printf '%s' "$SYSROOT/etc")"
    [ "$dest_etc" = "$real_etc" ]
}

# ---- live device inventory (read-only) ----------------------------------
# Every /dev/input/event* the daemon's own capability test would classify as a
# keyboard, a REL mouse or an ABS touchpad, with whether this user can read it
# right now and whether it already carries a user ACL. The daemon needs a
# keyboard AND at least one pointer — a mouse OR a touchpad, not necessarily
# both.
_dev_prop() { udevadm info -q property -n "$1" 2>/dev/null | awk -F= -v k="$2" '$1==k{print $2; exit}'; }
_has_user_acl() {
    command -v getfacl >/dev/null 2>&1 || return 1
    getfacl -p "$1" 2>/dev/null | grep -Eq "^user:$(id -un):.*r"
}

report_devices() {
    ui::section "Input devices this user can reach right now"
    local any_kbd=0 any_ptr=0 any_tp=0 kbd_ok=0 mouse_ok=0 tp_ok=0 d kind readable acl
    shopt -s nullglob
    for d in /dev/input/event*; do
        kind=""
        [ "$(_dev_prop "$d" ID_INPUT_KEYBOARD)" = 1 ] && kind="keyboard"
        [ "$(_dev_prop "$d" ID_INPUT_MOUSE)" = 1 ]    && kind="${kind:+$kind+}mouse"
        [ "$(_dev_prop "$d" ID_INPUT_TOUCHPAD)" = 1 ] && kind="${kind:+$kind+}touchpad"
        [ -n "$kind" ] || continue
        case "$kind" in *keyboard*) any_kbd=1 ;; esac
        case "$kind" in *mouse*|*touchpad*) any_ptr=1 ;; esac
        case "$kind" in *touchpad*) any_tp=1 ;; esac
        readable=no;  [ -r "$d" ] && readable=yes
        acl=no;       _has_user_acl "$d" && acl=yes
        if [ "$readable" = yes ]; then
            case "$kind" in *keyboard*) kbd_ok=1 ;; esac
            case "$kind" in *mouse*)    mouse_ok=1 ;; esac
            case "$kind" in *touchpad*) tp_ok=1 ;; esac
        fi
        ui::kv "$(basename "$d")  ($kind)" "readable=$readable  user-acl=$acl  $(cat "/sys/class/input/$(basename "$d")/device/name" 2>/dev/null)"
    done
    shopt -u nullglob

    printf '\n'
    if [ "$any_kbd" = 0 ] || [ "$any_ptr" = 0 ]; then
        log::warn "did not see both a keyboard and a pointer (mouse/touchpad) among /dev/input/event* — unusual; check hardware"
    fi
    if [ "$any_tp" = 1 ] && [ "$tp_ok" = 0 ]; then
        log::info "a touchpad is present but not readable yet — the rule below grants it via ID_INPUT_TOUCHPAD"
    fi
    local ptr_ok=0 via=""
    [ "$mouse_ok" = 1 ] && via="mouse"
    [ "$tp_ok" = 1 ] && via="${via:+$via + }touchpad"
    { [ "$mouse_ok" = 1 ] || [ "$tp_ok" = 1 ]; } && ptr_ok=1
    if [ "$kbd_ok" = 1 ] && [ "$ptr_ok" = 1 ]; then
        log::ok "a keyboard AND a usable pointer ($via) are readable now — the daemon can run"
        DAEMON_CAN_RUN=1
    else
        local miss=""
        [ "$kbd_ok" = 0 ] && miss="a keyboard"
        [ "$ptr_ok" = 0 ] && miss="${miss:+$miss and }a pointer (mouse or touchpad)"
        log::warn "the daemon canNOT read $miss yet"
        DAEMON_CAN_RUN=0
    fi
}

report_rule() {
    ui::section "udev rule  ->  /etc/udev/rules.d/$RULE_NAME"
    if [ -f "$DEST" ] && cmp -s "$TPL" "$DEST"; then
        ui::kv "$RULE_NAME" "already installed (matches the repo copy)"
        RULE_STATE=applied
    elif [ -f "$DEST" ] && _ours "$DEST"; then
        ui::kv "$RULE_NAME" "installed but OUT OF DATE — diff (current -> proposed):"
        diff -u "$DEST" "$TPL" 2>/dev/null | sed 's/^/    /' || true
        RULE_STATE=stale
    elif [ -f "$DEST" ]; then
        log::warn "$DEST exists and was NOT created by this installer — a .bak would be kept"
        RULE_STATE=foreign
    else
        ui::kv "$RULE_NAME" "not installed"
        RULE_STATE=absent
    fi

    printf '\n  --- proposed %s ---\n' "$DEST"
    sed 's/^/  /' "$TPL"
    printf '  ------------------------------------------------\n'
}

# ---- the exact privileged sequence, printed, never run ------------------
print_root_commands() {
    cat <<EOF

  Run these as root to apply (this command never runs sudo for you):

    sudo install -D -m 0644 \\
      "$TPL" \\
      /etc/udev/rules.d/$RULE_NAME
    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=input --action=change

  Then verify the ACL is present:
      getfacl /dev/input/event*  |  grep "user:$(id -un)"
      ./install.sh doctor        (Infinite Desktop / evdev section)
  On this machine the reload + trigger applied the ACL to the already-existing
  nodes immediately, with no logout. If getfacl still shows no "user:$(id -un)"
  entry, log out and back in (or reboot) as a fallback.

  Revert:  sudo rm /etc/udev/rules.d/$RULE_NAME
           sudo udevadm control --reload
           sudo udevadm trigger --subsystem-match=input --action=change
           (whether the trigger alone REVOKES an already-granted ACL was not
            tested here — log out/in or reboot to be sure it is dropped)
EOF
}

# ---- write path (root, or INPUT_SYSROOT sandbox) -----------------------
do_write() {
    if [ -f "$DEST" ] && cmp -s "$TPL" "$DEST"; then
        log::ok "$DEST already up to date — nothing to do"
        return 0
    fi
    CHANGES=1
    if [ -f "$DEST" ] && ! _ours "$DEST"; then
        ui::confirm "Back up $DEST and replace it with the repo rule?" || { log::warn "skipped $DEST"; return 0; }
        cp -a "$DEST" "${DEST}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    else
        ui::confirm "Write $DEST ?" || { log::warn "skipped $DEST"; return 0; }
    fi
    if ! install -D -m 0644 "$TPL" "$DEST" 2>/dev/null; then
        log::error "could not write $DEST"
        print_root_commands
        return 2
    fi
    log::ok "wrote $DEST"
    if [ -z "$SYSROOT" ]; then
        cat <<EOF

  The rule is in place but NOT active yet. Run:

    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=input --action=change

  then check:  getfacl /dev/input/event* | grep "user:$(id -un)"
  On this machine that applied the ACL live (no logout). If it does not appear,
  log out/in or reboot. This command does NOT run udevadm for you.
EOF
    else
        log::info "INPUT_SYSROOT set — wrote to the sandbox, ran no udevadm, changed no live state"
    fi
}

# ---------------------------------------------------------------------------
DAEMON_CAN_RUN=0
RULE_STATE=absent

ui::header "Infinite Desktop — input device access (udev uaccess)"
[ "$APPLY" = 1 ] && log::info "--apply: the rule is shown, then confirmed before writing" \
                 || log::info "read-only plan. Re-run with --apply to write the rule."
[ -n "$SYSROOT" ] && log::info "INPUT_SYSROOT=$SYSROOT — writes are redirected here; no live state is touched"

ui::section "What this grants"
cat <<'EOF'
  A udev rule tagging keyboard + mouse + touchpad event nodes with `uaccess`,
  so systemd-logind gives ONLY the active local session's user a temporary
  read/write ACL on them. Not the `input` group, not MODE=0666, not a
  permanent account-wide grant, not SSH.

  RISK: while your graphical session is active, any process you run can read
  every keystroke from these keyboards (and every touchpad/mouse motion).
  `uaccess` bounds this to the active local session and drops it when the
  session ends; it does not remove it. The stricter privileged-broker design
  is described in docs/INFINITE-DESKTOP.md "Input device access".
EOF

report_devices
report_rule

# ---- decide what --apply does ----------------------------------------
if [ "$APPLY" != 1 ]; then
    ui::header "Summary"
    ui::kv "rule state"        "$RULE_STATE"
    ui::kv "daemon can run now" "$([ "$DAEMON_CAN_RUN" = 1 ] && echo yes || echo no)"
    printf '\n'
    if [ "$RULE_STATE" = applied ] && [ "$DAEMON_CAN_RUN" = 1 ]; then
        log::ok "input (plan) complete — already configured, nothing to do"
        exit 0
    fi
    log::info "re-run with --apply to write the rule (needs root, or INPUT_SYSROOT for a dry sandbox)"
    print_root_commands
    log::ok "input (plan) complete — nothing was changed"
    exit 0
fi

# --apply from here
if _writing_to_real_etc_as_non_root; then
    ui::header "Cannot apply as a normal user"
    log::error "writing /etc/udev/rules.d/$RULE_NAME requires root."
    log::error "This command will NOT attempt a write that is bound to fail, and never runs sudo."
    print_root_commands
    exit 1
fi

ui::section "Applying"
rc=0
do_write || rc=$?

ui::header "Summary"
ui::kv "proposed changes" "$CHANGES"
if [ "$rc" -ne 0 ]; then
    log::error "input --apply did not complete cleanly (see above)"
    exit "$rc"
fi
[ -n "$SYSROOT" ] && log::ok "input --apply (sandbox) complete" \
                  || log::ok "input --apply complete — now reload udev + trigger, then check getfacl (commands above)"
exit 0
