#!/usr/bin/env bash
#
# TAPPaaS satellite module test (ADR-010)
#
# Fast tests: module-contract files present, JSON well-formed, satellite.json has
# the required shape. Deep/live tests (a real satellite host) gate behind
# TAPPAAS_TEST_DEEP=1 and land in packages P2-P6.
#
# Usage: ./test.sh
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok() { echo "  ok   - $*"; pass=$((pass+1)); }
no() { echo "  FAIL - $*"; fail=$((fail+1)); }

# 1. contract files present
for f in README.md INSTALL.md satellite.json satellite.nix install.sh update.sh test.sh; do
    [[ -f "${here}/${f}" ]] && ok "present: ${f}" || no "missing: ${f}"
done

# 2. satellite.json is valid JSON
if command -v jq >/dev/null 2>&1; then
    if jq empty "${here}/satellite.json" 2>/dev/null; then ok "satellite.json is valid JSON"; else no "satellite.json invalid JSON"; fi
    # 3. required shape: kind=external-host, tier=foundation, roles[], host.publicIp
    [[ "$(jq -r '.kind' "${here}/satellite.json")" == "external-host" ]] && ok "kind=external-host" || no "kind"
    [[ "$(jq -r '.tier' "${here}/satellite.json")" == "foundation" ]] && ok "tier=foundation" || no "tier"
    [[ "$(jq -r '.roles | length' "${here}/satellite.json")" -ge 1 ]] && ok "roles present" || no "roles"
    [[ -n "$(jq -r '.host.publicIp // empty' "${here}/satellite.json")" ]] && ok "host.publicIp present" || no "host.publicIp"
    # 4. backup role => s3 default backend with object lock
    if jq -e '.roles | index("backup")' "${here}/satellite.json" >/dev/null; then
        [[ "$(jq -r '.backup.backend' "${here}/satellite.json")" == "s3" ]] && ok "backup backend=s3 (default)" || no "backup backend"
        [[ "$(jq -r '.backup.s3.objectLock.enabled' "${here}/satellite.json")" == "true" ]] && ok "S3 Object Lock enabled" || no "object lock"
    fi
else
    no "jq not available (cannot validate satellite.json shape)"
fi

# 5. scripts parse
for s in install.sh update.sh test.sh; do
    bash -n "${here}/${s}" && ok "parses: ${s}" || no "syntax: ${s}"
done

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "  (deep tests: live satellite provisioning — implemented in P2-P6)"
fi

echo ""
echo "satellite module fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
