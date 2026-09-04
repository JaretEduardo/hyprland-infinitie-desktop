#!/usr/bin/env bash
#
# install.sh — entrypoint for the hyprland-infinitie-desktop installer.
#
# Thin dispatcher: resolves the repository root from this file's real location
# (following symlinks, never trusting the current working directory), then hands
# off to install/common.sh. See `./install.sh help`.
#
set -euo pipefail

# Resolve this script's real path, walking any symlink chain.
_entry="${BASH_SOURCE[0]}"
while [ -h "$_entry" ]; do
    _dir="$(cd -P "$(dirname "$_entry")" >/dev/null 2>&1 && pwd)"
    _entry="$(readlink "$_entry")"
    case "$_entry" in
        /*) ;;
        *)  _entry="$_dir/$_entry" ;;
    esac
done
REPO_DIR="$(cd -P "$(dirname "$_entry")" >/dev/null 2>&1 && pwd)"
unset _entry _dir

# shellcheck source=install/common.sh
. "$REPO_DIR/install/common.sh"

common::main "$@"
