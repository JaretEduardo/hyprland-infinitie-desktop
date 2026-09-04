# lib/hardware.sh — read-only hardware detection.
#
# Sourced by install/common.sh consumers (check, doctor, gpu, power, first-run).
# Everything here is strictly read-only:
#   - no sudo, no writes to sysfs, no power-state changes
#   - no nvidia-smi, no CUDA/NVML, no device wake-ups
#   - reads only world-readable /proc, /sys and DMI files, plus lspci/lscpu if
#     they happen to be installed (both read-only). Missing hardware, missing
#     files and missing tools are all tolerated silently.
#
# Two kinds of function:
#   getters      hw::cpu_model, hw::machine_vendor, ...   -> one value on stdout
#   booleans     hw::is_systemd, hw::has_nvidia_gpu, ...   -> exit status only
#   enumerators  hw::gpus, hw::net, hw::report, ...        -> machine-readable
#                "section.index.key=value" lines on stdout
#
# Run directly for a full dump:  bash lib/hardware.sh [section]

[ -n "${_LIB_HARDWARE_SH:-}" ] && return 0
_LIB_HARDWARE_SH=1

# --- low-level helpers -------------------------------------------------------

# _hw::readf <file> : first line of a file, trailing whitespace trimmed, or
# nothing. Never errors (unreadable / missing / binary all yield "").
_hw::readf() {
    local f="$1" v=""
    [ -r "$f" ] || return 0
    IFS= read -r v < "$f" 2>/dev/null || true
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# _hw::match <enumerator> <ERE> : run an enumerator, test its output against a
# regex. Uses a here-string, not a pipe, to dodge the `producer | grep -q`
# SIGPIPE + `set -o pipefail` false negative.
_hw::match() {
    local fn="$1" re="$2" out
    out=$("$fn") || true
    grep -Eq "$re" <<<"$out"
}

# _hw::has <cmd> : is an external tool available?
_hw::has() { command -v "$1" >/dev/null 2>&1; }

# _hw::vendor_name <hex id, with or without 0x> : coarse PCI vendor name, "" if unknown
_hw::vendor_name() {
    case "${1#0x}" in
        1002) printf 'AMD/ATI' ;;
        10de) printf 'NVIDIA' ;;
        8086|8087) printf 'Intel' ;;
        1022) printf 'AMD' ;;
        14c3) printf 'MediaTek' ;;
        10ec) printf 'Realtek' ;;
        168c) printf 'Qualcomm Atheros' ;;
        17cb) printf 'Qualcomm' ;;
        1969) printf 'Qualcomm Atheros' ;;
        14e4) printf 'Broadcom' ;;
        *) printf '' ;;
    esac
}

# _hw::chassis_name <dmi chassis_type number> : human label, or the number back
_hw::chassis_name() {
    case "$1" in
        3) printf 'desktop' ;; 4) printf 'low-profile-desktop' ;;
        5) printf 'pizza-box' ;; 6) printf 'mini-tower' ;; 7) printf 'tower' ;;
        8) printf 'portable' ;; 9) printf 'laptop' ;; 10) printf 'notebook' ;;
        11) printf 'handheld' ;; 13) printf 'all-in-one' ;; 14) printf 'sub-notebook' ;;
        30) printf 'tablet' ;; 31) printf 'convertible' ;; 32) printf 'detachable' ;;
        *) printf '%s' "$1" ;;
    esac
}

# --- machine / firmware ----------------------------------------------------

hw::machine_vendor() { _hw::readf /sys/class/dmi/id/sys_vendor; }
hw::machine_model()  { _hw::readf /sys/class/dmi/id/product_name; }

hw::machine() {
    local d=/sys/class/dmi/id ct
    printf 'machine.vendor=%s\n'          "$(_hw::readf "$d/sys_vendor")"
    printf 'machine.product_name=%s\n'    "$(_hw::readf "$d/product_name")"
    printf 'machine.product_version=%s\n' "$(_hw::readf "$d/product_version")"
    printf 'machine.board_vendor=%s\n'    "$(_hw::readf "$d/board_vendor")"
    printf 'machine.board_name=%s\n'      "$(_hw::readf "$d/board_name")"
    printf 'machine.bios_vendor=%s\n'     "$(_hw::readf "$d/bios_vendor")"
    printf 'machine.bios_version=%s\n'    "$(_hw::readf "$d/bios_version")"
    printf 'machine.bios_date=%s\n'       "$(_hw::readf "$d/bios_date")"
    ct=$(_hw::readf "$d/chassis_type")
    printf 'machine.chassis_type=%s\n'    "$ct"
    printf 'machine.chassis=%s\n'         "$(_hw::chassis_name "$ct")"
    return 0
}

# --- cpu -----------------------------------------------------------------------

hw::cpu_model() { awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true; }

hw::cpu() {
    local cores=""
    printf 'cpu.model=%s\n'  "$(hw::cpu_model)"
    printf 'cpu.vendor=%s\n' "$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    printf 'cpu.arch=%s\n'   "$(uname -m 2>/dev/null || true)"
    printf 'cpu.threads=%s\n' "$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
    if _hw::has lscpu; then
        cores=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | grep -c . || true)
    fi
    [ -n "$cores" ] && [ "$cores" != "0" ] && printf 'cpu.cores=%s\n' "$cores"
    return 0
}

# --- os / init ---------------------------------------------------------------

hw::os_id()     { ( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" ); }
hw::os_pretty() { ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}" ); }
hw::kernel()    { uname -r 2>/dev/null || true; }

hw::is_systemd() { [ -d /run/systemd/system ]; }

hw::init_system() {
    if [ -d /run/systemd/system ]; then
        printf 'systemd'
    else
        local c; c=$(ps -p 1 -o comm= 2>/dev/null || true)
        printf '%s' "${c:-unknown}"
    fi
}

hw::os() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release 2>/dev/null
          printf 'os.id=%s\n'          "${ID:-}"
          printf 'os.id_like=%s\n'     "${ID_LIKE:-}"
          printf 'os.pretty_name=%s\n' "${PRETTY_NAME:-}"
          printf 'os.version_id=%s\n'  "${VERSION_ID:-}" )
    fi
    printf 'os.kernel=%s\n'      "$(hw::kernel)"
    printf 'os.kernel_arch=%s\n' "$(uname -m 2>/dev/null || true)"
    printf 'os.init=%s\n'        "$(hw::init_system)"
    printf 'os.libc=%s\n'        "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    return 0
}

# --- GPUs ------------------------------------------------------------------

# _hw::gpu_class_vendor <vendor hex> : amd|nvidia|intel|other
_hw::gpu_vendor_tag() {
    case "${1#0x}" in
        1002) printf 'amd' ;;
        10de) printf 'nvidia' ;;
        8086) printf 'intel' ;;
        *) printf 'other' ;;
    esac
}

# _hw::gpu_desc <pci addr> <vendor hex> <device hex>
_hw::gpu_desc() {
    local addr="$1" ven="$2" dev="$3" desc=""
    if _hw::has lspci; then
        desc=$(lspci -mm -s "$addr" 2>/dev/null | awk -F'"' '{print $4" "$6}')
        desc=$(printf '%s' "$desc" | sed 's/  */ /g; s/^ //; s/ $//')
    fi
    if [ -z "$desc" ]; then
        desc="$(_hw::vendor_name "$ven") ${dev}"
        desc=$(printf '%s' "$desc" | sed 's/^ //')
    fi
    printf '%s' "$desc"
}

# Iterate PCI display controllers (class 0x03xxxx). Independent of card0/card1.
hw::gpus() {
    local i=0 d addr class ven dev sven sdev drv card render bootvga
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] || continue
        class=$(_hw::readf "$d/class")
        case "$class" in 0x03*) ;; *) continue ;; esac
        addr=${d##*/}
        ven=$(_hw::readf "$d/vendor")
        dev=$(_hw::readf "$d/device")
        sven=$(_hw::readf "$d/subsystem_vendor")
        sdev=$(_hw::readf "$d/subsystem_device")
        drv=""
        [ -L "$d/driver" ] && drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true)
        bootvga=$(_hw::readf "$d/boot_vga")
        card="/dev/dri/by-path/pci-$addr-card"
        render="/dev/dri/by-path/pci-$addr-render"

        printf 'gpu.%d.pci=%s\n'              "$i" "$addr"
        printf 'gpu.%d.vendor_id=%s\n'        "$i" "$ven"
        printf 'gpu.%d.device_id=%s\n'        "$i" "$dev"
        printf 'gpu.%d.subsystem_vendor=%s\n' "$i" "$sven"
        printf 'gpu.%d.subsystem_device=%s\n' "$i" "$sdev"
        printf 'gpu.%d.vendor=%s\n'           "$i" "$(_hw::gpu_vendor_tag "$ven")"
        printf 'gpu.%d.class=%s\n'            "$i" "$class"
        printf 'gpu.%d.driver=%s\n'           "$i" "${drv:-none}"
        printf 'gpu.%d.boot_vga=%s\n'         "$i" "${bootvga:-0}"
        [ -e "$card" ]   && printf 'gpu.%d.dri_card=%s\n'   "$i" "$card"
        [ -e "$render" ] && printf 'gpu.%d.dri_render=%s\n' "$i" "$render"
        printf 'gpu.%d.desc=%s\n'             "$i" "$(_hw::gpu_desc "$addr" "$ven" "$dev")"
        i=$((i + 1))
    done
    return 0
}

hw::has_nvidia_gpu() { _hw::match hw::gpus '\.vendor=nvidia$'; }
hw::has_amd_gpu()    { _hw::match hw::gpus '\.vendor=amd$'; }
hw::has_intel_gpu()  { _hw::match hw::gpus '\.vendor=intel$'; }

# PCI address of the primary GPU: the one with boot_vga=1, else the first
# enumerated, else nothing.
hw::primary_gpu_pci() {
    local out pci
    out=$(hw::gpus) || true
    pci=$(awk -F. '
        /\.pci=/        { split($0, a, "="); p[$2] = a[2] }
        /\.boot_vga=1$/ { print p[$2]; found=1; exit }
        END             { if (!found && p[0] != "") print p[0] }
    ' <<<"$out")
    printf '%s' "$pci"
}

# --- network interfaces --------------------------------------------------------

# Physical + virtual interfaces (loopback excluded). MAC addresses are
# deliberately not reported. wifi vs ethernet from sysfs, not the name.
hw::net() {
    local i=0 n ifn typ drv oper speed devreal bus
    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue
        ifn=${n##*/}
        [ "$ifn" = "lo" ] && continue

        if [ ! -e "$n/device" ]; then
            typ=virtual
        elif [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; then
            typ=wifi
        else
            typ=ethernet
        fi

        drv=""
        [ -L "$n/device/driver" ] && drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null || true)
        oper=$(_hw::readf "$n/operstate")
        speed=$(_hw::readf "$n/speed")   # often "-1" or errors while the link is down

        bus=""
        if [ -L "$n/device" ]; then
            devreal=$(readlink -f "$n/device" 2>/dev/null || true)
            case "$devreal" in
                *0000:*) bus="pci:$(basename "$devreal")" ;;
                */usb*)  bus="usb" ;;
            esac
        fi

        printf 'net.%d.name=%s\n'   "$i" "$ifn"
        printf 'net.%d.type=%s\n'   "$i" "$typ"
        printf 'net.%d.driver=%s\n' "$i" "${drv:-none}"
        printf 'net.%d.state=%s\n'  "$i" "${oper:-unknown}"
        [ -n "$bus" ] && printf 'net.%d.bus=%s\n' "$i" "$bus"
        case "$speed" in ''|-1) ;; *) printf 'net.%d.speed_mbps=%s\n' "$i" "$speed" ;; esac
        i=$((i + 1))
    done
    return 0
}

# --- power supplies (batteries + AC/USB-C adapters) --------------------------

hw::power_supplies() {
    local i=0 p name typ
    for p in /sys/class/power_supply/*; do
        [ -e "$p" ] || continue
        name=${p##*/}
        typ=$(_hw::readf "$p/type")
        printf 'ps.%d.name=%s\n' "$i" "$name"
        printf 'ps.%d.type=%s\n' "$i" "${typ:-Unknown}"
        [ -r "$p/online" ]        && printf 'ps.%d.online=%s\n'       "$i" "$(_hw::readf "$p/online")"
        [ -r "$p/status" ]        && printf 'ps.%d.status=%s\n'       "$i" "$(_hw::readf "$p/status")"
        [ -r "$p/capacity" ]      && printf 'ps.%d.capacity=%s\n'     "$i" "$(_hw::readf "$p/capacity")"
        [ -r "$p/capacity_level" ] && printf 'ps.%d.capacity_level=%s\n' "$i" "$(_hw::readf "$p/capacity_level")"
        [ -r "$p/manufacturer" ]  && printf 'ps.%d.manufacturer=%s\n' "$i" "$(_hw::readf "$p/manufacturer")"
        [ -r "$p/model_name" ]    && printf 'ps.%d.model=%s\n'        "$i" "$(_hw::readf "$p/model_name")"
        i=$((i + 1))
    done
    return 0
}

hw::has_battery() { _hw::match hw::power_supplies '\.type=Battery$'; }

# true if any Mains/USB power supply currently reports online=1
hw::on_ac() {
    local out; out=$(hw::power_supplies) || true
    awk -F. '
        /\.type=Mains$/ || /\.type=USB$/ { mains[$2]=1 }
        /\.online=1$/ { if (mains[$2]) ok=1 }
        END { exit ok?0:1 }
    ' <<<"$out"
}

# --- backlight devices -------------------------------------------------------

hw::backlights() {
    local i=0 b name
    for b in /sys/class/backlight/*; do
        [ -e "$b" ] || continue
        name=${b##*/}
        printf 'bl.%d.name=%s\n'           "$i" "$name"
        printf 'bl.%d.type=%s\n'           "$i" "$(_hw::readf "$b/type")"
        printf 'bl.%d.brightness=%s\n'     "$i" "$(_hw::readf "$b/brightness")"
        printf 'bl.%d.max_brightness=%s\n' "$i" "$(_hw::readf "$b/max_brightness")"
        i=$((i + 1))
    done
    return 0
}

# --- DRM connectors / monitors ---------------------------------------------

hw::drm_connectors() {
    local i=0 c base conn cardnode pci status enabled dpms mode
    for c in /sys/class/drm/card*-*; do
        [ -e "$c/status" ] || continue
        base=${c##*/}                 # e.g. card1-eDP-1
        cardnode=${base%%-*}          # card1
        conn=${base#"${cardnode}"-}   # eDP-1
        case "$conn" in Writeback-*) continue ;; esac
        status=$(_hw::readf "$c/status")
        enabled=$(_hw::readf "$c/enabled")
        dpms=$(_hw::readf "$c/dpms")
        mode=""
        [ -r "$c/modes" ] && IFS= read -r mode < "$c/modes" 2>/dev/null || true
        pci=""
        [ -L "/sys/class/drm/$cardnode/device" ] && \
            pci=$(basename "$(readlink -f "/sys/class/drm/$cardnode/device" 2>/dev/null)" 2>/dev/null || true)

        printf 'drm.%d.connector=%s\n' "$i" "$conn"
        printf 'drm.%d.card=%s\n'      "$i" "$cardnode"
        [ -n "$pci" ] && case "$pci" in 0000:*) printf 'drm.%d.pci=%s\n' "$i" "$pci" ;; esac
        printf 'drm.%d.status=%s\n'    "$i" "${status:-unknown}"
        printf 'drm.%d.enabled=%s\n'   "$i" "${enabled:-unknown}"
        [ -n "$dpms" ] && printf 'drm.%d.dpms=%s\n' "$i" "$dpms"
        [ -n "$mode" ] && printf 'drm.%d.preferred_mode=%s\n' "$i" "$mode"
        i=$((i + 1))
    done
    return 0
}

# --- aggregate -------------------------------------------------------------

hw::report() {
    hw::machine
    hw::cpu
    hw::os
    hw::gpus
    hw::net
    hw::power_supplies
    hw::backlights
    hw::drm_connectors
    return 0
}

# --- direct execution ------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-report}" in
        machine|cpu|os|gpus|net|power_supplies|backlights|drm_connectors|report)
            "hw::${1:-report}" ;;
        *)
            printf 'usage: %s [machine|cpu|os|gpus|net|power_supplies|backlights|drm_connectors|report]\n' "$0" >&2
            exit 2 ;;
    esac
fi
