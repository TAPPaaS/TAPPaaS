#!/usr/bin/env bash
# pvehost install — register a Proxmox cluster node as a module (ADR-026 D4 stage 1, #665).
#
# Proves, and changes NOTHING on the node: the mothership reaches it as root by
# key; it runs Proxmox VE on Debian; its hostname is the instance name; and it is
# a member of THIS Site's cluster (pn_cluster_member). Joining a node is
# `site-manager node add`; registering one is this. Its OS stays patched by the
# cluster module (update-os.sh) until stage 2.
#
# Usage: install.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/pvehost-lib.sh"

pn_load "$1"
info "${BOLD}Registering cluster node ${BL}${INSTANCE}${CL}${BOLD} at ${ADDRESS}${CL}"

pn_reachable || die "cannot log in to root@${ADDRESS} with the mothership's key"
facts="$(pn_ssh 'hostname -s; . /etc/os-release; echo "${ID:-}"; pveversion 2>/dev/null | head -1' 2>/dev/null)" \
    || die "could not read ${INSTANCE}'s facts"
host="$(sed -n 1p <<< "${facts}")"; id="$(sed -n 2p <<< "${facts}")"; pve="$(sed -n 3p <<< "${facts}")"
[[ "${id}" == "debian" ]] || die "${INSTANCE} runs '${id:-unknown}', not debian"
[[ "${pve}" == pve-manager/* ]] || die "${INSTANCE} runs no Proxmox VE (pveversion failed) — a plain Debian machine is a debianhost"
[[ "${host}" == "${INSTANCE}" ]] || die "the node at ${ADDRESS} calls itself '${host}', not '${INSTANCE}' — a node's instance is named after it"
pn_cluster_member "${INSTANCE}" || die "${INSTANCE} is not a member of this Site's cluster — join it with 'site-manager node add ${INSTANCE}' first"

info "  ${GN}✓${CL} root by key; ${pve}; a member of this Site's cluster"
pn_ssh 'test -c /dev/kvm' 2>/dev/null \
    || warn "  ${INSTANCE} has no hardware virtualisation (/dev/kvm missing): no VM can run on it — enable VT-x / AMD-V in its firmware"
# A new node changes what the cluster's CPUs have in common (#827).
# A node whose CPU differs from the others makes some live moves unsafe: name
# them now, not on the first failed drain.
if proxmox-controller cpu-inventory --apply > /dev/null; then
    _inv=/home/tappaas/config/cluster-cpu.json
    _unsafe="$(jq -r --arg n "${INSTANCE}" '[.matrix[]? | select(.liveSafe == false and (.from == $n or .to == $n))
               | "\(.from) → \(.to) (\(.hard | length) feature(s) missing)"] | join(", ")' "${_inv}" 2>/dev/null || true)"
    if [[ -n "${_unsafe}" ]]; then
        warn "  ${INSTANCE}'s CPU differs from the other nodes: a live move of a 'cpu: host' guest is not safe for ${_unsafe}"
        warn "    HA guests with haCpu common use the level all nodes share ($(jq -r '.common.level // "none"' "${_inv}")); a 'host' guest"
        warn "    moves across these pairs only offline (--force). Details: config/cluster-cpu.md"
    fi
else
    warn "  CPU inventory incomplete — see: proxmox-controller cpu-inventory"
fi
info "${GN}✓${CL} ${INSTANCE} registered — nothing on it was changed; its OS is patched by the cluster module"
