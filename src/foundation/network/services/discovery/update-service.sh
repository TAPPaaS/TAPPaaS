#!/usr/bin/env bash
#
# TAPPaaS Discovery Service - Update
#
# Idempotent re-apply of cross-VLAN discovery configuration.
# Identical to install-service.sh: mDNS uses GET→union→SET so re-running
# is always safe. UDP relay checks description before adding.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install-service.sh" "$@"
