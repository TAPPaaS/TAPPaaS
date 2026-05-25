#!/usr/bin/env bash
#
# TAPPaaS Platform Install (install-platform.sh)
#
# Run ONCE on the first node (tappaas1) AFTER all cluster nodes and the firewall
# are up. It builds the management control plane:
#
#   A. NixOS VM template (vmid 8080) — imports the prebuilt NixOS image and
#      finalises it into a Proxmox template (no manual NixOS install).
#   B. tappaas-cicd mothership (vmid 130) — clones the template and runs the
#      in-VM install end-to-end OVER SSH: install1.sh (clone + nixos-rebuild),
#      reboot the VM, then install2.sh (platform tooling + reverse proxy). cicd
#      then drives the rest of the platform (zone/caddy/rules-manager, modules).
#
# Phase B is automated: the node's root key is authorised on the cicd VM at clone
# time, so the script SSHes in as tappaas and runs the installers itself. It also
# pre-authorises cicd's key on every node so install2's node SSH setup needs no
# passwords. Use --manual-cicd to instead just print the in-VM steps.
#
# Usage:
#   install-platform.sh [--repo URL] [--branch NAME] [--domain DOMAIN]
#                       [--skip-template] [--skip-cicd] [--manual-cicd]
#                       [--non-interactive]
#
# Notes:
#   --domain  Public TLS domain for the platform. NOT derivable from the node
#             (the Proxmox FQDN is the internal mgmt.internal domain); the admin
#             email IS auto-discovered from the node. If omitted, install2 keeps
#             its CHANGE-domain.tld placeholder for you to set later.
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
SKIP_TEMPLATE=0 SKIP_CICD=0 INTERACTIVE=1 MANUAL_CICD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)            REPO="${2:-}"; shift 2 ;;
    --branch)          BRANCH="${2:-}"; shift 2 ;;
    --domain)          DOMAIN="${2:-}"; shift 2 ;;
    --skip-template)   SKIP_TEMPLATE=1; shift ;;
    --skip-cicd)       SKIP_CICD=1; shift ;;
    --manual-cicd)     MANUAL_CICD=1; shift ;;
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

# ── cicd-over-SSH helpers (Phase B automation) ───────────────────────
# The node's root key is injected into the cicd VM's tappaas user at clone time
# (Create-TAPPaaS-VM.sh --sshkey), so root@node can ssh tappaas@cicd with no
# password. We reach cicd by its DHCP IP (discovered via the guest agent), since
# DNS for tappaas-cicd does not exist this early in the install.
readonly CICD_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
CICD_IP=""

# Resolve the cicd VM's LAN IPv4 from the guest agent (matches net0's MAC).
cicd_resolve_ip() { # cicd_resolve_ip <vmid>  -> echoes IP or empty
  local vmid="$1" mac ifaces
  mac="$(qm config "$vmid" 2>/dev/null | sed -n 's/^net0:.*virtio=\([0-9A-Fa-f:]*\).*/\1/p' | tr 'A-F' 'a-f')"
  ifaces="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null)" || return 1
  [[ -n "$ifaces" ]] || return 1
  # Prefer the interface whose hardware-address matches net0; fall back to the
  # first non-loopback IPv4 if the MAC lookup misses.
  echo "$ifaces" | jq -r --arg m "${mac:-none}" '
    ([.[] | select((.["hardware-address"]//"" | ascii_downcase) == $m)
          | .["ip-addresses"][]? | select(.["ip-address-type"]=="ipv4") | .["ip-address"]]
     + [.[] | .["ip-addresses"][]? | select(.["ip-address-type"]=="ipv4")
          | .["ip-address"] | select(. != "127.0.0.1")])
    | .[0] // empty'
}

cicd_ssh() { ssh "${CICD_SSH_OPTS[@]}" "tappaas@${CICD_IP}" "$@"; }

# Wait until the cicd VM has an IP and accepts SSH as tappaas. Sets CICD_IP.
wait_cicd_ssh() { # wait_cicd_ssh <vmid> [max_wait_s]
  local vmid="$1" max="${2:-300}" waited=0 ip
  info "Waiting for tappaas-cicd (VM ${vmid}) to boot and accept SSH..."
  while (( waited < max )); do
    ip="$(cicd_resolve_ip "$vmid" || true)"
    if [[ -n "$ip" ]]; then
      CICD_IP="$ip"
      if cicd_ssh true 2>/dev/null; then
        info "  cicd reachable at ${BL}${CICD_IP}${CL} (ssh tappaas@ ok)"
        return 0
      fi
    fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

# Pre-authorise cicd's public key on every cluster node's root account, so
# install2.sh's `ssh-copy-id` to each node succeeds non-interactively (the key
# it would install already authenticates; no root-password prompt). Run from the
# node, which already has cluster-wide root SSH.
distribute_cicd_key() {
  local pub node
  pub="$(cicd_ssh 'cat /home/tappaas/.ssh/id_ed25519.pub' 2>/dev/null || true)"
  [[ -n "$pub" ]] || { warn "Could not read cicd public key — install2 may prompt for node passwords."; return 0; }
  info "Authorising cicd's key on cluster node root accounts..."
  while read -r node; do
    [[ -n "$node" ]] || continue
    if ssh -n "${CICD_SSH_OPTS[@]}" "root@${node}.mgmt.internal" \
         "mkdir -p /root/.ssh && touch /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && grep -qxF '${pub}' /root/.ssh/authorized_keys || echo '${pub}' >> /root/.ssh/authorized_keys" 2>/dev/null; then
      info "  ${node}: cicd key authorised"
    else
      warn "  ${node}: could not authorise cicd key (install2 may prompt for its root password)"
    fi
  done < <(pvesh get /cluster/resources --type node --output-format json 2>/dev/null | jq -r '.[].node')
}

# Propagate the firewall API credentials to the cicd. config-firewall.sh wrote
# them to THIS node's /root/.opnsense-credentials.txt; the cicd's
# opnsense-controller / setup-caddy read /home/tappaas/.opnsense-credentials.txt.
propagate_fw_credentials() {
  local creds="/root/.opnsense-credentials.txt"
  if [[ ! -s "$creds" ]]; then
    warn "No ${creds} on this node — cicd will lack firewall API credentials (firewall mgmt will fail)."
    return 0
  fi
  info "Copying firewall API credentials to cicd..."
  if cicd_ssh "umask 077; cat > /home/tappaas/.opnsense-credentials.txt && chmod 600 /home/tappaas/.opnsense-credentials.txt" < "$creds"; then
    info "  ${GN}✓${CL} API credentials copied to cicd"
  else
    warn "  could not copy API credentials to cicd"
  fi
}

# Give the cicd SSH access to the firewall. config-firewall.sh authorized THIS
# node's control-plane key on the firewall (key-only SSH); the cicd reaches the
# firewall over SSH for the VLAN-assign PHP patch (pre-update.sh) and the QEMU
# guest agent (install2.sh). Rather than mutate the firewall config to add a
# second key, the cicd reuses the node's already-authorized key: copy it over and
# point firewall SSH at it via ~/.ssh/config. (Single-operator control plane —
# the node already injects its key into cicd and cicd's key onto the nodes.)
grant_cicd_firewall_access() {
  local nodekey=""
  for _k in /root/.ssh/id_rsa /root/.ssh/id_ed25519; do [[ -f "$_k" ]] && { nodekey="$_k"; break; }; done
  [[ -n "$nodekey" ]] || { warn "No node private key found — cicd cannot SSH the firewall."; return 0; }
  info "Granting cicd SSH access to the firewall (via the control-plane key)..."
  cicd_ssh "umask 077; mkdir -p /home/tappaas/.ssh && cat > /home/tappaas/.ssh/tappaas-fw && chmod 600 /home/tappaas/.ssh/tappaas-fw" < "$nodekey" || {
    warn "  could not copy the firewall access key to cicd"; return 0; }
  cicd_ssh 'k=/home/tappaas/.ssh/config; touch "$k"; chmod 600 "$k"; grep -q "Host firewall" "$k" 2>/dev/null || printf "Host firewall.mgmt.internal firewall.internal 10.0.0.1\n  User root\n  IdentityFile /home/tappaas/.ssh/tappaas-fw\n  StrictHostKeyChecking accept-new\n" >> "$k"' \
    && info "  ${GN}✓${CL} cicd can now SSH root@firewall (control-plane key)" \
    || warn "  could not write cicd ~/.ssh/config for the firewall"
}

# Fallback: print the manual in-VM install steps (old behaviour / --manual-cicd).
print_manual_cicd() { # print_manual_cicd <vmid> <domain>
  local cicdid="$1" dom="$2"
  cat <<EOF

  ${BOLD}Finish tappaas-cicd inside the VM (SSH in as the tappaas user):${CL}
  1. ${BL}ssh tappaas@tappaas-cicd${CL}   (or its DHCP address; see 'qm guest cmd ${cicdid} network-get-interfaces')
  2. Bootstrap the checkout + system config:
        ${BL}curl -fsSL ${REPO}${BRANCH}/src/foundation/tappaas-cicd/install1.sh -o /tmp/install1.sh${CL}
        ${BL}bash /tmp/install1.sh "https://github.com/TAPPaaS/TAPPaaS.git" "${BRANCH}"${CL}
        ${BL}sudo reboot${CL}   (then reconnect)
  3. Install the platform tooling:
        ${BL}cd TAPPaaS/src/foundation/tappaas-cicd${CL}
        ${BL}./install2.sh --branch "${BRANCH}" --domain "${dom}"${CL}

Once cicd is up it owns the platform: zone-manager / caddy-manager / rules-manager
configure VLANs, the reverse proxy and firewall rules (using the firewall API key
in ~/.opnsense-credentials.txt), and modules are installed via install-module.sh.
EOF
}

# ── Phase A: NixOS VM template (vmid 8080) ──────────────────────────
# Imports the PREBUILT, pre-configured NixOS image (built by GitHub Actions and
# published as a Release asset; see .github/workflows/build-nixos-template-image.yml)
# and converts it straight to a Proxmox template. No manual NixOS install — the
# TAPPaaS baseline (tappaas-common.nix) is already baked into the image.
build_template() {
  local nixid; nixid="$(jq -r '.vmid' "${TAPPAAS_DIR}/tappaas-nixos.json" 2>/dev/null || echo 8080)"
  echo -e "\n${GN}${BOLD}=== A. NixOS VM template (vmid ${nixid}) ===${CL}"

  if is_template "$nixid"; then
    info "Template ${nixid} already exists — skipping build."
    return 0
  fi
  if vm_exists "$nixid"; then
    warn "VM ${nixid} exists but is not a template."
    confirm_enter "Press ENTER to finalise it into a template, or Ctrl-C to abort... "
  else
    [[ -f "${TAPPAAS_DIR}/tappaas-nixos.json" ]] || { info "Fetching tappaas-nixos.json"; fetch "${REPO}${BRANCH}/src/foundation/templates/tappaas-nixos.json" "${TAPPAAS_DIR}/tappaas-nixos.json"; }
    info "Creating VM ${nixid} from the prebuilt NixOS image (downloads + imports a"
    info "~700 MB compressed disk image — no manual install needed)..."
    "$CREATE_VM" tappaas-nixos
  fi

  info "Finalising: stopping VM ${nixid} and converting it to a template..."
  qm stop "$nixid" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do qm status "$nixid" 2>/dev/null | grep -q stopped && break; sleep 1; done
  if qm template "$nixid" >/dev/null 2>&1; then
    info "${GN}✓${CL} VM ${nixid} converted to a template."
    # Record which release this template was built from, so templates/update.sh
    # can later tell — with a cheap API call, no image download — whether a newer
    # release exists. Best-effort: a missing marker just makes the first update
    # run rebuild once.
    local latest_tag
    latest_tag="$(curl -fsSL "https://api.github.com/repos/TAPPaaS/TAPPaaS/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')"
    [[ -n "$latest_tag" ]] && printf '%s\n' "$latest_tag" > "${TAPPAAS_DIR}/nixos-template.version"
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

  local dom="${DOMAIN:-CHANGE-domain.tld}"

  # --manual-cicd: keep the old behaviour — just print the in-VM steps.
  if [[ "$MANUAL_CICD" == "1" ]]; then
    print_manual_cicd "$cicdid" "$dom"
    confirm_enter "Press ENTER when the tappaas-cicd install is complete... "
    return 0
  fi

  # Automated Phase B over SSH. Any prerequisite failure falls back to printing
  # the manual steps so the operator is never left stuck.
  if ! wait_cicd_ssh "$cicdid"; then
    warn "Could not reach the cicd VM over SSH automatically."
    print_manual_cicd "$cicdid" "$dom"
    return 0
  fi

  # Skip if cicd already looks installed (idempotent re-runs).
  if cicd_ssh 'test -f /home/tappaas/config/.tappaas-cicd-installed' 2>/dev/null; then
    info "cicd already fully installed (completion marker present) — skipping in-VM install."
    return 0
  fi

  # B.1 — clone the repo + rebuild the NixOS system (install1.sh).
  info "Running install1.sh on cicd (git clone + nixos-rebuild switch)..."
  if ! cicd_ssh "curl -fsSL '${REPO}${BRANCH}/src/foundation/tappaas-cicd/install1.sh' -o /tmp/install1.sh && bash /tmp/install1.sh 'https://github.com/TAPPaaS/TAPPaaS.git' '${BRANCH}'"; then
    warn "install1.sh failed on cicd. Finish manually:"
    print_manual_cicd "$cicdid" "$dom"
    return 0
  fi

  # B.2 — pre-authorise cicd's key on the nodes so install2's ssh-copy-id is
  #        non-interactive (no node root-password prompts).
  distribute_cicd_key

  # B.3 — reboot cicd to activate the rebuilt system generation, then wait.
  info "Rebooting cicd (VM ${cicdid}) to activate the new system generation..."
  qm reboot "$cicdid" >/dev/null 2>&1 || qm reset "$cicdid" >/dev/null 2>&1 || true
  sleep 10
  if ! wait_cicd_ssh "$cicdid"; then
    warn "cicd did not come back after reboot. Finish install2 manually:"
    print_manual_cicd "$cicdid" "$dom"
    return 0
  fi

  # B.3.5 — hand the cicd what it needs to manage the firewall: the API
  #          credentials (for opnsense-controller / caddy) and SSH access (for the
  #          VLAN-assign PHP patch + guest agent that install2/pre-update use).
  propagate_fw_credentials
  grant_cicd_firewall_access

  # B.4 — platform tooling + reverse proxy (install2.sh). Pass --branch so the
  #        cicd tracks the SAME branch we installed from: create-configuration.sh
  #        defaults to 'stable', which would make pre-update.sh check out stale
  #        stable code (e.g. predating the single-node HA guard) even on a main
  #        install. Pass --domain only when supplied (else install2 keeps its
  #        placeholder default).
  local install2_cmd="cd TAPPaaS/src/foundation/tappaas-cicd && ./install2.sh --branch '${BRANCH}'"
  if [[ -n "$DOMAIN" ]]; then
    install2_cmd+=" --domain '${DOMAIN}'"
  else
    warn "No --domain given; install2 will use the CHANGE-domain.tld placeholder."
    warn "Set it later with: create-configuration.sh --update --domain <yourdomain>"
  fi
  info "Running install2.sh on cicd${DOMAIN:+ (domain ${DOMAIN})}..."
  if ! cicd_ssh "$install2_cmd"; then
    warn "install2.sh reported errors — review on cicd (ssh tappaas@${CICD_IP})."
    return 1
  fi

  info "${GN}✓${CL} tappaas-cicd is installed and owns the platform (reachable at ${BL}${CICD_IP}${CL})."
}

# ── Run ──────────────────────────────────────────────────────────────
info "${BOLD}TAPPaaS platform install${CL} (NixOS template + tappaas-cicd) on $(hostname -s)"
if ! pvecm status >/dev/null 2>&1; then
  warn "This node is not a cluster member — run the node/cluster bootstrap first."
fi

if [[ "$SKIP_TEMPLATE" == "1" ]]; then info "Skipping NixOS template (--skip-template)"; else build_template; fi
if [[ "$SKIP_CICD" == "1" ]];     then info "Skipping tappaas-cicd (--skip-cicd)";      else build_cicd;     fi

echo ""
info "${GN}${BOLD}Platform install steps complete.${CL} Next steps (from the cicd mothership):"
info "  ${BOLD}1.${CL} Add the other cluster nodes (3-node cluster): FIRST ${BOLD}reboot this node${CL} so the"
info "     renumbered corosync config loads (a node cannot join until then), then run the"
info "     node bootstrap on each; they auto-join. cicd configures HA + replication on update."
info "  ${BOLD}2.${CL} Configure the Caddy ${BOLD}DNS-01 provider credentials${CL} (e.g. your Cloudflare API"
info "     token) so public TLS certificates can be issued for app domains."
info "  ${BOLD}3.${CL} Install the rest of the foundation — backup (35), identity (40), logging —"
info "     then add app/community stacks. See https://tappaas.org/installation/foundation/"
