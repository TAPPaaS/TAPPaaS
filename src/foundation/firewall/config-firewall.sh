#!/usr/bin/env bash
#
# TAPPaaS Firewall Bootstrap (config-firewall.sh)  — issues #141, #182, #231
#
# Stands up the OPNsense firewall VM during foundation bootstrap, BEFORE
# tappaas-cicd exists, with NO operator interaction (issue #231). It imports a
# PRECONFIGURED OPNsense image (built by GitHub Actions, published as a Release;
# see .github/workflows/build-opnsense-image.yml) that boots straight to a
# working firewall at 10.0.0.1, then pushes this deployment's UNIQUE config
# (unique API key + root password) over SSH and reboots into it.
#
# Why SSH (not the API): OPNsense has no API to create/rotate API keys, so the
# unique credentials are applied by replacing /conf/config.xml — the mechanism
# proven by the #231 spike (drop config.xml in /conf + reboot → adopted). The
# bootstrap IMAGE ships SSH-enabled with a well-known bootstrap root password
# (BOOTSTRAP_PW) for exactly this one push; the deployed config (rendered from
# firewall-config.xml.template, SSH off) replaces it, so the running firewall
# ends with SSH disabled and unique creds. The bootstrap creds are only ever
# reachable on the isolated bootstrap LAN during this push.
#
# Run on a PVE node (tappaas1) AFTER config-network.sh has created the lan/wan
# bridges (the node reaches the firewall at 10.0.0.1 over the lan bridge).
#
# Flow:
#   1. Generate a unique API key/secret + root password (+ hashes).
#   2. Render firewall-config.xml.template → unique config.xml (SSH off).
#   3. Create + boot the firewall VM from the prebuilt image (Create-TAPPaaS-VM.sh).
#   4. Wait for the bootstrap SSH, scp the unique config.xml into /conf, reboot.
#   5. Verify the firewall is back at 10.0.0.1; write API creds for cicd.
#
# IMPORTANT: BOOTSTRAP_PW below must match BOOTSTRAP_ROOT_PW baked by the image
# workflow (.github/workflows/build-opnsense-image.yml).
#
# Usage: config-firewall.sh [--repo URL] [--branch NAME] [--root-pw PASS]
#                           [--bootstrap-pw PASS] [--non-interactive] [-h|--help]
#
# Exit codes: 0 ok, 1 error, 2 usage.

set -euo pipefail

readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[firewall]${CL} $*"; }
warn()  { echo -e "${YW}[firewall][warn]${CL} $*"; }
error() { echo -e "${RD}[firewall][error]${CL} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── Cleanup ──────────────────────────────────────────────────────────
WORKDIR=""
cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# ── Arguments ────────────────────────────────────────────────────────
REPO="https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/"
BRANCH="main"
ROOT_PW=""
# Bootstrap root password baked into the prebuilt image (see workflow). Override
# only if you changed it in the workflow.
BOOTSTRAP_PW="opnsense"
INTERACTIVE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)            REPO="${2:-}"; shift 2 ;;
    --branch)          BRANCH="${2:-}"; shift 2 ;;
    --root-pw)         ROOT_PW="${2:-}"; shift 2 ;;
    --bootstrap-pw)    BOOTSTRAP_PW="${2:-}"; shift 2 ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || die "Must run as root on a PVE node."
[[ -t 0 && -t 1 ]] || INTERACTIVE=0
command -v qm      >/dev/null || die "qm not found — run this on a Proxmox node."
command -v openssl >/dev/null || die "openssl not found."
command -v jq      >/dev/null || die "jq not found."
command -v sshpass >/dev/null || { info "Installing sshpass"; apt-get -y install sshpass >/dev/null 2>&1 || die "could not install sshpass"; }

readonly CONFIG_DIR="/home/tappaas/config"
readonly TAPPAAS_DIR="/root/tappaas"
readonly CREDS_FILE="${HOME}/.opnsense-credentials.txt"
readonly FW_JSON="${TAPPAAS_DIR}/firewall.json"
readonly TEMPLATE="${TAPPAAS_DIR}/firewall-config.xml.template"
readonly CREATE_VM="${TAPPAAS_DIR}/Create-TAPPaaS-VM.sh"
readonly FW_IP="10.0.0.1"
readonly SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

bssh() { sshpass -p "$BOOTSTRAP_PW" ssh "${SSH_OPTS[@]}" "root@${FW_IP}" "$@"; }
bscp() { sshpass -p "$BOOTSTRAP_PW" scp "${SSH_OPTS[@]}" "$@"; }

# ── Fetch firewall.json + template if not present ───────────────────
mkdir -p "$TAPPAAS_DIR"
fetch() { # fetch <url> <dest>  (fatal on failure, never leaves a partial)
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$1" -o "$tmp" && [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Download failed: $1"; }
  mv "$tmp" "$2"
}
[[ -f "$FW_JSON" ]]   || { info "Fetching firewall.json";   fetch "${REPO}${BRANCH}/src/foundation/firewall/firewall.json" "$FW_JSON"; }
[[ -f "$TEMPLATE" ]]  || { info "Fetching config template"; fetch "${REPO}${BRANCH}/src/foundation/firewall/firewall-config.xml.template" "$TEMPLATE"; }
[[ -x "$CREATE_VM" ]] || die "Create-TAPPaaS-VM.sh not found at ${CREATE_VM} (run the PVE node bootstrap first)."

VMID="$(jq -r '.vmid' "$FW_JSON")"
VMNAME="$(jq -r '.vmname' "$FW_JSON")"
LAN_BRIDGE="$(jq -r '.bridge0 // "lan"' "$FW_JSON")"
[[ -n "$VMID" && "$VMID" != "null" ]] || die "vmid missing in firewall.json"

# ── Preconditions ────────────────────────────────────────────────────
ip link show "$LAN_BRIDGE" >/dev/null 2>&1 || die "Bridge '${LAN_BRIDGE}' not found — run config-network.sh first (it builds lan/wan)."
if qm status "$VMID" >/dev/null 2>&1; then
  die "VM ${VMID} already exists. Delete it first if you intend to rebuild the firewall."
fi

# ── 1. Generate unique credentials ───────────────────────────────────
# API key/secret for the opnsense-controller (cicd). OPNsense stores the key in
# clear and the secret as a sha512-crypt hash; it re-crypts with the embedded
# salt, so a random-salt `openssl passwd -6` hash is accepted.
info "Generating unique API credentials"
API_KEY="$(openssl rand -base64 60 | tr -d '\n')"
API_SECRET="$(openssl rand -base64 60 | tr -d '\n')"
API_SECRET_HASH="$(openssl passwd -6 "$API_SECRET")"

# Root password for the DEPLOYED firewall (replaces the bootstrap password).
if [[ -z "$ROOT_PW" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -r -s -p "  Set OPNsense root password (blank = generate one): " ROOT_PW; echo
  fi
  if [[ -z "$ROOT_PW" ]]; then
    ROOT_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    info "  Generated root password: ${BOLD}${ROOT_PW}${CL}  (save this!)"
  fi
fi
ROOT_PW_HASH="$(openssl passwd -6 "$ROOT_PW")"

# Guard: `openssl passwd -6 ""` emits literal "<NULL>" which would break the XML.
for _h in "$API_SECRET_HASH" "$ROOT_PW_HASH"; do
  case "$_h" in '$6$'*) ;; *) die "Generated hash is invalid ('${_h}') — refusing to build a broken config.xml" ;; esac
done

# ── 2. Render the unique config.xml (SSH off — deployed posture) ─────
WORKDIR="$(mktemp -d)"
CONFIG_XML="${WORKDIR}/config.xml"
APIKEYS_VALUE="${API_KEY}|${API_SECRET_HASH}"
export APIKEYS_VALUE ROOT_PW_HASH
awk '
  { gsub(/@APIKEYS@/, ENVIRON["APIKEYS_VALUE"]);
    gsub(/@ROOT_PW_HASH@/, ENVIRON["ROOT_PW_HASH"]);
    print }
' "$TEMPLATE" > "$CONFIG_XML"
grep -qE '@[A-Z_]+@' "$CONFIG_XML" && warn "Unsubstituted @PLACEHOLDER@ remains in config.xml — check the template."
info "Rendered unique config.xml ($(wc -l <"$CONFIG_XML") lines)"

# ── 3. Create + boot the firewall VM from the prebuilt image ─────────
info "Creating the firewall VM from the prebuilt image (downloads + imports)..."
cp "$FW_JSON" "${CONFIG_DIR}/firewall.json" 2>/dev/null || true
"$CREATE_VM" "$VMNAME"   # imageType img → download, import, boot (bootstrap config: 10.0.0.1, SSH on)

# ── 4. Wait for the firewall to FULLY boot, then swap config + reboot ─
info "Waiting for the firewall's bootstrap SSH at ${FW_IP} (first boot ~90s)..."
ok=0
for _ in $(seq 1 40); do
  if bssh true 2>/dev/null; then ok=1; break; fi
  sleep 5
done
[[ "$ok" == "1" ]] || die "Bootstrap SSH on ${FW_IP} never came up — check the VM console (is it the prebuilt image with SSH enabled?)."
# Wait until OPNsense has FULLY finished first boot (GUI answering on 443).
# OPNsense rewrites /conf/config.xml during first-boot settling; scp'ing before
# that races and is overwritten. The GUI answering means settling is done.
info "${GN}✓${CL} Bootstrap SSH up. Waiting for OPNsense to finish booting (GUI)..."
for _ in $(seq 1 30); do
  curl -ksS -o /dev/null --max-time 5 "https://${FW_IP}/" 2>/dev/null && break
  sleep 5
done
sleep 8   # small extra settle margin

info "Applying this deployment's unique config..."
# Upload to a TEMP path first: this does NOT change /conf/config.xml, so the
# bootstrap root password stays valid for the SSH auth below.
bscp "$CONFIG_XML" "root@${FW_IP}:/tmp/tappaas-deploy-config.xml" || die "Failed to upload config.xml to the firewall."
# Apply in two deterministic stages (subtleties learned on the test bench):
#   1. cp the config into place + rc.reload_all. rc.reload_all re-reads
#      /conf/config.xml into memory and rotates the API key + root password live,
#      so in-memory == deployed. (It does NOT reliably stop a running sshd, and a
#      reboot chained after it gets killed when the reload restarts sshd — so we
#      don't chain it.) Run detached + piped to /bin/sh (the OPNsense root shell
#      is csh and would mangle the redirects).
printf '%s\n' \
  'cp /tmp/tappaas-deploy-config.xml /conf/config.xml' \
  'rm -f /tmp/config.cache' \
  'nohup /usr/local/etc/rc.reload_all >/tmp/tappaas-apply.log 2>&1 &' \
  'sleep 1' \
  | bssh /bin/sh >/dev/null 2>&1 || true
info "Reloading firewall config (rotating credentials)..."
# Wait for the rotation to take effect: the UNIQUE API key must authenticate.
for _ in $(seq 1 30); do
  curl -ksS --max-time 6 -u "${API_KEY}:${API_SECRET}" "https://${FW_IP}/api/core/firmware/status" 2>/dev/null | grep -q '"product' && break
  sleep 5
done
#   2. Reboot the VM from the NODE (qm) — deterministic and independent of the
#      firewall's SSH (which the deployed config disables). Because in-memory is
#      now the deployed config, the clean boot persists it and brings sshd down.
info "Rebooting the firewall (clean boot into the hardened deployed config)..."
qm reboot "$VMID" >/dev/null 2>&1 || qm stop "$VMID" >/dev/null 2>&1 && qm start "$VMID" >/dev/null 2>&1 || true

# ── 5. Verify + write credentials for cicd ───────────────────────────
umask 077
cat > "$CREDS_FILE" <<EOF
key=${API_KEY}
secret=${API_SECRET}
EOF
info "Wrote API credentials → ${CREDS_FILE} (for tappaas-cicd / opnsense-controller)"

info "Verifying the firewall comes back at ${FW_IP} with the deployed config..."
ok=0
sleep 20
for _ in $(seq 1 24); do
  if ping -c1 -W2 "$FW_IP" >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [[ "$ok" == "1" ]]; then
  info "${GN}✓${CL} Firewall reachable at ${FW_IP}"
  # Confirm the DEPLOYED config is live: the unique API key must authenticate
  # (proves rotation succeeded, not the bootstrap config). Give the GUI a moment.
  api_ok=0
  for _ in $(seq 1 18); do
    if curl -ksS --max-time 6 -u "${API_KEY}:${API_SECRET}" "https://${FW_IP}/api/core/firmware/status" 2>/dev/null | grep -q '"product'; then api_ok=1; break; fi
    sleep 5
  done
  if [[ "$api_ok" == "1" ]]; then
    info "${GN}✓${CL} Unique API key authenticates — deployed config is live."
  else
    warn "Unique API key did not authenticate yet — the rotation may not have applied; check the console."
  fi
else
  warn "Firewall not yet answering at ${FW_IP} — give it a moment, then verify the console."
fi

cat <<EOF

${GN}${BOLD}========================  Firewall bootstrap complete  ========================${CL}

Next steps to finish the TAPPaaS foundation (run on this node unless noted):

  ${BOLD}1. Swap cables.${CL}
     Put the firewall inline: WAN uplink → the firewall's WAN, and the
     management switch/trunk → the firewall's LAN. Then point this node's
     routing + DNS at the firewall:
        ${BL}~/tappaas/config-network.sh --swap-cables${CL}

  ${BOLD}2. Move your management PC to the local network.${CL}
     Connect your admin workstation to the TAPPaaS management LAN; it gets a
     ${BL}10.0.0.x${CL} lease from the firewall. The firewall GUI is at
     ${BL}https://${FW_IP}${CL} (root + the password you set).

  ${BOLD}3. Run the sanity checks.${CL}
        ${BL}~/tappaas/sanity-check.sh${CL}
     Confirms gateway, internal/external DNS and internet all work before you
     build on top. Fix anything red before continuing.

  ${BOLD}4. Install additional cluster nodes${CL}  ${YW}(optional — skip for a single node).${CL}
     On each extra node, run the same node bootstrap (cluster install.sh); it
     auto-joins this cluster.

  ${BOLD}5. Build the management platform${CL} (once all nodes are up):
        ${BL}~/tappaas/install-platform.sh${CL}
     cicd then takes over VLANs, reverse proxy and firewall rules (via the API
     key in ${BL}${CREDS_FILE}${CL}), then backup (35) and identity (40) follow.
${GN}${BOLD}==============================================================================${CL}
EOF
