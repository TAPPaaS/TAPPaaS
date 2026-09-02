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
# The locate-and-read MECHANISM is shared with services/lxc/report-service.sh
# via ../../lib/report-lib.sh; only the FIELD SET below is provider-specific.
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
#     "net0": "virtio=02:..,bridge=lan,tag=200",
#     "net0.bridge": "lan", "net0.tag": "200", "net0.trunks": "",
#     "net0.mac": "02:..", "net0.queues": "",
#     "net1": "", "net1.bridge": "", ... }
#
# Each NIC is reported BOTH whole and split into components, because a module
# declares bridge0/zone0/trunks0/mac0 as four fields while Proxmox stores them
# as one string. Splitting here — in the provider's own reporter, with the
# provider's own parser — is what lets the manager give up netopts parsing
# altogether (ADR-020 Resolved Question 11).
#
# EVERY declared key is always present. An absent value is the empty string, so
# a consumer can tell "the guest does not have this" from "the reporter did not
# look" — the latter is an ERROR here, never an empty field. Values are RAW, as
# Proxmox spells them; the manager normalizes both sides.
#
# STDOUT carries that object and nothing else; every diagnostic goes to stderr.
#
# Exit codes (see ../../lib/report-lib.sh — each names a different operator
# action, so a consumer never has to pattern-match stderr):
#   0  found and reported          4  no cluster node answered
#   2  usage error                 5  the guest is not present on any node
#   3  the module is not deployed  6  located, but its config could not be read
# State is never reported partially: any non-zero code means UNKNOWN.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/vm-net.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/vm-net.sh"
# shellcheck source=../../lib/report-lib.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/report-lib.sh"

report_guard_stdout
report_begin qemu "$@"

disk_value="$(report_disk scsi0 virtio0 ide0 sata0)"

# `queues` has no module field — it is a live-only property that must be
# PRESERVED across a NIC change (never hot-changed on a running guest, #194).
# It is reported so the apply hook can carry it over.
net0="$(report_field 'net0')"
net1="$(report_field 'net1')"

# The jq program is deliberately single-quoted: $vmid and friends are JQ
# variables bound by the --arg pairs below, not shell expansions.
# shellcheck disable=SC2016
report_emit \
    '{vmid: $vmid, node: $node, status: $status, name: $name,
      cores: $cores, memory: $memory, cpu: $cpu, tags: $tags,
      bios: $bios, ostype: $ostype, storage: $storage, diskSize: $diskSize,
      net0: $net0,
      "net0.bridge": $net0b, "net0.tag": $net0t, "net0.trunks": $net0k,
      "net0.mac": $net0m, "net0.queues": $net0q,
      net1: $net1,
      "net1.bridge": $net1b, "net1.tag": $net1t, "net1.trunks": $net1k,
      "net1.mac": $net1m, "net1.queues": $net1q}' \
    --arg vmid     "${REPORT_VMID}" \
    --arg node     "${REPORT_NODE}" \
    --arg status   "${REPORT_STATUS}" \
    --arg name     "$(report_field 'name')" \
    --arg cores    "$(report_field_or 'cores' '1')" \
    --arg memory   "$(report_field_or 'memory' '512')" \
    --arg cpu      "$(report_field_or 'cpu' 'kvm64')" \
    --arg tags     "$(report_field 'tags')" \
    --arg bios     "$(report_field_or 'bios' 'seabios')" \
    --arg ostype   "$(report_field 'ostype')" \
    --arg storage  "$(report_disk_storage "${disk_value}")" \
    --arg diskSize "$(report_disk_size "${disk_value}")" \
    --arg net0     "${net0}" \
    --arg net0b    "$(vmnet_parse "${net0}" bridge)" \
    --arg net0t    "$(vmnet_parse "${net0}" tag)" \
    --arg net0k    "$(vmnet_parse "${net0}" trunks)" \
    --arg net0m    "$(vmnet_parse "${net0}" mac)" \
    --arg net0q    "$(vmnet_parse "${net0}" queues)" \
    --arg net1     "${net1}" \
    --arg net1b    "$(vmnet_parse "${net1}" bridge)" \
    --arg net1t    "$(vmnet_parse "${net1}" tag)" \
    --arg net1k    "$(vmnet_parse "${net1}" trunks)" \
    --arg net1m    "$(vmnet_parse "${net1}" mac)" \
    --arg net1q    "$(vmnet_parse "${net1}" queues)"
