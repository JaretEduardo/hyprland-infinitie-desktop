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
# shellcheck source=lib/portage.sh
. "$REPO_DIR/lib/portage.sh"
# shellcheck source=lib/nvidia.sh
. "$REPO_DIR/lib/nvidia.sh"

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

    # ECO but active -> WARN + best-effort client hints
    cd_n=$(_v nvidia.clients_detected "$nw")
    if [ "$policy" = eco ] && [ "$rpm" = active ]; then
        _warn "NVIDIA requested ECO but is currently active"
        _note "Detected NVIDIA clients (best-effort — this list may be incomplete):"
        while IFS= read -r line; do
            case "$line" in nvidia.client.*)
                p=${line#nvidia.client.}; p=${p%%=*}; c=${line#*=}
                _note "  - $c (pid $p)" ;;
            esac
        done <<<"$nw"
        [ "${cd_n:-0}" = 0 ] && _note "  (none detected — a client we cannot see, or the driver itself, is holding it)"
        _note "doctor does not terminate anything or change power/control."
    elif [ "$policy" = eco ] && [ "$rpm" = suspended ]; then
        _ok "ECO policy and the GPU is suspended"
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
    dpm=$(grep -oE 'DynamicPowerManagement: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}')
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

_sec "PipeWire / WirePlumber"
for b in pipewire wireplumber; do
    if _have "$b"; then
        if _have systemctl && systemctl --user is-active --quiet "$b" 2>/dev/null; then _ok "$b present and running (user)"
        else _info "$b present (user service state unknown from here)"; fi
    else _warn "$b not installed"; fi
done

_sec "Hyprland / Quickshell tools"
for b in hyprctl hypridle hyprlock brightnessctl qs; do
    _have "$b" && _ok "$b: $(command -v "$b")" || _info "$b not installed yet"
done
if _have hyprctl; then
    hv=$(hyprctl version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | tr -d v)
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

# ---- Infinite Desktop / evdev -----------------------------
_sec "Infinite Desktop / evdev"
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then _ok "user is in the 'input' group"
else _warn "user is NOT in the 'input' group — Infinite Desktop's evdev daemon needs it (sudo usermod -aG input \$USER)"; fi
if _have python3 && python3 -c 'import evdev' 2>/dev/null; then _ok "python 'evdev' module importable"
else _warn "python 'evdev' not importable (Gentoo: dev-python/evdev)"; fi
if [ -d "$HOME/scripts" ] && [ -e "$HOME/scripts/infinite_desktop_core.py" ]; then _ok "Infinite Desktop scripts installed in ~/scripts"
else _info "Infinite Desktop not installed to ~/scripts yet (install.sh infinite-desktop)"; fi

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
