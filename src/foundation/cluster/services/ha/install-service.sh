#!/usr/bin/env bash
#
# TAPPaaS Cluster HA Service - Install
#
# Configures High Availability for a consuming module's VM.
# Delegates to update-service.sh which manages HA rules and ZFS replication.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Configures HA for the specified module."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/update-service.sh" "$@"
