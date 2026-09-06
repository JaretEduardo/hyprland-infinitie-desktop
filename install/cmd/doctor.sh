#!/usr/bin/env bash
#
# install.sh doctor — read-only workstation diagnostics.
#
# 100% READ-ONLY. No sudo, no writes to /etc or $HOME, no service changes, no
# package installs, no overlay changes, no sysfs writes, no initramfs rebuild.
# All detection is reused from lib/hardware.sh, lib/portage.sh, lib/nvidia.sh
# and the stage-12 GPU config templates — nothing is re-detected here.
#
# NVIDIA: the default run uses ONLY nvidia::probe_nowake. Even when Runtime PM
# says "active" it never runs nvidia-smi — doctor must not be what keeps the
# GPU awake. `--nvidia-deep` opts into nvidia::probe_deep (wake-capable) and
# warns first.
#
# Exit: 0 = no real problems (warnings alone are fine)
#       1 = one or more [ERROR] checks
#       2 = usage / argument error
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"
# shellcheck source=lib/profile.sh
. "$REPO_DIR/lib/profile.sh"
# shellcheck source=lib/portage.sh
. "$REPO_DIR/lib/portage.sh"
# shellcheck source=lib/nvidia.sh
. "$REPO_DIR/lib/nvidia.sh"
# shellcheck source=lib/session.sh
. "$REPO_DIR/lib/session.sh"
# shellcheck source=lib/symlink.sh
. "$REPO_DIR/lib/symlink.sh"

VERBOSE="${INSTALL_VERBOSE:-${LOG_VERBOSE:-}}"
NVIDIA_DEEP=0
for a in "$@"; do
    case "$a" in
        --nvidia-deep) NVIDIA_DEEP=1 ;;
        --verbose|-v)  VERBOSE=1 ;;
        --dry-run)     : ;;    # doctor is already read-only
        -*) printf 'doctor: unknown option: %s\n' "$a" >&2; exit 2 ;;
        *)  printf 'doctor: unexpected argument: %s\n' "$a" >&2; exit 2 ;;
    esac
done

N_ERR=0
N_WARN=0
_ok()   { printf '  %s[OK]%s    %s\n' "${_C_GREEN:-}"  "${_C_RESET:-}" "$*"; }
_warn() { printf '  %s[WARN]%s  %s\n' "${_C_YELLOW:-}" "${_C_RESET:-}" "$*"; N_WARN=$((N_WARN + 1)); }
_err()  { printf '  %s[ERROR]%s %s\n' "${_C_RED:-}"    "${_C_RESET:-}" "$*"; N_ERR=$((N_ERR + 1)); }
_info() { printf '  %s[INFO]%s  %s\n' "${_C_CYAN:-}"   "${_C_RESET:-}" "$*"; }
_note() { printf '            %s\n' "$*"; }
_sec()  { printf '\n%s▸ %s%s\n' "${_C_CYAN:-}" "$*" "${_C_RESET:-}"; }
_have() { command -v "$1" >/dev/null 2>&1; }
# _v <key> <block>  -> value of a "key=value" line
_v() { awk -v k="$1" 'index($0,k"=")==1{print substr($0,length(k)+2);exit}' <<<"${2:-}"; }

IS_GENTOO=0; portage::is_gentoo && IS_GENTOO=1

printf '%s%s%s\n' "${_C_CYAN:-}" "System doctor (read-only)" "${_C_RESET:-}"
printf '%s\n' "────────────────────────────────────────────────────────────"

# ---- system / kernel / init ---------------------------------------------
_sec "System"
osb=$(hw::os)
_info "$(_v os.pretty_name "$osb")  ·  kernel $(_v os.kernel "$osb") $(_v os.kernel_arch "$osb")"
if hw::is_systemd; then _ok "systemd is the active init"
else _warn "init is $(hw::init_system) — the desktop/power/audio stages assume systemd"; fi
_info "bash ${BASH_VERSION%%(*}"
[ "${XDG_SESSION_TYPE:-}" = wayland ] && _info "session type: wayland" || _info "session type: ${XDG_SESSION_TYPE:-unknown}"

# ---- distro ------------------------------------------------------------
_sec "Distribution"
if [ "$IS_GENTOO" = 1 ]; then
    _ok "running Gentoo"
else
    _info "not Gentoo ($(hw::os_pretty)) — Gentoo-specific checks below are INFO/WARN, not failures"
fi

# ---- hardware / drivers ----------------------------------------------
_sec "Hardware and drivers"
mv=$(hw::machine_vendor); mm=$(hw::machine_model)
_info "machine: ${mv:-?} ${mm:-?}"
g=$(hw::gpus)
amd_pci=$(hw::primary_gpu_pci)
nv_pci=$(nvidia::pci)
_gidx() { awk -F. -v p="$1" '$0 ~ ("\\.pci=" p "$"){print $2; exit}' <<<"$g"; }
_gf() { awk -F= -v k="gpu.$1.$2" 'index($0,k"=")==1{print substr($0,length(k)+2);exit}' <<<"$g"; }
ai=$(_gidx "$amd_pci"); ni=$(_gidx "$nv_pci")
if [ -n "$ai" ]; then
    [ "$(_gf "$ai" driver)" = amdgpu ] && _ok "AMD $amd_pci — driver amdgpu" \
        || _warn "AMD $amd_pci — driver is '$(_gf "$ai" driver)' (expected amdgpu)"
else
    _err "no AMD GPU detected"
fi
if [ -n "$ni" ]; then
    nd=$(_gf "$ni" driver)
    case "$nd" in
        nvidia) _ok "NVIDIA $nv_pci — driver nvidia" ;;
        none)   _warn "NVIDIA $nv_pci present but NO kernel driver bound" ;;
        *)      _warn "NVIDIA $nv_pci — driver is '$nd'" ;;
    esac
else
    _info "no NVIDIA GPU detected — hybrid-GPU / compute checks skipped"
fi
n=$(hw::net)
for i in $(awk -F. '/^net\.[0-9]+\.name=/{print $2}' <<<"$n" | sort -nu); do
    nm=$(awk -F= -v k="net.$i.name" 'index($0,k"=")==1{print substr($0,length(k)+2)}' <<<"$n")
    nt=$(awk -F= -v k="net.$i.type" 'index($0,k"=")==1{print substr($0,length(k)+2)}' <<<"$n")
    ndr=$(awk -F= -v k="net.$i.driver" 'index($0,k"=")==1{print substr($0,length(k)+2)}' <<<"$n")
    [ "$nt" = virtual ] && continue
    [ "$ndr" = none ] && _warn "$nt $nm — no driver bound" || _ok "$nt $nm — driver $ndr"
done

# ---- machine profile ---------------------------------------------------
_sec "Machine profile"
prof_id=$(profile::detect)
if [ "$prof_id" = common ]; then
    _info "no machine-specific profile matched — using 'common' (install.sh profile for detail)"
else
    _ok "profile match: $prof_id ($(profile::get name "$prof_id"))"
    pv=$(profile::validate "$prof_id")
    pidx=$(awk -F. '/^validate\.[0-9]+\.item=/{print $2}' <<<"$pv" | sort -nu)
    for i in $pidx; do
        item=$(_v "validate.$i.item" "$pv")
        st=$(_v "validate.$i.status" "$pv")
        det=$(_v "validate.$i.detail" "$pv")
        [ "$st" = ok ] && _ok "$item" || _warn "$item${det:+  ($det)}"
    done
fi

# ---- AMD primary ------------------------------------------------------
_sec "Compositor GPU"
if [ -z "$nv_pci" ]; then
    _ok "single GPU ($amd_pci)"
elif [ "$(_gf "$ni" boot_vga)" = 1 ]; then
    _err "the NVIDIA GPU is boot_vga (primary) — this design needs the AMD iGPU primary; check BIOS graphics mode"
elif [ "$(_gf "$ai" boot_vga)" = 1 ]; then
    _ok "AMD iGPU is boot_vga (primary); NVIDIA is secondary"
else
    _warn "no GPU is marked boot_vga — verify which one the firmware treats as primary"
fi

# ---- NVIDIA (no-wake) -----------------------------------------------
if [ -n "$nv_pci" ]; then
    _sec "NVIDIA — power state (no-wake probe)"
    nw=$(nvidia::probe_nowake)
    rpm=$(_v nvidia.runtime_pm_state "$nw")
    pcs=$(_v nvidia.pci_power_state "$nw")
    pc=$(_v nvidia.power_control "$nw")
    d3a=$(_v nvidia.d3cold_allowed "$nw")
    mset=$(_v nvidia.modeset "$nw")

    _info "driver module: $(_v nvidia.driver "$nw")  ·  version $(_v nvidia.module_version "$nw")"
    _info "Runtime PM: $rpm"
    if [ "$pcs" = D3cold ]; then _info "PCI power state: D3cold (confirmed)"
    else _info "PCI power state: $pcs  (D3cold is only reported when power_state says so)"; fi
    _info "runtime suspended / active: $(_v nvidia.runtime_suspended_time_ms "$nw")ms / $(_v nvidia.runtime_active_time_ms "$nw")ms"

    case "$pc" in
        auto) _ok "power/control = auto (RTD3 permitted)" ;;
        on)   _warn "power/control = on — RTD3 autosuspend is disabled" ;;
        *)    _warn "power/control = $pc" ;;
    esac
    case "$d3a" in
        1) _ok "d3cold_allowed = 1" ;;
        0) _warn "d3cold_allowed = 0 — the GPU cannot reach D3cold" ;;
        *) _info "d3cold_allowed = $d3a" ;;
    esac
    case "$mset" in
        Y) _ok "nvidia_drm modeset = Y" ;;
        N) _warn "nvidia_drm modeset = N — needed for Wayland (run: install.sh gpu)" ;;
        *) _info "nvidia_drm modeset: unreadable here — verify on Gentoo (want Y)" ;;
    esac

    # nvidia-compute-mode policy / backend (read state files; do not run the CLI)
    ncm_dir="${NVCM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nvidia-compute-mode}"
    policy=eco; backend=auto
    [ -r "$ncm_dir/policy" ]  && { read -r policy  < "$ncm_dir/policy"  || true; }
    [ -r /etc/nvidia-compute-mode/backend ] && { read -r backend < /etc/nvidia-compute-mode/backend || true; } \
        || { [ -r "$ncm_dir/backend" ] && { read -r backend < "$ncm_dir/backend" || true; }; }
    case "$policy" in eco|compute) ;; *) policy=eco ;; esac
    case "$backend" in auto|power-control|persistenced|none) ;; *) backend=auto ;; esac
    _info "nvidia-compute-mode: policy=$policy  backend=$backend"
    [ "$backend" = auto ] && _info "compute_backend is unresolved — first-run on Gentoo should pick one"

    # ECO policy: grade the runtime state instead of warning on "active" alone.
    #
    # RTD3 that is momentarily active while the rest of the picture is healthy
    # (power/control=auto, d3cold_allowed=1, no clients, and it HAS suspended
    # at least once this session) is an optimisation trade-off, not a broken
    # config: a Wayland compositor / GL client can wake the dGPU occasionally
    # (client-buffer imports, EGL device enumeration). That is INFO. WARN is
    # reserved for states that actually defeat RTD3.
    cd_n=$(_v nvidia.clients_detected "$nw")
    cd_unread=$(_v nvidia.clients_scan_unreadable "$nw")
    susp_ms=$(_v nvidia.runtime_suspended_time_ms "$nw")
    case "${susp_ms:-}" in ''|*[!0-9]*) susp_ms=0 ;; esac

    _client_hints() {
        local line p c
        while IFS= read -r line; do
            case "$line" in nvidia.client.*)
                p=${line#nvidia.client.}; p=${p%%=*}; c=${line#*=}
                _note "  - $c (pid $p)" ;;
            esac
        done <<<"$nw"
        if [ "${cd_n:-0}" = 0 ]; then
            _note "NVIDIA client scan: none among the processes doctor can see."
        fi
        if [ "${cd_unread:-0}" != 0 ] && [ "${cd_unread:-0}" != unknown ]; then
            _note "  (scan is incomplete — ${cd_unread} /proc/<pid>/fd dirs were unreadable;"
            _note "   run doctor as root, or check 'sudo lsof /dev/nvidia*', for a full list)"
        fi
        _note "doctor does not terminate anything or change power/control."
    }

    if [ "$policy" = eco ] && [ "$rpm" = suspended ]; then
        _ok "ECO policy and the GPU is suspended"
    elif [ "$policy" = eco ]; then
        bad=""
        [ "$pc" = auto ]     || bad="$bad|power/control=$pc (want auto)"
        [ "$d3a" = 1 ]       || bad="$bad|d3cold_allowed=$d3a (want 1)"
        [ "${cd_n:-0}" = 0 ] || bad="$bad|NVIDIA clients are holding it"
        [ "$susp_ms" -gt 0 ] || bad="$bad|RTD3 has not suspended once this session"
        if [ -n "$bad" ]; then
            _warn "NVIDIA is active under ECO and RTD3 looks genuinely defeated:"
            IFS='|' read -ra _reasons <<<"${bad#|}" || true
            for r in "${_reasons[@]}"; do _note "  - $r"; done
            _client_hints
        else
            _info "NVIDIA runtime PM is 'active' right now, but RTD3 is healthy:"
            _note "power/control=auto, d3cold_allowed=1, no clients detected,"
            _note "and it has already spent ${susp_ms}ms suspended this session (RTD3 has engaged)."
            _note "A compositor / GL client can wake the dGPU occasionally — this is a"
            _note "battery/latency trade-off, not a broken RTD3 setup. See docs/HYBRID-GPU.md."
            [ "${cd_unread:-0}" != 0 ] && [ "${cd_unread:-0}" != unknown ] && \
                _note "(client scan skipped ${cd_unread} unreadable /proc/<pid>/fd dirs — run as root for certainty)"
        fi
    fi

    # deep probe only under the explicit flag
    _sec "NVIDIA — deep metrics"
    if [ "$NVIDIA_DEEP" = 1 ]; then
        _info "--nvidia-deep: This check may wake or keep the NVIDIA GPU active."
        dp=$(nvidia::probe_deep 2>/dev/null || true)
        if grep -q '^nvidia.deep.error=' <<<"$dp"; then
            _warn "deep probe: $(grep '^nvidia.deep.error=' <<<"$dp" | cut -d= -f2-)"
        else
            for f in name temp_c util_pct mem_used_mib mem_total_mib clock_sm_mhz power_draw_w pstate; do
                v=$(_v "nvidia.deep.$f" "$dp"); [ -n "$v" ] && _info "$f: $v"
            done
            grep '^nvidia.deep.proc.' <<<"$dp" | while IFS= read -r l; do _note "proc: ${l#nvidia.deep.proc.}"; done
        fi
    else
        _info "not run. Add --nvidia-deep to query nvidia-smi (temperature, VRAM, utilisation,"
        _info "clocks, processes). That probe is wake-capable."
    fi
fi

# ---- hybrid GPU config (stage 12) ---------------------------------
if [ -n "$nv_pci" ]; then
    _sec "Hybrid GPU configuration"
    _mark() { [ -r "$1" ] && head -n1 "$1" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop'; }
    if [ -f /etc/udev/rules.d/70-hypr-gpu-paths.rules ]; then
        _mark /etc/udev/rules.d/70-hypr-gpu-paths.rules && _ok "udev stable-paths rule installed" \
            || _warn "70-hypr-gpu-paths.rules exists but was not written by this installer"
    else
        _info "udev stable-paths rule not installed — run: install.sh gpu --apply"
    fi
    for s in /dev/dri/hypr-primary /dev/dri/hypr-secondary; do
        [ -e "$s" ] && _ok "$s -> $(readlink "$s" 2>/dev/null)" \
                    || _info "$s not present (udev rule not applied / not reloaded / not on this host)"
    done
    for pci in "$amd_pci" "$nv_pci"; do
        for k in card render; do
            [ -e "/dev/dri/by-path/pci-$pci-$k" ] && _ok "/dev/dri/by-path/pci-$pci-$k" \
                || _warn "/dev/dri/by-path/pci-$pci-$k missing"
        done
    done
    if grep -rqsE 'nvidia[_-]drm[[:space:]]+modeset|nvidia-drm\.modeset' /etc/modprobe.d /proc/cmdline 2>/dev/null; then
        _ok "an nvidia_drm modeset setting is present in modprobe.d / cmdline"
    else
        _info "no nvidia_drm modeset config found (may still be a driver default — verify)"
    fi
    pmrule=$(grep -rlsE 'ATTR\{power/control\}' /usr/lib/udev/rules.d /lib/udev/rules.d /etc/udev/rules.d 2>/dev/null | grep -i nvidia | head -n1 || true)
    [ -n "$pmrule" ] && _ok "RTD3 power/control udev rule: $pmrule" \
                     || _warn "no RTD3 power/control udev rule found (driver may still handle it)"
    dpm=$({ grep -oE 'DynamicPowerManagement: [0-9]+' /proc/driver/nvidia/params 2>/dev/null || true; } | awk '{print $2}')
    if [ -n "$dpm" ]; then
        [ "$dpm" = 0 ] && _warn "DynamicPowerManagement = 0 (RTD3 off) — add NVreg_DynamicPowerManagement=0x02" \
                       || _ok "DynamicPowerManagement = $dpm (RTD3 active)"
    else
        _info "DynamicPowerManagement: unreadable here — verify on Gentoo"
    fi
fi

# ---- NVIDIA sleep services ------------------------------------------
if [ -n "$nv_pci" ] && _have systemctl; then
    _sec "NVIDIA suspend / resume services"
    for svc in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
        st=$(systemctl is-enabled "$svc" 2>/dev/null || true); st=${st:-not-installed}
        case "$st" in
            enabled|static|enabled-runtime) _ok "$svc: $st" ;;
            disabled) _warn "$svc: disabled (systemctl enable $svc)" ;;
            *) _info "$svc: $st" ;;
        esac
    done
    pd=$(systemctl is-enabled nvidia-persistenced.service 2>/dev/null || true); pd=${pd:-not-installed}
    [ "$pd" = enabled ] && _warn "nvidia-persistenced.service is enabled — keep it disabled for ECO / RTD3" \
                        || _ok "nvidia-persistenced.service: $pd (correct for ECO)"
fi

# ---- Gentoo overlays -----------------------------------------------
_sec "Gentoo overlays"
if [ "$IS_GENTOO" = 1 ]; then
    for r in $(portage::catalog_repos); do
        portage::repo_enabled "$r" && _ok "overlay '$r' enabled" || _warn "overlay '$r' not enabled (install.sh deps)"
    done
else
    _info "$(portage::catalog_repos | paste -sd, -) needed on Gentoo (install.sh deps prints the commands)"
fi

# ---- required packages -------------------------------------------
_sec "Required packages"
req=$(portage::catalog | awk -F'|' '$4=="required"{print $2}')
req_total=$(printf '%s\n' "$req" | grep -c . || true)
if [ "$IS_GENTOO" = 1 ]; then
    miss=""
    while IFS= read -r atom; do
        [ -n "$atom" ] || continue
        portage::pkg_installed "$atom" || miss="${miss:+$miss }$atom"
    done <<<"$req"
    mc=$(printf '%s' "$miss" | wc -w)
    if [ "$mc" = 0 ]; then _ok "all $req_total required packages installed"
    else
        _err "$mc of $req_total required packages missing"
        [ -n "$VERBOSE" ] && for a in $miss; do _note "- $a"; done
        [ -n "$VERBOSE" ] || _note "run with --verbose to list them, or: install.sh deps"
    fi
else
    _info "$req_total required atoms in the catalogue — not verifiable off Gentoo (install.sh deps)"
fi

# ---- services / stacks ------------------------------------------
_sec "NetworkManager"
if _have systemctl && systemctl is-active --quiet NetworkManager 2>/dev/null; then _ok "NetworkManager active"
elif _have nmcli; then _warn "nmcli present but NetworkManager.service not active"
else _info "NetworkManager not detected (install.sh deps: net-misc/networkmanager)"; fi

# ---- session environment ------------------------------------------
# Values apps + xdg-desktop-portal read to know they are in a Hyprland Wayland
# session. lua/env.lua sets all three; Hyprland itself sets the first two when
# launched bare from a TTY. A missing one is a portal / theming problem.
_sec "Session environment"
_have_session=0
[ -n "${WAYLAND_DISPLAY:-}" ] && _have_session=1
_envset() { grep -qE "hl\.env\(\"$1\"" "$REPO_DIR/config/hypr/lua/env.lua" 2>/dev/null; }
for _e in XDG_CURRENT_DESKTOP:Hyprland XDG_SESSION_DESKTOP:Hyprland XDG_SESSION_TYPE:wayland; do
    _k=${_e%%:*}; _want=${_e#*:}; _cur=$(printenv "$_k" 2>/dev/null || true)
    if _envset "$_k"; then _repo="set by lua/env.lua"; else _repo=""; fi
    if [ "$_have_session" = 0 ]; then
        [ -n "$_repo" ] && _info "$_k: $_repo (not in this non-session shell)" \
                        || _warn "$_k: lua/env.lua does not set it — add hl.env(\"$_k\", \"$_want\")"
    elif [ "$_cur" = "$_want" ]; then _ok "$_k=$_cur"
    elif [ -z "$_cur" ]; then
        [ -n "$_repo" ] && _info "$_k unset now but $_repo — takes effect on the next Hyprland reload / re-login" \
                        || _warn "$_k is unset and lua/env.lua does not set it — add hl.env(\"$_k\", \"$_want\")"
    else _info "$_k=$_cur (repo expects '$_want'; a different launcher set it — usually fine)"; fi
done
[ -n "${WAYLAND_DISPLAY:-}" ] && _ok "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" \
                             || _info "WAYLAND_DISPLAY unset — not inside a Wayland session here"
if session::user_bus; then _ok "user D-Bus session bus reachable"
else _info "no user session bus here — the checks below that need one are skipped, not failed"; fi

# ---- Xwayland (X11 app support) ----------------------------------
_sec "Xwayland (X11 apps)"
case "$(session::xwayland)" in
    builtin)
        _ok "Xwayland present and gui-wm/hyprland was built with USE=X"
        session::proc_running Xwayland && _info "an Xwayland server is running now" \
                                        || _info "no Xwayland server running yet (Hyprland starts it on the first X11 client)" ;;
    binary-only)
        _warn "Xwayland is installed but gui-wm/hyprland is NOT built with USE=X — X11 apps will not work; rebuild: emerge --newuse gui-wm/hyprland" ;;
    none)
        if [ "$IS_GENTOO" = 1 ] && ! portage::pkg_installed x11-base/xwayland; then
            _warn "x11-base/xwayland not installed and gui-wm/hyprland[X] off — no X11 app support (install.sh deps)"
        else
            _info "Xwayland not on PATH (not verifiable off Gentoo)"
        fi ;;
    *) _info "cannot determine Xwayland support here (verify on Gentoo: Xwayland binary + gui-wm/hyprland[X])" ;;
esac
if session::pkg_use_has gui-wm/hyprland systemd; then :; else
    case "$(session::pkg_use_has gui-wm/hyprland systemd; echo $?)" in
        1) _warn "gui-wm/hyprland is not built with USE=systemd — the user-session integration this repo assumes is weaker; rebuild with USE=systemd" ;;
    esac
fi

# ---- desktop portals / screen sharing ---------------------------
# Hyprland: xdg-desktop-portal (frontend) + xdg-desktop-portal-hyprland
# (ScreenCast/Screenshot/GlobalShortcuts, via wlroots screencopy + PipeWire) +
# a file-chooser backend (xdg-desktop-portal-gtk). Screen sharing in
# Firefox/Chromium/Discord/OBS/Zoom goes through this. Read-only: no capture.
_sec "Desktop portals / screen sharing"
for _pp in \
    "sys-apps/xdg-desktop-portal|xdg-desktop-portal|portal frontend" \
    "gui-libs/xdg-desktop-portal-hyprland|.|Hyprland backend (screencast/screenshot)" \
    "sys-apps/xdg-desktop-portal-gtk|.|GTK backend (file chooser, settings)"; do
    _atom=${_pp%%|*}; _r=${_pp#*|}; _pdesc=${_r#*|}
    if [ "$IS_GENTOO" = 1 ]; then
        portage::pkg_installed "$_atom" && _ok "$_atom installed ($_pdesc)" \
            || _warn "$_atom NOT installed (install.sh deps) — $_pdesc"
    else
        _info "$_atom — not verifiable off Gentoo ($_pdesc)"
    fi
done
if session::user_bus; then
    if session::dbus_owned --user org.freedesktop.portal.Desktop; then
        _ok "org.freedesktop.portal.Desktop is being served (xdg-desktop-portal running)"
    elif session::dbus_known --user org.freedesktop.portal.Desktop; then
        _info "portal frontend not running yet — D-Bus-activatable, starts on first use"
    else
        _warn "org.freedesktop.portal.Desktop has no owner and is not activatable"
    fi
    session::dbus_known --user org.freedesktop.impl.portal.desktop.hyprland \
        && _ok "the Hyprland portal backend is registered (screencast/screenshot available)" \
        || _warn "the Hyprland portal backend is not registered — start xdg-desktop-portal-hyprland.service"
    _pc="${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal/hyprland-portals.conf"
    if [ -L "$_pc" ] || [ -f "$_pc" ]; then _ok "portal backend preference pinned: $_pc"
    elif [ -f /usr/share/xdg-desktop-portal/hyprland-portals.conf ]; then _info "backend preference from the distro default (/usr/share/...); the repo pins its own via install.sh dotfiles --apply"
    else _info "no hyprland-portals.conf — xdg-desktop-portal chooses a backend by its own heuristics; run install.sh dotfiles --apply to pin it"; fi
else
    _info "portal runtime state not checked (no session bus here)"
fi

# ---- audio session (PipeWire / WirePlumber) --------------------
# PipeWire user units are socket-activated: they must be ENABLED for the
# session to have audio. `disabled` is a real problem, not a transient state.
_sec "Audio session (PipeWire / WirePlumber)"
_pw_missing=0
for _pb in pipewire wireplumber wpctl; do
    _have "$_pb" || { _pw_missing=1; _warn "$_pb not installed"; }
done
if [ "$_pw_missing" = 0 ]; then
    if session::user_bus; then
        _pw_sock=$(session::unit_enabled --user pipewire.socket)
        _wp_svc=$(session::unit_enabled --user wireplumber.service)
        if [ "$_pw_sock" = enabled ] && [ "$_wp_svc" = enabled ]; then
            _ok "pipewire.socket + wireplumber.service are enabled for the user session"
        else
            _warn "PipeWire user units are not enabled (pipewire.socket=$_pw_sock, wireplumber.service=$_wp_svc) — no audio. Fix:"
            _note "systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service"
        fi
        # runtime, read-only (timeout-guarded: a wedged socket must not hang doctor)
        if session::have wpctl && timeout 5 wpctl status >/dev/null 2>&1; then
            _ok "wpctl can reach PipeWire (audio server is up)"
        elif session::have pactl && timeout 5 pactl info >/dev/null 2>&1; then
            _ok "pactl can reach the audio server (PipeWire-Pulse)"
        else
            _info "no running PipeWire yet (it socket-activates on the first client once enabled)"
        fi
    else
        _info "PipeWire/WirePlumber installed; session state not checked (no user bus here)"
    fi
fi

_sec "Hyprland / Quickshell tools"
for b in hyprctl hypridle hyprlock brightnessctl qs; do
    _have "$b" && _ok "$b: $(command -v "$b")" || _info "$b not installed yet"
done
if _have hyprctl; then
    hv=$(hyprctl version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | tr -d v || true)
    if [ -n "$hv" ]; then
        maj=${hv%%.*}; rest=${hv#*.}; minr=${rest%%.*}
        if [ "$maj" -eq 0 ] && [ "$minr" -lt 55 ] 2>/dev/null; then
            _err "Hyprland $hv is < 0.55 — this repo targets the Lua hl.dsp.* dispatch API (0.55+)"
        else
            _ok "Hyprland $hv (>= 0.55, Lua dispatch API available)"
        fi
    else _info "could not parse Hyprland version"; fi
fi

# ---- battery / backlight --------------------------------------
_sec "Battery / backlight"
hw::has_battery && _ok "battery present" || _info "no battery reported"
bl=$(hw::backlights)
if [ -n "$bl" ]; then
    bn=$(awk -F= '/^bl\.0\.name=/{print $2;exit}' <<<"$bl")
    _ok "backlight device: $bn"
else _info "no backlight device exposed"; fi
_have brightnessctl && _ok "brightnessctl present" || _info "brightnessctl not installed (media-key backlight control)"

# ---- session services: notifications / UPower / polkit agent ----------
# Read-only. Distinguishes: package missing · installed but the bus service is
# unavailable · installed and D-Bus-activatable but not running yet · OK.
# D-Bus activation is normal: a service that is only "activatable" is NOT a
# problem, and nothing here sends a real notification or triggers a pkexec.
_sec "Session services (notifications, UPower, polkit agent)"

_user_bus=0
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
    _user_bus=1
fi

# _svc_present <atom> <bin> [abs-path]  -> "yes" | "no" | "unknown"
#   Gentoo: the packages.gentoo catalogue is the source of truth.
#   Off Gentoo: fall back to a binary on PATH or an absolute path.
_svc_present() {
    if [ "$IS_GENTOO" = 1 ]; then
        portage::pkg_installed "$1" && echo yes || echo no
    elif _have "$2" || { [ -n "${3:-}" ] && [ -x "$3" ]; }; then
        echo yes
    else
        echo unknown
    fi
}

# --- notification daemon (repo standard: gui-apps/mako) ---
case "$(_svc_present gui-apps/mako mako)" in
  yes)
    _ok "notifications: mako installed"
    if [ "$_user_bus" = 1 ] && _have busctl; then
        if busctl --user status org.freedesktop.Notifications >/dev/null 2>&1; then
            if pgrep -x mako >/dev/null 2>&1; then _ok "  org.freedesktop.Notifications is served by mako"
            else                                   _ok "  org.freedesktop.Notifications is served (by another daemon)"; fi
        elif busctl --user list 2>/dev/null | grep -qE '^org\.freedesktop\.Notifications[[:space:]]'; then
            _info "  not running yet — D-Bus-activatable; lua/autostart.lua brings it up with the session"
        else
            _warn "  installed but org.freedesktop.Notifications has no owner and is not activatable"
        fi
    else
        _info "  session bus not available here — runtime state not checked"
    fi
    ;;
  no)      _warn "notifications: gui-apps/mako NOT installed (install.sh deps) — notify-send / the Notifications API fail silently" ;;
  *)       _info "notifications: mako not found (repo standard; not verifiable off Gentoo)" ;;
esac

# --- UPower (Quickshell modules/Battery.qml; system bus, activated on demand) ---
# `upower.service` sitting inactive is NORMAL (D-Bus-activated) — never a WARN.
case "$(_svc_present sys-power/upower upower)" in
  yes)
    _ok "UPower: sys-power/upower installed"
    if _have busctl; then
        if busctl --system list 2>/dev/null | grep -qE '^org\.freedesktop\.UPower[[:space:]]'; then
            _ok "  org.freedesktop.UPower is on the system bus (running or activatable)"
            if hw::has_battery && _have upower; then
                # `upower -e` only enumerates (read-only); it D-Bus-activates the
                # daemon, which is exactly how Quickshell will use it.
                if upower -e 2>/dev/null | grep -qi battery; then
                    _ok "  UPower reports a battery device"
                else
                    _warn "  this machine has a battery but UPower lists none (upower -e) — investigate"
                fi
            fi
        else
            _warn "  org.freedesktop.UPower is neither running nor activatable — is the package fully installed?"
        fi
    else
        _info "  busctl not available — UPower bus state not checked"
    fi
    ;;
  no)      _warn "UPower: sys-power/upower NOT installed (install.sh deps) — the bar's battery widget stays hidden" ;;
  *)       _info "UPower: 'upower' not found (repo standard; not verifiable off Gentoo)" ;;
esac

# --- polkit authentication agent (repo standard: sys-auth/hyprpolkitagent) ---
# Binary lives in libexec (not on PATH). Never trigger a pkexec prompt here.
case "$(_svc_present sys-auth/hyprpolkitagent hyprpolkitagent /usr/libexec/hyprpolkitagent)" in
  yes)     _ok "polkit agent: sys-auth/hyprpolkitagent installed" ;;
  no)      _warn "polkit agent: sys-auth/hyprpolkitagent NOT installed (install.sh deps) — pkexec prompts would have no UI" ;;
  *)       _info "polkit agent: hyprpolkitagent not found (repo standard; not verifiable off Gentoo)" ;;
esac
_agent_running=""
for _pa in hyprpolkitagent polkit-gnome-authentication-agent-1 polkit-kde-authentication-agent-1 \
           polkit-mate-authentication-agent-1 lxpolkit xfce-polkit; do
    if pgrep -x "$_pa" >/dev/null 2>&1 || pgrep -f "$_pa" >/dev/null 2>&1; then
        _agent_running="$_pa"; break
    fi
done
if [ "$_agent_running" = hyprpolkitagent ]; then
    _ok "  hyprpolkitagent is running in this session"
elif [ -n "$_agent_running" ]; then
    _info "  a non-standard polkit agent is running ($_agent_running) — the repo standard is hyprpolkitagent; the other is no longer needed"
elif [ "$_user_bus" = 1 ]; then
    if _have systemctl && systemctl --user cat hyprpolkitagent.service >/dev/null 2>&1; then
        _info "  hyprpolkitagent.service is known but not active yet — lua/autostart.lua starts it on hyprland.start"
    else
        _info "  no polkit agent running; hyprpolkitagent.service not yet known to 'systemctl --user' (run 'systemctl --user daemon-reload' after install, or re-login)"
    fi
else
    _info "  polkit agent runtime state not checked (no session here)"
fi

# ---- idle / lock (hypridle + hyprlock) ---------------------------
# Never locks the screen from here. hypridle is started (guarded) by
# lua/autostart.lua; hyprlock is only ever launched by hypridle's lock_cmd.
_sec "Idle / lock (hypridle + hyprlock)"
_have hypridle && _ok "hypridle installed" || _warn "hypridle not installed (gui-apps/hypridle)"
_have hyprlock && _ok "hyprlock installed" || _warn "hyprlock not installed (gui-apps/hyprlock)"
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if session::proc_running hypridle; then
        _ok "hypridle is running in this session"
        session::user_bus && session::dbus_owned --user org.freedesktop.ScreenSaver \
            && _ok "org.freedesktop.ScreenSaver is served (idle-inhibit works)" || true
    else
        _warn "hypridle is NOT running — no idle dim/lock/DPMS/suspend ladder (lua/autostart.lua starts it on hyprland.start)"
    fi
else
    _info "not inside a Hyprland session here — hypridle runtime state not checked"
fi
for _hc in hypridle/hypridle.conf hyprlock/hyprlock.conf; do
    _hl="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/${_hc#*/}"
    _ht="$REPO_DIR/config/$_hc"
    case "$(symlink::state "$_hl" "$_ht")" in
        correct)    _ok "${_hc#*/} linked to the repo" ;;
        absent)     _warn "${_hc#*/} not linked — run: install.sh dotfiles --apply" ;;
        broken)     _warn "${_hc#*/} is a broken symlink — run: install.sh dotfiles --apply" ;;
        real-file)  _info "${_hc#*/} is a real file (local edit, not the repo copy)" ;;
        wrong-link) _warn "${_hc#*/} points somewhere other than the repo" ;;
    esac
done

# ---- logind drop-in (lid / power-key / idle-action) ------------
# install.sh power writes config/logind/50-hyprland-infinite-desktop.conf.
# Read-only: reports the file + compares content + reads the LIVE values logind
# publishes over D-Bus. Never restarts systemd-logind.
_sec "logind drop-in (lid / power key / idle)"
_ld=/etc/systemd/logind.conf.d/50-hyprland-infinite-desktop.conf
_ldt="$REPO_DIR/config/logind/50-hyprland-infinite-desktop.conf"
if [ -f "$_ld" ]; then
    head -n1 "$_ld" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop' \
        && _ok "drop-in installed (managed): $_ld" \
        || _warn "$_ld exists but was not written by this installer"
    _body() { { grep -vE '^[[:space:]]*(#|$|\[)' "$1" 2>/dev/null | sort; } || true; }
    [ "$(_body "$_ld")" = "$(_body "$_ldt")" ] \
        && _ok "drop-in content matches the repo" \
        || _warn "drop-in content differs from the repo — re-run install.sh power --apply"
else
    _warn "logind drop-in NOT installed — a single Power-key press will power the machine OFF instead of locking. Fix: install.sh power --apply"
fi
if _have busctl; then
    _lv() {
        timeout 5 busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager "$1" 2>/dev/null | awk -F'"' 'NR==1{print $2}' || true
    }
    _pk=$(_lv HandlePowerKey || true)
    _lid=$(_lv HandleLidSwitch || true)
    _ia=$(_lv IdleAction || true)
    if [ -n "$_pk" ]; then
        if [ "$_pk" = lock ]; then _ok "live: HandlePowerKey=lock"
        else _warn "live: HandlePowerKey=$_pk (repo wants 'lock' — install.sh power --apply)"; fi
        if [ "$_ia" = ignore ]; then _ok "live: IdleAction=ignore (hypridle owns idle)"
        else _warn "live: IdleAction=$_ia (repo wants 'ignore'; hypridle owns the ladder)"; fi
        [ -n "$_lid" ] && _info "live: HandleLidSwitch=$_lid"
    else
        _info "logind live values not readable here"
    fi
fi

# ---- fonts (avoid tofu on a minimal install) -------------------
_sec "Fonts"
if _have fc-match; then
    _fs=$(session::fc_family sans-serif); _fm=$(session::fc_family monospace); _fe=$(session::fc_family emoji)
    [ -n "$_fs" ] && _ok "sans-serif resolves to: $_fs" || _warn "fontconfig has no sans-serif family — tofu everywhere (install a font, e.g. media-fonts/dejavu)"
    [ -n "$_fm" ] && _ok "monospace resolves to: $_fm" || _warn "fontconfig has no monospace family — foot / code will show tofu"
    if [ -z "$_fe" ] || [ "$_fe" = "$_fs" ]; then
        _info "no dedicated emoji font (emoji render as tofu). Optional: media-fonts/noto-emoji"
    else
        _ok "emoji font: $_fe"
    fi
    if [ "$IS_GENTOO" = 1 ] && ! portage::pkg_installed media-fonts/dejavu \
        && ! portage::pkg_installed media-fonts/noto \
        && ! portage::pkg_installed media-fonts/liberation-fonts; then
        _warn "no baseline font package installed (install.sh deps: media-fonts/dejavu)"
    fi
else
    _info "fc-match not available — cannot check fonts here (media-libs/fontconfig)"
fi

# ---- dotfile integrity ----------------------------------------
# Derived straight from install/dotfiles.manifest — no second copy of the list.
# gpu.local.lua / monitors.local.lua are machine-local BY DESIGN and are not in
# the manifest, so they are never reported here.
_sec "Dotfile integrity"
_dn_ok=0; _dn_bad=0
while IFS='|' read -r _base _src _dest _rest; do
    _base=$(printf '%s' "$_base" | tr -d '[:space:]')
    _src=$(printf '%s' "$_src" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    _dest=$(printf '%s' "$_dest" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$_base" in config) _root="${XDG_CONFIG_HOME:-$HOME/.config}" ;; home) _root="$HOME" ;; *) continue ;; esac
    _lnk="$_root/$_dest"; _tgt="$REPO_DIR/$_src"
    case "$(symlink::state "$_lnk" "$_tgt")" in
        correct)    _dn_ok=$((_dn_ok+1)) ;;
        real-file)  _info "$_dest is a real file, not the repo link (intentional local copy?)" ;;
        absent)     _warn "$_dest missing — run: install.sh dotfiles --apply"; _dn_bad=$((_dn_bad+1)) ;;
        broken)     _warn "$_dest is a broken symlink — run: install.sh dotfiles --apply"; _dn_bad=$((_dn_bad+1)) ;;
        wrong-link) _warn "$_dest points somewhere other than the repo"; _dn_bad=$((_dn_bad+1)) ;;
        *)          _warn "$_dest: unexpected state"; _dn_bad=$((_dn_bad+1)) ;;
    esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO_DIR/install/dotfiles.manifest")
[ "$_dn_bad" = 0 ] && _ok "all $_dn_ok managed dotfiles link to the repo" \
                   || _warn "$_dn_bad of $((_dn_ok+_dn_bad)) managed dotfiles need attention (see above)"

# ---- desktop utilities: launcher / screenshots / clipboard -----------
# Read-only. These are all `required` in the catalogue, so a missing one also
# shows up under "Required packages"; this section adds the binary + the
# hypr-screenshot symlink. It never takes a screenshot.
_sec "Desktop utilities (launcher, screenshots, clipboard)"
for _pair in \
    "fuzzel|gui-apps/fuzzel|app launcher (Super+Space)" \
    "grim|gui-apps/grim|screenshot capture" \
    "slurp|gui-apps/slurp|region select (Super+Shift+S)" \
    "wl-copy|gui-apps/wl-clipboard|Wayland clipboard (wl-copy / wl-paste)"; do
    _b=${_pair%%|*}; _rest=${_pair#*|}; _atom=${_rest%%|*}; _desc=${_rest#*|}
    if _have "$_b"; then _ok "$_b present ($_desc)"
    elif [ "$IS_GENTOO" = 1 ] && ! portage::pkg_installed "$_atom"; then
        _warn "$_b missing — $_atom not installed (install.sh deps) [$_desc]"
    else
        _info "$_b not on PATH ($_atom; not verifiable off Gentoo)"
    fi
done
if _have wl-copy && ! _have wl-paste; then
    _warn "wl-copy is present but wl-paste is not — gui-apps/wl-clipboard looks incomplete"
fi
_ss_repo="$REPO_DIR/scripts/desktop/hypr-screenshot"
_ss_link="$HOME/.local/bin/hypr-screenshot"
if [ -L "$_ss_link" ] && [ "$(readlink -f "$_ss_link" 2>/dev/null)" = "$(readlink -f "$_ss_repo" 2>/dev/null)" ]; then
    _ok "hypr-screenshot linked: $_ss_link -> repo"
elif [ -e "$_ss_link" ]; then
    _warn "$_ss_link exists but does not point at the repo copy — run: install.sh dotfiles --apply"
elif _have hypr-screenshot; then
    _info "hypr-screenshot on PATH but not from ~/.local/bin (a manual copy?)"
else
    _info "hypr-screenshot not linked yet — run: install.sh dotfiles --apply"
fi

# ---- Infinite Desktop / evdev -----------------------------
_sec "Infinite Desktop / evdev"
if _have python3 && python3 -c 'import evdev' 2>/dev/null; then _ok "python 'evdev' module importable"
else _warn "python 'evdev' not importable (Gentoo: dev-python/evdev)"; fi
if [ -d "$HOME/scripts" ] && [ -e "$HOME/scripts/infinite_desktop_core.py" ]; then _ok "Infinite Desktop scripts installed in ~/scripts"
else _info "Infinite Desktop not installed to ~/scripts yet (install.sh infinite-desktop)"; fi

# Input-device access. The evdev daemon reads /dev/input/event* directly; the
# repo's model is a udev `uaccess` rule (install.sh input), NOT the `input`
# group. The real test is "can this user read a keyboard AND a pointer (a REL
# mouse OR an ABS touchpad) right now".
_id_rule=/etc/udev/rules.d/72-hypr-infinite-input.rules
_id_tpl="$REPO_DIR/config/udev/72-hypr-infinite-input.rules"
if [ -f "$_id_rule" ] && head -n1 "$_id_rule" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop'; then
    # Compare only the effective rule lines (the ACL behaviour depends on those,
    # not on the comment block).
    _rule_body() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null; }
    if [ -f "$_id_tpl" ] && [ "$(_rule_body "$_id_rule")" != "$(_rule_body "$_id_tpl")" ]; then
        _warn "udev uaccess rule installed but OUT OF DATE vs the repo — run: install.sh input (then reload udev + trigger)"
    elif [ -f "$_id_tpl" ] && ! cmp -s "$_id_rule" "$_id_tpl"; then
        _ok "udev uaccess rule installed (repo has newer comments only): $_id_rule"
    else
        _ok "udev uaccess rule installed: $_id_rule"
    fi
elif [ -f "$_id_rule" ]; then
    _warn "$_id_rule exists but was not written by this installer"
else
    _info "udev uaccess rule not installed — run: install.sh input  (then reload udev + trigger)"
fi
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then
    _warn "user is in the 'input' group — broader than needed; the uaccess rule (install.sh input) replaces it"
fi
if _have udevadm && ls /dev/input/event* >/dev/null 2>&1; then
    _kbd_ok=0; _mouse_ok=0; _tp_ok=0
    for _d in /dev/input/event*; do
        [ -e "$_d" ] || continue
        _props=$(udevadm info -q property -n "$_d" 2>/dev/null)
        case "$_props" in *"ID_INPUT_KEYBOARD=1"*) [ -r "$_d" ] && _kbd_ok=1 ;; esac
        case "$_props" in *"ID_INPUT_MOUSE=1"*)    [ -r "$_d" ] && _mouse_ok=1 ;; esac
        case "$_props" in *"ID_INPUT_TOUCHPAD=1"*) [ -r "$_d" ] && _tp_ok=1 ;; esac
    done
    _ptr_ok=0; { [ "$_mouse_ok" = 1 ] || [ "$_tp_ok" = 1 ]; } && _ptr_ok=1
    _via=""; [ "$_mouse_ok" = 1 ] && _via=mouse
    [ "$_tp_ok" = 1 ] && _via="${_via:+$_via + }touchpad"
    if [ "$_kbd_ok" = 1 ] && [ "$_ptr_ok" = 1 ]; then
        _ok "a keyboard and a usable pointer ($_via) are readable by this user now — the daemon can run"
    else
        _miss=""
        [ "$_kbd_ok" = 0 ] && _miss="a keyboard"
        [ "$_ptr_ok" = 0 ] && _miss="${_miss:+$_miss and }a pointer (mouse or touchpad)"
        _warn "the daemon cannot read $_miss yet — run install.sh input (reload + trigger; re-login/reboot only if getfacl still shows no ACL)"
    fi
else
    _info "no udevadm / no /dev/input here — input-access check skipped (verify on the target)"
fi
# Daemon lifecycle — THIS Hyprland session only. The daemon keeps one instance
# per session (an flock in $XDG_RUNTIME_DIR/infinite-desktop/<sig>.lock),
# self-exits when its session ends, and logs to a per-session file. Never infer
# state from another session's daemon or its log.
_id_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
_id_sd="$_id_rt/infinite-desktop"
_id_sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
_id_procs=$({ pgrep -f 'infinite_desktop_core\.py' 2>/dev/null || true; } | tr '\n' ' ')
_id_procs="${_id_procs% }"
_id_nproc=$(printf '%s' "$_id_procs" | wc -w)

if [ -n "$_id_sig" ]; then
    _id_key=$(printf '%s' "$_id_sig" | tr / _)
    _id_lock="$_id_sd/$_id_key.lock"
    _id_log="$_id_sd/$_id_key.log"
    _id_pid=""
    if _have flock && [ -e "$_id_lock" ] && ! flock -n "$_id_lock" -c true 2>/dev/null; then
        _id_pid=$(head -n1 "$_id_lock" 2>/dev/null)
        _ok "Infinite Desktop daemon running for this session (pid ${_id_pid:-?})"
    elif [ "$_id_nproc" -gt 0 ]; then
        _warn "Infinite Desktop: $_id_nproc process(es) running ($_id_procs) but none holds this session's lock — likely all from previous sessions"
    else
        _info "Infinite Desktop daemon not running for this session (it starts on hyprland.start; ./install.sh infinite-desktop to (re)install)"
    fi
    # daemons from OTHER sessions still alive
    _id_stale=0
    for _p in $_id_procs; do
        [ "$_p" = "${_id_pid:-x}" ] || _id_stale=$((_id_stale + 1))
    done
    if [ "$_id_stale" -gt 0 ]; then
        _warn "$_id_stale Infinite Desktop process(es) from other/older Hyprland sessions still running — the watchdog exits each ~10 s after its session ends; if they persist, something is wrong"
    fi
    # only THIS session's log
    if [ -f "$_id_log" ] && grep -q 'Sin dispositivos de entrada accesibles' "$_id_log" 2>/dev/null; then
        _warn "this session's daemon reported no accessible input devices ($_id_log) — run: install.sh input"
    fi
elif [ "$_id_nproc" -gt 0 ]; then
    _info "not inside a Hyprland session here (no HYPRLAND_INSTANCE_SIGNATURE) — $_id_nproc infinite_desktop_core.py process(es) running, not attributable to a session from here"
else
    _info "not inside a Hyprland session here — Infinite Desktop runtime state not checked"
fi

# ---- summary -------------------------------------------------
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf 'doctor: %s%d error(s)%s, %s%d warning(s)%s\n' \
    "${_C_RED:-}" "$N_ERR" "${_C_RESET:-}" "${_C_YELLOW:-}" "$N_WARN" "${_C_RESET:-}"
if [ "$N_ERR" -gt 0 ]; then
    printf '%s\n' "read-only — nothing was changed. Fix the [ERROR] items above."
    exit 1
fi
printf '%s\n' "read-only — nothing was changed."
exit 0
