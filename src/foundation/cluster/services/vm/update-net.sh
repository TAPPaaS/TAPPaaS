#!/usr/bin/env bash
#
# cluster:vm — the net0/net1 field hook (ADR-020 D4).
#
# Applies one NIC composite from a drift record. The manager decided WHAT should
# change — bridge0/zone0/trunks0/mac0 are four declared fields, while Proxmox
# stores them as a single `netN` string — and resolved every value it could;
# this assembles the string and sets it.
#
# THREE INVARIANTS THIS PRESERVES, all of them hard-won:
#
#   1. The live MAC is kept unless the module pins one. A NIC that silently
#      changes MAC loses its DHCP lease and its DNS record.
#   2. `queues` is carried over verbatim and NEVER changed on a running NIC —
#      changing it forces a disruptive hot-replug (#194). No module field
#      declares it, so it can only come from the reported actual state.
#   3. Removing the NIC is `qm set --delete netN`, not an empty value. A module
#      that no longer declares bridge1 while the guest still has net1 means
#      "take the second NIC away".
#
# A composite carries ONLY the fields that drifted. Every other component is
# read from the record's `actual` — which is exactly what makes 1 and 2 fall
# out of the data model instead of needing a special case.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-net.sh <module> --unit <file> [--check] [--force]
#                          [--field <f> --desired <v> --actual <v>]
#
# The unit file is authoritative; the trio cannot carry a composite's four
# fields plus the live-only components.
#
# Exit codes (the uniform hook protocol):
#   0   applied, or already in sync
#   10  would change, but needs disruption authorization
#   20  refused — cannot be applied
#   1   error
#
# Reboot / wait-for-IP / DNS are NOT done here. They are declared side effects
# on the manifest's net0/net1 composites and are sequenced ONCE per drift record
# by the runner, so two changed NICs still produce exactly one reboot and one
# DNS pass.

# The remote `qm` command embeds locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/vm-net.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/vm-net.sh"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

MODULE=""
UNIT_FILE=""
CHECK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)    UNIT_FILE="${2:-}"; shift ;;
        --check)   CHECK=1 ;;
        --force)   : ;;  # A NIC change applies the same way either way; the
                         # DISRUPTION it implies is the runner's reboot side
                         # effect, authorized there, not here.
        --field|--desired|--actual) shift ;;
        -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-net.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}"    ]] || { echo "Usage: $0 <module> --unit <file> [--check] [--force]" >&2; exit 1; }
[[ -r "${UNIT_FILE}" ]] || { echo "update-net.sh: --unit <file> is required and must be readable" >&2; exit 1; }

NIC="$(jq -r '.name' "${UNIT_FILE}")"          # net0 | net1
[[ "${NIC}" =~ ^net[0-9]+$ ]] || { error "update-net.sh: unit '${NIC}' is not a NIC"; exit 1; }
IDX="${NIC#net}"

# A drifted field's value from the unit ("" when that field did not drift), and
# the record's view of live state. `*Norm` is the manager's normalized form:
# for zone<N> that is the resolved VLAN TAG and for trunks<N> the resolved tag
# list, so this hook never reads zones.json — resolution has one home.
u_desired()      { jq -r --arg f "$1" '(.fields[] | select(.field == $f) | .desired) // ""'     "${UNIT_FILE}"; }
u_desired_norm() { jq -r --arg f "$1" '(.fields[] | select(.field == $f) | .desiredNorm) // ""' "${UNIT_FILE}"; }
u_live()         { jq -r --arg k "$1" '(.actual[$k]) // ""' "${UNIT_FILE}"; }

# Did this field drift at all? A composite carries ONLY the fields that changed,
# so PRESENCE is the question — not whether the value is empty. Removing a
# trunk list drifts trunks0 to "", which must not be mistaken for "trunks0 did
# not change" or the NIC would silently keep its old trunks.
u_has() { jq -e --arg f "$1" '.fields[] | select(.field == $f)' "${UNIT_FILE}" >/dev/null 2>&1; }

# A component: the drifted value when the field changed, else what the guest
# already has. This single rule is invariants 1 and 2. `norm` selects the
# manager's normalized form, which for zone<N>/trunks<N> is the resolved VLAN
# tag / tag list Proxmox wants.
component() {
    local field="$1" live_key="$2" norm="${3:-0}"
    if u_has "${field}"; then
        if [[ "${norm}" == "1" ]]; then u_desired_norm "${field}"; else u_desired "${field}"; fi
    else
        u_live "${live_key}"
    fi
}

# ── Locate the guest ─────────────────────────────────────────────────
# From the record, not from another cluster query: `actual.node` is where the
# reporter found it, and re-asking could race with a migrate that happened in
# between (#526).
VMID="$(u_live vmid)"
NODE="$(u_live node)"
[[ -n "${VMID}" && -n "${NODE}" ]] \
    || { error "update-net.sh: the drift record carries no vmid/node — cannot reach the guest"; exit 1; }
NODE_FQDN="${NODE}.${MGMT}.internal"

# ── Removal: the module no longer declares this NIC ──────────────────
# bridge<N> resolving to the "NONE" sentinel with a live NIC present means the
# second interface is being taken away.
DESIRED_BRIDGE="$(u_desired "bridge${IDX}")"
LIVE_BRIDGE="$(u_live "${NIC}.bridge")"

if [[ "${DESIRED_BRIDGE}" == "NONE" || "${DESIRED_BRIDGE}" == "none" ]]; then
    if [[ -z "${LIVE_BRIDGE}" ]]; then
        debug "  ${NIC}: already absent"
        exit 0
    fi
    if [[ "${CHECK}" == "1" ]]; then
        info "  ${NIC}: would be REMOVED (no bridge${IDX} in config)"
        exit 0
    fi
    debug "  ${NIC}: removing (no bridge${IDX} in config)"
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm set ${VMID} --delete ${NIC}" >/dev/null \
        || { error "  qm set --delete ${NIC} failed"; exit 1; }
    exit 0
fi

# ── Build and set ────────────────────────────────────────────────────
BRIDGE="$(component "bridge${IDX}" "${NIC}.bridge")"
TAG="$(component    "zone${IDX}"   "${NIC}.tag"    1)"
TRUNKS="$(component "trunks${IDX}" "${NIC}.trunks" 1)"
MAC="$(component    "mac${IDX}"    "${NIC}.mac")"
# queues is live-only: never desired, never changed — only carried across.
QUEUES="$(u_live "${NIC}.queues")"

NETOPTS="$(vmnet_build_netopts "${BRIDGE}" "${MAC}" "${TAG}" "${TRUNKS}" "${QUEUES}")"

if [[ "${CHECK}" == "1" ]]; then
    info "  ${NIC}: would set ${NETOPTS}"
    exit 0
fi

debug "  ${NIC}: ${NETOPTS}"
ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm set ${VMID} --${NIC} $(printf '%q' "${NETOPTS}")" >/dev/null \
    || { error "  qm set --${NIC} failed"; exit 1; }
exit 0
