#!/usr/bin/env bash
# Bash component: nothing to rebuild; re-link bins. Idempotent.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" "$@"
