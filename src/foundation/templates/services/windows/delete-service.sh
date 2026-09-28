#!/usr/bin/env bash
#
# templates:windows delete-service
#
# Nothing to remove, deliberately: the Windows baseline this service applies
# (disk, guest agent, updates, RDP, the tappaas account) lives inside the
# consumer's own VM, which cluster:vm deletes along with the module. Nothing
# lives on the provider side. (ADR-027 D3 requires the file; it says so here
# rather than being absent.)
#
# Usage: delete-service.sh <module-name>

set -euo pipefail
echo "templates:windows: nothing to remove for ${1:-the module} — the baseline lives in its own VM, deleted with it"
exit 0
