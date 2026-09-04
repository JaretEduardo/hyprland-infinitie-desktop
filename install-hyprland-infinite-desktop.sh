#!/usr/bin/env bash
#
# Compatibility wrapper — kept so existing instructions and muscle memory keep
# working. The installer is now `install.sh`; this forwards to its
# `infinite-desktop` subcommand. Prefer calling `./install.sh infinite-desktop`.
#
set -euo pipefail

_here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
exec "$_here/install.sh" infinite-desktop "$@"
