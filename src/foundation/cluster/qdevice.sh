#!/usr/bin/env bash
#
# TAPPaaS cluster QDevice (qdevice.sh) — a third vote for a two-node cluster (#835)
#
# Two nodes are two votes and a quorum of two: when one is down the other is not
# quorate and HA fences it — the whole site, firewall included. A QDevice is
# corosync-qnetd on a small always-on Debian machine that is not a node (a
# debianhost, the satellite); it gives the vote that keeps the survivor running.
#
# Usage:
#   qdevice.sh add <host> [--user <u>] [--force]
#   qdevice.sh remove [--user <u>]
#   qdevice.sh status
#
#   <host>      the qnetd machine's address, reachable from the nodes (TCP 5403)
#   --user <u>  how the mothership logs in to it (default tappaas, with sudo;
#               root works too)
#   --force     also on an odd number of nodes, which Proxmox does not support
#
# add: installs corosync-qnetd on the host and corosync-qdevice on every node,
# lets the first node log in to the host as root for `pvecm qdevice setup` (it
# exchanges certificates that way), runs it, and takes that login away again.
# Idempotent: a cluster that already has a QDevice is left as it is, except
# that a login an earlier add left on <host> is taken away.
# remove: `pvecm qdevice remove`, and the first node's login on the QDevice host
# is taken away (when the host still answers) — the packages stay.
#
# Exit: 0 done, 1 refused or failed.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VERB="${1:-}"; shift || true
HOST=""; HUSER="tappaas"; FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) HUSER="${2:?--user needs a name}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        -*) die "unknown option '$1'" ;;
        *) HOST="$1"; shift ;;
    esac
done

mapfile -t NODES < <(get_all_node_hostnames)
[[ ${#NODES[@]} -gt 0 ]] || die "no cluster nodes in site.json"
N1="${NODES[0]}"
node_ssh() { local n="$1"; shift; ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${n}.${MGMT:-mgmt}.internal" "$@"; }
host_ssh() {
    local sudo=""; [[ "${HUSER}" == "root" ]] || sudo="sudo"
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${HUSER}@${HOST}" "${sudo} bash -s"
}
n1_key() { node_ssh "${N1}" "cat /root/.ssh/id_rsa.pub" 2>/dev/null; }
# The first node's root login on the QDevice host is needed only while
# `pvecm qdevice setup` runs; afterwards it would be a standing root login on a
# machine outside the cluster (the satellite faces the internet).
#   drop_n1_key <key>   — a warning, not a failure, when the host cannot be reached
drop_n1_key() {
    local key="$1"
    [[ -n "${key}" ]] || return 0
    if host_ssh <<EOF
set -e
f=/root/.ssh/authorized_keys
[ -f "\$f" ] || exit 0
grep -vxF '${key}' "\$f" > "\$f.tappaas" || true
chmod 600 "\$f.tappaas" && mv "\$f.tappaas" "\$f"
EOF
    then
        info "  ${N1}'s root login on ${HOST} removed"
    else
        warn "  could not remove ${N1}'s root key from ${HOST}:/root/.ssh/authorized_keys — remove it by hand"
    fi
}
# The QDevice's host, as corosync has it.
qdevice_host() { node_ssh "${N1}" "corosync-cmapctl -g quorum.device.net.host" 2>/dev/null | sed -n 's/.* = //p'; }
quorum() { node_ssh "${N1}" "pvecm status" 2>/dev/null | sed -n '/^Votequorum/,/^Membership/p' | sed '/^Membership/d'; }
has_qdevice() { node_ssh "${N1}" "pvecm status" 2>/dev/null | grep -qi 'qdevice'; }

case "${VERB}" in
    status)
        quorum
        has_qdevice && info "QDevice: present" || info "QDevice: none"
        ;;

    add)
        [[ -n "${HOST}" ]] || die "Usage: qdevice.sh add <host> [--user <u>] [--force]"
        if has_qdevice; then
            info "${GN}✓${CL} the cluster already has a QDevice — nothing to do (qdevice.sh remove to replace it)"
            drop_n1_key "$(n1_key)"
            exit 0
        fi
        n=${#NODES[@]}
        if (( n % 2 == 1 )) && [[ "${FORCE}" != "1" ]]; then
            die "${n} nodes: Proxmox supports a QDevice only on an even number of nodes (an odd cluster has a majority already) — --force to add it anyway"
        fi
        info "${BOLD}QDevice on ${HOST}${CL} for ${n} node(s): ${NODES[*]}"

        n1key="$(n1_key)" || die "could not read ${N1}'s root key"
        info "  installing corosync-qnetd on ${HOST}, and ${N1}'s root key there (for pvecm's setup only)"
        host_ssh <<EOF || die "could not prepare ${HOST} (as ${HUSER})"
set -e
export DEBIAN_FRONTEND=noninteractive
command -v corosync-qnetd >/dev/null || { apt-get update -qq && apt-get install -y -qq corosync-qnetd >/dev/null; }
systemctl enable --now corosync-qnetd >/dev/null 2>&1
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qxF '${n1key}' /root/.ssh/authorized_keys || printf '%s\n' '${n1key}' >> /root/.ssh/authorized_keys
EOF
        for n in "${NODES[@]}"; do
            info "  installing corosync-qdevice on ${n}"
            node_ssh "${n}" "command -v corosync-qdevice >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq corosync-qdevice >/dev/null" \
                || die "could not install corosync-qdevice on ${n}"
        done
        # The host's current key, not one an earlier machine at the address left.
        node_ssh "${N1}" "ssh-keygen -R '${HOST}' >/dev/null 2>&1; ssh-keyscan -T 10 '${HOST}' >> /root/.ssh/known_hosts 2>/dev/null"
        info "  pvecm qdevice setup ${HOST} (restarts corosync on every node)"
        _f=""; [[ "${FORCE}" == "1" ]] && _f="--force"
        _rc=0
        node_ssh "${N1}" "pvecm qdevice setup '${HOST}' ${_f} </dev/null" || _rc=$?
        drop_n1_key "${n1key}"
        [[ ${_rc} -eq 0 ]] || die "pvecm qdevice setup failed — see above; the cluster keeps its votes"
        has_qdevice || die "setup ran, but pvecm status shows no QDevice"
        quorum
        info "${GN}✓${CL} QDevice on ${HOST} added"
        ;;

    remove)
        if ! has_qdevice; then
            info "${GN}✓${CL} the cluster has no QDevice — nothing to do"
            exit 0
        fi
        info "${BOLD}Removing the QDevice${CL} (restarts corosync on every node)"
        [[ -n "${HOST}" ]] || HOST="$(qdevice_host)"
        node_ssh "${N1}" "pvecm qdevice remove </dev/null" || die "pvecm qdevice remove failed"
        has_qdevice && die "remove ran, but pvecm status still shows a QDevice"
        if [[ -n "${HOST}" ]]; then
            drop_n1_key "$(n1_key)"
        else
            warn "  the QDevice's host is not in corosync's config — check its /root/.ssh/authorized_keys for ${N1}'s root key"
        fi
        quorum
        info "${GN}✓${CL} QDevice removed (corosync-qnetd stays installed on its host)"
        ;;

    *)
        die "Usage: qdevice.sh add <host> [--user <u>] [--force] | remove [--user <u>] | status"
        ;;
esac
