#!/usr/bin/env bash
# pvenode-lib.sh — what every pvenode script needs: the instance's config, a
# root shell on the node by the mothership's key, and the Site's own list of
# cluster nodes. Sourced after common-install-routines.sh. pn_load sets
# INSTANCE and ADDRESS.

# pn_load <instance> — load config/<instance>.json; the node is reached by its
# `address` (written by `module adopt`), never by a name derived from the instance.
pn_load() {
    INSTANCE="${1:?usage: <instance>}"
    check_json "${CONFIG_DIR:-/home/tappaas/config}/${INSTANCE}.json" || exit 1
    ADDRESS="$(get_config_value 'address' '')"
    [[ -n "${ADDRESS}" ]] || {
        error "${INSTANCE}: no 'address' in its config — a machine is reached by its address (ADR-026 D8.1)"
        exit 1
    }
}

# pn_ssh <command...> — run as root on the node: key only, never a password.
pn_ssh() {
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o LogLevel=ERROR \
        "root@${ADDRESS}" "$@"
}

pn_reachable() { pn_ssh true >/dev/null 2>&1; }

# pn_site_member <name> [site.json] — rc 0 when site.json's hardware.nodes names
# <name>: the Site's own record of its cluster, which a Proxmox host that is
# merely reachable is not part of.
pn_site_member() {
    local site="${2:-${CONFIG_DIR:-/home/tappaas/config}/site.json}"
    jq -e --arg n "$1" 'any(.hardware.nodes[]?; .name == $n)' "${site}" >/dev/null 2>&1
}
