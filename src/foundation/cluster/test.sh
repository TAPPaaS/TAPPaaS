#!/usr/bin/env bash
#
# TAPPaaS Cluster Module Test
#
# Validates the cluster foundation module: VM/LXC lifecycle scripts, the
# vm-net.sh network helpers, the cluster:vm drift reconciler (services/vm/
# update-service.sh, #192), the cluster:ha drift reconciler (services/ha/
# update-service.sh, #193), and the cluster:lxc provisioner + reconciler
# (services/lxc/, #203).
#
# Standard mode: quick checks (~seconds) — file presence, vm-net.sh unit
#                tests, and a read-only drift --check against installed VMs.
# Deep mode:     additionally stands up disposable test guests and verifies the
#                reconcilers correct induced drift:
#                  #192 — VM zone change (net0 VLAN tag + DNS)
#                  #193 — replication-schedule + HA-rule node drift
#                  #203 — LXC create on srv_home/210 + DNS + cores drift
#                Creates and deletes real VMs/containers (~minutes).
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
# Matches both qemu VMs and lxc containers (vmid is unique cluster-wide).
find_vm() {
    local vmid="$1" node row
    for node in $(get_all_node_hostnames); do
        # shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
        row=$(ssh ${SSH_OPTS} "root@${node}.${MGMT}.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
            | jq -r --argjson id "${vmid}" \
                '.[] | select(.vmid == $id and (.type == "qemu" or .type == "lxc")) | "\(.node) \(.status)"' 2>/dev/null) || true
        if [[ -n "${row}" ]]; then echo "${row}"; return 0; fi
    done
    return 1
}

# ── Test 1: VM lifecycle + reconciler scripts present ───────────────

info "${BOLD}Test 1: Cluster scripts present${CL}"

required=(
    Create-TAPPaaS-VM.sh
    Create-TAPPaaS-LXC.sh
    lib/vm-net.sh
    lib/test-vm-net.sh
    services/vm/install-service.sh
    services/vm/update-service.sh
    services/vm/delete-service.sh
    services/vm/test-service.sh
    services/ha/install-service.sh
    services/ha/update-service.sh
    services/ha/delete-service.sh
    services/ha/test-service.sh
    services/lxc/install-service.sh
    services/lxc/update-service.sh
    services/lxc/delete-service.sh
    services/lxc/test-service.sh
)
missing=0
for f in "${required[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
        fail "Missing: ${f}"; missing=$((missing + 1))
    fi
done
[[ "${missing}" -eq 0 ]] && pass "All ${#required[@]} cluster scripts present"

# Both update-service.sh reconcilers must be executable (called by update-module.sh)
if [[ -x "${SCRIPT_DIR}/services/vm/update-service.sh" \
   && -x "${SCRIPT_DIR}/services/ha/update-service.sh" ]]; then
    pass "vm + ha update-service.sh are executable"
else
    fail "an update-service.sh is not executable"
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
        [[ "$m" == "test-vmdrift" || "$m" == "test-hadrift" || "$m" == "test-lxcdrift" ]] && continue
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
    dns-manager --no-ssl-verify delete test-vmdrift srv_home.internal  >/dev/null 2>&1 || true
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

    # 3. Induce zone drift mgmt -> srv_home (active, VLAN 210, has DHCP).
    if [[ "${deep_ok}" -eq 1 ]]; then
        # Pattern A-aware write (#207).
        if jq_module_write "${TVM}" '.zone0 = "srv_home"'; then
            pass "induced drift: zone0 mgmt→srv_home in config"
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
                pass "live net0 bound to srv_home VLAN (tag=210)"
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
        dns_line=$(dns-manager --no-ssl-verify list 2>/dev/null | grep -i "test-vmdrift" | grep "srv_home.internal" || true)
        if [[ -n "${dns_line}" ]] && { [[ -z "${new_ip}" ]] || grep -q "${new_ip}" <<< "${dns_line}"; }; then
            pass "DNS record test-vmdrift.srv_home.internal registered (${new_ip:-ip unknown})"
        else
            fail "DNS record for test-vmdrift.srv_home.internal (${new_ip:-?}) not found"
        fi
    fi

    deep_cleanup
    trap - EXIT
else
    info "${BOLD}Deep Test: cluster:vm drift reconcile${CL}"
    skip "VM creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Deep Test: create an HA VM, induce HA drift, verify reconcile ───

deep_cleanup_ha() {
    dns-manager --no-ssl-verify delete test-hadrift srv_home.internal >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/test-hadrift.json" ]] || return 0
    info "  Cleaning up HA test VM (delete-module test-hadrift)..."
    /home/tappaas/bin/delete-module.sh test-hadrift --force >/dev/null 2>&1 || true
}

if [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: cluster:ha drift reconcile (issue #193)${CL}"
    trap deep_cleanup_ha EXIT

    THVM="test-hadrift"
    HFIX="${SCRIPT_DIR}/test-hadrift"
    HUPSVC="${SCRIPT_DIR}/services/ha/update-service.sh"
    HVMID=921
    hdeep_ok=1

    # 1. Install the disposable HA-managed test VM. The cluster:vm service
    #    creates the VM (zone0=srv_home / VLAN 210 so it stays reachable on
    #    either node); the cluster:ha service configures the rule + replication.
    info "  Installing ${THVM} (NixOS clone, HA-managed on srv_home/210)..."
    if ( cd "${HFIX}" && /home/tappaas/bin/install-module.sh "${THVM}" ) >/dev/null 2>&1; then
        pass "HA test VM installed + HA configured"
    else
        fail "HA test VM install failed — aborting deep test"
        hdeep_ok=0
    fi

    # Locate the node hosting VM 921 for live state queries.
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        hrow=$(find_vm "${HVMID}") || true
        HNODE="${hrow%% *}"
        if [[ -z "${HNODE}" ]]; then
            fail "could not locate ${THVM} (VMID ${HVMID}) after install"; hdeep_ok=0
        fi
    fi

    # 2. Right after install, the reconciler should report no drift.
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        info "  Waiting for HA + replication to register..."
        sleep 20
        if "${HUPSVC}" --check "${THVM}" 2>&1 | grep -q "in sync"; then
            pass "post-install: HA reconciler reports in sync"
        else
            fail "post-install: expected 'in sync'"
        fi
    fi

    # 3. Induce replication-schedule drift (*/15 → */30) in config.
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        # Pattern A-aware write (#207).
        if jq_module_write "${THVM}" '.replicationSchedule = "*/30"'; then
            pass "induced drift: replicationSchedule */15→*/30 in config"
        else
            fail "could not edit test config"; hdeep_ok=0
        fi
    fi

    # 4. --check detects schedule drift; apply; verify the live job changed.
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        if "${HUPSVC}" --check "${THVM}" 2>&1 | grep -q "replication schedule"; then
            pass "reconciler detects replication-schedule drift"
        else
            fail "reconciler did not detect replication-schedule drift"
        fi
    fi
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        info "  Applying HA reconcile (replication schedule)..."
        "${HUPSVC}" "${THVM}" 2>&1 | indent
        # shellcheck disable=SC2086
        live_sched=$(ssh ${SSH_OPTS} "root@${HNODE}.${MGMT}.internal" \
            "pvesh get /cluster/replication --output-format json" 2>/dev/null \
            | jq -r --argjson id "${HVMID}" '.[] | select(.guest==$id) | .schedule' 2>/dev/null) || true
        if [[ "${live_sched}" == "*/30" ]]; then
            pass "live replication schedule reconciled to */30"
        else
            fail "live replication schedule not */30 (got: ${live_sched:-none})"
        fi
    fi

    # 5. Induce HA-rule node drift directly in the live cluster (config-vs-
    #    reality). A spurious low-priority tappaas3 is added; primary stays
    #    tappaas1 so this does NOT trigger a live migration. (The placement-
    #    migrate path is logic-only here to keep the test from doing a slow
    #    online migration.)
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        # shellcheck disable=SC2086,SC2029
        if ssh ${SSH_OPTS} "root@${HNODE}.${MGMT}.internal" \
            "ha-manager rules set node-affinity ha-${THVM} --nodes tappaas1:2,tappaas2:1,tappaas3:1 --resources vm:${HVMID}" \
            >/dev/null 2>&1; then
            pass "induced drift: HA rule nodes mangled in live state"
        else
            fail "could not mangle live HA rule"; hdeep_ok=0
        fi
    fi

    # 6. --check detects rule-nodes drift; apply; verify normalized back.
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        if "${HUPSVC}" --check "${THVM}" 2>&1 | grep -q "ha-rule nodes"; then
            pass "reconciler detects HA-rule node drift"
        else
            fail "reconciler did not detect HA-rule node drift"
        fi
    fi
    if [[ "${hdeep_ok}" -eq 1 ]]; then
        info "  Applying HA reconcile (rule nodes)..."
        "${HUPSVC}" "${THVM}" 2>&1 | indent
        # shellcheck disable=SC2086
        live_nodes=$(ssh ${SSH_OPTS} "root@${HNODE}.${MGMT}.internal" \
            "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null \
            | jq -r --arg res "vm:${HVMID}" '.[] | select(.resources==$res) | .nodes' 2>/dev/null) || true
        norm=$(tr ', ' '\n' <<< "${live_nodes}" | sed '/^$/d' | sort | paste -sd',' -)
        if [[ "${norm}" == "tappaas1:2,tappaas2:1" ]]; then
            pass "live HA rule reconciled to tappaas1:2,tappaas2:1"
        else
            fail "live HA rule not reconciled (got: ${live_nodes:-none})"
        fi
    fi

    deep_cleanup_ha
    trap - EXIT
else
    info "${BOLD}Deep Test: cluster:ha drift reconcile${CL}"
    skip "HA VM creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Deep Test: create an LXC, verify net/DNS, induce drift, reconcile ─

deep_cleanup_lxc() {
    dns-manager --no-ssl-verify delete test-lxcdrift srv_home.internal >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/test-lxcdrift.json" ]] || return 0
    info "  Cleaning up LXC test container (delete-module test-lxcdrift)..."
    /home/tappaas/bin/delete-module.sh test-lxcdrift --force >/dev/null 2>&1 || true
}

if [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: cluster:lxc provisioner + drift reconcile (issue #203)${CL}"
    trap deep_cleanup_lxc EXIT

    TLVM="test-lxcdrift"
    LFIX="${SCRIPT_DIR}/test-lxcdrift"
    LUPSVC="${SCRIPT_DIR}/services/lxc/update-service.sh"
    LVMID=922
    ldeep_ok=1

    # 1. Install the disposable plain-Debian container (no GPU/meta) on
    #    srv_home / VLAN 210 (the only test VLAN this switch trunks cross-node).
    info "  Installing ${TLVM} (Debian CT on srv_home/210; first run downloads the template)..."
    if ( cd "${LFIX}" && /home/tappaas/bin/install-module.sh "${TLVM}" ) >/dev/null 2>&1; then
        pass "LXC container installed via cluster:lxc"
    else
        fail "LXC install failed — aborting deep test"
        ldeep_ok=0
    fi

    # Locate the node hosting CT 922.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        lrow=$(find_vm "${LVMID}") || true
        LNODE="${lrow%% *}"
        [[ -z "${LNODE}" ]] && { fail "could not locate ${TLVM} (VMID ${LVMID}) after install"; ldeep_ok=0; }
    fi

    # 2. net0 must be on the srv_home VLAN tag (210) — proves zone→tag for LXC.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        # shellcheck disable=SC2086,SC2029
        lnet0=$(ssh ${SSH_OPTS} "root@${LNODE}.${MGMT}.internal" "pct config ${LVMID} | grep '^net0'" 2>/dev/null) || true
        if grep -q "tag=210" <<< "${lnet0}"; then
            pass "container net0 bound to srv_home VLAN (tag=210)"
        else
            fail "container net0 not tagged 210 (got: ${lnet0:-none})"
        fi
    fi

    # 3. post-install reconciler reports in sync.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        if "${LUPSVC}" --check "${TLVM}" 2>&1 | grep -q "in sync"; then
            pass "post-install: LXC reconciler reports in sync"
        else
            fail "post-install: expected 'in sync'"
        fi
    fi

    # 4. DNS registered in srv_home.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        if dns-manager --no-ssl-verify list 2>/dev/null | grep -i "test-lxcdrift" | grep -q "srv_home.internal"; then
            pass "DNS record test-lxcdrift.srv_home.internal registered"
        else
            fail "DNS record test-lxcdrift.srv_home.internal not found"
        fi
    fi

    # 5. Induce cores drift (1→2) in config; detect; apply; verify live.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        # Pattern A-aware write (#207).
        if jq_module_write "${TLVM}" '.cores = 2'; then
            pass "induced drift: cores 1→2 in config"
        else
            fail "could not edit test config"; ldeep_ok=0
        fi
    fi
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        if "${LUPSVC}" --check "${TLVM}" 2>&1 | grep -q "cores:"; then
            pass "reconciler detects cores drift"
        else
            fail "reconciler did not detect cores drift"
        fi
    fi
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        info "  Applying LXC reconcile (cores)..."
        "${LUPSVC}" "${TLVM}" 2>&1 | indent
        # shellcheck disable=SC2086,SC2029
        live_cores=$(ssh ${SSH_OPTS} "root@${LNODE}.${MGMT}.internal" "pct config ${LVMID} | awk -F': ' '/^cores/{print \$2}'" 2>/dev/null) || true
        if [[ "${live_cores}" == "2" ]]; then
            pass "live container reconciled to cores=2"
        else
            fail "live container cores not 2 (got: ${live_cores:-none})"
        fi
    fi

    deep_cleanup_lxc
    trap - EXIT
else
    info "${BOLD}Deep Test: cluster:lxc provisioner + drift reconcile${CL}"
    skip "LXC creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
