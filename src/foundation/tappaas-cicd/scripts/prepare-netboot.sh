#!/usr/bin/env bash
#
# prepare-netboot.sh — stage the PVE netboot assets so THIS TAPPaaS system
# can provision follow-on nodes (docs/design/node-provisioning.md N3).
#
# Runs on the tappaas-cicd mothership; called automatically at the end of the
# cicd install so node-adding is a latent capability of EVERY TAPPaaS system,
# and re-runnable by the operator for a new PVE version:
#
#   prepare-netboot.sh [--force] [--node tappaas1.mgmt.internal] [--iso-url <url>]
#
# What it does (all idempotent):
#   1. asks the first cluster node (a PVE box — the assistant needs one) for
#      its PVE version and picks the matching installer ISO from
#      download.proxmox.com (override with --iso-url);
#   2. downloads the ISO on that node (kept under /root, reused when present),
#      installs proxmox-auto-install-assistant, and runs
#      `prepare-iso --fetch-from http --url http://<cicd>:8090/answer`;
#   3. copies the prepared ISO to /home/tappaas/pve-tappaas-netboot.iso and
#      stages kernel/initrd/ISO via `node-provisioner prepare`.
#
# After this, `site-manager node add <name> --pxe` works with zero prep. The
# prepared ISO is ALSO a valid USB image (dd it) — a stick is the PXE-less
# alternative: boot from it and the flow is identical (answer over HTTP).
#
set -euo pipefail

GN="\033[1;92m"; YW="\033[33m"; RD="\033[01;31m"; CL="\033[m"
info() { echo -e "${GN}[Info]${CL} $*"; }
warn() { echo -e "${YW}[Warning]${CL} $*"; }
die()  { echo -e "${RD}[Error]${CL} $*" >&2; exit 1; }

FORCE=0
NODE="tappaas1.mgmt.internal"
ISO_URL=""
DEST_ISO="/home/tappaas/pve-tappaas-netboot.iso"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --node)    NODE="${2:?}"; shift 2 ;;
    --iso-url) ISO_URL="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

if [[ "$FORCE" -ne 1 && -f /var/lib/tappaas-pxe/boot.ipxe && -f /var/lib/tappaas-pxe/initrd ]]; then
  info "netboot assets already staged (/var/lib/tappaas-pxe) — nothing to do (--force to re-stage)"
  exit 0
fi

# ── SSH identity helper (root@<node> Proxmox-host domain only) ──────────
# Mirrors lib/common-install-routines.sh's tappaas_ssh() exactly (ADR-018,
# #518/#519/#520) — duplicated here rather than sourcing the shared lib,
# matching this script's own existing self-contained design (it already
# defines its own info/warn/die rather than sourcing common-install-routines.sh).
function tappaas_operator_home() {
  if [ -n "${TAPPAAS_OPERATOR_HOME:-}" ]; then
    echo "${TAPPAAS_OPERATOR_HOME}"
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    echo "/home/${SUDO_USER}"
    return 0
  fi
  echo ""
}
function tappaas_ssh_identity() {
  if [ -n "${TAPPAAS_SSH_IDENTITY:-}" ]; then
    echo "${TAPPAAS_SSH_IDENTITY}"
    return 0
  fi
  local home
  home="$(tappaas_operator_home)"
  echo "${home:-/home/tappaas}/.ssh/id_ed25519"
}

_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$(tappaas_ssh_identity)" "root@${NODE}" "$@"; }

_ssh true 2>/dev/null || die "cannot reach root@${NODE} — pass --node <a-PVE-node> (the assistant must run on a PVE box)"

# cicd mgmt IP = the answer/asset server address baked into the ISO.
CICD_IP="$(ip -4 route get 10.0.0.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')"
[[ -n "$CICD_IP" ]] || die "cannot determine the cicd mgmt IP (no route to 10.0.0.1)"

# 1. Pick the ISO matching the cluster's PVE version.
if [[ -z "$ISO_URL" ]]; then
  PVE_VER="$(_ssh "pveversion" | sed -E 's|^pve-manager/([0-9]+\.[0-9]+).*|\1|')"
  [[ -n "$PVE_VER" ]] || die "cannot read the PVE version from ${NODE}"
  info "cluster runs PVE ${PVE_VER} — locating the matching installer ISO..."
  ISO_NAME="$(_ssh "wget -qO- http://download.proxmox.com/iso/ | grep -oE 'proxmox-ve_${PVE_VER}-[0-9]+\\.iso' | sort -V | tail -1" || true)"
  [[ -n "$ISO_NAME" ]] || die "no proxmox-ve_${PVE_VER}-*.iso found on download.proxmox.com — pass --iso-url"
  ISO_URL="http://download.proxmox.com/iso/${ISO_NAME}"
else
  ISO_NAME="$(basename "$ISO_URL")"
fi
info "installer ISO: ${ISO_URL}"

# 2. Download + prepare on the PVE node (assistant needs a PVE/Debian box).
PREPARED="/root/${ISO_NAME%.iso}-tappaas-netboot.iso"
_ssh "[ -f /root/${ISO_NAME} ] || wget -q -O /root/${ISO_NAME} '${ISO_URL}'" \
  || die "ISO download failed on ${NODE}"
_ssh "command -v proxmox-auto-install-assistant >/dev/null || apt-get install -y proxmox-auto-install-assistant >/dev/null" \
  || die "cannot install proxmox-auto-install-assistant on ${NODE}"
info "preparing the answer-fetching ISO (answer URL http://${CICD_IP}:8090/answer)..."
_ssh "proxmox-auto-install-assistant prepare-iso /root/${ISO_NAME} \
        --fetch-from http --url 'http://${CICD_IP}:8090/answer' \
        --output ${PREPARED} >/dev/null" \
  || die "prepare-iso failed on ${NODE}"

# 3. Copy to the mothership + stage the netboot assets.
info "copying the prepared ISO to ${DEST_ISO} (~1.5 GB)..."
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$(tappaas_ssh_identity)" "root@${NODE}:${PREPARED}" "${DEST_ISO}" \
  || die "copying the prepared ISO failed"
sudo node-provisioner prepare --iso "${DEST_ISO}" \
  || die "node-provisioner prepare failed"

info "netboot staging complete — 'site-manager node add <name> --pxe' is ready."
info "USB alternative: write the SAME image to a stick:  dd if=${DEST_ISO} of=/dev/<usb> bs=4M"
