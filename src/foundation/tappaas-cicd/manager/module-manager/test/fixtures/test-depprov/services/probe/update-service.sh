#!/usr/bin/env bash
#
# probe:update-service.sh — RE-WIRE verb for the test 'probe' service (#511).
# Harmless: appends "update <consumer>" to the marker. reconcile (update-module
# Steps 4+5) runs this over the whole dependsOn list, so it fires on every update
# once the dependency exists — the e2e uses it to confirm reconcile still
# converges the freshly-created integration. No live side effects.
#
# Usage: update-service.sh <consumer-module>
#
set -euo pipefail
marker="${TAPPAAS_PROBE_MARKER:-/tmp/tappaas-depprov-probe.log}"
echo "update ${1:-}" >> "${marker}"
echo "[test-depprov] probe update-service ran for '${1:-}'"
