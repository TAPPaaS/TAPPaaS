#!/usr/bin/env bash
#
# Shared helpers for the rollback-test fixture (#307).
#
# The fixture's "functionality" is a single sentinel file on the GUEST DISK.
# It is managed entirely host-side through the QEMU guest agent (ssh to the
# node -> `qm guest exec`), so no guest IP or DNS is required and the value
# lives on the disk that `qm rollback` definitively restores.
#
#   GOOD   -> module is healthy   (test.sh exits 0)
#   BROKEN -> functionality broke (test.sh exits 2 = fatal -> triggers rollback)
#
# Source AFTER common-install-routines.sh (needs info/warn/error/die,
# read_module_config, get_node_hostname).

# Where the sentinel lives inside the guest. /root is writable on NixOS and is
# captured by the disk snapshot that update-module.sh takes before updating.
readonly RBT_SENTINEL="/root/tappaas-rollback-test.state"

# BatchMode so a missing host key fails fast instead of prompting.
readonly RBT_SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# Resolve vmid/node from the installed module config (written by install-module.sh).
rbt_vmid() {
    local m="${1:-rollback-test}"
    read_module_config "${m}" 2>/dev/null | jq -r '.vmid // empty'
}
rbt_node() {
    local m="${1:-rollback-test}" n
    n=$(read_module_config "${m}" 2>/dev/null | jq -r '.node // empty')
    [[ -z "${n}" ]] && n="$(get_node_hostname 0)"
    echo "${n}"
}

# Block until the guest agent answers (the VM may still be booting right after a
# snapshot restore — snapshot-vm.sh starts it but does not wait). Returns 0 once
# the agent pings, 1 on timeout.
rbt_wait_agent() {
    local vmid="$1" node="$2" timeout="${3:-150}" waited=0
    while [[ "${waited}" -lt "${timeout}" ]]; do
        # shellcheck disable=SC2029,SC2086  # vmid expands locally; SSH_OPTS split on purpose
        if ssh ${RBT_SSH_OPTS} "root@${node}.mgmt.internal" \
                "qm guest cmd ${vmid} ping" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Write a value to the guest sentinel (waits for the agent first, then syncs so
# the value is durable on disk before any snapshot is taken).
rbt_write_sentinel() {
    local vmid="$1" node="$2" value="$3"
    rbt_wait_agent "${vmid}" "${node}" || { error "guest agent never came up on VM ${vmid}"; return 1; }
    # shellcheck disable=SC2029,SC2086  # vmid/value expand locally; SSH_OPTS split on purpose
    ssh ${RBT_SSH_OPTS} "root@${node}.mgmt.internal" \
        "qm guest exec ${vmid} -- /bin/sh -c 'echo ${value} > ${RBT_SENTINEL}; sync'" >/dev/null
}

# Read the guest sentinel; echoes the trimmed value ("" on any failure).
# qm guest exec returns JSON: {"out-data":"GOOD\n","exitcode":0,...}
rbt_read_sentinel() {
    local vmid="$1" node="$2"
    rbt_wait_agent "${vmid}" "${node}" || return 0
    # shellcheck disable=SC2029,SC2086  # vmid expands locally; SSH_OPTS split on purpose
    ssh ${RBT_SSH_OPTS} "root@${node}.mgmt.internal" \
        "qm guest exec ${vmid} -- /bin/sh -c 'cat ${RBT_SENTINEL} 2>/dev/null'" 2>/dev/null \
        | jq -r '."out-data" // empty' 2>/dev/null | tr -d '[:space:]'
}
