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

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; rc=1; }
skip() { echo "  ⊘ $* (skipped)"; }

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
    # Not every template is built on every site. The Windows Server template
    # (8081) is explicitly OPTIONAL — INSTALL.md: "Windows Server 2025 template
    # (VMID 8081, optional)" and "8080 (and 8081 if built)" — so a site that runs
    # no Windows has no 8081, and failing on that reported a healthy cluster as
    # broken on every deep run.
    #
    # The signal for "should exist" is the DEPLOYED CONFIG: a template installed
    # via install-module.sh leaves ${CONFIG_DIR}/<name>.json behind. So:
    #   VM present                      → pass
    #   VM absent, module installed     → FAIL (installed but the VM is gone —
    #                                      real drift, the case worth catching)
    #   VM absent, module not installed → skip (never built here)
    # A site with NO template VM at all still fails below: nothing could clone.
    node="$(get_node_hostname 0 2>/dev/null || echo tappaas1)"
    _tmpl_found=0
    for j in "${here}"/*.json; do
        vmid="$(jq -r '.vmid // empty' "$j" 2>/dev/null)"
        [ -n "$vmid" ] || continue
        _name="$(basename "$j" .json)"
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
               "root@${node}.mgmt.internal" "qm status ${vmid}" >/dev/null 2>&1; then
            pass "template VM ${vmid} (${_name}) present on ${node}"
            _tmpl_found=$((_tmpl_found + 1))
        elif [ -f "${CONFIG_DIR:-/home/tappaas/config}/${_name}.json" ]; then
            fail "template VM ${vmid} (${_name}) NOT found on ${node} — but ${_name} IS installed (config present): the template VM was removed"
        else
            skip "template VM ${vmid} (${_name}) not built on this site — install it with: install-module.sh ${_name}"
        fi
    done
    if [ "${_tmpl_found}" -eq 0 ]; then
        fail "no template VM found on ${node} — nothing for a module install to clone from"
    fi
else
    echo "  (deep tier skipped — set TAPPAAS_TEST_DEEP=1 to check template VMs on the cluster)"
fi

echo ""
[[ "${rc}" -eq 0 ]] && echo "templates: all tests passed" || echo "templates: FAILURES above"
exit "${rc}"
