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
#                  #193 — replication-schedule + HA-rule node drift (≥2 nodes)
#                  #203 — LXC create in the default zone + DNS + cores drift
#                The drift target is the org-named DEFAULT zone (site.json .name,
#                Active per zones-init), NOT a hardcoded legacy zone — see the
#                resolver below.
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

# ── Default service zone resolution (ADR-007) ──────────────────────
# The deep drift tests must target the zone a REAL module lands in — the
# org-named default zone that `zones-init --name <N>` makes Active on every
# fresh install AND migration (site.json .name; renamed from `srv`). The former
# hardcode (`srvHome`/VLAN 210) is a catalog zone that stays Inactive on a
# minimal deploy, so a VM placed there never gets DHCP and the install times out
# — which is exactly why the deep sweep's srvHome VMs failed while the mgmt ones
# passed. Resolve site.json .name, assert it is present + Active in zones.json,
# and read its VLAN tag. Echoes "<zone> <vlantag>"; non-zero when unresolvable
# (callers skip the drift tests rather than fail).
resolve_default_zone_and_vlan() {
    local site="${CONFIG_DIR}/site.json" zones="${CONFIG_DIR}/zones.json"
    local name state vlan
    [[ -f "$site" && -f "$zones" ]] || return 1
    name="$(jq -r '.name // empty' "$site" 2>/dev/null)"
    [[ -n "$name" && "$name" != "mgmt" ]] || return 1
    state="$(jq -r --arg z "$name" '.[$z].state // empty' "$zones" 2>/dev/null)"
    vlan="$(jq -r --arg z "$name" '.[$z].vlantag // empty' "$zones" 2>/dev/null)"
    [[ "$state" == "Active" && -n "$vlan" ]] || return 1
    printf '%s %s\n' "$name" "$vlan"
}

DEFAULT_ZONE=""
DEFAULT_VLAN=""
if _dz="$(resolve_default_zone_and_vlan)"; then
    DEFAULT_ZONE="${_dz%% *}"
    DEFAULT_VLAN="${_dz##* }"
fi

# The HA drift test (#193) needs a replication target — i.e. ≥2 cluster nodes.
NODE_COUNT="$(get_all_node_hostnames 2>/dev/null | wc -w | tr -d ' ')"

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
    dns-manager --no-ssl-verify delete test-vmdrift "${DEFAULT_ZONE:-srvHome}.internal"  >/dev/null 2>&1 || true
    dns-manager --no-ssl-verify delete test-vmdrift mgmt.internal >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/test-vmdrift.json" ]] || return 0
    info "  Cleaning up test VM (delete-module test-vmdrift)..."
    /home/tappaas/bin/delete-module.sh test-vmdrift --force >/dev/null 2>&1 || true
}

if [[ "${DEEP}" -eq 1 && -n "${DEFAULT_ZONE}" ]]; then
    info "${BOLD}Deep Test: cluster:vm drift reconcile (issue #192)${CL}"
    info "  Drift target = default zone ${BL}${DEFAULT_ZONE}${CL} (VLAN ${DEFAULT_VLAN})"
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

    # 3. Induce zone drift mgmt -> <default zone> (Active, VLAN ${DEFAULT_VLAN},
    #    has DHCP — the zone a real module lands in by default).
    if [[ "${deep_ok}" -eq 1 ]]; then
        # Pattern A-aware write (#207).
        if jq_module_write "${TVM}" ".zone0 = \"${DEFAULT_ZONE}\""; then
            pass "induced drift: zone0 mgmt→${DEFAULT_ZONE} in config"
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

    # 5. Apply the reconcile (qm set net0 tag=${DEFAULT_VLAN}, reboot, wait IP, DNS).
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

    # 6. Verify the live VM is now tagged onto the default zone's VLAN.
    if [[ "${deep_ok}" -eq 1 ]]; then
        vmrow=$(find_vm 920) || true
        vmnode="${vmrow%% *}"
        if [[ -n "${vmnode}" ]]; then
            # shellcheck disable=SC2086
            net0=$(ssh ${SSH_OPTS} "root@${vmnode}.${MGMT}.internal" "qm config 920 | grep '^net0'" 2>/dev/null) || true
            if grep -q "tag=${DEFAULT_VLAN}" <<< "${net0}"; then
                pass "live net0 bound to ${DEFAULT_ZONE} VLAN (tag=${DEFAULT_VLAN})"
            else
                fail "live net0 not tagged ${DEFAULT_VLAN} (got: ${net0:-none})"
            fi
        else
            fail "could not locate test VM after reconcile"
        fi
    fi

    # 7. Verify DNS RESOLVES in the new zone, to a target-subnet address. The
    #    reconciler registers a static fast-path when it gets the IP in time; a
    #    slow guest re-DHCP falls back to masqdns (dynamic, lease-based) — either
    #    way <vm>.<zone>.internal must RESOLVE via the firewall (the old check
    #    queried only the STATIC host list, which the masqdns-only path misses).
    #    Generous retry + subnet check: NixOS boot + re-DHCP into a new subnet
    #    can be slow, and a lingering old-subnet lease must not satisfy the test.
    if [[ "${deep_ok}" -eq 1 ]]; then
        vfqdn="test-vmdrift.${DEFAULT_ZONE}.internal"
        vprefix=""
        zcidr=$(jq -r --arg z "${DEFAULT_ZONE}" '.[$z].ip // empty' "${CONFIG_DIR}/zones.json" 2>/dev/null)
        [[ "${zcidr}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. ]] && vprefix="${BASH_REMATCH[1]}."
        vresolved=""
        for _ in $(seq 1 30); do
            vresolved=$(getent hosts "${vfqdn}" 2>/dev/null | awk '{print $1}' | head -1)
            if [[ -n "${vresolved}" ]]; then
                [[ -z "${vprefix}" || "${vresolved}" == "${vprefix}"* ]] && break
                vresolved=""   # resolved but old-subnet/stale — keep waiting
            fi
            sleep 6
        done
        if [[ -n "${vresolved}" ]]; then
            pass "DNS resolves ${vfqdn} → ${vresolved} (${DEFAULT_ZONE} subnet, masqdns/static)"
        else
            fail "DNS did not resolve ${vfqdn} to a ${DEFAULT_ZONE}-subnet address"
        fi
    fi

    deep_cleanup
    trap - EXIT
elif [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: cluster:vm drift reconcile${CL}"
    skip "no Active default zone resolved (site.json .name / zones.json) — drift test needs it"
else
    info "${BOLD}Deep Test: cluster:vm drift reconcile${CL}"
    skip "VM creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Deep Test: create an HA VM, induce HA drift, verify reconcile ───

deep_cleanup_ha() {
    dns-manager --no-ssl-verify delete test-hadrift "${DEFAULT_ZONE:-srvHome}.internal" >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/test-hadrift.json" ]] || return 0
    info "  Cleaning up HA test VM (delete-module test-hadrift)..."
    /home/tappaas/bin/delete-module.sh test-hadrift --force >/dev/null 2>&1 || true
}

if [[ "${DEEP}" -eq 1 && -n "${DEFAULT_ZONE}" && "${NODE_COUNT}" -ge 2 ]]; then
    info "${BOLD}Deep Test: cluster:ha drift reconcile (issue #193)${CL}"
    info "  Default zone ${BL}${DEFAULT_ZONE}${CL} (VLAN ${DEFAULT_VLAN}); ${NODE_COUNT} nodes"
    trap deep_cleanup_ha EXIT

    THVM="test-hadrift"
    HFIX="${SCRIPT_DIR}/test-hadrift"
    HUPSVC="${SCRIPT_DIR}/services/ha/update-service.sh"
    HVMID=921
    hdeep_ok=1

    # 1. Install the disposable HA-managed test VM. The cluster:vm service
    #    creates the VM in the default zone (--zone0 override beats the fixture's
    #    baked value) so it is Active + reachable on either node; the cluster:ha
    #    service configures the rule + replication.
    info "  Installing ${THVM} (NixOS clone, HA-managed on ${DEFAULT_ZONE}/${DEFAULT_VLAN})..."
    if ( cd "${HFIX}" && /home/tappaas/bin/install-module.sh "${THVM}" --zone0 "${DEFAULT_ZONE}" ) >/dev/null 2>&1; then
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
elif [[ "${DEEP}" -eq 1 && -n "${DEFAULT_ZONE}" && "${NODE_COUNT}" -lt 2 ]]; then
    info "${BOLD}Deep Test: cluster:ha drift reconcile${CL}"
    skip "HA drift test needs ≥2 cluster nodes for a replication target (found ${NODE_COUNT})"
elif [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: cluster:ha drift reconcile${CL}"
    skip "no Active default zone resolved (site.json .name / zones.json) — HA drift test skipped"
else
    info "${BOLD}Deep Test: cluster:ha drift reconcile${CL}"
    skip "HA VM creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Deep Test: create an LXC, verify net/DNS, induce drift, reconcile ─

deep_cleanup_lxc() {
    dns-manager --no-ssl-verify delete test-lxcdrift "${DEFAULT_ZONE:-srvHome}.internal" >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/test-lxcdrift.json" ]] || return 0
    info "  Cleaning up LXC test container (delete-module test-lxcdrift)..."
    /home/tappaas/bin/delete-module.sh test-lxcdrift --force >/dev/null 2>&1 || true
}

if [[ "${DEEP}" -eq 1 && -n "${DEFAULT_ZONE}" ]]; then
    info "${BOLD}Deep Test: cluster:lxc provisioner + drift reconcile (issue #203)${CL}"
    info "  Default zone ${BL}${DEFAULT_ZONE}${CL} (VLAN ${DEFAULT_VLAN})"
    trap deep_cleanup_lxc EXIT

    TLVM="test-lxcdrift"
    LFIX="${SCRIPT_DIR}/test-lxcdrift"
    LUPSVC="${SCRIPT_DIR}/services/lxc/update-service.sh"
    LVMID=922
    ldeep_ok=1

    # 1. Install the disposable plain-Debian container (no GPU/meta) in the
    #    default zone (--zone0 override beats the fixture's baked value). The
    #    default zone is Active + trunked cross-node, unlike the legacy srvHome.
    info "  Installing ${TLVM} (Debian CT on ${DEFAULT_ZONE}/${DEFAULT_VLAN}; first run downloads the template)..."
    if ( cd "${LFIX}" && /home/tappaas/bin/install-module.sh "${TLVM}" --zone0 "${DEFAULT_ZONE}" ) >/dev/null 2>&1; then
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

    # 2. net0 must be on the default zone's VLAN tag — proves zone→tag for LXC.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        # shellcheck disable=SC2086,SC2029
        lnet0=$(ssh ${SSH_OPTS} "root@${LNODE}.${MGMT}.internal" "pct config ${LVMID} | grep '^net0'" 2>/dev/null) || true
        if grep -q "tag=${DEFAULT_VLAN}" <<< "${lnet0}"; then
            pass "container net0 bound to ${DEFAULT_ZONE} VLAN (tag=${DEFAULT_VLAN})"
        else
            fail "container net0 not tagged ${DEFAULT_VLAN} (got: ${lnet0:-none})"
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

    # 4. DNS RESOLVES in the default zone. LXCs use masqdns (dynamic, lease-based
    #    DNS) — install-service.sh deliberately registers NO static dns-manager
    #    pin (a static addn-host would shadow the live lease). So verify that
    #    <vm>.<zone>.internal RESOLVES via the firewall resolver, not that it
    #    appears in the STATIC host list (`dns-manager list`) — the old check
    #    asserted the wrong mechanism. Retry: the lease + masqdns take a moment.
    if [[ "${ldeep_ok}" -eq 1 ]]; then
        lfqdn="test-lxcdrift.${DEFAULT_ZONE}.internal"
        resolved=""
        for _ in $(seq 1 15); do
            resolved=$(getent hosts "${lfqdn}" 2>/dev/null | awk '{print $1}' | head -1)
            [[ -n "${resolved}" ]] && break
            sleep 4
        done
        if [[ -n "${resolved}" ]]; then
            pass "DNS resolves ${lfqdn} → ${resolved} (masqdns lease)"
        else
            fail "DNS did not resolve ${lfqdn} (masqdns lease)"
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
elif [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: cluster:lxc provisioner + drift reconcile${CL}"
    skip "no Active default zone resolved (site.json .name / zones.json) — LXC drift test skipped"
else
    info "${BOLD}Deep Test: cluster:lxc provisioner + drift reconcile${CL}"
    skip "LXC creation + drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Deep Test: storage nodes-list drift reconcile (node-prov. §7.3) ──
# Induce drift on a REAL pool (drop the last site.json-declared node from
# its storage.cfg nodes list), run reconcile-storage-nodes.sh, verify the
# node is restored. Self-healing by construction: the reconcile itself is
# the cleanup, and a trap restores the original list on abort.

if [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: storage nodes-list drift reconcile${CL}"
    _sd_node1="$(get_primary_node_fqdn)"
    # Pick a pool declared for >= 2 nodes whose storage entry HAS a nodes list.
    _sd_pool="" _sd_orig=""
    while read -r _p; do
        _l="$(ssh -n -o BatchMode=yes root@"${_sd_node1}" \
            "sed -n '/^zfspool: ${_p}\$/,/^\$/s/^[[:space:]]*nodes //p' /etc/pve/storage.cfg" 2>/dev/null | head -1)"
        [[ "${_l}" == *,* ]] && { _sd_pool="${_p}"; _sd_orig="${_l}"; break; }
    done < <(jq -r '[.hardware.nodes[].storagePools[]?] | unique | .[]' "${CONFIG_DIR}/site.json" 2>/dev/null)
    if [[ -z "${_sd_pool}" ]]; then
        skip "no multi-node pool with a nodes list found — drift test needs one"
    else
        _sd_drifted="${_sd_orig%,*}"   # drop the last member
        _sd_restore() { ssh -n -o BatchMode=yes root@"${_sd_node1}" "pvesm set '${_sd_pool}' --nodes '${_sd_orig}'" >/dev/null 2>&1 || true; }
        trap _sd_restore EXIT
        ssh -n -o BatchMode=yes root@"${_sd_node1}" "pvesm set '${_sd_pool}' --nodes '${_sd_drifted}'" >/dev/null 2>&1
        if bash "${SCRIPT_DIR}/reconcile-storage-nodes.sh" >/dev/null 2>&1; then
            _sd_now="$(ssh -n -o BatchMode=yes root@"${_sd_node1}" \
                "sed -n '/^zfspool: ${_sd_pool}\$/,/^\$/s/^[[:space:]]*nodes //p' /etc/pve/storage.cfg" 2>/dev/null | head -1)"
            _sd_lost="${_sd_orig##*,}"
            case ",${_sd_now}," in
                *",${_sd_lost},"*) pass "reconcile restored '${_sd_lost}' to ${_sd_pool} nodes (${_sd_now})" ;;
                *) fail "reconcile did not restore '${_sd_lost}' to ${_sd_pool} (now: ${_sd_now})"; _sd_restore ;;
            esac
        else
            fail "reconcile-storage-nodes.sh exited non-zero"
            _sd_restore
        fi
        trap - EXIT
    fi
else
    info "${BOLD}Deep Test: storage nodes-list drift reconcile${CL}"
    skip "storage drift test (use TAPPAAS_TEST_DEEP=1 to run)"
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
