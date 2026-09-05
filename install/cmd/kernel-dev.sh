#!/usr/bin/env bash
#
# install.sh kernel-dev — Linux kernel development readiness, detection and
# reproducible command suggestions.
#
# STRICTLY READ-ONLY. There is no --apply and there never will be one on this
# command: it does not run make, does not clone or modify any kernel source
# tree, does not write /boot, does not run make install / modules_install,
# does not touch the bootloader/EFI, does not run dracut/genkernel, does not
# change the /usr/src/linux symlink, and does not reboot. Its entire job is
# to tell you exactly what command YOU would run next, and why.
#
# Reuses lib/hardware.sh (CPU/memory) and install/packages.gentoo (via
# lib/portage.sh, the same way deps.sh/doctor.sh already do) — nothing about
# hardware or the package catalogue is re-detected or re-declared here.
#
#   install.sh kernel-dev             everything below (readiness + env +
#                                      suggested commands)
#   install.sh kernel-dev --check     just the toolchain/tool readiness list
#   install.sh kernel-dev --env       just source tree / output dir / jobs
#   install.sh kernel-dev --commands  just the reproducible command list
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
# shellcheck source=lib/portage.sh
. "$REPO_DIR/lib/portage.sh"

SHOW_CHECK=0 SHOW_ENV=0 SHOW_COMMANDS=0
for a in "$@"; do
    case "$a" in
        --check)    SHOW_CHECK=1 ;;
        --env)      SHOW_ENV=1 ;;
        --commands) SHOW_COMMANDS=1 ;;
        --dry-run)  : ;;   # already read-only; nothing to skip
        -*) log::error "kernel-dev: unknown option: $a"; exit 2 ;;
        *)  log::error "kernel-dev: unexpected argument: $a"; exit 2 ;;
    esac
done
# No section flag given -> show everything.
if [ "$SHOW_CHECK" = 0 ] && [ "$SHOW_ENV" = 0 ] && [ "$SHOW_COMMANDS" = 0 ]; then
    SHOW_CHECK=1 SHOW_ENV=1 SHOW_COMMANDS=1
fi

IS_GENTOO=0
portage::is_gentoo && IS_GENTOO=1

_have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Source tree detection: $KERNEL_SRC, then ~/src/linux, then /usr/src/linux
# (the Gentoo eselect-kernel symlink). Never guessed further than that, never
# written to, never deleted. A directory only counts as a real kernel source
# tree if its own Makefile and Kconfig look like one — a stray empty
# directory at one of these paths is reported honestly, not treated as a hit.
# ---------------------------------------------------------------------------
_valid_kernel_tree() {
    local d="$1"
    [ -d "$d" ] || return 1
    [ -f "$d/Makefile" ] || return 1
    [ -f "$d/Kconfig" ] || return 1
    grep -q '^VERSION = ' "$d/Makefile" 2>/dev/null
}

_kernel_tree_version() {
    local d="$1" v p
    v=$(awk -F'= ' '/^VERSION = /{print $2; exit}' "$d/Makefile" 2>/dev/null)
    p=$(awk -F'= ' '/^PATCHLEVEL = /{print $2; exit}' "$d/Makefile" 2>/dev/null)
    [ -n "$v" ] && printf '%s.%s' "$v" "${p:-0}"
}

# Populates KTREE_CANDIDATES (label|path|valid) in priority order.
KTREE_CANDIDATES=()
[ -n "${KERNEL_SRC:-}" ] && KTREE_CANDIDATES+=("\$KERNEL_SRC|$KERNEL_SRC")
KTREE_CANDIDATES+=("~/src/linux|$HOME/src/linux")
KTREE_CANDIDATES+=("/usr/src/linux (Gentoo eselect-kernel symlink)|/usr/src/linux")

KTREE_CHOSEN_LABEL=""
KTREE_CHOSEN_PATH=""
for entry in "${KTREE_CANDIDATES[@]+"${KTREE_CANDIDATES[@]}"}"; do
    label="${entry%%|*}"; path="${entry#*|}"
    if _valid_kernel_tree "$path" && [ -z "$KTREE_CHOSEN_PATH" ]; then
        KTREE_CHOSEN_LABEL="$label"
        KTREE_CHOSEN_PATH="$path"
    fi
done

# Output dir: OUT-OF-TREE build (O=), never written into the source tree.
BUILD_DIR="${KERNEL_BUILD_DIR:-$HOME/build/linux}"

# Running kernel / existing config sources.
RUNNING_KERNEL="$(hw::kernel)"
MODULES_BUILD_DIR="/lib/modules/$RUNNING_KERNEL/build"
HAS_IKCONFIG=0; [ -r /proc/config.gz ] && HAS_IKCONFIG=1
BOOT_CONFIG="/boot/config-$RUNNING_KERNEL"
HAS_BOOT_CONFIG=0; [ -r "$BOOT_CONFIG" ] && HAS_BOOT_CONFIG=1
TREE_HAS_DOTCONFIG=0
[ -n "$KTREE_CHOSEN_PATH" ] && [ -r "$KTREE_CHOSEN_PATH/.config" ] && TREE_HAS_DOTCONFIG=1
OUT_HAS_DOTCONFIG=0
[ -r "$BUILD_DIR/.config" ] && OUT_HAS_DOTCONFIG=1

# Parallelism: conservative, memory-aware — never just nproc.
CORES="$(awk -F= '/^cpu.cores=/{print $2; exit}' <<<"$(hw::cpu)")"
THREADS="$(nproc 2>/dev/null || echo "$CORES")"
RAM_GB="$(hw::mem_total_gb)"
if [ -n "$CORES" ] && [ -n "$RAM_GB" ] && [ "$RAM_GB" -gt 0 ] 2>/dev/null; then
    MEM_JOBS=$(( RAM_GB / 2 ))
    [ "$MEM_JOBS" -lt 1 ] && MEM_JOBS=1
    RECOMMENDED_JOBS=$(( CORES < MEM_JOBS ? CORES : MEM_JOBS ))
    JOBS_REASON="~${RAM_GB} GB RAM / ${CORES} physical cores (${THREADS} threads) -> min(cores, RAM_GB/2) = $RECOMMENDED_JOBS. A GCC/Clang compile unit can peak past 1 GB RSS with debug info (BTF/DWARF) enabled; capping below thread count leaves headroom for the rest of the desktop and avoids swap thrashing. Watch \`free -h\` during your first build on this tree and raise it if memory stays idle."
else
    RECOMMENDED_JOBS=2
    JOBS_REASON="CPU core count or RAM size could not be read here — defaulting to a minimal -j2. Re-run this on the real target for a real recommendation."
fi

# ---------------------------------------------------------------------------
ui::header "Kernel development"

# ===========================================================================
if [ "$SHOW_CHECK" = 1 ]; then
ui::section "Kernel development readiness"

_tool_line() {
    local bin="$1" note="${2:-}"
    if _have "$bin"; then
        printf '  %s[OK]%s    %s\n' "${_C_GREEN:-}" "${_C_RESET:-}" "$bin"
    else
        printf '  %s[WARN]%s  %s missing%s\n' "${_C_YELLOW:-}" "${_C_RESET:-}" "$bin" "${note:+  ($note)}"
    fi
}

log::info "Core build tools:"
_tool_line git
_tool_line make
_tool_line gcc
_tool_line bc          "kernel Kconfig arithmetic"
_tool_line flex
_tool_line bison
printf '\n'
log::info "Clang/LLVM toolchain (optional — for CC=clang / LLVM=1 builds):"
_tool_line clang
_tool_line ld.lld      "llvm-core/lld"
printf '\n'
log::info "Static analysis / debug info / rebuild speed:"
_tool_line sparse      "sys-devel/sparse — make C=1/C=2 CHECK=sparse"
_tool_line pahole      "dev-util/pahole — BTF for CONFIG_DEBUG_INFO_BTF"
_tool_line ccache      "optional — CC=\"ccache gcc\" / CC=\"ccache clang\""
printf '\n'
log::info "Scripting (used by Kconfig / kernel scripts, usually already present):"
_tool_line perl
_tool_line python3     "scripts/clang-tools/gen_compile_commands.py, checkpatch helpers"

printf '\n'
if [ "$IS_GENTOO" = 1 ]; then
    log::info "For the exact emerge / overlay commands, see: install.sh deps (kernel-dev group)"
else
    log::info "not Gentoo — tool presence above is real; install.sh deps (kernel-dev group)"
    log::info "shows the plan for when you are on the real target."
fi

printf '\n'
ui::kv "Current running kernel" "$RUNNING_KERNEL"
if [ -d "$MODULES_BUILD_DIR" ]; then
    log::ok "module build dir present: $MODULES_BUILD_DIR (external modules can build against it)"
else
    log::warn "module build dir missing: $MODULES_BUILD_DIR (install matching kernel headers/sources to build external modules)"
fi
if [ "$HAS_IKCONFIG" = 1 ]; then
    log::ok "/proc/config.gz readable (CONFIG_IKCONFIG_PROC) — the running kernel's own .config is available"
else
    log::info "/proc/config.gz not available (CONFIG_IKCONFIG_PROC not enabled on the running kernel, or not readable)"
fi
if [ "$HAS_BOOT_CONFIG" = 1 ]; then
    log::ok "$BOOT_CONFIG readable — a saved config for the running kernel is available"
else
    log::info "$BOOT_CONFIG not found"
fi

printf '\n'
ui::kv "Kernel source tree" "${KTREE_CHOSEN_PATH:-none found}"
if [ -n "$KTREE_CHOSEN_PATH" ]; then
    kver="$(_kernel_tree_version "$KTREE_CHOSEN_PATH")"
    log::ok "using $KTREE_CHOSEN_LABEL${kver:+  (Makefile reports $kver)}"
else
    log::warn "no kernel source tree found at any of: \$KERNEL_SRC, ~/src/linux, /usr/src/linux"
fi
for entry in "${KTREE_CANDIDATES[@]+"${KTREE_CANDIDATES[@]}"}"; do
    label="${entry%%|*}"; path="${entry#*|}"
    if _valid_kernel_tree "$path"; then
        mark=""; [ "$path" = "$KTREE_CHOSEN_PATH" ] && mark="  <- chosen"
        printf '  %s[OK]%s    %-55s %s%s\n' "${_C_GREEN:-}" "${_C_RESET:-}" "$label" "$path" "$mark"
    elif [ -L "$path" ] && [ ! -e "$path" ]; then
        printf '  %s[WARN]%s  %-55s %s  (broken symlink)\n' "${_C_YELLOW:-}" "${_C_RESET:-}" "$label" "$path"
    elif [ -e "$path" ]; then
        printf '  %s[WARN]%s  %-55s %s  (exists, does not look like a kernel source tree)\n' \
            "${_C_YELLOW:-}" "${_C_RESET:-}" "$label" "$path"
    else
        printf '  %s[INFO]%s  %-55s %s  (not present)\n' "${_C_CYAN:-}" "${_C_RESET:-}" "$label" "$path"
    fi
done
if [ -z "$KTREE_CHOSEN_PATH" ]; then
    printf '\n'
    log::info "Options to get one (none of these are done automatically):"
    printf '  - Gentoo sources, managed by portage + eselect-kernel:\n'
    printf '      emerge sys-kernel/gentoo-sources\n'
    printf '      eselect kernel list ; eselect kernel set <N>   # sets the /usr/src/linux symlink\n'
    printf '  - your own clone (preferred for kernel *development*, not just building):\n'
    printf '      git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git ~/src/linux\n'
    printf '  - a dedicated worktree off an existing clone, for working on more than one branch:\n'
    printf '      git -C ~/src/linux worktree add ~/src/linux-next next\n'
fi
fi

# ===========================================================================
if [ "$SHOW_ENV" = 1 ]; then
ui::section "Kernel development environment"
printf '\n'
printf 'Source:\n  %s\n' "${KTREE_CHOSEN_PATH:-none found — see install.sh kernel-dev --check}"
printf 'Output (out-of-tree, O=):\n  %s\n' "$BUILD_DIR"
[ -d "$BUILD_DIR" ] || log::info "(does not exist yet — make O=$BUILD_DIR ... creates it)"
[ -n "${KERNEL_BUILD_DIR:-}" ] && log::info "from \$KERNEL_BUILD_DIR" \
                                || log::info "default suggestion — override with \$KERNEL_BUILD_DIR"

printf '\nToolchains:\n'
if _have gcc; then printf '  %s\n' "$(gcc --version | head -n1)"; else log::warn "  gcc not found"; fi
if _have clang; then printf '  %s\n' "$(clang --version | head -n1)"; else log::info "  clang not found (optional)"; fi

printf '\nRecommended parallelism:\n  -j%s\n' "$RECOMMENDED_JOBS"
printf 'Reason:\n  %s\n' "$JOBS_REASON"
fi

# ===========================================================================
if [ "$SHOW_COMMANDS" = 1 ]; then
ui::section "Suggested commands"
SRC="${KTREE_CHOSEN_PATH:-<kernel-source-tree>}"
O="$BUILD_DIR"

printf '\n'
log::info "Nothing below is run for you. Every /boot, bootloader, module-install or"
log::info "symlink-changing step is explicitly marked manual/out of scope, further down."

printf '\n▸ Config\n'
if [ "$TREE_HAS_DOTCONFIG" = 1 ] || [ "$OUT_HAS_DOTCONFIG" = 1 ]; then
    log::ok "a .config already exists ($([ "$OUT_HAS_DOTCONFIG" = 1 ] && echo "$O/.config" || echo "$SRC/.config")) — olddefconfig will just refresh it for the current source"
elif [ "$HAS_IKCONFIG" = 1 ]; then
    printf '  zcat /proc/config.gz > %s/.config    # this running kernel exposes CONFIG_IKCONFIG_PROC\n' "$O"
elif [ "$HAS_BOOT_CONFIG" = 1 ]; then
    printf '  mkdir -p %s && cp %s %s/.config      # saved config for the running kernel\n' "$O" "$BOOT_CONFIG" "$O"
else
    printf '  # no existing config source detected (no /proc/config.gz, no %s).\n' "$BOOT_CONFIG"
    printf '  # start from the tree defaults instead:\n'
    printf '  make -C %s O=%s defconfig\n' "$SRC" "$O"
fi
printf '  make -C %s O=%s olddefconfig   # normalise/fill in defaults after copying a .config in\n' "$SRC" "$O"
printf '  make -C %s O=%s menuconfig     # interactive config (needs sys-libs/ncurses)\n' "$SRC" "$O"
log::warn "make localmodconfig trims the config down to only the modules currently"
log::warn "lsmod-loaded on THIS boot — anything not loaded right now (a USB device not"
log::warn "plugged in, a filesystem not mounted) gets dropped. Safe to try, but review"
log::warn "the resulting .config before trusting it for a kernel you'll boot generally."
printf '  make -C %s O=%s localmodconfig # (review the diff before trusting it — see warning above)\n' "$SRC" "$O"

printf '\n▸ Build\n'
printf '  make -C %s O=%s -j%s                          # GCC\n' "$SRC" "$O" "$RECOMMENDED_JOBS"
printf '  make -C %s O=%s LLVM=1 -j%s                    # Clang/LLVM (integrated assembler is already the default; add LLVM_IAS=0 only if you need the GNU assembler)\n' "$SRC" "$O" "$RECOMMENDED_JOBS"
if _have ccache; then
    printf '  make -C %s O=%s CC="ccache gcc" -j%s           # GCC via ccache\n' "$SRC" "$O" "$RECOMMENDED_JOBS"
fi
printf '  make -C %s O=%s modules -j%s                   # modules only\n' "$SRC" "$O" "$RECOMMENDED_JOBS"
printf '  make -C %s O=%s M=drivers/net/wireless -j%s     # a specific subdirectory of modules\n' "$SRC" "$O" "$RECOMMENDED_JOBS"

printf '\n▸ compile_commands.json (for clangd / IDE tooling)\n'
printf '  make -C %s O=%s compile_commands.json   # needs an already-built (or at least object-producing) tree\n' "$SRC" "$O"
log::info "this Makefile target already wraps scripts/clang-tools/gen_compile_commands.py — call the"
log::info "script directly only if you need options that target does not expose."

printf '\n▸ Static analysis\n'
printf '  make -C %s O=%s C=1 CHECK=sparse   # sparse on files the build actually recompiles\n' "$SRC" "$O"
printf '  make -C %s O=%s C=2 CHECK=sparse   # sparse on ALL files, whether recompiled or not\n' "$SRC" "$O"
[ -f "$SRC/.clang-format" ] && printf '  clang-format -i <file>.c                # this tree ships its own .clang-format\n'

printf '\n▸ Patch workflow (git, real — nothing here is run for you)\n'
cat <<EOF
  git status
  git diff
  git add -p
  git commit -s                       # -s: sign off, required by the kernel's own contribution process
  $SRC/scripts/checkpatch.pl <patch-or-commit>
  $SRC/scripts/get_maintainer.pl <patch-or-commit>
EOF
log::info "Sending patches (git send-email / --to / --cc from get_maintainer.pl's output) is"
log::info "deliberately not automated here — see docs/KERNEL-DEVELOPMENT.md."

printf '\n▸ External (out-of-tree) module build\n'
printf '  make -C %s M=$PWD modules   # builds *.ko in the current directory against the running kernel\n' "$MODULES_BUILD_DIR"
log::info "see docs/KERNEL-DEVELOPMENT.md for the out-of-tree vs. in-tree module difference"
log::info "and a minimal Makefile/Kbuild snippet — no example module is added to this repo."

printf '\n▸ Explicitly OUT OF SCOPE for this command — manual, deliberate steps only\n'
cat <<'EOF'
  make install                 # installs to /boot — not run
  make modules_install          # installs to /lib/modules — not run
  grub-mkconfig / grub2-mkconfig
  efibootmgr
  dracut / genkernel            # initramfs generation
  eselect kernel set <N>        # changes the /usr/src/linux symlink
  a reboot
EOF
fi
