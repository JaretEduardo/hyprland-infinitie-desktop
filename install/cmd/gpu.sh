#!/usr/bin/env bash
#
# install.sh gpu — hybrid AMD + NVIDIA / RTD3 configuration.
#
#   install.sh gpu              detect + explain + show the proposed changes (read-only)
#   install.sh gpu --apply      apply, one change at a time, after confirmation
#   install.sh gpu --dry-run    like the default (never writes)
#
# What it configures (only what the driver package does NOT provide):
#   - a udev rule giving stable /dev/dri/hypr-{primary,secondary} symlinks so
#     Hyprland's AQ_DRM_DEVICES can pin the AMD iGPU as the compositor GPU
#     without hardcoding cardN
#   - /etc/modprobe.d for `nvidia_drm modeset=1`, IF it is not already on
#   - an RTD3 power-management udev rule, ONLY if the driver ships none
#
# What it does NOT touch: the initramfs (never regenerated silently), the
# bootloader, nvidia-persistenced, or any pre-existing file it did not create
# (those are backed up and only replaced after you confirm).
#
set -euo pipefail

if [ -n "${INSTALL_REPO_DIR:-}" ]; then REPO_DIR="$INSTALL_REPO_DIR"
else REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/hardware.sh
. "$REPO_DIR/lib/hardware.sh"
# shellcheck source=lib/nvidia.sh
. "$REPO_DIR/lib/nvidia.sh"

TPL_DIR="$REPO_DIR/config/gpu"
# GPU_SYSROOT redirects the files this command WRITES (for testing against a
# simulated /etc). Detection always reads the real system.
SYSROOT="${GPU_SYSROOT:-}"
DEST_UDEV="$SYSROOT/etc/udev/rules.d"
DEST_MODPROBE="$SYSROOT/etc/modprobe.d"
APPLY=0
DRY="${INSTALL_DRY_RUN:-}"
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --dry-run) DRY=1 ;;
        -*) log::error "gpu: unknown option: $a"; exit 2 ;;
        *)  log::error "gpu: unexpected argument: $a"; exit 2 ;;
    esac
done
[ -n "$DRY" ] && APPLY=0

CHANGES=0      # proposed changes
BLOCKERS=0     # conflicts needing a human

_is_root() { [ "$(id -u)" = 0 ]; }

# _ours <file>  -> 0 if it carries our managed-by marker
_ours() { [ -r "$1" ] && head -n1 "$1" 2>/dev/null | grep -q 'managed by hyprland-infinitie-desktop'; }

# _install_file <rendered-tmp> <dest> <human description>
_install_file() {
    local src="$1" dest="$2" desc="$3"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        ui::kv "$desc" "already applied"
        return 0
    fi
    CHANGES=$((CHANGES + 1))
    printf '\n'
    if [ -f "$dest" ] && ! _ours "$dest"; then
        log::warn "$dest exists and was NOT created by this installer."
        BLOCKERS=$((BLOCKERS + 1))
        printf '  proposed replacement (a .bak backup would be kept):\n'
    elif [ -f "$dest" ]; then
        log::info "$desc: updating our managed file $dest"
        printf '  diff (current -> proposed):\n'
        diff -u "$dest" "$src" 2>/dev/null | sed 's/^/    /' || true
    else
        log::info "$desc: new file $dest"
    fi
    printf '  --- %s ---\n' "$dest"
    sed 's/^/  /' "$src"
    printf '  ------------------------------------------------\n'

    if [ "$APPLY" != 1 ]; then
        return 0
    fi
    if [ -f "$dest" ] && ! _ours "$dest"; then
        ui::confirm "Back up $dest and replace it?" || { log::warn "skipped $dest"; return 0; }
    else
        ui::confirm "Write $dest ?" || { log::warn "skipped $dest"; return 0; }
    fi
    if [ -f "$dest" ] && ! _ours "$dest"; then
        cp -a "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    if ! install -D -m 0644 "$src" "$dest" 2>/dev/null; then
        log::error "could not write $dest (need root?)"
        printf '    sudo install -D -m 0644 %s %s\n' "$src" "$dest" >&2
        return 2
    fi
    log::ok "wrote $dest"
}

# ---------------------------------------------------------------------------
ui::header "Hybrid GPU configuration"
[ "$APPLY" = 1 ] && log::info "--apply: changes will be offered one at a time" \
                 || log::info "read-only plan. Re-run with --apply to make changes."

# ---- 1. topology -----------------------------------------------------------
ui::section "GPU topology"
amd_pci=$(hw::primary_gpu_pci)
nv_pci=$(nvidia::pci)
g=$(hw::gpus)
_desc() { awk -F= -v p="$1" '$0 ~ ("\\.pci=" p "$") {idx=$0; sub(/\.pci=.*/,"",idx)} idx!="" && $0 ~ (idx "\\.desc=") {sub(/^[^=]*=/,""); print; exit}' <<<"$g"; }
ui::kv "AMD (primary)"   "${amd_pci:-?}   $(_desc "$amd_pci")"
if [ -n "$nv_pci" ]; then
    ui::kv "NVIDIA (offload)" "$nv_pci   $(_desc "$nv_pci")   driver $(nvidia::driver)"
    nv_bootvga=$(awk -F= -v p="$nv_pci" '
        $0 ~ ("\\.pci=" p "$")      { i=$1; sub(/\.pci$/,"",i) }
        i!="" && $0 ~ (i "\\.boot_vga=") { sub(/^[^=]*=/,""); print; exit }' <<<"$g")
    if [ "${nv_bootvga:-0}" = 1 ]; then
        log::warn "the NVIDIA GPU is marked boot_vga — it is the primary GPU."
        log::warn "check the BIOS for a 'hybrid' / MSHybrid graphics mode. This installer will not change that."
        BLOCKERS=$((BLOCKERS + 1))
    fi
else
    log::warn "no NVIDIA GPU detected — nothing hybrid to configure."
    exit 0
fi

# ---- 2. AQ_DRM_DEVICES ---------------------------------------------------
ui::section "Hyprland compositor GPU (AQ_DRM_DEVICES)"
AQ_VALUE="/dev/dri/hypr-primary:/dev/dri/hypr-secondary"
ui::kv "recommended value" "$AQ_VALUE"
printf '  Add ONE of these to a hand-written ~/.config/hypr/gpu.local.lua yourself if you\n'
printf '  ever need to override the default (nothing wires it in automatically — without\n'
printf '  one, Aquamarine already auto-selects the boot_vga GPU, which is AMD here):\n'
printf '    hyprlang:  env = AQ_DRM_DEVICES,%s\n' "$AQ_VALUE"
printf '    lua:       hl.env("AQ_DRM_DEVICES", "%s")\n' "$AQ_VALUE"
printf '  AMD first = compositor GPU; NVIDIA listed so its HDMI output still works.\n'
printf '  The stable symlinks come from the udev rule below.\n'

# ---- 3. udev: stable DRM paths -----------------------------------------
ui::section "udev — stable GPU device paths"
tmp_paths=$(mktemp)
sed -e "s|@AMD_PCI@|$amd_pci|" -e "s|@NVIDIA_PCI@|$nv_pci|" \
    "$TPL_DIR/udev/70-hypr-gpu-paths.rules" > "$tmp_paths"
_install_file "$tmp_paths" "$DEST_UDEV/70-hypr-gpu-paths.rules" "stable /dev/dri symlinks"
rm -f "$tmp_paths"

# ---- 4. nvidia_drm modeset --------------------------------------------
ui::section "nvidia_drm modeset"
modeset=$(nvidia::modeset)
existing_ms=$(grep -rlE 'nvidia[_-]drm[[:space:]]+modeset|nvidia-drm\.modeset' /etc/modprobe.d /usr/lib/modprobe.d /proc/cmdline 2>/dev/null | grep -v '70-hypr-gpu-paths' || true)
case "$modeset" in
    Y)  ui::kv "modeset" "Y — already enabled" ;;
    N)  ui::kv "modeset" "N — needs enabling"
        _install_file "$TPL_DIR/modprobe.d/hypr-nvidia.conf" "$DEST_MODPROBE/hypr-nvidia.conf" "nvidia_drm modeset=1"
        log::warn "takes effect after a reboot. This installer does NOT rebuild the initramfs;"
        log::warn "if your setup needs it:  (dracut)  sudo dracut --force    (mkinitcpio)  sudo mkinitcpio -P" ;;
    *)  ui::kv "modeset" "cannot read /sys/module/nvidia_drm/parameters/modeset without root"
        if [ -n "$existing_ms" ]; then
            ui::kv "found" "$existing_ms already references nvidia_drm modeset — assuming handled"
        else
            log::info "no existing modeset config found. The proposed file is safe and idempotent:"
            _install_file "$TPL_DIR/modprobe.d/hypr-nvidia.conf" "$DEST_MODPROBE/hypr-nvidia.conf" "nvidia_drm modeset=1"
            log::warn "verify on the target system:  cat /sys/module/nvidia_drm/parameters/modeset  -> Y"
        fi ;;
esac

# ---- 5. RTD3 power management --------------------------------------
ui::section "RTD3 power management"
driver_pm_rule=$(grep -rlE 'ATTR\{power/control\}|power/control.*auto' \
    /usr/lib/udev/rules.d /lib/udev/rules.d 2>/dev/null | grep -i nvidia | head -n1 || true)
if [ -n "$driver_pm_rule" ]; then
    ui::kv "udev PM rule" "provided by the driver: $driver_pm_rule"
else
    ui::kv "udev PM rule" "not provided by the driver — proposing one"
    _install_file "$TPL_DIR/udev/80-nvidia-rtd3.rules" "$DEST_UDEV/80-nvidia-rtd3.rules" "RTD3 power/control rule"
fi
dpm=$(grep -oE 'DynamicPowerManagement: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}')
if [ -n "$dpm" ]; then
    if [ "$dpm" = 0 ]; then
        log::warn "DynamicPowerManagement is 0 (off). Add to /etc/modprobe.d/hypr-nvidia.conf:"
        printf '    options nvidia NVreg_DynamicPowerManagement=0x02\n'
    else
        ui::kv "DynamicPowerManagement" "$dpm (RTD3 active; driver auto-selected — no modprobe option needed)"
    fi
else
    ui::kv "DynamicPowerManagement" "unreadable here (no /proc/driver/nvidia/params) — verify on Gentoo"
fi
ui::kv "power/control (now)" "$(nvidia::power_control)"
ui::kv "PCI power state (now)" "$(nvidia::pci_power_state)  (D3cold only claimed when power_state says so)"

# ---- 6. suspend / resume ---------------------------------------------
ui::section "suspend / resume"
if command -v systemctl >/dev/null 2>&1; then
    for svc in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
        st=$(systemctl is-enabled "$svc" 2>/dev/null || true); st=${st:-not-installed}
        ui::kv "$svc" "$st"
        [ "$st" = disabled ] && printf '    sudo systemctl enable %s\n' "$svc"
    done
    pd=$(systemctl is-enabled nvidia-persistenced.service 2>/dev/null || true); pd=${pd:-not-installed}
    ui::kv "nvidia-persistenced.service" "$pd  $([ "$pd" = enabled ] && echo '(WARNING: keep DISABLED for ECO / RTD3)')"
else
    log::info "no systemctl here — verify the nvidia sleep services on the target system"
fi

# ---- summary -----------------------------------------------------------
ui::header "Summary"
ui::kv "proposed changes" "$CHANGES"
ui::kv "conflicts / manual" "$BLOCKERS"
printf '\n'
cat <<'EOF'
Requires validation on Gentoo first-run:
  - `cat /sys/module/nvidia_drm/parameters/modeset` returns Y after reboot
  - `grep DynamicPowerManagement /proc/driver/nvidia/params` (0 => add NVreg option)
  - whether x11-drivers/nvidia-drivers already ships the RTD3 udev rule
  - the nvidia-suspend/resume/hibernate services are installed + enabled
  - whether the GPU actually reaches D3cold on this laptop's ACPI (may be D3hot only)
  - a real compute_backend for `nvidia-compute-mode compute` (power-control vs persistenced)
EOF
if [ "$APPLY" != 1 ]; then
    [ "$CHANGES" -gt 0 ] && log::info "re-run with --apply to make the $CHANGES change(s) above"
    log::ok "gpu (plan) complete — nothing was changed"
else
    log::ok "gpu --apply complete"
fi
