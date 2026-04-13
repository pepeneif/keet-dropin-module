#!/usr/bin/env bash
set -euo pipefail
# Resolve where the repository lives (either a clone or a remote URL)
# If we are already inside the repo, just execute the installer.
SCRIPT="$(git rev-parse --show-toplevel 2>/dev/null)/install_keet_dropin.sh" \
  || SCRIPT="$(dirname "$0")/install_keet_dropin.sh"
exec bash "$SCRIPT"
