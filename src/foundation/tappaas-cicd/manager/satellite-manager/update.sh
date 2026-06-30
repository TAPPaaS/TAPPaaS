#!/usr/bin/env bash
# update.sh — re-link satellite-manager (idempotent). Bash component: nothing to
# rebuild; re-link so a moved checkout still resolves.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/install.sh"
