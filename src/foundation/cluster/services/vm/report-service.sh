#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Report (actual state)
#
# Prints the LIVE state of a module's Proxmox VM as a flat JSON object, keyed by
# the `liveKey`s this service's fields.json declares. It is the READ half of the
# ADR-020 D7 contract:
#
#     desired = module-manager module resolve <name>        [TS, the one resolver]
#     actual  = cluster:vm/report-service.sh <name>         [this script]
#     drift   = diff(desired, actual)                       [TS, the one differ]
#               update-service.sh <name> --apply-drift ...  [bash, pure apply]
#
# This script EXTRACTS ONLY. It does not resolve desired state, does not
# normalize, does not compare, and never touches the VM. Those all belong to the
# single differ in the manager — which is the whole point: before ADR-020 the
# same `qm config` parsing lived in cluster:vm/update-service.sh AND (in TS) in
# module-manager's inspect.ts, so the reporting and acting paths could disagree
# about what "actual" even was (#550).
#
# One read, several consumers: `module resolve`/`reconcile` (report), `modify`
# (apply), test-service.sh and the health checks all take their actual state
# from here rather than each running their own `qm config`.
#
# Usage: report-service.sh [--vmid ID] <module-name>
#   --vmid ID   Report a non-default instance (mirrors test-service.sh's
#               TAPPAAS_VMID_OVERRIDE), for fixtures and deep tests.
#
# Output: a single JSON object on stdout. Keys are the fields.json `liveKey`s:
#
#   { "vmid": "340", "node": "tappaas1", "status": "running",
#     "name": "nextcloud", "cores": "4", "memory": "8192", "cpu": "host",
#     "tags": "TAPPaaS;App", "bios": "ovmf", "ostype": "l26",
#     "storage": "tanka1", "diskSize": "80G",
#     "net0": "virtio=02:..,bridge=lan,tag=200", "net1": "" }
#
# EVERY declared key is always present. An absent value is the empty string, so
# a consumer can tell "the guest does not have this" from "the reporter did not
# look" — the latter is an ERROR here, never an empty field. Values are RAW, as
# Proxmox spells them; the manager normalizes both sides.
#
# STDOUT carries that object and nothing else; every diagnostic goes to stderr.
#
# Exit codes:
#   0  the guest was found and its state reported
#   1  the guest could not be located or read (state UNKNOWN — never partial)
#   2  usage error
#

# Remote `qm`/`pvesh` commands intentionally embed locally-computed values
# (VMID, node) that expand client-side before being sent over ssh.
# shellcheck disable=SC2029
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="/home/tappaas/config"
readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/vm-net.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/vm-net.sh"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# STDOUT IS THE CONTRACT: exactly one JSON object, nothing else. The shared
# logging helpers — and check_json's schema validation, which warns about any
# field module-fields.json does not declare — write to stdout, so a module with
# one unknown field would otherwise emit a warning line ahead of the JSON and
# every consumer's parse would fail. Rather than chase each call site, hold the
# real stdout on fd 3 and point stdout at stderr for the whole script; the final
# jq writes to fd 3. Diagnostics stay visible to a human, and machine output
# cannot be contaminated by a library that decides to print something new.
exec 3>&1 1>&2

# ── Arguments ────────────────────────────────────────────────────────

MODULE=""
VMID_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)    VMID_OVERRIDE="${2:-}"; [[ -n "${VMID_OVERRIDE}" ]] || { echo "--vmid requires a value" >&2; exit 2; }; shift ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "report-service.sh: unknown option '$1'" >&2; exit 2 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 [--vmid ID] <module-name>" >&2
    exit 2
fi

check_json "${CONFIG_DIR}/${MODULE}.json" || exit 1

# Normalize Pattern-A configs (nested under .config."<module>:<service>") so the
# vmid/node lookups below work for either config shape. This reads ONLY the two
# fields needed to LOCATE the guest — no defaulting of reported values happens
# in this script; that is the resolver's job, on the desired side.
JSON="$(normalize_module_config < "${CONFIG_DIR}/${MODULE}.json")"

VMID="${VMID_OVERRIDE:-$(get_config_value 'vmid')}"
CONFIG_NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
[[ "${CONFIG_NODE}" == "null" || -z "${CONFIG_NODE}" ]] && CONFIG_NODE="$(get_node_hostname 0)"

# ── Locate the guest cluster-wide ────────────────────────────────────
# The config node is only a HINT: a migrate or an HA failover deliberately
# leaves .node unchanged, so the guest may live elsewhere (#526). Ask the
# config node first (the common case, one round-trip), then every other node.
# Reporting the node we FOUND it on is what makes `node` drift detectable at
# all — if this script trusted config.node, a migrated guest would report as
# being exactly where the config claims.

actual_node=""
vm_status=""
# shellcheck disable=SC2046  # word-splitting of hostnames is intended
for cand in "${CONFIG_NODE}" $(get_all_node_hostnames); do
    row=$(ssh "${SSH_OPTS[@]}" "root@${cand}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" \
            '.[] | select(.vmid == $id and .type == "qemu") | "\(.node) \(.status)"' 2>/dev/null) || true
    if [[ -n "${row}" ]]; then
        actual_node="${row%% *}"
        vm_status="${row##* }"
        break
    fi
done

if [[ -z "${actual_node}" ]]; then
    echo "report-service.sh: VM ${VMID} (${MODULE}) not found on any cluster node" >&2
    exit 1
fi

NODE_FQDN="${actual_node}.${MGMT}.internal"

# ── Read the live config ─────────────────────────────────────────────

LIVE="$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm config ${VMID}" 2>/dev/null)" || {
    echo "report-service.sh: failed to read 'qm config ${VMID}' on ${actual_node}" >&2
    exit 1
}

# One key from the `qm config` "key: value" text. Empty when the key is absent —
# which is a fact about the guest, not a failure: a VM with one NIC genuinely
# has no net1.
live_field() { awk -F': ' -v k="$1" '$1==k {print $2; exit}' <<< "${LIVE}"; }

# Some keys are OMITTED from `qm config` when the guest runs at the HYPERVISOR's
# implicit default, so an absent key still describes a real running value: a VM
# with no `cores:` line genuinely has one core. Supplying those is EXTRACTION
# (decoding how Proxmox spells a value), not defaulting — the TAPPaaS schema
# defaults live in module-fields.json and belong to the DESIRED side, resolved
# once by the manager. Keeping the two apart is the #550 distinction.
#
# These are the four update-service.sh has always applied. inspect.ts applied
# only the `bios` one, so a guest running on the implicit default reported
# differently depending on which path you asked — one more reason the two paths
# now share this single reader.
live_field_or() {
    local v
    v="$(live_field "$1")"
    [[ -n "${v}" ]] && { printf '%s' "${v}"; return 0; }
    printf '%s' "$2"
}

# The boot disk, across the buses Proxmox may have used. The FIRST present bus
# wins, matching how install-service.sh creates them and how inspect has always
# read them. Both the storage pool and the size come from the same value
# ("tanka1:vm-340-disk-0,size=80G"), so they are extracted together.
disk_value=""
for bus in scsi0 virtio0 ide0 sata0; do
    v="$(live_field "${bus}")"
    if [[ -n "${v}" ]]; then
        disk_value="${v}"
        break
    fi
done
live_storage="${disk_value%%:*}"
live_disksize="$(sed -n 's/.*size=\([0-9]\+[GMTKgmtk]\?\).*/\1/p' <<< "${disk_value}")"

# ── Emit ─────────────────────────────────────────────────────────────
# jq builds the object so every value is correctly escaped — a guest name or a
# tag list containing a quote must not be able to produce invalid JSON (or,
# worse, inject a key). Keys are the fields.json `liveKey`s, and EVERY one is
# emitted, empty when absent.

jq -n \
    --arg vmid     "${VMID}" \
    --arg node     "${actual_node}" \
    --arg status   "${vm_status}" \
    --arg name     "$(live_field 'name')" \
    --arg cores    "$(live_field_or 'cores' '1')" \
    --arg memory   "$(live_field_or 'memory' '512')" \
    --arg cpu      "$(live_field_or 'cpu' 'kvm64')" \
    --arg tags     "$(live_field 'tags')" \
    --arg bios     "$(live_field_or 'bios' 'seabios')" \
    --arg ostype   "$(live_field 'ostype')" \
    --arg storage  "${live_storage}" \
    --arg diskSize "${live_disksize}" \
    --arg net0     "$(live_field 'net0')" \
    --arg net1     "$(live_field 'net1')" \
    '{vmid: $vmid, node: $node, status: $status, name: $name,
      cores: $cores, memory: $memory, cpu: $cpu, tags: $tags,
      bios: $bios, ostype: $ostype, storage: $storage, diskSize: $diskSize,
      net0: $net0, net1: $net1}' >&3
