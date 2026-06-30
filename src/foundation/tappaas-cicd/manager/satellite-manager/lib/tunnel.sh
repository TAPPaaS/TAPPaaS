#!/usr/bin/env bash
# lib/tunnel.sh — satellite-side WireGuard infra-tunnel helpers (ADR-010 P2).
#
# Sourced by satellite-manager. These talk to the SATELLITE over SSH (the home
# OPNsense side is handled by wg-manager in the opnsense-controller). The
# satellite's private key never leaves the host — we only ever read its PUBLIC
# key (ADR-010 §7.1 #1 / D19).
#
# Testability: the SSH runner is overridable via $TAPPAAS_SSH_RUNNER (a command
# invoked as: <runner> <user@host> <remote-cmd...>), so fast tests mock the host.
#
# shellcheck shell=bash

# Run a remote command on the satellite (real ssh, or the injected test runner).
_tunnel_ssh() {
    local target="$1"; shift
    if [[ -n "${TAPPAAS_SSH_RUNNER:-}" ]]; then
        "${TAPPAAS_SSH_RUNNER}" "${target}" "$@"
    else
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
            "${target}" "$@"
    fi
}

# Read the satellite's infra-tunnel WireGuard PUBLIC key.
# Echoes the key; non-zero if unreachable / interface absent.
tunnel_satellite_pubkey() {
    local target="${1:?target required}"
    local key
    key="$(_tunnel_ssh "${target}" "wg show wg-infra public-key" 2>/dev/null)" || return 1
    [[ -n "${key}" ]] || return 1
    echo "${key}"
}

# Tunnel health → echoes one of: <seconds-since-handshake> | never | down.
# Returns non-zero when the host/interface is unreachable ("down").
tunnel_handshake_age() {
    local target="${1:?target required}"
    local hs now
    hs="$(_tunnel_ssh "${target}" "wg show wg-infra latest-handshakes" 2>/dev/null \
            | awk 'NR==1 {print $2}')" || { echo "down"; return 1; }
    if [[ -z "${hs}" ]]; then echo "down"; return 1; fi
    if [[ "${hs}" == "0" ]]; then echo "never"; return 0; fi
    now="$(_tunnel_ssh "${target}" "date +%s" 2>/dev/null)" || { echo "unknown"; return 1; }
    echo $(( now - hs ))
}
