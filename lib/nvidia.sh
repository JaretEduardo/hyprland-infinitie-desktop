# lib/nvidia.sh — power-aware, read-only NVIDIA observation.
#
# STRICTLY READ-ONLY. This library never writes sysfs, never changes
# power/control or modeset, never (un)loads modules, never kills processes,
# never sudo.
#
# Two probe levels, kept explicitly separate:
#
#   nvidia::probe_nowake / nvidia::json_nowake
#       Safe to call repeatedly and automatically. Reads ONLY sources that do
#       not open or touch the NVIDIA device:
#         /sys/bus/pci/devices/<addr>/{power/*,power_state,d3cold_allowed,driver}
#         /sys/module/nvidia*/{version,refcnt,...}
#         /sys/module/nvidia_drm/parameters/modeset
#         modinfo (reads the .ko file, not the device)
#         /proc/<pid>/fd/* symlink targets (best-effort client scan)
#       It NEVER runs nvidia-smi, CUDA, NVML, or anything that opens
#       /dev/nvidia*.
#
#   nvidia::probe_deep
#       WAKE-CAPABLE. Runs nvidia-smi, which powers the GPU on if it is in
#       RTD3. Must only ever be called from an explicit, user-initiated action.
#       Not wired into doctor, Quickshell, or any automatic path.
#
# The NVIDIA GPU and its PCI address are discovered via lib/hardware.sh —
# nothing here is hardcoded to a specific bus address or PCI ID.
#
# Run directly:  bash lib/nvidia.sh [probe_nowake|json_nowake|clients|probe_deep]

[ -n "${_LIB_NVIDIA_SH:-}" ] && return 0
_LIB_NVIDIA_SH=1

if [ -z "${_LIB_HARDWARE_SH:-}" ]; then
    if [ -n "${INSTALL_REPO_DIR:-}" ]; then
        # shellcheck source=lib/hardware.sh
        . "$INSTALL_REPO_DIR/lib/hardware.sh"
    else
        # shellcheck source=lib/hardware.sh
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hardware.sh"
    fi
fi

# --- discovery (cached) ---------------------------------------------------

_nv::discover_pci() {
    local out; out=$(hw::gpus) || true
    awk -F. '
        /\.pci=/           { split($0, a, "="); p[$2] = a[2] }
        /\.vendor=nvidia$/ { if (p[$2] != "") { print p[$2]; exit } }
    ' <<<"$out"
}

# nvidia::pci  -> PCI address of the NVIDIA GPU, or empty. Cached.
nvidia::pci() {
    if [ -z "${_NV_PCI+x}" ]; then
        _NV_PCI=$(_nv::discover_pci)
    fi
    printf '%s' "$_NV_PCI"
}

nvidia::present() { [ -n "$(nvidia::pci)" ]; }

# absolute /sys path of the PCI device, or empty
_nv::devdir() {
    local pci; pci=$(nvidia::pci)
    [ -n "$pci" ] || return 0
    printf '/sys/bus/pci/devices/%s' "$pci"
}

# --- individual no-wake getters -----------------------------------------

nvidia::driver() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || return 0
    [ -L "$d/driver" ] || { printf 'none'; return 0; }
    basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || printf 'none'
}

# Runtime PM state (from the PM core: active|suspended|suspending|resuming).
# This is NOT the PCI power state.
nvidia::runtime_pm_state() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || { printf 'unknown'; return 0; }
    local v; v=$(_hw::readf "$d/power/runtime_status")
    printf '%s' "${v:-unknown}"
}

# PCI power state (from dev->current_state cache: D0|D3hot|D3cold|unknown).
# Separate from runtime PM. Only this can confirm D3cold.
nvidia::pci_power_state() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || { printf 'unknown'; return 0; }
    local v; v=$(_hw::readf "$d/power_state")
    case "$v" in
        D0|D1|D2|D3hot|D3cold) printf '%s' "$v" ;;
        *) printf 'unknown' ;;
    esac
}

# true only when the PCI power state genuinely reads D3cold
nvidia::d3cold_confirmed() { [ "$(nvidia::pci_power_state)" = D3cold ]; }

nvidia::power_control() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || { printf 'unknown'; return 0; }
    local v; v=$(_hw::readf "$d/power/control")
    printf '%s' "${v:-unknown}"
}

nvidia::d3cold_allowed() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || { printf 'unknown'; return 0; }
    local v; v=$(_hw::readf "$d/d3cold_allowed")
    printf '%s' "${v:-unknown}"
}

nvidia::runtime_suspended_time_ms() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || return 0
    _hw::readf "$d/power/runtime_suspended_time"
}

nvidia::runtime_active_time_ms() {
    local d; d=$(_nv::devdir); [ -n "$d" ] || return 0
    _hw::readf "$d/power/runtime_active_time"
}

# Driver/module version WITHOUT nvidia-smi: /sys/module first, then modinfo
# (which reads the .ko file, not the device).
nvidia::module_version() {
    local v; v=$(_hw::readf /sys/module/nvidia/version)
    if [ -z "$v" ] && command -v modinfo >/dev/null 2>&1; then
        v=$(modinfo -F version nvidia 2>/dev/null | head -n1)
    fi
    printf '%s' "$v"
}

nvidia::modules_loaded() {
    local m
    for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm nvidia_peermem; do
        [ -d "/sys/module/$m" ] && printf '%s\n' "$m"
    done
    return 0
}

# Informational only. NOT a process count and NOT a client count.
nvidia::module_refcnt() { _hw::readf /sys/module/nvidia/refcnt; }

# nvidia_drm modeset (Y|N|unknown). The sysfs parameter is root-readable only,
# so fall back to the kernel command line, which is world-readable.
nvidia::modeset() {
    local v; v=$(_hw::readf /sys/module/nvidia_drm/parameters/modeset)
    case "$v" in
        Y|1) printf 'Y'; return 0 ;;
        N|0) printf 'N'; return 0 ;;
    esac
    if [ -r /proc/cmdline ]; then
        case " $(cat /proc/cmdline) " in
            *" nvidia-drm.modeset=1 "*|*" nvidia_drm.modeset=1 "*) printf 'Y'; return 0 ;;
            *" nvidia-drm.modeset=0 "*|*" nvidia_drm.modeset=0 "*) printf 'N'; return 0 ;;
        esac
    fi
    printf 'unknown'
}

# Detected NVIDIA clients — BEST-EFFORT, NO-WAKE.
# Scans /proc/<pid>/fd for symlinks into /dev/nvidia*. As a non-root user only
# our own processes' fds are readable, so this UNDER-counts. It is never a
# definitive or complete list of what is holding the GPU awake.
nvidia::clients() {
    command -v find >/dev/null 2>&1 || return 0
    local dir pid comm
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        pid=${dir#/proc/}; pid=${pid%/fd}
        comm=$(_hw::readf "/proc/$pid/comm")
        printf '%s\t%s\n' "$pid" "${comm:-?}"
    done < <(
        find /proc/[0-9]*/fd -maxdepth 1 -type l \
            \( -lname '/dev/nvidia'        -o -lname '/dev/nvidia[0-9]*' \
            -o -lname '/dev/nvidiactl'     -o -lname '/dev/nvidia-uvm*'  \
            -o -lname '/dev/nvidia-modeset' -o -lname '/dev/nvidia-caps/*' \) \
            -printf '%h\n' 2>/dev/null | sort -u
    )
    return 0
}

# --- aggregate: machine-readable, no-wake -------------------------------

nvidia::probe_nowake() {
    if ! nvidia::present; then
        printf 'nvidia.present=false\n'
        return 0
    fi
    local rpm pcs
    rpm=$(nvidia::runtime_pm_state)
    pcs=$(nvidia::pci_power_state)

    printf 'nvidia.present=true\n'
    printf 'nvidia.pci=%s\n'                       "$(nvidia::pci)"
    printf 'nvidia.driver=%s\n'                    "$(nvidia::driver)"
    printf 'nvidia.runtime_pm_state=%s\n'          "$rpm"
    printf 'nvidia.pci_power_state=%s\n'           "$pcs"
    printf 'nvidia.d3cold_confirmed=%s\n'          "$([ "$pcs" = D3cold ] && echo true || echo false)"
    printf 'nvidia.power_control=%s\n'             "$(nvidia::power_control)"
    printf 'nvidia.d3cold_allowed=%s\n'            "$(nvidia::d3cold_allowed)"
    printf 'nvidia.runtime_suspended_time_ms=%s\n' "$(nvidia::runtime_suspended_time_ms)"
    printf 'nvidia.runtime_active_time_ms=%s\n'    "$(nvidia::runtime_active_time_ms)"
    printf 'nvidia.module_version=%s\n'            "$(nvidia::module_version)"
    printf 'nvidia.module_refcnt=%s\n'             "$(nvidia::module_refcnt)"
    printf 'nvidia.modeset=%s\n'                   "$(nvidia::modeset)"
    printf 'nvidia.modules_loaded=%s\n'            "$(nvidia::modules_loaded | paste -sd, - 2>/dev/null)"

    local clients n
    clients=$(nvidia::clients)
    n=$(printf '%s' "$clients" | grep -c . || true)
    printf 'nvidia.clients_detected=%s\n' "$n"
    printf 'nvidia.clients_note=best-effort; non-root fd scan under-counts\n'
    if [ -n "$clients" ]; then
        while IFS=$'\t' read -r p c; do
            [ -n "$p" ] && printf 'nvidia.client.%s=%s\n' "$p" "$c"
        done <<<"$clients"
    fi
    return 0
}

# --- aggregate: JSON, no-wake ------------------------------------------

_nv::jnum() { case "${1:-}" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

nvidia::json_nowake() {
    if ! nvidia::present; then
        printf '{"present":false}\n'
        return 0
    fi
    local rpm pcs mods clients arr p c
    rpm=$(nvidia::runtime_pm_state)
    pcs=$(nvidia::pci_power_state)
    mods=$(nvidia::modules_loaded | sed 's/.*/"&"/' | paste -sd, - 2>/dev/null)
    clients=$(nvidia::clients)

    arr=""
    if [ -n "$clients" ]; then
        while IFS=$'\t' read -r p c; do
            [ -n "$p" ] || continue
            arr="${arr:+$arr,}{\"pid\":${p},\"comm\":\"${c}\"}"
        done <<<"$clients"
    fi

    printf '{'
    printf '"present":true'
    printf ',"pci":"%s"'                       "$(nvidia::pci)"
    printf ',"driver":"%s"'                    "$(nvidia::driver)"
    printf ',"runtime_pm_state":"%s"'          "$rpm"
    printf ',"pci_power_state":"%s"'           "$pcs"
    printf ',"d3cold_confirmed":%s'            "$([ "$pcs" = D3cold ] && echo true || echo false)"
    printf ',"power_control":"%s"'             "$(nvidia::power_control)"
    printf ',"d3cold_allowed":"%s"'            "$(nvidia::d3cold_allowed)"
    printf ',"runtime_suspended_time_ms":%s'   "$(_nv::jnum "$(nvidia::runtime_suspended_time_ms)")"
    printf ',"runtime_active_time_ms":%s'      "$(_nv::jnum "$(nvidia::runtime_active_time_ms)")"
    printf ',"module_version":"%s"'            "$(nvidia::module_version)"
    printf ',"module_refcnt":%s'              "$(_nv::jnum "$(nvidia::module_refcnt)")"
    printf ',"modeset":"%s"'                   "$(nvidia::modeset)"
    printf ',"modules_loaded":[%s]'            "$mods"
    printf ',"clients_detected":%s'            "$(printf '%s' "$clients" | grep -c . || true)"
    printf ',"clients_note":"best-effort; non-root fd scan under-counts"'
    printf ',"clients":[%s]'                   "$arr"
    printf '}\n'
}

# --- deep probe (WAKE-CAPABLE — never call automatically) --------------

nvidia::deep_available() { command -v nvidia-smi >/dev/null 2>&1; }

# nvidia::probe_deep — WAKE-CAPABLE. Runs nvidia-smi; if the GPU is in RTD3
# this powers it on. Only for an explicit user action. Prints a warning first.
nvidia::probe_deep() {
    printf 'nvidia.deep.WARNING=nvidia-smi was run; this may have powered on the GPU\n'
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf 'nvidia.deep.error=nvidia-smi not found\n'
        return 1
    fi
    nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,clocks.sm,power.draw,pstate \
        --format=csv,noheader,nounits 2>/dev/null \
      | awk -F', *' 'NR==1{
            print "nvidia.deep.name="            $1
            print "nvidia.deep.temp_c="          $2
            print "nvidia.deep.util_pct="        $3
            print "nvidia.deep.mem_used_mib="    $4
            print "nvidia.deep.mem_total_mib="   $5
            print "nvidia.deep.clock_sm_mhz="    $6
            print "nvidia.deep.power_draw_w="    $7
            print "nvidia.deep.pstate="          $8
        }'
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null \
      | awk -F', *' 'NF{ print "nvidia.deep.proc." $1 "=" $2 " (" $3 " MiB)" }'
    return 0
}

# --- direct execution -------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _nv_arg="${1:-probe_nowake}"
    case "$_nv_arg" in
        probe_nowake|json_nowake|clients|probe_deep)
            "nvidia::${_nv_arg}" ;;
        *)
            printf 'usage: %s [probe_nowake|json_nowake|clients|probe_deep]\n' "$0" >&2
            printf '  probe_deep is WAKE-CAPABLE (runs nvidia-smi)\n' >&2
            exit 2 ;;
    esac
fi
