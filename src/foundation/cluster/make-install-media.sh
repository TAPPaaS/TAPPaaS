#!/usr/bin/env bash
#
# make-install-media.sh — build a preconfigured Proxmox VE install ISO for a
# TAPPaaS FIRST node (issue #404 item 1; docs/design/node-provisioning.md N2).
#
# Wraps `proxmox-auto-install-assistant prepare-iso` around a stock PVE ISO
# with a TAPPaaS answer file, so the resulting USB stick installs Proxmox
# fully unattended. Only the four operator-specific answers (#404) are asked
# for — email, locale (country/keyboard/timezone), root password, boot disk —
# everything else is TAPPaaS defaults (network from DHCP; follow-on nodes are
# provisioned over PXE by node-provisioner instead, see design doc N3/N4).
#
# Run this on a machine with proxmox-auto-install-assistant installed — any
# existing Proxmox node works:  apt install proxmox-auto-install-assistant
#
# Usage:
#   make-install-media.sh --iso proxmox-ve_9.x.iso \
#       [--email <e>] [--country <cc>] [--keyboard <kb>] [--timezone <tz>] \
#       [--password-file <f>] [--disk <dev>] [--fqdn <host.domain>] \
#       [--filesystem ext4|zfs] [--ssh-key <pubkey-file>] [--out <out.iso>]
#
# Anything not given is prompted for. The answer file is validated by the
# assistant before the ISO is built, so schema drift across PVE versions
# fails loudly at BUILD time, never at install time.
#
set -euo pipefail

RD="\033[01;31m"; GN="\033[1;92m"; YW="\033[33m"; CL="\033[m"
info()  { echo -e "${GN}[Info]${CL} $*"; }
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
die()   { echo -e "${RD}[Error]${CL} $*" >&2; exit 1; }

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

ISO="" OUT="" EMAIL="" COUNTRY="" KEYBOARD="" TIMEZONE="" PASSWORD="" \
  PASSWORD_FILE="" DISK="" FQDN="" FILESYSTEM="ext4"
SSH_KEYS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)           ISO="${2:?}"; shift 2 ;;
    --out)           OUT="${2:?}"; shift 2 ;;
    --email)         EMAIL="${2:?}"; shift 2 ;;
    --country)       COUNTRY="${2:?}"; shift 2 ;;
    --keyboard)      KEYBOARD="${2:?}"; shift 2 ;;
    --timezone)      TIMEZONE="${2:?}"; shift 2 ;;
    --password-file) PASSWORD_FILE="${2:?}"; shift 2 ;;
    --disk)          DISK="${2:?}"; shift 2 ;;
    --fqdn)          FQDN="${2:?}"; shift 2 ;;
    --filesystem)    FILESYSTEM="${2:?}"; shift 2 ;;
    --ssh-key)       SSH_KEYS+=("${2:?}"); shift 2 ;;
    -h|--help)       usage ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

command -v proxmox-auto-install-assistant >/dev/null 2>&1 \
  || die "proxmox-auto-install-assistant not found — run on a PVE node or 'apt install proxmox-auto-install-assistant'."
[[ -n "$ISO" && -f "$ISO" ]] || die "--iso <proxmox-ve.iso> is required (download from proxmox.com)."

# ── The four #404 operator answers (prompt for whatever is missing) ────
prompt() { local v; read -r -p "  $1: " v; printf '%s' "$v"; }
[[ -n "$EMAIL"    ]] || EMAIL="$(prompt 'Admin email (Proxmox mailto)')"
[[ -n "$COUNTRY"  ]] || COUNTRY="$(prompt 'Country code (e.g. dk)')"
[[ -n "$KEYBOARD" ]] || KEYBOARD="$(prompt 'Keyboard layout (e.g. en-us, dk)')"
[[ -n "$TIMEZONE" ]] || TIMEZONE="$(prompt 'Timezone (e.g. Europe/Copenhagen)')"
[[ -n "$FQDN"     ]] || FQDN="$(prompt 'Node FQDN (e.g. tappaas1.mgmt.internal)')"
if [[ -n "$PASSWORD_FILE" ]]; then
  PASSWORD="$(<"$PASSWORD_FILE")"
else
  read -r -s -p "  Root password: " PASSWORD; echo ""
  read -r -s -p "  Root password (again): " PASSWORD2; echo ""
  [[ "$PASSWORD" == "$PASSWORD2" ]] || die "Passwords do not match."
fi
[[ ${#PASSWORD} -ge 8 ]] || die "Root password must be at least 8 characters."
if [[ -z "$DISK" ]]; then
  echo "  Boot disk is the ONE tricky question (#404) — the installer wipes it."
  DISK="$(prompt 'Boot disk device (e.g. nvme0n1, sda — as listed by lsblk on the target)')"
fi
case "$FILESYSTEM" in ext4|zfs) ;; *) die "--filesystem must be ext4 or zfs" ;; esac

# ── Build the answer file ──────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ANSWER="${WORK}/answer.toml"

{
  echo '[global]'
  echo "keyboard = \"${KEYBOARD}\""
  echo "country = \"${COUNTRY}\""
  echo "fqdn = \"${FQDN}\""
  echo "mailto = \"${EMAIL}\""
  echo "timezone = \"${TIMEZONE}\""
  echo "root-password = \"${PASSWORD}\""
  if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
    echo -n 'root-ssh-keys = ['
    _sep=""
    for k in "${SSH_KEYS[@]}"; do
      [[ -f "$k" ]] && k="$(<"$k")"
      echo -n "${_sep}\"${k}\""
      _sep=", "
    done
    echo ']'
  fi
  echo ''
  echo '[network]'
  echo 'source = "from-dhcp"'
  echo ''
  echo '[disk-setup]'
  echo "filesystem = \"${FILESYSTEM}\""
  if [[ "$FILESYSTEM" == "zfs" ]]; then
    echo 'zfs.raid = "raid0"'
  fi
  echo "disk-list = [\"${DISK}\"]"
} > "$ANSWER"

info "Validating the answer file (assistant catches schema drift here)..."
proxmox-auto-install-assistant validate-answer "$ANSWER" \
  || die "Answer file failed validation — see above (PVE version schema mismatch?)."

# ── Prepare the ISO (answer embedded — no network needed at install) ──
[[ -n "$OUT" ]] || OUT="${ISO%.iso}-tappaas-auto.iso"
info "Preparing ISO: ${OUT}"
proxmox-auto-install-assistant prepare-iso "$ISO" \
  --fetch-from iso --answer-file "$ANSWER" --output "$OUT" \
  || die "prepare-iso failed."

info "${GN}✓${CL} Done. Write it to USB:  dd if='${OUT}' of=/dev/<usb> bs=4M status=progress"
info "The install runs UNATTENDED and WIPES ${DISK} on the target machine."
warn "The ISO embeds the root password — treat the media like a credential."
