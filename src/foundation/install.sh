#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# foundation/install.sh — TAPPaaS install ORCHESTRATOR (the entry point).
#
# This is the script the install guide downloads + runs on the FIRST Proxmox node.
# It drives the whole first-node bring-up as a 5-step chain:
#   [1/5] node     — cluster/install.sh: Proxmox post-install, lan/wan bridges,
#                    cluster create named <orgname>, ZFS pools
#   [2/5] firewall — config-firewall.sh: prebuilt OPNsense boots at 10.0.0.1
#   [3/5] cutover  — config-network.sh --swap-gateway: route via firewall (additive)
#   [4/5] sanity   — sanity-check.sh
#   [5/5] platform — install-platform.sh: NixOS template + tappaas-cicd, whose own
#                    install.sh then creates site.json + zones + the mgmt/<orgname>
#                    environments (the organization is created later, by
#                    rest-of-foundation.sh).
#
# <orgname> is the ONE name threaded everywhere: the Proxmox CLUSTER name, the
# site.json `.name`, the default ENVIRONMENT name, and (later) the ORGANIZATION
# name. Pass it with --name (prompted when omitted). It must be known up front
# because it names the cluster at create time.
#
# On a SECONDARY node (joining an existing cluster) only [1/5] runs — the firewall,
# gateway and platform already exist — and the chain stops after the join.
#
# Usage:
#   install.sh [REPO] [BRANCH] --name <orgname> [--domain <d>]
#              [--cluster|--join|--no-cluster] [--skip-network] [--skip-storage]
#              [--skip-firewall] [--skip-platform] [--non-interactive]

set -euo pipefail
shopt -s inherit_errexit nullglob

RD=$(echo "\033[01;31m"); YW=$(echo "\033[33m"); GN=$(echo "\033[1;92m")
CL=$(echo "\033[m"); BL=$(echo "\033[36m"); BOLD=$(echo "\033[1m")
BFR="\\r\\033[K"; HOLD="-"; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

msg_info()  { echo -ne " ${HOLD} ${YW}${1}..."; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; }

# Robust download (see the long note in cluster/install.sh): temp file, checks
# curl status + non-empty, fatal on failure so a broken node is never "good".
fetch() {
  local url="$1" dest="$2" mode="${3:-644}" tmp
  tmp="$(mktemp)" || { msg_error "mktemp failed"; exit 1; }
  if ! curl -fsSL "$url" -o "$tmp"; then rm -f "$tmp"; msg_error "Download failed: ${url}"; exit 1; fi
  [ -s "$tmp" ] || { rm -f "$tmp"; msg_error "Empty download: ${url}"; exit 1; }
  mkdir -p "$(dirname "$dest")"; mv "$tmp" "$dest"; chmod "$mode" "$dest"
}

# ── Arguments ─────────────────────────────────────────────────────────
REPO="https://raw.githubusercontent.com/TAPPaaS/"
BRANCH="stable"
ORGNAME=""
DOMAIN=""
NONINTERACTIVE=0
SKIP_FIREWALL=0
SKIP_PLATFORM=0
NODE_ARGS=()              # pass-through to the node step (cluster/install.sh)
_pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name)            ORGNAME="${2:-}"; shift ;;
    --domain)          DOMAIN="${2:-}"; shift ;;
    --skip-firewall)   SKIP_FIREWALL=1 ;;
    --skip-platform)   SKIP_PLATFORM=1 ;;
    --non-interactive) NONINTERACTIVE=1; NODE_ARGS+=("--non-interactive") ;;
    --cluster|--join|--no-cluster|--skip-network|--skip-storage) NODE_ARGS+=("$1") ;;
    -h|--help)
      echo "Usage: install.sh [REPO] [BRANCH] --name <orgname> [--domain <d>]"
      echo "                  [--cluster|--join|--no-cluster] [--skip-network] [--skip-storage]"
      echo "                  [--skip-firewall] [--skip-platform] [--non-interactive]"
      echo ""
      echo "The first-node entry point. Runs the 5-step chain: node → firewall →"
      echo "gateway cutover → sanity → platform. --name is the org/system name and"
      echo "names the cluster, site.json, the default environment and the organization."
      exit 0 ;;
    --*) msg_error "Unknown option: $1"; exit 2 ;;
    *)   _pos+=("$1") ;;
  esac
  shift
done
[ "${#_pos[@]}" -ge 1 ] && REPO="${_pos[0]}"
[ "${#_pos[@]}" -ge 2 ] && BRANCH="${_pos[1]}"
NONINT_ARG=""; [ "$NONINTERACTIVE" = 1 ] && NONINT_ARG="--non-interactive"

# ── Resolve <orgname> (the one name; needed before the cluster is created) ──
if [ -z "$ORGNAME" ]; then
  if [ "$NONINTERACTIVE" = 0 ] && [ -t 0 ]; then
    read -r -p "TAPPaaS org / system name (names the cluster, site, default environment & org): " ORGNAME
  fi
  [ -n "$ORGNAME" ] || { msg_error "--name <orgname> is required (it names the cluster/site/environment/org)."; exit 2; }
fi
if ! printf '%s' "$ORGNAME" | grep -qE '^[a-z][a-z0-9-]*$'; then
  msg_error "orgname '${ORGNAME}' invalid — use lowercase letters/digits/hyphen, starting with a letter."
  exit 2
fi
# The Proxmox cluster name (corosync) is capped at 15 chars; the orgname becomes
# that name, so enforce it up front rather than fail confusingly at pvecm create.
if [ "${#ORGNAME}" -gt 15 ]; then
  msg_error "orgname '${ORGNAME}' is ${#ORGNAME} chars — max 15 (it becomes the Proxmox cluster name)."
  exit 2
fi

mkdir -p ~/tappaas

# ── [1/5] node ──────────────────────────────────────────────────────────
echo -e "\n${GN}=== [1/5] Node (post-install, bridges, cluster '${ORGNAME}', storage) ===${CL}"
fetch "${REPO}${BRANCH}/src/foundation/cluster/install.sh" ~/tappaas/cluster-install.sh 755
~/tappaas/cluster-install.sh "$REPO" "$BRANCH" --name "$ORGNAME" ${NODE_ARGS[@]+"${NODE_ARGS[@]}"} \
  || { msg_error "node step (cluster/install.sh) failed — fix it, then re-run."; exit 1; }

# Primary (created the cluster) vs secondary (joined/member): cluster/install.sh
# writes the role to ~/tappaas/.cluster-role. Only the first node runs [2/5]–[5/5].
ROLE="$(cat ~/tappaas/.cluster-role 2>/dev/null || echo '')"
if [ "$ROLE" != "created" ]; then
  echo ""
  msg_ok "Node step complete (cluster role: ${ROLE:-unknown})."
  echo -e "  This node ${BOLD}joined${CL} an existing TAPPaaS cluster — the firewall, gateway"
  echo -e "  and platform already exist, so the chain stops here."
  echo -e "  On ${BL}tappaas-cicd${CL} run ${BL}update-tappaas --force${CL} to fold this node into HA + replication."
  exit 0
fi

# ── [2/5] firewall ────────────────────────────────────────────────────
if [ "$SKIP_FIREWALL" = 1 ]; then
  msg_ok "Skipping firewall (--skip-firewall). Run later: ~/tappaas/config-firewall.sh"; exit 0
fi
echo -e "\n${GN}=== [2/5] OPNsense firewall ===${CL}"
fetch "${REPO}${BRANCH}/src/foundation/network/config-firewall.sh" ~/tappaas/config-firewall.sh 755
~/tappaas/config-firewall.sh --repo "$REPO" --branch "$BRANCH" --chained ${NONINT_ARG} \
  || { msg_error "config-firewall.sh did not complete — fix it, then re-run ~/tappaas/config-firewall.sh and continue."; exit 1; }

# ── [3/5] gateway cutover (additive — no connectivity break) ──────────
echo -e "\n${GN}=== [3/5] Gateway cutover (route via the firewall) ===${CL}"
~/tappaas/config-network.sh --swap-gateway ${NONINT_ARG} \
  || { msg_error "Gateway cutover failed — re-run ~/tappaas/config-network.sh --swap-gateway, then continue."; exit 1; }

# ── [4/5] sanity check ─────────────────────────────────────────────────
echo -e "\n${GN}=== [4/5] Sanity check ===${CL}"
fetch "${REPO}${BRANCH}/src/foundation/cluster/sanity-check.sh" ~/tappaas/sanity-check.sh 755
~/tappaas/sanity-check.sh || msg_error "sanity-check reported problems — review above (continuing)."

# ── [5/5] platform: NixOS template + tappaas-cicd ─────────────────────
if [ "$SKIP_PLATFORM" = 1 ]; then
  msg_ok "Skipping platform (--skip-platform). Run later: ~/tappaas/install-platform.sh --name ${ORGNAME} --domain <d>"; exit 0
fi
echo -e "\n${GN}=== [5/5] Platform (NixOS template + tappaas-cicd) ===${CL}"
fetch "${REPO}${BRANCH}/src/foundation/cluster/install-platform.sh" ~/tappaas/install-platform.sh 755
dom_arg=(); [ -n "$DOMAIN" ] && dom_arg=(--domain "$DOMAIN")
~/tappaas/install-platform.sh --repo "$REPO" --branch "$BRANCH" --name "$ORGNAME" "${dom_arg[@]}" ${NONINT_ARG} \
  || { msg_error "install-platform.sh did not complete — re-run ~/tappaas/install-platform.sh --name ${ORGNAME} --domain <yourdomain>."; exit 1; }

# ── Done ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════════════════════════╗"
echo "  ║   Congratulations! TAPPaaS foundation (first node) is installed.       ║"
echo "  ╚═══════════════════════════════════════════════════════════════════════╝"
echo -e "${CL}"
echo -e "  System name: ${BL}${ORGNAME}${CL}  (cluster = site.json .name = default environment = organization)"
echo ""
echo -e "  ${BOLD}Next steps (from tappaas-cicd — ssh tappaas@tappaas-cicd):${CL}"
echo -e "  1. Additional nodes: install PVE, re-run this installer on each (auto-joins),"
echo -e "     then ${BL}update-tappaas --force${CL} to configure HA + replication."
echo -e "  2. Physical switch(es): ${BL}setup-switches.sh${CL}"
echo -e "  3. TLS certificates:    ${BL}acme-setup.sh${CL}"
echo -e "  4. Rest of foundation:  ${BL}rest-of-foundation.sh${CL}"
echo -e "       installs backup / identity / logging, then creates the ${BL}${ORGNAME}${CL} organization."
echo ""
