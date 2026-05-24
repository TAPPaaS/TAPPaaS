#!/usr/bin/env bash
#
# TAPPaaS Platform Install (install-platform.sh)
#
# Run ONCE on the first node (tappaas1) AFTER all cluster nodes and the firewall
# are up. It builds the management control plane:
#
#   A. NixOS VM template (vmid 8080) — creates the VM, guides the (manual) NixOS
#      install + TAPPaaS configuration, then finalises it into a Proxmox template.
#   B. tappaas-cicd mothership (vmid 130) — clones the template and guides the
#      in-VM install (install1.sh / install2.sh). cicd then drives the rest of
#      the platform (zone/caddy/rules-manager, modules, etc.).
#
# The heavy lifting inside each VM (the NixOS installer, nixos-rebuild, and the
# cicd install scripts) is interactive/manual — this script creates the VMs,
# prints the exact commands, and does the finalisation (qm template).
#
# Usage:
#   install-platform.sh [--repo URL] [--branch NAME] [--domain DOMAIN]
#                       [--skip-template] [--skip-cicd] [--non-interactive]
#
# Exit codes: 0 ok, 1 error, 2 usage.

set -euo pipefail

readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[platform]${CL} $*"; }
warn()  { echo -e "${YW}[platform][warn]${CL} $*"; }
error() { echo -e "${RD}[platform][error]${CL} $*" >&2; }
die()   { error "$*"; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# ── Arguments ────────────────────────────────────────────────────────
REPO="https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/"
BRANCH="main"
DOMAIN=""
SKIP_TEMPLATE=0 SKIP_CICD=0 INTERACTIVE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)            REPO="${2:-}"; shift 2 ;;
    --branch)          BRANCH="${2:-}"; shift 2 ;;
    --domain)          DOMAIN="${2:-}"; shift 2 ;;
    --skip-template)   SKIP_TEMPLATE=1; shift ;;
    --skip-cicd)       SKIP_CICD=1; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || die "Must run as root on the first PVE node."
[[ -t 0 && -t 1 ]] || INTERACTIVE=0
command -v qm >/dev/null || die "qm not found — run this on a Proxmox node."

readonly TAPPAAS_DIR="/root/tappaas"
readonly CREATE_VM="${TAPPAAS_DIR}/Create-TAPPaaS-VM.sh"
[[ -x "$CREATE_VM" ]] || die "Create-TAPPaaS-VM.sh not found at ${CREATE_VM} (run the node bootstrap first)."
mkdir -p "$TAPPAAS_DIR"

fetch() { # fetch <url> <dest> [mode]  (fatal on failure)
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$1" -o "$tmp" && [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Download failed: $1"; }
  mv "$tmp" "$2"; chmod "${3:-644}" "$2"
}

confirm_enter() { [[ "$INTERACTIVE" == "1" ]] && read -r -p "$1" _ || true; }

vm_exists() { qm status "$1" >/dev/null 2>&1; }
is_template() { qm config "$1" 2>/dev/null | grep -q '^template:\s*1'; }

# ── Phase A: NixOS VM template (vmid 8080) ──────────────────────────
build_template() {
  local nixid; nixid="$(jq -r '.vmid' "${TAPPAAS_DIR}/tappaas-nixos.json" 2>/dev/null || echo 8080)"
  echo -e "\n${GN}${BOLD}=== A. NixOS VM template (vmid ${nixid}) ===${CL}"

  if is_template "$nixid"; then
    info "Template ${nixid} already exists — skipping build."
    return 0
  fi
  if vm_exists "$nixid"; then
    warn "VM ${nixid} exists but is not a template. Finish/convert it, or destroy it to rebuild."
    confirm_enter "Press ENTER to (re)finalise it into a template, or Ctrl-C to abort... "
  else
    [[ -f "${TAPPAAS_DIR}/tappaas-nixos.json" ]] || { info "Fetching tappaas-nixos.json"; fetch "${REPO}${BRANCH}/src/foundation/templates/tappaas-nixos.json" "${TAPPAAS_DIR}/tappaas-nixos.json"; }
    info "Creating the NixOS VM (${nixid}) from the installer ISO..."
    "$CREATE_VM" tappaas-nixos
  fi

  cat <<EOF

  ${BOLD}Build the NixOS template in the Proxmox console (VM ${nixid}):${CL}
  1. Open Datacenter → tappaas-nixos → Console.
  2. Install NixOS with the graphical installer (defaults are fine; set a user +
     root password; install to the disk; reboot).
  3. Apply the TAPPaaS template configuration inside the VM:
        ${BL}sudo curl -fsSL ${REPO}${BRANCH}/src/foundation/templates/tappaas-nixos.nix \\
             -o /etc/nixos/configuration.nix${CL}
        ${BL}sudo nixos-rebuild switch${CL}
  4. Optimise + power off (so the template is clean):
        ${BL}sudo nix-collect-garbage -d && sudo poweroff${CL}
EOF
  confirm_enter "Press ENTER once the NixOS VM is configured and powered off... "

  info "Finalising: stopping VM ${nixid} and converting it to a template..."
  qm stop "$nixid" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do qm status "$nixid" 2>/dev/null | grep -q stopped && break; sleep 1; done
  if qm template "$nixid" >/dev/null 2>&1; then
    info "${GN}✓${CL} VM ${nixid} converted to a template."
  else
    warn "Could not convert VM ${nixid} to a template (already one? still running?). Check 'qm config ${nixid}'."
  fi
}

# ── Phase B: tappaas-cicd mothership (vmid 130) ─────────────────────
build_cicd() {
  local cicdid; cicdid="$(jq -r '.vmid' "${TAPPAAS_DIR}/tappaas-cicd.json" 2>/dev/null || echo 130)"
  echo -e "\n${GN}${BOLD}=== B. tappaas-cicd mothership (vmid ${cicdid}) ===${CL}"

  if vm_exists "$cicdid"; then
    warn "VM ${cicdid} already exists — skipping creation (finish its in-VM install if needed)."
  else
    [[ -f "${TAPPAAS_DIR}/tappaas-cicd.json" ]] || { info "Fetching tappaas-cicd.json"; fetch "${REPO}${BRANCH}/src/foundation/tappaas-cicd/tappaas-cicd.json" "${TAPPAAS_DIR}/tappaas-cicd.json"; }
    info "Cloning the NixOS template into the tappaas-cicd VM (${cicdid})..."
    "$CREATE_VM" tappaas-cicd
  fi

  local dom="${DOMAIN:-yourdomain.com}"
  cat <<EOF

  ${BOLD}Finish tappaas-cicd inside the VM (SSH in as the tappaas user):${CL}
  1. ${BL}ssh tappaas@tappaas-cicd${CL}   (or its DHCP address; see 'qm guest cmd ${cicdid} network-get-interfaces')
  2. Bootstrap the checkout + system config:
        ${BL}curl -fsSL ${REPO}${BRANCH}/src/foundation/tappaas-cicd/install1.sh -o /tmp/install1.sh${CL}
        ${BL}bash /tmp/install1.sh "https://github.com/TAPPaaS/TAPPaaS.git" "${BRANCH}"${CL}
  3. Install the platform tooling:
        ${BL}cd TAPPaaS/src/foundation/tappaas-cicd${CL}
        ${BL}./install2.sh --domain "${dom}"${CL}

Once cicd is up it owns the platform: zone-manager / caddy-manager / rules-manager
configure VLANs, the reverse proxy and firewall rules (using the firewall API key
in ~/.opnsense-credentials.txt), and modules are installed via install-module.sh.
EOF
  confirm_enter "Press ENTER when the tappaas-cicd install is complete... "
}

# ── Run ──────────────────────────────────────────────────────────────
info "${BOLD}TAPPaaS platform install${CL} (NixOS template + tappaas-cicd) on $(hostname -s)"
if ! pvecm status >/dev/null 2>&1; then
  warn "This node is not a cluster member — run the node/cluster bootstrap first."
fi

if [[ "$SKIP_TEMPLATE" == "1" ]]; then info "Skipping NixOS template (--skip-template)"; else build_template; fi
if [[ "$SKIP_CICD" == "1" ]];     then info "Skipping tappaas-cicd (--skip-cicd)";      else build_cicd;     fi

echo ""
info "${GN}${BOLD}Platform install steps complete.${CL}"
info "Continue with backup (35-backup) and identity (40-Identity) — see https://tappaas.org/installation/foundation/"
