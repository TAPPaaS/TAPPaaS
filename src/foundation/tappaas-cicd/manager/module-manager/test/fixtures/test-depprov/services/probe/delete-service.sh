#!/usr/bin/env bash
#
# probe:delete-service.sh — TEARDOWN verb for the test 'probe' service (#511).
# Harmless: appends "delete <consumer>" to the marker so the e2e can prove
# delete-service.sh fired when the dependency was removed from a shipped module.
# No live side effects.
#
# Usage: delete-service.sh <consumer-module>
#
set -euo pipefail
marker="${TAPPAAS_PROBE_MARKER:-/tmp/tappaas-depprov-probe.log}"
echo "delete ${1:-}" >> "${marker}"
echo "[test-depprov] probe delete-service ran for '${1:-}'"
