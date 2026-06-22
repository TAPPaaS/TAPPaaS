#!/usr/bin/env bash
# identity-controller/update.sh — rebuild + relink (delegates to install.sh).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" "$@"
