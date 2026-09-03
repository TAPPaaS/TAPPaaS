#!/usr/bin/env bash
#
# cluster:lxc — the net0 field hook (ADR-020 D4).
#
# The container counterpart of services/vm/update-net.sh. Same contract, same
# uniform CLI; what differs is how Proxmox spells a container's NIC:
#
#   VM         virtio=<MAC>,bridge=lan,tag=200[,trunks=…][,queues=…]
#   container  name=eth0,bridge=lan,hwaddr=<MAC>,ip=dhcp[,tag=200][,trunks=…]
#
# A container's NIC carries `name=` and `ip=dhcp`, has no queues, and puts the
# MAC in `hwaddr=`. TAPPaaS gives a container exactly ONE interface, which is
# why there is no net1 here and why bridge1/mac1/zone1/trunks1 are cluster:vm's
# alone (corrected in module-fields.json, ADR-020 P5).
#
# THE INVARIANT THIS PRESERVES: the live hwaddr is carried across. A container
# that silently changes MAC loses its DHCP lease, and with it the masqdns name
# the whole estate reaches it by.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-net.sh <module> --unit <file> [--check] [--force]
#                          [--field <f> --desired <v> --actual <v>]
#
# Exit codes (the uniform hook protocol):
#   0   applied, or already in sync
#   10  would change, but needs disruption authorization
#   20  refused — cannot be applied
#   1   error
#
# The restart, the wait for an address and the DNS pass are NOT done here: they
# are declared side effects on the manifest's net0 composite, sequenced once per
# drift record by the runner.

# The remote `pct` command embeds locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

MODULE=""
UNIT_FILE=""
CHECK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)    UNIT_FILE="${2:-}"; shift ;;
        --check)   CHECK=1 ;;
        --force)   : ;;  # the disruption a NIC change implies is the runner's
                         # restart side effect, authorized there, not here
        --field|--desired|--actual) shift ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-net.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}"    ]] || { echo "Usage: $0 <module> --unit <file> [--check] [--force]" >&2; exit 1; }
[[ -r "${UNIT_FILE}" ]] || { echo "update-net.sh: --unit <file> is required and must be readable" >&2; exit 1; }

NIC="$(jq -r '.name' "${UNIT_FILE}")"
[[ "${NIC}" == "net0" ]] || { error "update-net.sh: a container has one NIC; got unit '${NIC}'"; exit 1; }

u_desired()      { jq -r --arg f "$1" '(.fields[] | select(.field == $f) | .desired) // ""'     "${UNIT_FILE}"; }
u_desired_norm() { jq -r --arg f "$1" '(.fields[] | select(.field == $f) | .desiredNorm) // ""' "${UNIT_FILE}"; }
u_live()         { jq -r --arg k "$1" '(.actual[$k]) // ""' "${UNIT_FILE}"; }

# PRESENCE, not emptiness: a composite carries only the fields that drifted, so
# clearing a trunk list (drifting it to "") must not read as "did not change".
u_has() { jq -e --arg f "$1" '.fields[] | select(.field == $f)' "${UNIT_FILE}" >/dev/null 2>&1; }

component() {
    local field="$1" live_key="$2" norm="${3:-0}"
    if u_has "${field}"; then
        if [[ "${norm}" == "1" ]]; then u_desired_norm "${field}"; else u_desired "${field}"; fi
    else
        u_live "${live_key}"
    fi
}

# From the record, not a fresh cluster query: actual.node is where the reporter
# found the container, and re-asking could race with a move in between.
VMID="$(u_live vmid)"
NODE="$(u_live node)"
[[ -n "${VMID}" && -n "${NODE}" ]] \
    || { error "update-net.sh: the drift record carries no vmid/node — cannot reach the container"; exit 1; }
NODE_FQDN="${NODE}.${MGMT}.internal"

BRIDGE="$(component "bridge0" "net0.bridge")"
TAG="$(component    "zone0"   "net0.tag"    1)"
TRUNKS="$(component "trunks0" "net0.trunks" 1)"
MAC="$(component    "mac0"    "net0.mac")"

[[ -n "${BRIDGE}" ]] || { error "update-net.sh: no bridge for net0 — a container must have one NIC"; exit 1; }

# Build the container form. Order matches what Create-TAPPaaS-LXC.sh writes, so
# a converged NIC is spelled the same as a freshly created one.
NETOPTS="name=eth0,bridge=${BRIDGE}"
[[ -n "${MAC}" ]]                    && NETOPTS="${NETOPTS},hwaddr=${MAC}"
NETOPTS="${NETOPTS},ip=dhcp"
[[ -n "${TAG}" && "${TAG}" != "0" ]] && NETOPTS="${NETOPTS},tag=${TAG}"
[[ -n "${TRUNKS}" ]]                 && NETOPTS="${NETOPTS},trunks=${TRUNKS}"

if [[ "${CHECK}" == "1" ]]; then
    info "  ${NIC}: would set ${NETOPTS}"
    exit 0
fi

debug "  ${NIC}: ${NETOPTS}"
ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct set ${VMID} --${NIC} $(printf '%q' "${NETOPTS}")" >/dev/null \
    || { error "  pct set --${NIC} failed"; exit 1; }
exit 0
