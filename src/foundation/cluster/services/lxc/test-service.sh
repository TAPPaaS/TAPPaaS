#!/usr/bin/env bash
#
# TAPPaaS Cluster LXC Service - Test
#
# Verifies a module's LXC container is healthy and correctly placed.
# Called by test-module.sh for any module that depends on cluster:lxc.
#
# Tests:
#   1. Container exists and is running
#   2. Can exec into the container
#   3. net0 is on the zone0 VLAN tag (or untagged for mgmt)
#   Deep mode:
#   4. Container has an IPv4 and DNS resolves to it
#
# Usage: test-service.sh <module-name>
#
# Exit codes: 0 all passed · 1 a check failed · 2 fatal
#

# shellcheck disable=SC2029
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

check_json "/home/tappaas/config/${MODULE}.json" || exit 2
readonly ZONES_FILE="/home/tappaas/config/zones.json"
MGMT="mgmt"

# vmid/zone0 may be overridden to test a non-default instance (issue #196).
VMID="${TAPPAAS_VMID_OVERRIDE:-$(get_config_value 'vmid')}"
ZONE0="${TAPPAAS_ZONE0_OVERRIDE:-$(get_config_value 'zone0' 'mgmt')}"
VMNAME="$(get_config_value 'vmname' "${MODULE}")"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0
pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

info "  ${BOLD}cluster:lxc tests for ${BL}${MODULE}${CL} (VMID ${VMID})"

# ── Locate the container's node ──────────────────────────────────────

node=""
status=""
# shellcheck disable=SC2046
for cand in $(get_all_node_hostnames); do
    row=$(ssh "${SSH_OPTS[@]}" "root@${cand}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" \
            '.[] | select(.vmid == $id and .type == "lxc") | "\(.node) \(.status)"' 2>/dev/null) || true
    if [[ -n "${row}" ]]; then node="${row%% *}"; status="${row##* }"; break; fi
done

if [[ -z "${node}" ]]; then
    fail "container ${VMID} not found on the cluster"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi
NODE_FQDN="${node}.${MGMT}.internal"

# ── Test 1: running ──────────────────────────────────────────────────
info "  Check 1: container running"
if [[ "${status}" == "running" ]]; then
    pass "LXC ${VMID} is running on ${node}"
else
    fail "LXC ${VMID} status is '${status:-unknown}'"
fi

# ── Test 2: exec ─────────────────────────────────────────────────────
info "  Check 2: exec into container"
if ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct exec ${VMID} -- true" &>/dev/null; then
    pass "can exec into LXC ${VMID}"
else
    fail "cannot exec into LXC ${VMID}"
fi

# ── Test 3: net0 on the right VLAN ───────────────────────────────────
info "  Check 3: net0 VLAN matches zone0 (${ZONE0})"
desired_tag=$(jq -r --arg z "${ZONE0}" '.[$z].vlantag // empty' "${ZONES_FILE}" 2>/dev/null)
live_net0=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct config ${VMID} | grep '^net0'" 2>/dev/null) || true
live_tag=$( { grep -oE 'tag=[0-9]+' <<< "${live_net0}" || true; } | cut -d= -f2)
if [[ "${ZONE0}" == "mgmt" || -z "${desired_tag}" || "${desired_tag}" == "0" ]]; then
    if [[ -z "${live_tag}" ]]; then pass "net0 untagged (zone ${ZONE0})"; else fail "net0 tagged ${live_tag} but zone ${ZONE0} is untagged"; fi
elif [[ "${live_tag}" == "${desired_tag}" ]]; then
    pass "net0 tagged ${live_tag} (zone ${ZONE0})"
else
    fail "net0 tag ${live_tag:-none} != expected ${desired_tag} (zone ${ZONE0})"
fi

# ── Deep: IPv4 + DNS ─────────────────────────────────────────────────
if [[ "${DEEP}" -eq 1 ]]; then
    info "  Check 4: IPv4 + DNS resolution"
    ip=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct exec ${VMID} -- hostname -I 2>/dev/null" 2>/dev/null \
         | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -1) || true
    if [[ -z "${ip}" ]]; then
        fail "container reported no IPv4"
    else
        resolved=$(dig +short A "${VMNAME}.${ZONE0}.internal" 2>/dev/null | head -1) || true
        if [[ "${resolved}" == "${ip}" ]]; then
            pass "DNS ${VMNAME}.${ZONE0}.internal → ${ip}"
        else
            fail "DNS mismatch: ${VMNAME}.${ZONE0}.internal=${resolved:-none}, container IP=${ip}"
        fi
    fi
fi

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
