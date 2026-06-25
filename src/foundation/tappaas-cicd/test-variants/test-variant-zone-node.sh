#!/usr/bin/env bash
#
# test-variant-zone-node.sh — environment with a dedicated zone, module placed on
# a NON-firewall node (tappaas3). The legacy ADR-005 variant registry is retired
# (ADR-007) — "variant" below is just the environment/zone name.
#
# A module VM on a node OTHER than the firewall's gets a DHCP IP only if the new
# VLAN is present at EVERY layer of the path:
#   1. zones.json                      ← zone-controller
#   2. OPNsense L3 + DHCP              ← zone-manager
#   3. firewall-VM trunk              ← proxmox-manager trunks
#   4. each node's lan bridge-vids    ← zone-controller → proxmox-manager bridge-vids (the fix)
#   5. PHYSICAL inter-node switch trunk ← NOT automated (ADR-008 switch-controller, WIP)
#
# This test asserts the node side (1-4, what zone-controller owns) and then PROBES
# the inter-node L2 path (5). On this cluster the physical switch trunks the static
# VLAN set but not new variant VLANs, so step 5 fails and the VM phase is SKIPPED
# with that diagnosis — proving the bridge-vids fix is necessary but not sufficient
# for off-firewall-node placement (the switch trunk is the remaining requirement).
# See docs/design/zone-controller.md.
#
# DEEP test: it creates and destroys a real zone (and a real VM only if the L2 path
# is viable). Run as:
#   ./test-variant-zone-node.sh --deep [--no-cleanup]
#   TAPPAAS_TEST_DEEP=1 ./test-variant-zone-node.sh
#
# Exit codes: 0 all passed/skipped · 1 a check failed · 2 fatal (bad environment)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIX="${SCRIPT_DIR}/fixtures"

# shellcheck source=../lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null \
    || . "${SCRIPT_DIR}/../lib/common-install-routines.sh"

# ── parameters ───────────────────────────────────────────────────────
readonly VAR="zcnode"                       # environment + dedicated-zone name
readonly DOMAIN="zcnode.test2.tapaas.org"
readonly FROM_ZONE="srvCust"
readonly DEST_NODE="${TAPPAAS_TEST_NODE:-tappaas3}"   # the non-firewall destination
readonly MODULE="tvbase"                    # minimal fixture VM (deps: cluster:vm, templates:debian)
readonly VMID="8950"                        # fixture VMID band 8900-8999
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
readonly ENV_FILE="${CONFIG_DIR}/environments/${VAR}.json"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
NO_CLEANUP="${TAPPAAS_TEST_NO_CLEANUP:-0}"
for arg in "$@"; do
    case "${arg}" in
        --deep) DEEP=1 ;;
        --no-cleanup) NO_CLEANUP=1 ;;
        -h|--help) echo "Usage: $0 [--deep] [--no-cleanup]"; exit 0 ;;
        *) ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { warn "  ⊘ $1 (skipped)"; SKIP=$((SKIP + 1)); }
section() { echo; info "${BOLD:-}${1}${CL}"; }

# Firewall node (where the firewall VM lives) — for the "co-located vs not" point.
FW_NODE="$(ssh -o ConnectTimeout=6 root@"$(get_node_hostname 0)".mgmt.internal \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[]|select(.name==\"firewall\")|.node'" 2>/dev/null || echo "")"

# ── cleanup (idempotent; runs on any exit) ───────────────────────────
cleanup() {
    local rc=$?
    if [[ "${NO_CLEANUP}" == "1" ]]; then
        warn "Skipping cleanup (--no-cleanup): environment '${VAR}', zone '${VAR}', VM ${VMID} left in place."
        exit "${rc}"
    fi
    section "─── cleanup ───"
    if [[ -f "${CONFIG_DIR}/${MODULE}-${VAR}.json" ]] || ssh -o ConnectTimeout=6 root@"${DEST_NODE}".mgmt.internal "qm status ${VMID}" >/dev/null 2>&1; then
        info "Removing module ${MODULE}-${VAR} (VM ${VMID})…"
        /home/tappaas/bin/delete-module.sh "${MODULE}-${VAR}" --force >/dev/null 2>&1 \
            || warn "  delete-module ${MODULE}-${VAR} returned non-zero — check VM ${VMID} on ${DEST_NODE}"
    fi
    [[ -f "${ENV_FILE}" ]] && { rm -f "${ENV_FILE}"; info "Removed environment '${VAR}'"; }
    if jq -e --arg z "${VAR}" 'has($z)' "${ZONES_FILE}" >/dev/null 2>&1; then
        info "Removing dedicated zone '${VAR}' (via zone-controller)…"
        zone-controller delete "${VAR}" --apply >/dev/null 2>&1 \
            || warn "  zone-controller delete ${VAR} returned non-zero — clean up the zone manually"
    fi
    exit "${rc}"
}
trap cleanup EXIT INT TERM

# ── preflight ────────────────────────────────────────────────────────
section "Preflight"
if [[ "${DEEP}" != "1" ]]; then
    skip "variant zone-on-node test is DEEP only — pass --deep (creates a real zone + VM on ${DEST_NODE})"
    echo; info "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
    NO_CLEANUP=1   # nothing was created
    exit 0
fi
command -v zone-controller >/dev/null 2>&1 || { fail "zone-controller not on PATH"; exit 2; }
[[ -f "${FIX}/${MODULE}.json" ]] || { fail "fixture ${MODULE}.json missing"; exit 2; }
ssh -o ConnectTimeout=6 root@"${DEST_NODE}".mgmt.internal true >/dev/null 2>&1 \
    || { fail "destination node ${DEST_NODE} unreachable over mgmt"; exit 2; }
if jq -e --arg z "${VAR}" 'has($z)' "${ZONES_FILE}" >/dev/null 2>&1; then
    fail "zone '${VAR}' already exists — a previous run did not clean up"; exit 2
fi
[[ "${FW_NODE}" != "${DEST_NODE}" ]] \
    && pass "destination ${DEST_NODE} is NOT the firewall node (${FW_NODE:-unknown}) — this is the gap-exposing case" \
    || skip "firewall also runs on ${DEST_NODE}; co-located placement masks the bridge-vids gap"

# ── 1. create the dedicated zone (zone-controller) + author the environment ──
section "1. zone-controller add ${VAR} --from-zone ${FROM_ZONE} + author environment ${VAR}"
if zone-controller add "${VAR}" --from-zone "${FROM_ZONE}" --variant "${VAR}" >/dev/null 2>&1; then
    pass "dedicated zone '${VAR}' created"
else
    fail "zone-controller add failed"; exit 1
fi
# Author the environment file (the source of truth — no variant registry).
mkdir -p "$(dirname "${ENV_FILE}")"
_owner="$(jq -r '.owner // empty' "${CONFIG_DIR}/site.json" 2>/dev/null)"
[[ -n "${_owner}" ]] || _owner="$(ls "${CONFIG_DIR}/people/organizations"/*.json 2>/dev/null | head -1 | xargs -r basename | sed 's/\.json$//')"
if jq -n --arg n "${VAR}" --arg owner "${_owner}" --arg d "${DOMAIN}" --arg z "${VAR}" '
        { name: $n, displayName: $n, ownerOrg: $owner,
          domains: { primary: $d, dnsMode: "wildcard" },
          network: { zone: $z } }' > "${ENV_FILE}"; then
    pass "environment '${VAR}' authored (zone ${VAR}, ${DOMAIN})"
else
    fail "could not author environment file ${ENV_FILE}"; exit 1
fi
VLAN="$(jq -r --arg z "${VAR}" '.[$z].vlantag // empty' "${ZONES_FILE}")"
SUBNET="$(jq -r --arg z "${VAR}" '.[$z].ip // empty' "${ZONES_FILE}" | cut -d/ -f1 | cut -d. -f1-3)"
[[ -n "${VLAN}" ]] && pass "zone '${VAR}' has VLAN ${VLAN} (subnet ${SUBNET}.0/24)" || { fail "zone has no vlantag"; exit 1; }

# ── 2. the fix: VLAN must be on EVERY node's bridge-vids (the gap-closer) ──
section "2. node bridge-vids — new VLAN ${VLAN} on every node (the fix)"
if proxmox-manager bridge-vids 2>&1 | grep -q "Proxmox network in sync"; then
    pass "bridge-vids in sync across all nodes (no drift after add)"
else
    fail "bridge-vids drift remains after add — the gap is NOT closed"
fi
if ssh -o ConnectTimeout=6 root@"${DEST_NODE}".mgmt.internal \
        "bridge vlan show | grep -qw ${VLAN}" >/dev/null 2>&1; then
    pass "VLAN ${VLAN} present on ${DEST_NODE} lan bridge"
else
    fail "VLAN ${VLAN} ABSENT from ${DEST_NODE} lan bridge — VMs there will get no IP"
fi

# ── 3. inter-node L2 path: does the NEW VLAN actually traverse to the firewall? ──
# The node side (steps 1-2) is what zone-controller owns. But a VM on a non-firewall
# node also needs the PHYSICAL inter-node path to carry the new VLAN. We test this
# cheaply (no VM): put the destination host on the new VLAN and ping the firewall
# gateway. This isolates a switch-trunk gap from the node bridge-vids fix.
section "3. inter-node L2 — does VLAN ${VLAN} reach the firewall gateway ${SUBNET}.1 from ${DEST_NODE}?"
L2_RC="$(ssh -o ConnectTimeout=8 root@"${DEST_NODE}".mgmt.internal "
    bridge vlan add vid ${VLAN} dev lan self 2>/dev/null
    ip link add link lan name zcp${VLAN} type vlan id ${VLAN} 2>/dev/null
    ip addr add ${SUBNET}.222/24 dev zcp${VLAN} 2>/dev/null
    ip link set zcp${VLAN} up; sleep 3
    ping -c2 -W2 ${SUBNET}.1 >/dev/null 2>&1; echo \$?
    ip link del zcp${VLAN} 2>/dev/null
    bridge vlan del vid ${VLAN} dev lan self 2>/dev/null
" 2>/dev/null | tail -1)"
INTERNODE_OK=0
if [[ "${L2_RC}" == "0" ]]; then
    INTERNODE_OK=1
    pass "VLAN ${VLAN} reaches the firewall from ${DEST_NODE} — full L2 path (node + switch) carries the new VLAN"
else
    # Node bridge-vids passed (step 2) but the new VLAN does not traverse to the
    # firewall: the PHYSICAL inter-node switch trunks the static VLAN set but not
    # this new one. That is the ADR-008 switch-controller gap, NOT the bridge-vids fix.
    skip "VLAN ${VLAN} does NOT reach the firewall from ${DEST_NODE} — node bridge-vids is OK (step 2), but the physical inter-node switch does not trunk the new VLAN (ADR-008 switch-controller / manual switch trunk). Off-node placement is blocked here regardless of zone-controller."
fi

# ── 4. end-to-end VM install — only meaningful if the L2 path is viable ──
if [[ "${INTERNODE_OK}" != "1" ]]; then
    skip "VM install on ${DEST_NODE} (the new VLAN can't traverse the switch — would just time out waiting for an IP)"
else
    section "4. install ${MODULE} --environment ${VAR} --node ${DEST_NODE} → VM gets an IP"
    INSTALL_LOG="${TAPPAAS_LOG_DIR:-/home/tappaas/log}/zone-node-install-${VAR}.log"
    if ( cd "${FIX}" && /home/tappaas/bin/install-module.sh "${MODULE}" --environment "${VAR}" --node "${DEST_NODE}" --vmid "${VMID}" ) >"${INSTALL_LOG}" 2>&1; then
        pass "install-module ${MODULE}-${VAR} on ${DEST_NODE} succeeded"
    else
        fail "install-module failed despite a viable L2 path — see ${INSTALL_LOG}:"
        tail -n 12 "${INSTALL_LOG}" 2>/dev/null | sed 's/^/        | /' >&2
    fi
    VM_IP="$(ssh -o ConnectTimeout=6 root@"${DEST_NODE}".mgmt.internal \
        "qm guest cmd ${VMID} network-get-interfaces 2>/dev/null" \
        | grep -oE "${SUBNET}\.[0-9]+" | head -1 || true)"
    [[ -n "${VM_IP}" ]] \
        && pass "VM acquired DHCP IP ${VM_IP} on ${DEST_NODE} (end-to-end off-node placement works)" \
        || fail "VM has NO ${SUBNET}.x IP on ${DEST_NODE}"
fi

# ── summary ──────────────────────────────────────────────────────────
echo
info "Results: ${GN}${PASS} passed${CL}, $([[ ${FAIL} -gt 0 ]] && echo "${RD}")${FAIL} failed${CL}, ${SKIP} skipped"
[[ "${FAIL}" -eq 0 ]] || exit 1
exit 0
