#!/usr/bin/env bash
# Bash component: nothing to rebuild; re-link the bin. Idempotent.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" "$@"
