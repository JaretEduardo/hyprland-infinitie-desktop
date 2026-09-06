#!/usr/bin/env bash
#
# install.sh check — read-only system report.
#
# Strictly read-only: no sudo, no file changes, no nvidia-smi, no power-state
# changes. Every fact comes from lib/hardware.sh (no hardware logic duplicated
# here). Works on any distro; it does not assume Gentoo. Missing tools or
# hardware produce an info/warning line and the report continues.
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then
    REPO_DIR="$INSTALL_REPO_DIR"
else
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"
# shellcheck source=lib/profile.sh
. "$REPO_DIR/lib/profile.sh"

VERBOSE="${INSTALL_VERBOSE:-${LOG_VERBOSE:-}}"

# _val <key> <block>  -> value of a "key=value" line, or nothing
_val() {
    awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' <<<"${2:-}"
}
# _indices <prefix> <block>  -> sorted numeric indices present under "prefix.N."
_indices() {
    awk -F. -v p="$1" '$1 == p && $2 ~ /^[0-9]+$/ { print $2 }' <<<"${2:-}" | sort -nu
}
# _tool <name> [note]  -> aligned "present/absent" line
_tool() {
    local p
    if p=$(command -v "$1" 2>/dev/null); then
        ui::kv "$1" "$p"
    else
        ui::kv "$1" "not found${2:+   ($2)}"
    fi
}

# --------------------------------------------------------------------------

ui::header "System check"
[ -n "${INSTALL_DRY_RUN:-}" ] && log::debug "check is read-only; --dry-run changes nothing"

# ---- Operating system ---------------------------------------------------------
ui::section "Operating system"
os_block=$(hw::os)
os_id=$(_val os.id "$os_block")
pretty=$(_val os.pretty_name "$os_block")
[ -z "$pretty" ] && pretty="${os_id:-unknown}"

is_gentoo=no
if [ "$os_id" = "gentoo" ] || [ -e /etc/gentoo-release ] || command -v emerge >/dev/null 2>&1; then
    is_gentoo=yes
fi

ui::kv "Distribution" "$pretty"
[ -n "$os_id" ] && ui::kv "ID" "$os_id"
if [ "$is_gentoo" = yes ]; then
    ui::kv "Gentoo" "yes"
else
    ui::kv "Gentoo" "no  — this report is distro-agnostic; the deps/desktop stages target Gentoo"
fi
ui::kv "Kernel" "$(_val os.kernel "$os_block")  ($(_val os.kernel_arch "$os_block"))"
if hw::is_systemd; then
    ui::kv "Init" "systemd (active)"
else
    ui::kv "Init" "$(_val os.init "$os_block")"
    log::warn "systemd is not the active init — the desktop/power/audio stages assume systemd units"
fi
ui::kv "Bash" "${BASH_VERSION:-unknown}"
lc=$(_val os.libc "$os_block"); [ -n "$lc" ] && ui::kv "libc" "$lc"

# ---- Machine ----------------------------------------------------------------
ui::section "Machine"
m_block=$(hw::machine)
mv=$(_val machine.vendor "$m_block")
mp=$(_val machine.product_name "$m_block")
if [ -n "$mv$mp" ]; then
    ui::kv "Vendor / model" "$(printf '%s %s' "$mv" "$mp" | sed 's/^ *//; s/ *$//')"
else
    log::info "no DMI data (vendor/model unavailable — common in VMs / restricted sysfs)"
fi
pver=$(_val machine.product_version "$m_block"); [ -n "$pver" ] && ui::kv "Marketing name" "$pver"
bd_v=$(_val machine.board_vendor "$m_block"); bd_n=$(_val machine.board_name "$m_block")
[ -n "$bd_v$bd_n" ] && ui::kv "Board" "$(printf '%s %s' "$bd_v" "$bd_n" | sed 's/^ *//; s/ *$//')"
bi_v=$(_val machine.bios_vendor "$m_block"); bi_r=$(_val machine.bios_version "$m_block"); bi_d=$(_val machine.bios_date "$m_block")
[ -n "$bi_v$bi_r" ] && ui::kv "Firmware" "$(printf '%s %s%s' "$bi_v" "$bi_r" "${bi_d:+  ($bi_d)}" | sed 's/^ *//')"
ch=$(_val machine.chassis "$m_block"); [ -n "$ch" ] && ui::kv "Chassis" "$ch"
prof_id=$(profile::detect)
if [ "$prof_id" = common ]; then
    ui::kv "Profile" "common  (no machine-specific profile matched — install.sh profile for detail)"
else
    ui::kv "Profile" "$prof_id  ($(profile::get name "$prof_id"))"
fi

# ---- CPU ------------------------------------------------------------------
ui::section "CPU"
c_block=$(hw::cpu)
ui::kv "Model" "$(_val cpu.model "$c_block")"
cores=$(_val cpu.cores "$c_block"); threads=$(_val cpu.threads "$c_block")
if [ -n "$cores" ]; then
    ui::kv "Topology" "$cores cores / $threads threads  ($(_val cpu.arch "$c_block"))"
else
    ui::kv "Topology" "$threads threads  ($(_val cpu.arch "$c_block"))"
fi

# ---- GPUs ------------------------------------------------------------------
ui::section "GPUs"
g_block=$(hw::gpus)
g_idx=$(_indices gpu "$g_block")
if [ -z "$g_idx" ]; then
    log::warn "no PCI display controllers detected"
else
    primary=$(hw::primary_gpu_pci)
    for i in $g_idx; do
        pci=$(_val "gpu.$i.pci" "$g_block")
        vid=$(_val "gpu.$i.vendor_id" "$g_block"); did=$(_val "gpu.$i.device_id" "$g_block")
        desc=$(_val "gpu.$i.desc" "$g_block")
        drv=$(_val "gpu.$i.driver" "$g_block")
        mark=""; [ "$pci" = "$primary" ] && mark="   <- primary"
        printf '  [%s] %s%s\n' "$i" "${desc:-unknown}" "$mark"
        ui::kv "    PCI" "$pci   (${vid#0x}:${did#0x})"
        ui::kv "    Driver" "$drv"
        if [ "$drv" = none ]; then
            log::info "GPU $pci has no kernel driver bound"
        fi
        dc=$(_val "gpu.$i.dri_card" "$g_block"); dr=$(_val "gpu.$i.dri_render" "$g_block")
        [ -n "$dc" ] && ui::kv "    DRI" "$dc"
        [ -n "$dr" ] && ui::kv "    " "$dr"
        if [ -n "$VERBOSE" ]; then
            ui::kv "    Subsystem" "$(_val "gpu.$i.subsystem_vendor" "$g_block"):$(_val "gpu.$i.subsystem_device" "$g_block")"
            ui::kv "    Class" "$(_val "gpu.$i.class" "$g_block")"
        fi
    done
    ui::kv "Primary GPU" "${primary:-unknown}"
fi
command -v lspci >/dev/null 2>&1 || log::info "lspci not installed — GPU descriptions are limited to vendor/device IDs"

# ---- Network ---------------------------------------------------------------
ui::section "Network"
n_block=$(hw::net)
n_idx=$(_indices net "$n_block")
if [ -z "$n_idx" ]; then
    log::warn "no network interfaces detected"
else
    for i in $n_idx; do
        name=$(_val "net.$i.name" "$n_block")
        typ=$(_val "net.$i.type" "$n_block")
        [ "$typ" = virtual ] && [ -z "$VERBOSE" ] && continue
        drv=$(_val "net.$i.driver" "$n_block")
        st=$(_val "net.$i.state" "$n_block")
        bus=$(_val "net.$i.bus" "$n_block")
        spd=$(_val "net.$i.speed_mbps" "$n_block")
        printf '  %-16s %-9s driver %-10s link %-8s %s%s\n' \
            "$name" "$typ" "$drv" "$st" "${bus:+($bus)}" "${spd:+  ${spd}Mb/s}"
    done
fi

# ---- Power ---------------------------------------------------------------
ui::section "Power"
p_block=$(hw::power_supplies)
p_idx=$(_indices ps "$p_block")
if [ -z "$p_idx" ]; then
    log::info "no power_supply devices (desktop, or restricted sysfs)"
else
    for i in $p_idx; do
        name=$(_val "ps.$i.name" "$p_block")
        typ=$(_val "ps.$i.type" "$p_block")
        case "$typ" in
            Battery)
                st=$(_val "ps.$i.status" "$p_block"); cap=$(_val "ps.$i.capacity" "$p_block")
                man=$(_val "ps.$i.manufacturer" "$p_block"); mod=$(_val "ps.$i.model" "$p_block")
                printf '  %-27s battery — %s %s%%%s\n' "$name" "${st:-?}" "${cap:-?}" "${man:+  ($man ${mod})}"
                ;;
            Mains)
                on=$(_val "ps.$i.online" "$p_block")
                printf '  %-27s AC (Mains) — %s\n' "$name" "$([ "$on" = 1 ] && echo online || echo offline)"
                ;;
            USB)
                on=$(_val "ps.$i.online" "$p_block")
                printf '  %-27s USB-C PD — %s\n' "$name" "$([ "$on" = 1 ] && echo online || echo offline)"
                ;;
            *)
                printf '  %-27s %s\n' "$name" "$typ"
                ;;
        esac
    done
    if hw::has_battery; then
        ui::kv "On AC" "$(hw::on_ac && echo yes || echo 'no (on battery)')"
    fi
fi

# ---- Backlight ---------------------------------------------------------------
ui::section "Backlight"
b_block=$(hw::backlights)
b_idx=$(_indices bl "$b_block")
if [ -z "$b_idx" ]; then
    log::info "no backlight devices (external display only, or none exposed)"
else
    for i in $b_idx; do
        name=$(_val "bl.$i.name" "$b_block")
        typ=$(_val "bl.$i.type" "$b_block")
        cur=$(_val "bl.$i.brightness" "$b_block"); max=$(_val "bl.$i.max_brightness" "$b_block")
        pct=""
        if [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
            pct="$(( cur * 100 / max ))%  "
        fi
        printf '  %-20s %-9s %s(%s/%s)\n' "$name" "$typ" "$pct" "${cur:-?}" "${max:-?}"
    done
fi

# ---- Displays ---------------------------------------------------------------
ui::section "Displays (DRM connectors)"
d_block=$(hw::drm_connectors)
d_idx=$(_indices drm "$d_block")
if [ -z "$d_idx" ]; then
    log::info "no DRM connectors exposed by sysfs"
else
    disconnected=""
    for i in $d_idx; do
        conn=$(_val "drm.$i.connector" "$d_block")
        st=$(_val "drm.$i.status" "$d_block")
        if [ "$st" != connected ] && [ -z "$VERBOSE" ]; then
            disconnected="${disconnected:+$disconnected, }$conn"
            continue
        fi
        en=$(_val "drm.$i.enabled" "$d_block")
        mode=$(_val "drm.$i.preferred_mode" "$d_block")
        card=$(_val "drm.$i.card" "$d_block")
        pci=$(_val "drm.$i.pci" "$d_block")
        printf '  %-14s %s, %s%s   (%s%s)\n' \
            "$conn" "$st" "$en" "${mode:+   preferred $mode}" "$card" "${pci:+ / $pci}"
    done
    [ -n "$disconnected" ] && printf '  %s\n' "disconnected: $disconnected   (--verbose to detail)"
fi

# ---- Base tools ----------------------------------------------------------
ui::section "Base tools"
_tool bash
_tool git
_tool python3
_tool jq            "used by parts of infinite-desktop"
_tool lspci         "sys-apps/pciutils"
_tool lscpu         "sys-apps/util-linux"
_tool hyprctl       "the Hyprland compositor"
_tool qs            "Quickshell"
_tool hypridle
_tool hyprlock
_tool mako          "notification daemon"
_tool brightnessctl "backlight control for keybinds"
_tool upower        "battery/power D-Bus service (bar battery widget)"
_tool fuzzel        "app launcher (Super+Space)"
_tool grim          "screenshot capture"
_tool slurp         "region select for screenshots"
_tool wl-copy       "Wayland clipboard (gui-apps/wl-clipboard)"
_tool wpctl         "PipeWire / WirePlumber"
_tool pipewire
_tool emerge        "Gentoo package manager"
_tool eselect       "Gentoo overlay / profile management"
if command -v nvidia-smi >/dev/null 2>&1; then
    ui::kv "nvidia-smi" "$(command -v nvidia-smi)   (present; NOT run by check)"
else
    ui::kv "nvidia-smi" "not found"
fi

printf '\n'
log::ok "check complete — read-only, nothing was changed"
