#!/usr/bin/env bash
#
# pvehost:nfs — update-service (ADR-029, #766). The mounts are reconciled whole:
# the same steps as install-service.sh, so a mount added, changed or removed in
# config."pvehost:nfs".mounts[] is what the guest ends up with. A removed mount
# unmounts; the share's data is never touched (D6).
#
# Usage: update-service.sh <consumer>
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install-service.sh" "$@"
