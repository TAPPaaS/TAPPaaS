#!/usr/bin/env bash
#
# TAPPaaS Identity Access Control Service — Update (issue #45).
#
# Re-applies the forward-auth wiring for an already-installed consumer:
# refreshes the Authentik Proxy app/provider's external_host (so a changed
# proxyDomain propagates) and ensures the Caddy handler still has ForwardAuth=1.
# Both operations are idempotent, so this is identical to install.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# install-service.sh is fully idempotent; reuse it.
exec "${SCRIPT_DIR}/install-service.sh" "$@"
