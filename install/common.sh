# install/common.sh — installer bootstrap and command dispatcher.
#
# Sourced by ./install.sh, which sets REPO_DIR (resolved from its own real
# location) before sourcing. Not meant to be executed directly.

: "${REPO_DIR:?install/common.sh must be sourced by install.sh}"
set -euo pipefail

LIB_DIR="$REPO_DIR/lib"
CMD_DIR="$REPO_DIR/install/cmd"

# Flags that change how the libraries initialise must be seen before sourcing
# them (colour setup, verbosity). Do a cheap pre-scan of the caller's args.
for _a in "$@"; do
    case "$_a" in
        --no-color)    export LOG_NO_COLOR=1 ;;
        --verbose|-v)  export LOG_VERBOSE=1 ;;
        --)            break ;;
    esac
done
unset _a

# shellcheck source=lib/log.sh
. "$LIB_DIR/log.sh"
# shellcheck source=lib/ui.sh
. "$LIB_DIR/ui.sh"

# Shared state, exported so command subprocesses inherit it.
export INSTALL_REPO_DIR="$REPO_DIR"
export INSTALL_DRY_RUN="${INSTALL_DRY_RUN:-}"
export INSTALL_VERBOSE="${INSTALL_VERBOSE:-}"

# Commands with a real implementation today (one script per name in install/cmd/).
_CMD_IMPLEMENTED="check deps gpu doctor dotfiles infinite-desktop input power desktop monitor first-run profile full kernel-dev"
# Commands recognised but not implemented yet (added in later stages).
_CMD_PLANNED=""
# Of the implemented commands, those that honour --dry-run. 'check', 'deps',
# 'doctor', 'profile' and 'kernel-dev' are read-only; 'gpu', 'dotfiles',
# 'infinite-desktop', 'input', 'power', 'desktop', 'monitor', 'first-run' and
# 'full' show what they would do and write nothing under --dry-run.
_CMD_DRYRUN_OK="check deps gpu doctor dotfiles infinite-desktop input power desktop monitor first-run profile full kernel-dev"

common::usage() {
    cat <<'EOF'
hyprland-infinitie-desktop installer

Usage:
  ./install.sh [global options] <command> [command args...]

Commands:
  help                Show this help
  check               Read-only system report (works on any distro)
  profile             Detect which machine profile applies (read-only;
                      profiles/common vs. profiles/<machine-id>)
  deps                Detect missing Gentoo packages/overlays, print the commands
  gpu                 Hybrid AMD/NVIDIA + RTD3 config (plan; --apply to write)
  doctor              Read-only diagnostics ([OK]/[WARN]/[ERROR]/[INFO])
  dotfiles            Link repo config files into ~/.config (plan; --apply to link)
  infinite-desktop    Install the Infinite Desktop component
                      (evdev daemon + Hyprland keybinds, copied to ~/scripts)
  input               Grant the Infinite Desktop daemon session-scoped access to
                      keyboard/mouse event devices via a udev `uaccess` rule —
                      NOT the `input` group (plan; --apply to write, needs root)
  power               logind lid/power-key/idle-action policy (plan; --apply to write)
                      hypridle/hyprlock config itself is linked by `dotfiles`
  desktop             Orchestrates check/deps/dotfiles/gpu/power/input/infinite-desktop/doctor
                      (plan; --apply to run the real sequence). Reuses each of
                      those commands as-is; adds no new privileged action.
  monitor             Detect real monitors from a live Hyprland session, write
                      ~/.config/hypr/monitors.local.lua (plan; --apply to write)
  first-run           Guided checklist for what only Gentoo+Hyprland can decide:
                      real monitor config, the NVIDIA compute backend, and the
                      remaining hardware validations (plan; --apply to work
                      through pending items)
  full                Top-level orchestration: profile + desktop + first-run,
                      each reused as-is (plan; --apply to run the real thing)
  kernel-dev          Kernel development readiness, source-tree detection and
                      reproducible build/config/analysis commands (read-only;
                      --check / --env / --commands to show just one section).
                      Not part of `full` — invoke it on its own.

Global options:
  --dry-run           Print intended actions without changing the system
  --verbose, -v       Extra diagnostic output
  --no-color          Disable coloured output
  -h, --help          Show this help
EOF
}

# run <argv...> — execute a command, or under --dry-run just print it.
# For use by command implementations added in later stages.
run() {
    if [ -n "${INSTALL_DRY_RUN:-}" ]; then
        printf '%s[dry-run]%s %s\n' "${_C_DIM:-}" "${_C_RESET:-}" "$*" >&2
        return 0
    fi
    log::debug "run: $*"
    "$@"
}

# common::main <all args from install.sh>
common::main() {
    local cmd=""
    local -a rest=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)      export INSTALL_DRY_RUN=1 ;;
            --verbose|-v)   export INSTALL_VERBOSE=1 LOG_VERBOSE=1 ;;
            --no-color)     export LOG_NO_COLOR=1 ;;
            -h|--help)      cmd="help" ;;
            --)             shift; rest+=("$@"); break ;;
            -?*)            log::error "unknown option: $1"; echo >&2; common::usage >&2; return 2 ;;
            *)              cmd="$1"; shift; rest+=("$@"); break ;;
        esac
        shift
    done

    cmd="${cmd:-help}"

    if [ "$cmd" = "help" ]; then
        common::usage
        return 0
    fi

    case " $_CMD_IMPLEMENTED " in
        *" $cmd "*) ;;
        *)
            case " $_CMD_PLANNED " in
                *" $cmd "*)
                    log::warn "'$cmd' is planned for a later stage and is not implemented yet."
                    return 3
                    ;;
                *)
                    log::error "unknown command: $cmd"
                    echo >&2
                    common::usage >&2
                    return 2
                    ;;
            esac
            ;;
    esac

    local script="$CMD_DIR/$cmd.sh"
    if [ ! -f "$script" ]; then
        log::error "command '$cmd' is registered but its script is missing: $script"
        return 1
    fi

    if [ -n "${INSTALL_DRY_RUN:-}" ]; then
        case " $_CMD_DRYRUN_OK " in
            *" $cmd "*)
                log::info "dry-run: no changes will be made"
                ;;
            *)
                log::error "--dry-run is not supported by '$cmd' yet; aborting so nothing is changed"
                return 3
                ;;
        esac
    fi

    log::debug "dispatching to $script"
    exec bash "$script" ${rest[@]+"${rest[@]}"}
}
