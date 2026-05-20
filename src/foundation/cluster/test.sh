#!/usr/bin/env bash
#
# TAPPaaS Cluster Module Test
#
# Validates the cluster foundation module: VM lifecycle scripts, the
# vm-net.sh network helpers, and the cluster:vm drift reconciler
# (update-service.sh, issue #192).
#
# Standard mode: quick checks (~seconds) — file presence, vm-net.sh unit
#                tests, and a read-only drift --check against an installed VM.
# Deep mode:     additionally stands up a disposable test VM, induces a
#                zone change, and verifies update-service.sh reconciles it
#                (net0 VLAN tag + DNS). Creates and deletes a real VM (~minutes).
#
# Usage: ./test.sh [module-name]
#
# Environment:
#   TAPPAAS_TEST_DEEP=1  Run deep tests (VM creation + drift reconcile)
#   TAPPAAS_DEBUG=1      Show debug output
#

set -uo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="/home/tappaas/config"
readonly MGMT="mgmt"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0
SKIP=0

pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { info "  ${YW}⊘${CL} $1 (skipped)"; SKIP=$((SKIP + 1)); }
indent() { while IFS= read -r _l; do printf '      %s\n' "${_l}"; done; }

readonly SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# Find the node a VMID lives on (cluster-wide); echoes "<node> <status>".
find_vm() {
    local vmid="$1" node row
    for node in $(get_all_node_hostnames); do
        # shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
        row=$(ssh ${SSH_OPTS} "root@${node}.${MGMT}.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
            | jq -r --argjson id "${vmid}" \
                '.[] | select(.vmid == $id and .type == "qemu") | "\(.node) \(.status)"' 2>/dev/null) || true
        if [[ -n "${row}" ]]; then echo "${row}"; return 0; fi
    done
    return 1
}

# ── Test 1: VM lifecycle + reconciler scripts present ───────────────

info "${BOLD}Test 1: Cluster scripts present${CL}"

required=(
    Create-TAPPaaS-VM.sh
    lib/vm-net.sh
    lib/test-vm-net.sh
    services/vm/install-service.sh
    services/vm/update-service.sh
    services/vm/delete-service.sh
    services/vm/test-service.sh
)
missing=0
for f in "${required[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
        fail "Missing: ${f}"; missing=$((missing + 1))
    fi
done
[[ "${missing}" -eq 0 ]] && pass "All ${#required[@]} cluster scripts present"

# update-service.sh must be executable (called by update-module.sh)
if [[ -x "${SCRIPT_DIR}/services/vm/update-service.sh" ]]; then
    pass "update-service.sh is executable"
else
    fail "update-service.sh is not executable"
fi

# ── Test 2: vm-net.sh helper unit tests ─────────────────────────────

info "${BOLD}Test 2: vm-net.sh helper unit tests${CL}"

if [[ -x "${SCRIPT_DIR}/lib/test-vm-net.sh" ]]; then
    if vmnet_out=$("${SCRIPT_DIR}/lib/test-vm-net.sh" 2>&1); then
        pass "$(tail -1 <<< "${vmnet_out}")"
    else
        fail "vm-net.sh unit tests failed"
        indent <<< "${vmnet_out}"
    fi
else
    fail "lib/test-vm-net.sh not found or not executable"
fi

# ── Test 3: drift --check against an installed VM (read-only) ───────

info "${BOLD}Test 3: Drift reconciler --check (read-only)${CL}"

# Is any Proxmox node reachable?
node_reachable=0
for node in $(get_all_node_hostnames); do
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "root@${node}.${MGMT}.internal" "true" &>/dev/null; then
        node_reachable=1; break
    fi
done

if [[ "${node_reachable}" -eq 0 ]]; then
    skip "no Proxmox node reachable"
else
    # Pick an installed module that dependsOn cluster:vm (skip the test fixture).
    target=""
    for j in "${CONFIG_DIR}"/*.json; do
        m=$(basename "$j" .json)
        [[ "$m" == "test-vmdrift" ]] && continue
        if jq -e '(.dependsOn // []) | index("cluster:vm") != null' "$j" >/dev/null 2>&1; then
            target="$m"; break
        fi
    done

    if [[ -z "${target}" ]]; then
        skip "no installed cluster:vm module to check"
    elif "${SCRIPT_DIR}/services/vm/update-service.sh" --check "${target}" >/dev/null 2>&1; then
        pass "update-service.sh --check ${target} succeeded (live qm config parsed)"
    else
        fail "update-service.sh --check ${target} failed"
    fi
fi

# ── Deep Test: create a VM, induce zone drift, verify reconcile ─────

deep_cleanup() {
    # Remove DNS records the reconciler may have registered (delete-module
    # does not touch DNS). Harmless if absent.
    dns-manager --no-ssl-verify delete test-vmdrift srv.internal  >/dev/null 2>&1 || true
    dns-manager --no-ssl-verify delete test-vmdrift mgmt.internal >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/test-vmdrift.json" ]] || return 0
    info "  Cleaning up test VM (delete-module test-vmdrift)..."
    /home/tappaas/bin/delete-module.sh test-vmdrift --force >/dev/null 2>&1 || true
}

if [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: cluster:vm drift reconcile (issue #192)${CL}"
    trap deep_cleanup EXIT

    TVM="test-vmdrift"
    FIX="${SCRIPT_DIR}/test-vmdrift"
    UPSVC="${SCRIPT_DIR}/services/vm/update-service.sh"
    deep_ok=1

    # 1. Install the disposable test VM (zone0=mgmt).
    info "  Installing ${TVM} (NixOS clone on mgmt)..."
    if ( cd "${FIX}" && /home/tappaas/bin/install-module.sh "${TVM}" ) >/dev/null 2>&1; then
        pass "test VM installed"
    else
        fail "test VM install failed — aborting deep test"
        deep_ok=0
    fi

    # 2. Right after install, the reconciler should report no drift.
    if [[ "${deep_ok}" -eq 1 ]]; then
        info "  Waiting for VM to settle..."
        sleep 30
        if "${UPSVC}" --check "${TVM}" 2>&1 | grep -q "in sync"; then
            pass "post-install: reconciler reports in sync"
        else
            fail "post-install: expected 'in sync'"
        fi
    fi

    # 3. Induce zone drift mgmt -> srv (active, VLAN 210, has DHCP).
    if [[ "${deep_ok}" -eq 1 ]]; then
        tmp=$(mktemp)
        if jq '.zone0 = "srv"' "${CONFIG_DIR}/${TVM}.json" > "${tmp}" && mv "${tmp}" "${CONFIG_DIR}/${TVM}.json"; then
            pass "induced drift: zone0 mgmt→srv in config"
        else
            fail "could not edit test config"; deep_ok=0
        fi
    fi

    # 4. --check must now detect the net0 drift.
    if [[ "${deep_ok}" -eq 1 ]]; then
        if "${UPSVC}" --check "${TVM}" 2>&1 | grep -q "net0:"; then
            pass "reconciler detects net0 drift"
        else
            fail "reconciler did not detect net0 drift"
        fi
    fi

    # 5. Apply the reconcile (qm set net0 tag=210, reboot, wait IP, DNS).
    if [[ "${deep_ok}" -eq 1 ]]; then
        info "  Applying reconcile (this reboots the VM)..."
        reconcile_out=$("${UPSVC}" "${TVM}" 2>&1); reconcile_rc=$?
        indent <<< "${reconcile_out}"
        if [[ "${reconcile_rc}" -eq 0 ]]; then
            pass "reconcile applied without error"
        else
            fail "reconcile apply failed"; deep_ok=0
        fi
    fi

    # 6. Verify the live VM is now tagged onto VLAN 210.
    if [[ "${deep_ok}" -eq 1 ]]; then
        vmrow=$(find_vm 920) || true
        vmnode="${vmrow%% *}"
        if [[ -n "${vmnode}" ]]; then
            # shellcheck disable=SC2086
            net0=$(ssh ${SSH_OPTS} "root@${vmnode}.${MGMT}.internal" "qm config 920 | grep '^net0'" 2>/dev/null) || true
            if grep -q "tag=210" <<< "${net0}"; then
                pass "live net0 bound to srv VLAN (tag=210)"
            else
                fail "live net0 not tagged 210 (got: ${net0:-none})"
            fi
        else
            fail "could not locate test VM after reconcile"
        fi
    fi

    # 7. Verify DNS was registered in the new zone, pointing at the new IP.
    if [[ "${deep_ok}" -eq 1 ]]; then
        # shellcheck disable=SC2001  # regex ANSI strip not expressible as ${//}
        new_ip=$(sed 's/\x1b\[[0-9;]*m//g' <<< "${reconcile_out}" \
                 | grep -oE 'came up with IP [0-9.]+' | grep -oE '[0-9.]+$')
        dns_line=$(dns-manager --no-ssl-verify list 2>/dev/null | grep -i "test-vmdrift" | grep "srv.internal" || true)
        if [[ -n "${dns_line}" ]] && { [[ -z "${new_ip}" ]] || grep -q "${new_ip}" <<< "${dns_line}"; }; then
            pass "DNS record test-vmdrift.srv.internal registered (${new_ip:-ip unknown})"
        else
            fail "DNS record for test-vmdrift.srv.internal (${new_ip:-?}) not found"
        fi
    fi

    deep_cleanup
    trap - EXIT
else
    info "${BOLD}Deep Test: cluster:vm drift reconcile${CL}"
    skip "VM creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
