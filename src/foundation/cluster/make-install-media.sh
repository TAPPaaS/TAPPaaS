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
# Runs anywhere (first-node chicken-and-egg: no PVE system exists yet):
#   - a PVE/Debian box with proxmox-auto-install-assistant — used directly;
#   - any other Linux — the assistant's .deb is fetched from the Proxmox
#     repo and extracted into a temp dir (no root, no install);
#   - macOS — re-executes itself inside a debian container (Docker
#     required); run it FROM the directory holding the ISO (the CWD is
#     what gets mounted).
#
# Usage:
#   make-install-media.sh --iso proxmox-ve_9.x.iso \
#       [--email <e>] [--country <cc>] [--keyboard <kb>] [--timezone <tz>] \
#       [--password-file <f>] [--disk <dev>] [--fqdn <host.domain>] \
#       [--filesystem ext4|zfs] [--ssh-key <pubkey-file>] [--out <out.iso>]
#
# Anything not given is prompted for — EXCEPT the boot disk: like the PXE
# flow, network comes from DHCP and the disk is asked ON THE TARGET'S
# CONSOLE at install time (it lists the machine's real disks; the answer's
# placeholder is rewritten by a prompt injected into the installer initrd).
# Pass --disk <dev> to bake it in and keep the install fully unattended.
# The answer file is validated by the assistant before the ISO is built, so
# schema drift across PVE versions fails loudly at BUILD time.
#
set -euo pipefail

ORIG_ARGS=("$@")

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

# ── Assistant bootstrap (first-node chicken-and-egg) ───────────────────
if ! command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin)
      command -v docker >/dev/null 2>&1 \
        || die "proxmox-auto-install-assistant is Linux-only and Docker is not available — install Docker Desktop, or run this script on any Linux box."
      info "assistant not found — re-running inside a Debian container (mounting \$PWD)..."
      exec docker run --rm -it -v "$PWD:/work" -w /work debian:trixie bash -c "
        apt-get update -qq >/dev/null &&
        apt-get install -y -qq wget ca-certificates zstd cpio xorriso >/dev/null &&
        echo 'deb [trusted=yes] http://download.proxmox.com/debian/pve trixie pve-no-subscription' > /etc/apt/sources.list.d/pve.list &&
        apt-get update -qq >/dev/null &&
        apt-get install -y -qq proxmox-auto-install-assistant >/dev/null &&
        exec ./$(basename "$0") $(printf '%q ' "${ORIG_ARGS[@]}")"
      ;;
    Linux)
      info "assistant not found — fetching the .deb from the Proxmox repo (no install needed)..."
      _PAIA_DIR="$(mktemp -d)"
      _pve_base="http://download.proxmox.com/debian/pve"
      _pkg=""
      for _codename in trixie bookworm; do
        _pkg="$(wget -qO- "${_pve_base}/dists/${_codename}/pve-no-subscription/binary-amd64/Packages" 2>/dev/null \
                | awk '/^Package: proxmox-auto-install-assistant$/{f=1} f&&/^Filename:/{print $2; exit}')" \
          && [[ -n "$_pkg" ]] && break
      done
      [[ -n "$_pkg" ]] || die "could not locate proxmox-auto-install-assistant in the Proxmox repo — install it manually."
      wget -q "${_pve_base}/${_pkg}" -O "${_PAIA_DIR}/paia.deb" || die "assistant .deb download failed."
      if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "${_PAIA_DIR}/paia.deb" "${_PAIA_DIR}"
      else
        (cd "${_PAIA_DIR}" && ar x paia.deb && tar -xf data.tar.*)
      fi
      export PATH="${_PAIA_DIR}/usr/bin:${PATH}"
      command -v proxmox-auto-install-assistant >/dev/null 2>&1 \
        || die "assistant extraction failed (${_PAIA_DIR})."
      ;;
    *) die "unsupported platform $(uname -s)" ;;
  esac
fi
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
ASK_DISK=0
if [[ -z "$DISK" ]]; then
  # Like the PXE flow: the disk is asked ON THE TARGET'S CONSOLE at install
  # time (the answer carries a placeholder; a prompt injected into the
  # installer initrd rewrites it with the operator's choice).
  ASK_DISK=1
  DISK="ASKDISK"
  info "no --disk given — the boot disk will be asked on the target's console at install time"
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

# ── Ask-at-install boot disk: inject the console prompt into the initrd ──
# Same mechanism as the PXE flow (node-provisioner assets.py): the kernel
# accepts a LATER initramfs segment overriding /init, so we append a cpio
# with a patched init that (a) shows the machine's real disks and reads the
# choice on the console, (b) bind-mounts a rewritten answer.toml (the
# ASKDISK placeholder replaced) over the ISO's copy before switch_root.
if [[ "$ASK_DISK" -eq 1 ]]; then
  for _tool in xorriso cpio; do
    command -v "$_tool" >/dev/null 2>&1 || die "$_tool is required for the ask-at-install disk prompt (apt/brew install $_tool) — or pass --disk <dev> to bake the disk in."
  done
  info "Injecting the boot-disk console prompt into the installer initrd..."
  AW="$(mktemp -d)"
  xorriso -osirrox on -indev "$OUT" -extract /boot/initrd.img "${AW}/initrd.img" >/dev/null 2>&1 \
    || die "cannot extract boot/initrd.img from the prepared ISO."
  chmod u+w "${AW}/initrd.img"
  # Extract the pristine /init (initrd is zstd on PVE 9, gzip on older).
  if ! zstd -dcq "${AW}/initrd.img" 2>/dev/null | (cd "$AW" && cpio -i --quiet init 2>/dev/null); then
    gzip -dc "${AW}/initrd.img" 2>/dev/null | (cd "$AW" && cpio -i --quiet init 2>/dev/null) \
      || die "cannot extract /init from the initrd (unknown compression — PVE layout drift?)."
  fi
  _ANCHOR='cp /etc/hostid /mnt/.installer-mp/etc/'
  grep -qF "$_ANCHOR" "${AW}/init" || die "PVE init layout drift — cannot inject the disk prompt (anchor missing). Re-run with --disk <dev>."
  cat > "${AW}/askblock" <<'ASKBLOCK'
    # TAPPaaS make-install-media: ask-at-install boot disk (the answer's
    # ASKDISK placeholder is rewritten with the console choice).
    _tap_ans=""
    for _tap_f in /mnt/.installer-mp/cdrom/answer.toml /mnt/.installer-mp/cdrom/*.toml; do
        [ -f "$_tap_f" ] && grep -q "ASKDISK" "$_tap_f" 2>/dev/null && _tap_ans="$_tap_f" && break
    done
    if [ -n "$_tap_ans" ]; then
    {
        sleep 3
        echo "1 1 1 7" > /proc/sys/kernel/printk 2>/dev/null || true
        echo ""
        echo "==== TAPPaaS install: choose the BOOT disk ===="
        echo "The chosen disk is WIPED (PVE system). Disks found:"
        for _tap_d in /sys/block/*; do
            _tap_b="${_tap_d##*/}"
            case "$_tap_b" in loop*|ram*|sr*|dm-*|zram*) continue ;; esac
            _tap_sz=$(cat "$_tap_d/size" 2>/dev/null || echo 0)
            echo "  $_tap_b  ($((_tap_sz / 2097152)) GB)  $(cat "$_tap_d/device/model" 2>/dev/null)"
        done
        _tap_disk=""
        while [ ! -e "/sys/block/$_tap_disk" ] || [ -z "$_tap_disk" ]; do
            printf "TAPPaaS boot disk> "
            read -r _tap_disk
        done
        while IFS= read -r _tap_l; do
            case "$_tap_l" in
                *ASKDISK*) echo "disk-list = [\"${_tap_disk}\"]" ;;
                *) echo "$_tap_l" ;;
            esac
        done < "$_tap_ans" > /tappaas-answer.toml
        mount --bind /tappaas-answer.toml "$_tap_ans"
        echo "TAPPaaS: installing to '$_tap_disk'"
    } < "/dev/${console:-console}" > "/dev/${console:-console}" 2>&1
    fi
ASKBLOCK
  awk -v anchor="$_ANCHOR" -v blockfile="${AW}/askblock" \
    '{ print; if (index($0, anchor)) { while ((getline l < blockfile) > 0) print l } }' \
    "${AW}/init" > "${AW}/init.new"
  mv "${AW}/init.new" "${AW}/init"
  chmod 755 "${AW}/init"
  # 4-byte segment alignment (the kernel SILENTLY drops a misaligned
  # trailing cpio — stage-1 hardware finding), then append the override.
  _sz="$(stat -c %s "${AW}/initrd.img" 2>/dev/null || stat -f %z "${AW}/initrd.img")"
  _pad=$(( (4 - _sz % 4) % 4 ))
  [[ "$_pad" -gt 0 ]] && head -c "$_pad" /dev/zero >> "${AW}/initrd.img"
  (cd "$AW" && echo init | cpio -o -H newc --quiet >> initrd.img)
  # Swap the initrd inside the ISO, preserving bootability (El Torito/EFI).
  xorriso -indev "$OUT" -outdev "${OUT}.tmp.iso" \
    -map "${AW}/initrd.img" /boot/initrd.img -boot_image any replay >/dev/null 2>&1 \
    || die "xorriso initrd swap failed."
  mv "${OUT}.tmp.iso" "$OUT"
  rm -rf "$AW"
  info "boot-disk console prompt injected."
fi

info "${GN}✓${CL} Done. Write it to USB:  dd if='${OUT}' of=/dev/<usb> bs=4M status=progress"
if [[ "$ASK_DISK" -eq 1 ]]; then
  info "The install asks ONE question on the target's console (the boot disk), then runs unattended and WIPES it."
else
  info "The install runs UNATTENDED and WIPES ${DISK} on the target machine."
fi
warn "The ISO embeds the root password — treat the media like a credential."
