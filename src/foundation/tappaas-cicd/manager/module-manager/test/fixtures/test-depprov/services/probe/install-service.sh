#!/usr/bin/env bash
#
# probe:install-service.sh — CREATE verb for the test 'probe' service (#511).
# Harmless: appends "install <consumer>" to the marker so the e2e can prove the
# right lifecycle verb fired for a newly-added dependency. No live side effects.
#
# Usage: install-service.sh <consumer-module>
#
set -euo pipefail
marker="${TAPPAAS_PROBE_MARKER:-/tmp/tappaas-depprov-probe.log}"
echo "install ${1:-}" >> "${marker}"
echo "[test-depprov] probe install-service ran for '${1:-}'"
