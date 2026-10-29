#!/usr/bin/env bash
# Rebuild and relink; the service restarts into the new build. Idempotent.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" "$@"
