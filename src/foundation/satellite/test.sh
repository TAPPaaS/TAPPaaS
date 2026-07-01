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
for f in README.md INSTALL.md satellite.json satellite.nix install.sh update.sh test.sh delete.sh; do
    [[ -f "${here}/${f}" ]] && ok "present: ${f}" || no "missing: ${f}"
done

# 2. satellite.json valid + slim operator-facing shape (derived values are NOT here)
if command -v jq >/dev/null 2>&1; then
    if jq empty "${here}/satellite.json" 2>/dev/null; then ok "satellite.json is valid JSON"; else no "satellite.json invalid JSON"; fi
    [[ "$(jq -r '.kind' "${here}/satellite.json")" == "external-host" ]] && ok "kind=external-host" || no "kind"
    [[ "$(jq -r '.tier' "${here}/satellite.json")" == "foundation" ]] && ok "tier=foundation" || no "tier"
    [[ "$(jq -r '.roles | length' "${here}/satellite.json")" -ge 1 ]] && ok "roles present" || no "roles"
    [[ -n "$(jq -r '.host.publicIp // empty' "${here}/satellite.json")" ]] && ok "host.publicIp present" || no "host.publicIp"
    [[ "$(jq -r '.host.operatorSshKeys | length' "${here}/satellite.json")" -ge 1 ]] && ok "host.operatorSshKeys present" || no "operatorSshKeys"
    # slim: derived tunnel/reverseProxy/adminVpn/update must NOT be exposed here
    [[ "$(jq -r 'has("tunnel") or has("reverseProxy") or has("adminVpn") or has("update")' "${here}/satellite.json")" == "false" ]] \
        && ok "derived values not exposed in json (sensible defaults)" || no "json exposes derived values"
    # backup role => operator supplies the S3 target (bucket)
    if jq -e '.roles | index("backup")' "${here}/satellite.json" >/dev/null; then
        [[ -n "$(jq -r '.backup.s3.bucket // empty' "${here}/satellite.json")" ]] && ok "backup.s3.bucket present" || no "backup.s3.bucket"
    fi
else
    no "jq not available (cannot validate satellite.json shape)"
fi

# 5. scripts parse
for s in install.sh update.sh test.sh delete.sh; do
    bash -n "${here}/${s}" && ok "parses: ${s}" || no "syntax: ${s}"
done

# 6. deep test: reverse-proxy end-to-end through a LIVE satellite (ADR-010).
#    Delegates to test-vm-creation/ (install sat-hello → probe via the satellite
#    public IP → teardown), mirroring tappaas-cicd/test-vm-creation. The driver
#    SKIPs (exit 0) when prerequisites (satellite + wildcard cert) are absent, so
#    the gate stays green on a cluster without a satellite.
if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo ""
    echo "  deep: reverse-proxy end-to-end (test-vm-creation/)"
    if [[ -x "${here}/test-vm-creation/test.sh" ]]; then
        if "${here}/test-vm-creation/test.sh"; then
            ok "reverse-proxy deep test passed (or skipped: prerequisites absent)"
        else
            no "reverse-proxy deep test failed"
        fi
    else
        no "missing: test-vm-creation/test.sh"
    fi
fi

echo ""
echo "satellite module fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
