#!/usr/bin/env bash
#
# TAPPaaS Templates NixOS Service - Install
#
# Applies NixOS configuration to a consuming module's VM.
# Delegates to update-service.sh which runs the OS update.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Applies NixOS configuration for the specified module."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A new guest's first build, copy and switch take minutes: show each as a line
# with progress dots (update-os.sh), also in a console job with no terminal.
TAPPAAS_OS_PROGRESS=1 exec "${SCRIPT_DIR}/update-service.sh" "$@"
