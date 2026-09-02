#!/usr/bin/env bash
#
# TAPPaaS Cluster LXC Service - Report (actual state)
#
# The container counterpart of services/vm/report-service.sh: the READ half of
# the ADR-020 D7 contract, for a module whose guest is an LXC container rather
# than a QEMU VM (#465).
#
#     desired = module-manager module resolve <name>        [TS, the one resolver]
#     actual  = cluster:lxc/report-service.sh <name>        [this script]
#     drift   = diff(desired, actual)                       [TS, the one differ]
#               update-service.sh <name> --apply-drift ...  [bash, pure apply]
#
# EXTRACTS ONLY — no resolving, no normalizing, no comparing, no writes. The
# locate-and-read mechanism is shared with the VM reporter via
# ../../lib/report-lib.sh; what differs is the FIELD SET, because Proxmox spells
# a container differently from a VM:
#
#   VM                          container
#   ----------------------      ------------------------------------------
#   name: nextcloud             hostname: vllm-amd
#   scsi0: tanka1:…,size=80G    rootfs: tanka1:subvol-312-disk-0,size=32G
#   bios / cpu                  (neither exists — a container has no firmware
#                               and no emulated CPU model)
#   net0: virtio=<MAC>,…        net0: name=eth0,…,hwaddr=<MAC>,ip=dhcp,…
#   ostype: l26                 ostype: debian   (the DISTRO, not a kernel ABI)
#
# The keys emitted are those a container actually has. A consumer must not read
# an absent key as "empty" — bios is not reported here at all, because a
# container has no BIOS, and the manifest for cluster:lxc does not claim the
# field (module-fields.json's `usedBy` already keeps bios/cputype to cluster:vm).
#
# Usage: report-service.sh [--vmid ID] <module-name>
#
# Output: one JSON object on stdout, nothing else; diagnostics go to stderr.
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
report_begin lxc "$@"

disk_value="$(report_disk rootfs)"

# A container NIC spells its MAC `hwaddr=` where a VM spells it `virtio=`;
# vmnet_parse accepts both, so the same parser serves both reporters and the
# component keys stay identical across guest types. That matters: the differ
# must not need to know which kind of guest it is looking at.
net0="$(report_field 'net0')"

# The jq program is deliberately single-quoted: $vmid and friends are JQ
# variables bound by the --arg pairs below, not shell expansions.
# shellcheck disable=SC2016
report_emit \
    '{vmid: $vmid, node: $node, status: $status, hostname: $hostname,
      cores: $cores, memory: $memory, tags: $tags, ostype: $ostype,
      storage: $storage, diskSize: $diskSize,
      net0: $net0,
      "net0.bridge": $net0b, "net0.tag": $net0t, "net0.trunks": $net0k,
      "net0.mac": $net0m}' \
    --arg vmid     "${REPORT_VMID}" \
    --arg node     "${REPORT_NODE}" \
    --arg status   "${REPORT_STATUS}" \
    --arg hostname "$(report_field 'hostname')" \
    --arg cores    "$(report_field_or 'cores' '1')" \
    --arg memory   "$(report_field_or 'memory' '512')" \
    --arg tags     "$(report_field 'tags')" \
    --arg ostype   "$(report_field 'ostype')" \
    --arg storage  "$(report_disk_storage "${disk_value}")" \
    --arg diskSize "$(report_disk_size "${disk_value}")" \
    --arg net0     "${net0}" \
    --arg net0b    "$(vmnet_parse "${net0}" bridge)" \
    --arg net0t    "$(vmnet_parse "${net0}" tag)" \
    --arg net0k    "$(vmnet_parse "${net0}" trunks)" \
    --arg net0m    "$(vmnet_parse "${net0}" mac)"
