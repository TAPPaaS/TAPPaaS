#!/usr/bin/env bash
#
# pvehost:nfs — update-service (ADR-029 v0.8). The mounts are reconciled whole:
# the same steps as install-service.sh, so a mount added, changed or removed in
# config."pvehost:nfs".mounts[] is what the guest ends up with. This is also where
# a pending mount whose share has appeared is migrated into (D14, with consent),
# and where the local copy a migration left is removed once the share is healthy.
# A removed mount unmounts; the share's data is never touched (D6).
#
# Usage: update-service.sh <consumer>
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install-service.sh" "$@"
