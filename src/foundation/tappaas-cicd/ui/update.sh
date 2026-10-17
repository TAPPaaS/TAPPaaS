#!/usr/bin/env bash
# Rebuild and relink; the running service picks the new build up on its next restart.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" "$@"
