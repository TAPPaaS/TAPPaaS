#!/usr/bin/env bash
# pvenode install — register a Proxmox cluster node as a module (ADR-026 D4 stage 1, #665).
#
# Proves, and changes NOTHING on the node: the mothership reaches it as root by
# key; it runs Proxmox VE on Debian; its hostname is the instance name; and it is
# a member of THIS Site's cluster (site.json hardware.nodes). Joining a node is
# `site-manager node add`; registering one is this. Its OS stays patched by the
# cluster module (update-os.sh) until stage 2.
#
# Usage: install.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/pvenode-lib.sh"

pn_load "$1"
info "${BOLD}Registering cluster node ${BL}${INSTANCE}${CL}${BOLD} at ${ADDRESS}${CL}"

pn_reachable || die "cannot log in to root@${ADDRESS} with the mothership's key"
facts="$(pn_ssh 'hostname -s; . /etc/os-release; echo "${ID:-}"; pveversion 2>/dev/null | head -1' 2>/dev/null)" \
    || die "could not read ${INSTANCE}'s facts"
host="$(sed -n 1p <<< "${facts}")"; id="$(sed -n 2p <<< "${facts}")"; pve="$(sed -n 3p <<< "${facts}")"
[[ "${id}" == "debian" ]] || die "${INSTANCE} runs '${id:-unknown}', not debian"
[[ "${pve}" == pve-manager/* ]] || die "${INSTANCE} runs no Proxmox VE (pveversion failed) — a plain Debian machine is a debianhost"
[[ "${host}" == "${INSTANCE}" ]] || die "the node at ${ADDRESS} calls itself '${host}', not '${INSTANCE}' — a node's instance is named after it"
pn_site_member "${INSTANCE}" || die "${INSTANCE} is not in site.json hardware.nodes — join it with 'site-manager node add ${INSTANCE}' first"

info "  ${GN}✓${CL} root by key; ${pve}; a member of this Site's cluster"
info "${GN}✓${CL} ${INSTANCE} registered — nothing on it was changed; its OS is patched by the cluster module"
