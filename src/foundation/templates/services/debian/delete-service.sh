#!/usr/bin/env bash
#
# templates:debian delete-service
#
# Nothing to remove, deliberately: everything this service does — applying and
# updating the consumer's OS — happens inside the consumer's own VM, which
# cluster:vm deletes along with the module. Nothing lives on the provider side.
# (ADR-027 D3 requires the file; it says so here rather than being absent.)
#
# Usage: delete-service.sh <module-name>

set -euo pipefail
echo "templates:debian: nothing to remove for the module — the OS lives in its own VM, deleted with it"
exit 0
