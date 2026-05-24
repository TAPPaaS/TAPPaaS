#!/usr/bin/env bash
#
# TAPPaaS Firewall Bootstrap (config-firewall.sh)  — issues #141, #182
#
# Stands up the OPNsense firewall VM during foundation bootstrap, BEFORE
# tappaas-cicd exists. It seeds a complete management-network configuration via
# the OPNsense "importer" so the firewall comes up fully functional (LAN,
# DNS/DHCP, static hosts, hostname, API key) with no GUI clicking — the manual
# marathon the old docs required. The VLAN/zone/proxy/rule setup is layered on
# later by the opnsense-controller (zone/caddy/rules-manager) inside cicd, which
# connects using the API key seeded here.
#
# Run on a PVE node (tappaas1) AFTER config-network.sh has created the lan/wan
# bridges. Fixes #182 by installing from the dvd ISO onto an expandable UFS
# disk (not the fixed nano image).
#
# Flow:
#   1. Generate an API key/secret (for cicd) and hash the root password.
#   2. Render firewall-config.xml.template → config.xml.
#   3. Build a small FAT importer drive holding /conf/config.xml.
#   4. Create + start the firewall VM (installer ISO + UFS disk + importer drive
#      + lan/wan NICs) via Create-TAPPaaS-VM.sh.
#   5. Guide the short OPNsense installer; on confirmation, finalize boot order
#      and verify reachability + the API key.
#   6. Write the API credentials to ~/.opnsense-credentials.txt for cicd.
#
# Usage: config-firewall.sh [--repo URL] [--branch NAME] [--root-pw PASS]
#                           [--non-interactive] [-h|--help]
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
cleanup() {
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] || return 0
  mountpoint -q "$WORKDIR/mnt" 2>/dev/null && umount "$WORKDIR/mnt" 2>/dev/null || true
  [[ -n "${IMPORT_LOOP:-}" ]] && losetup -d "$IMPORT_LOOP" 2>/dev/null || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# ── Arguments ────────────────────────────────────────────────────────
REPO="https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/"
BRANCH="main"
ROOT_PW=""
INTERACTIVE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)            REPO="${2:-}"; shift 2 ;;
    --branch)          BRANCH="${2:-}"; shift 2 ;;
    --root-pw)         ROOT_PW="${2:-}"; shift 2 ;;
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

readonly CONFIG_DIR="/home/tappaas/config"
readonly TAPPAAS_DIR="/root/tappaas"
readonly CREDS_FILE="${HOME}/.opnsense-credentials.txt"
readonly FW_JSON="${TAPPAAS_DIR}/firewall.json"
readonly TEMPLATE="${TAPPAAS_DIR}/firewall-config.xml.template"
readonly CREATE_VM="${TAPPAAS_DIR}/Create-TAPPaaS-VM.sh"

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
STORAGE="$(jq -r '.storage' "$FW_JSON")"
LAN_BRIDGE="$(jq -r '.bridge0 // "lan"' "$FW_JSON")"
[[ -n "$VMID" && "$VMID" != "null" ]] || die "vmid missing in firewall.json"

# ── Preconditions ────────────────────────────────────────────────────
if ! ip link show "$LAN_BRIDGE" >/dev/null 2>&1; then
  die "Bridge '${LAN_BRIDGE}' not found — run config-network.sh first (it builds lan/wan)."
fi
if qm status "$VMID" >/dev/null 2>&1; then
  die "VM ${VMID} already exists. Delete it first if you intend to rebuild the firewall."
fi

# ── 1. Generate credentials ──────────────────────────────────────────
# API key/secret for the opnsense-controller (cicd). OPNsense stores the key in
# clear and the secret as a sha512-crypt hash; it verifies by re-crypting with
# the embedded salt, so a random-salt `openssl passwd -6` hash is accepted.
info "Generating API credentials"
API_KEY="$(openssl rand -base64 60 | tr -d '\n')"
API_SECRET="$(openssl rand -base64 60 | tr -d '\n')"
API_SECRET_HASH="$(openssl passwd -6 "$API_SECRET")"

# Root password (the importer adopts the config's root password). Prompt unless
# given; generate one if non-interactive.
if [[ -z "$ROOT_PW" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -r -s -p "  Set OPNsense root password (blank = generate one): " ROOT_PW; echo
  fi
  if [[ -z "$ROOT_PW" ]]; then
    ROOT_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    info "  Generated root password: ${BOLD}${ROOT_PW}${CL}  (save this!)"
  fi
fi
# OPNsense verifies local passwords via crypt() too; sha512 is accepted.
ROOT_PW_HASH="$(openssl passwd -6 "$ROOT_PW")"

# Sanity-check the hashes: `openssl passwd -6 ""` emits the literal "<NULL>",
# which would inject a bogus tag and break the config.xml. Real creds are never
# empty, but fail loudly rather than ship a broken seed.
for _h in "$API_SECRET_HASH" "$ROOT_PW_HASH"; do
  case "$_h" in '$6$'*) ;; *) die "Generated hash is invalid ('${_h}') — refusing to build a broken config.xml" ;; esac
done

# ── 2. Render config.xml ─────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
CONFIG_XML="${WORKDIR}/config.xml"
# Use a non-/ delimiter and awk to inject values safely (hashes contain / . $).
APIKEYS_VALUE="${API_KEY}|${API_SECRET_HASH}"
export APIKEYS_VALUE ROOT_PW_HASH
awk '
  { gsub(/@APIKEYS@/, ENVIRON["APIKEYS_VALUE"]);
    gsub(/@ROOT_PW_HASH@/, ENVIRON["ROOT_PW_HASH"]);
    print }
' "$TEMPLATE" > "$CONFIG_XML"
grep -qE '@[A-Z_]+@' "$CONFIG_XML" && warn "Unsubstituted @PLACEHOLDER@ remains in config.xml — check the template."
info "Rendered config.xml ($(wc -l <"$CONFIG_XML") lines)"

# ── 3. Build the FAT importer drive (/conf/config.xml) ──────────────
# CRITICAL: the OPNsense importer only mounts the config as FAT (msdos) when it
# lives on a *partition* (da1s1 / da1p1). A whole-disk FAT (no partition table)
# falls through to its last branch and is mounted as cd9660 → fails. So we lay
# down an MBR with one FAT partition, not mkfs.vfat on the raw image.
command -v mkfs.vfat >/dev/null || { info "Installing dosfstools"; apt-get -y install dosfstools >/dev/null 2>&1 || die "could not install dosfstools"; }
command -v parted   >/dev/null || { info "Installing parted";    apt-get -y install parted    >/dev/null 2>&1 || die "could not install parted"; }
IMPORT_IMG="${WORKDIR}/importer.img"
IMPORT_LOOP=""
info "Building importer drive (MBR + FAT partition)"
dd if=/dev/zero of="$IMPORT_IMG" bs=1M count=32 status=none
parted -s "$IMPORT_IMG" mklabel msdos
parted -s "$IMPORT_IMG" mkpart primary fat16 1MiB 100%
IMPORT_LOOP="$(losetup -P --show -f "$IMPORT_IMG")"
for _ in 1 2 3 4 5 6; do [[ -e "${IMPORT_LOOP}p1" ]] && break; sleep 0.3; done
[[ -e "${IMPORT_LOOP}p1" ]] || die "partition node ${IMPORT_LOOP}p1 did not appear"
mkfs.vfat -F 16 -n OPNCONFIG "${IMPORT_LOOP}p1" >/dev/null
mkdir -p "${WORKDIR}/mnt"
mount "${IMPORT_LOOP}p1" "${WORKDIR}/mnt"
mkdir -p "${WORKDIR}/mnt/conf"
cp "$CONFIG_XML" "${WORKDIR}/mnt/conf/config.xml"
umount "${WORKDIR}/mnt"
losetup -d "$IMPORT_LOOP"; IMPORT_LOOP=""

# ── 4. Create the VM + attach the importer drive ────────────────────
info "Creating the firewall VM (installer ISO + UFS disk + lan/wan NICs)..."
cp "$FW_JSON" "${CONFIG_DIR}/firewall.json" 2>/dev/null || true
"$CREATE_VM" "$VMNAME"

# Create-TAPPaaS-VM.sh powers the VM on at the end. Stop it: the importer drive
# isn't attached yet, and the importer prompt is a brief (~8s) window ~20s into
# boot — the operator must attach-then-watch, not have it boot unattended.
info "Stopping VM to attach the importer drive (it must not boot unattended)..."
qm stop "$VMID" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  qm status "$VMID" 2>/dev/null | grep -q stopped && break
  sleep 1
done

info "Attaching the importer drive (config seed)..."
qm importdisk "$VMID" "$IMPORT_IMG" "$STORAGE" >/dev/null
# Attach the freshly imported volume as scsi1 (it is the highest-indexed unused).
IMPORTED_VOL="$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/{v=$2} END{print v}')"
[[ -n "$IMPORTED_VOL" ]] || die "Could not find the imported config volume"
qm set "$VMID" --scsi1 "$IMPORTED_VOL" >/dev/null

# ── 5. Guide the installer + finalize ───────────────────────────────
# IMPORTANT: open the console BEFORE powering on — the importer prompt appears
# only ~20s into boot and lasts ~8s, so you must be watching from the start.
cat <<EOF

${BOLD}=== OPNsense install for VM ${VMID} (${VMNAME}) ===${CL}
  FIRST: open the console now → Datacenter → ${VMNAME} → Console (noVNC).
EOF
if [[ "$INTERACTIVE" == "1" ]]; then
  read -r -p "  With the console open, press ENTER here to power on the VM... " _
fi
info "Starting the firewall VM..."
qm start "$VMID" >/dev/null
cat <<EOF

  ${BOLD}Watch the console:${CL}
  1. Boot runs ~20s ("${BL}Root mount waiting for: CAM${CL}" pause is NORMAL). You can
     ${BOLD}ignore${CL} the brief "Press any key … importer" prompt — we import inside the
     installer instead (more reliable, and it's what carries onto the disk).
  2. Log in as ${BOLD}installer / opnsense${CL} (the default password).
  3. In the installer menu, FIRST choose ${BOLD}Import Config${CL} → select the ${BOLD}OPNCONFIG${CL}
     disk (the small 16M one, usually ${BOLD}da1${CL}) → "Configuration import completed".
  4. Then choose ${BOLD}Install (UFS)${CL}: accept the keymap, select the ${BL}$(jq -r '.diskSize' "$FW_JSON")${CL}
     target disk (${BOLD}da0${CL}), confirm the ${BOLD}erase/overwrite${CL}, then ${BOLD}Complete install${CL} →
     reboot (no cable changes).

The installed firewall comes up as ${BL}firewall${CL} / LAN ${BL}10.0.0.1${CL} (root password = the one
you set), with DNS/DHCP and the API enabled. If LAN shows 192.168.1.1, the import
was skipped — reinstall and be sure to run ${BOLD}Import Config${CL} before Install.
EOF

if [[ "$INTERACTIVE" == "1" ]]; then
  read -r -p "Press ENTER once OPNsense has installed and rebooted to the login prompt... " _
else
  info "Non-interactive: finalize later by re-running with --non-interactive after install, or run the qm steps below."
fi

# Finalize: with the CD still attached and CD-first boot order, the post-install
# reboot lands back in the live installer. Stop the VM, detach the installer CD
# + importer drive, set boot to the installed disk, and start it — so it boots
# the real installed firewall (and the verify below checks that, not the CD).
info "Finalizing VM (detach installer media, boot from disk)..."
qm stop "$VMID" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do qm status "$VMID" 2>/dev/null | grep -q stopped && break; sleep 1; done
qm set "$VMID" --delete ide2 >/dev/null 2>&1 || true   # installer CD
qm set "$VMID" --delete scsi1 >/dev/null 2>&1 || true  # importer drive (config already applied)
qm set "$VMID" --boot order='scsi0' >/dev/null 2>&1 || true
qm start "$VMID" >/dev/null 2>&1 || true
info "Booting the installed firewall..."

# ── 6. Write credentials for cicd + verify ──────────────────────────
umask 077
cat > "$CREDS_FILE" <<EOF
key=${API_KEY}
secret=${API_SECRET}
EOF
info "Wrote API credentials → ${CREDS_FILE} (for tappaas-cicd / opnsense-controller)"

info "Verifying firewall reachability..."
ok=0
for _ in $(seq 1 12); do
  if ping -c1 -W2 10.0.0.1 >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [[ "$ok" == "1" ]]; then
  info "${GN}✓${CL} Firewall reachable at 10.0.0.1"
else
  warn "Firewall not yet answering at 10.0.0.1 — give it a moment, then verify the install/console."
fi

info "${GN}Firewall bootstrap complete.${CL}"
info "Next: run config-network.sh --swap-cables, bring up tappaas-cicd, then zone-manager/caddy-manager."
