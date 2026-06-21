#!/usr/bin/env bash
# manager/health-manager/update.sh — bash components have nothing to rebuild;
# just (re)link bins. Idempotent.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" "$@"
