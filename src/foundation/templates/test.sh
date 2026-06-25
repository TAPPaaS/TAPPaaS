#!/usr/bin/env bash
# templates/test.sh — module test for the templates module (the NixOS / Debian /
# Windows base images every other VM clones from).
#
# FAST (default): validate the template config JSONs (templates.json + the
#   per-template build configs) and parse the service scripts. Flags the known
#   NixOS test-service.sh stub.
# DEEP (TAPPAAS_TEST_DEEP=1): check the template VMs (by vmid) exist on the
#   cluster's primary node.
#
# Note: services/<os>/test-service.sh are SERVICE tests run by test-module.sh for
# each module that `dependsOn templates:nixos|windows` — they verify a CONSUMER
# VM matches the baseline, so they belong to those modules, not here.
#
# Usage: ./test.sh        (fast) ; TAPPAAS_TEST_DEEP=1 ./test.sh   (+ live VMs)
set -uo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; rc=1; }

echo "== templates: config + service-script sanity (fast) =="
command -v jq >/dev/null 2>&1 || { echo "[Error] jq required"; exit 2; }
for j in "${here}"/*.json; do
    [ -f "$j" ] || continue
    jq empty "$j" 2>/dev/null && pass "$(basename "$j") is valid JSON" || fail "$(basename "$j") is INVALID JSON"
done
for s in "${here}"/services/*/*.sh; do
    [ -f "$s" ] || continue
    bash -n "$s" 2>/dev/null && pass "$(basename "$(dirname "$s")")/$(basename "$s") parses" \
        || fail "$s has a parse error"
done
# Known gap: the NixOS service test is a stub with no assertions (see TESTING.md).
if grep -qiE "no tests implemented|stub" "${here}/services/nixos/test-service.sh" 2>/dev/null; then
    echo "  ⚠ services/nixos/test-service.sh is a STUB (no assertions) — the NixOS"
    echo "    base image is effectively unverified; implementing it is a tracked TODO."
fi

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "== templates (deep): template VMs present on the cluster =="
    node="$(get_node_hostname 0 2>/dev/null || echo tappaas1)"
    for j in "${here}"/*.json; do
        vmid="$(jq -r '.vmid // empty' "$j" 2>/dev/null)"
        [ -n "$vmid" ] || continue
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
               "root@${node}.mgmt.internal" "qm status ${vmid}" >/dev/null 2>&1; then
            pass "template VM ${vmid} ($(basename "$j" .json)) present on ${node}"
        else
            fail "template VM ${vmid} ($(basename "$j" .json)) NOT found on ${node}"
        fi
    done
else
    echo "  (deep tier skipped — set TAPPAAS_TEST_DEEP=1 to check template VMs on the cluster)"
fi

echo ""
[[ "${rc}" -eq 0 ]] && echo "templates: all tests passed" || echo "templates: FAILURES above"
exit "${rc}"
