#!/usr/bin/env bash
#
# bootstrap-tappaas.sh — install TAPPaaS on a first node from this computer.
#
# It builds a Proxmox VE install image that installs unattended (a stock ISO with
# a TAPPaaS answer file), writes it to a USB stick or serves it over the network,
# waits for the node, and runs the TAPPaaS install on it. Further nodes are added
# from the running site instead (the console's Add a node).
#
# Runs anywhere (first-node chicken-and-egg: no PVE system exists yet):
#   - a PVE/Debian box with proxmox-auto-install-assistant — used directly;
#   - any other Linux — the assistant's .deb is fetched from the Proxmox
#     repo and extracted into a temp dir (no root, no install);
#   - macOS — the build alone runs inside a debian container (Docker
#     required); run it FROM the directory holding the ISO (the CWD is
#     what gets mounted).
#
# Everything is asked first, before the build: what the options below do not give.
# Then the image is built, written to a USB stick or served over the network,
# the node waited for and the TAPPaaS install run on it over ssh, with no further
# question. The ISO carries the public half of a key made for it, <out>.key,
# which is how the node is found and logged in to.
#
# Usage:
#   bootstrap-tappaas.sh [options]
#
# Mandatory (asked when not given; without a terminal, the script stops):
#   --email <e>              the admin's email, for email alerting
#   --password-file <f>      the node's root password, in a file (asked hidden)
#   --site <name>            the TAPPaaS Site name, when the install is started
#
# What to do, the first question when --boot is not given:
#   1) make the image and write it to a USB stick
#   2) the same, then install TAPPaaS on the machine booted from it (default)
#   3) the stick is made already: install TAPPaaS on the machine booted from it
#      (the image made earlier in this directory, or --use)
#   4) make the image, boot the machine over the network, and install TAPPaaS
#   5) only make the image file
#   6) install TAPPaaS on a rented server (Hetzner), through its rescue system
#
# How the target boots the image (instead of the question):
#   --boot usb|network|booted|none
#                            usb: write it to a stick; network: serve it from this
#                            machine (needs dnsmasq); booted: the target already
#                            runs it; none: only build it
#   --stick <device>         the stick to erase (/dev/disk4, /dev/sdb); else chosen
#                            from a list
#   --yes                    the stick may be erased without asking
#   --iface <if>             this machine's interface on the target's network
#
# The TAPPaaS install on the node (asked when not given; --install follows from
# the first question's answer):
#   --install | --no-install start it over ssh when the node is up, or not
#   --branch <b>             stable (default), or main for the newest work
#   --organization <org>     the organisation controlling the Site (default: the
#                            Site name)
#   --domain <d>             the Site's domain (default: <site>.home.arpa)
#   --size <s>               how big the Site is: small (a few users, one node or a
#                            test system), medium (default, up to ~50 users) or
#                            large (100+ users, 3+ large nodes); it sizes every
#                            module's cores, memory and disk
#   --show-token | --no-show-token
#                            show the console's access token on this screen at the
#                            end (never in the log)
#   --node <ip>              the node's address, when it is not in this /24
#
# Not asked (each has a right default, shown before the build):
#   --country <cc> --keyboard <kb> --timezone <tz>
#                            the site's, else this machine's settings
#   --fqdn <host.domain>     the first node's name (tappaas1.mgmt.internal)
#   --disk <d> [--disk <d>]  the boot disk, chosen on the target (below)
#   --filesystem zfs|ext4    zfs (default)
#   --ssh-key <pubkey-file>  another key for root on the node
#
# A rented server (Hetzner), choice 6 (asked when not given):
#   --rescue <ip>            the server's main IPv4, booted into Hetzner's rescue
#                            system with your SSH key: Proxmox is installed from
#                            there (the build and the installer run on the server,
#                            in QEMU), then TAPPaaS
#   --wan-address <ip>       the firewall's own public IPv4 (an additional IP)
#   --wan-mac <mac>          its virtual MAC, generated in Robot
#   --wan-gateway <ip>       its gateway (default: the server's)
#   Needs wg (wireguard-tools) here: your WireGuard key is made on this computer,
#   enrolled at the install, and its config written to <site>.conf at the end.
#
# The image:
#   --iso <proxmox-ve_9.x.iso>   the stock ISO (default: the one in this directory;
#                                with none, the newest Proxmox lists is downloaded)
#   --iso-sha256 <hex>           its checksum, when Proxmox does not list it
#   --out <out.iso>              the built image (default: <iso>-tappaas-auto.iso)
#   --use <built.iso>            skip the build: an image this script built
#   --log <f>                    the log (default: bootstrap-tappaas-<time>.log)
#   -h, --help                   this text
#
# Everything shown, the TAPPaaS install on the node included, also goes to a log in
# this directory, or to --log; only you can read it, as that output can carry
# generated credentials.
#
# The boot disk is ZFS by default: the boot pool then carries the
# guests on a node with no data disk. A second --disk mirrors it (zfs raid1);
# each disk then gets its own EFI system partition, and config-storage.sh makes
# sure proxmox-boot-tool keeps both, so the node boots from either. ext4 is for
# a node that has data disks: config-storage.sh refuses an ext4 boot disk alone.
#
# The boot disk is not asked here: it is chosen ON THE TARGET at install time, as with a network-booted node: a hook injected
# into the installer initrd matches --disk against the machine's real disks and
# rewrites the answer's placeholder. --disk is a size (2TB, 500GB), a model
# ("Samsung 990") or a serial; left out, the smallest SSD or NVMe disk not on
# USB, and both when the smallest two are the same model and size (mirrored —
# a second --disk none keeps one). --disk ask, or a field that matches no disk,
# asks on the target's console. Kernel names (nvme0n1) are baked in as given:
# NVMe names are not stable across boots, so give them only for a mirrored pair.
# The answer file is validated by the assistant before the ISO is built, so
# schema drift across PVE versions fails loudly at BUILD time.
#
set -euo pipefail

ORIG_ARGS=("$@")

RD="\033[01;31m"; GN="\033[1;92m"; YW="\033[1;33m"; CY="\033[1;96m"; MG="\033[1;95m"; CL="\033[m"
# What the operator answers, and what the operator must go and do, stand out from the rest.
IN="$(printf '%b' "${CY}[Input]${CL}")"
info()  { echo -e "${GN}[Info]${CL} $*"; }
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
action() { echo -e "${MG}[Action]${CL} $*"; }
die()   { echo -e "${RD}[Error]${CL} $*" >&2; exit 1; }
debug() { [[ "${TAPPAAS_DEBUG:-0}" == 1 ]] || return 0; echo "[Debug] $*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0; }

ISO="" ISO_FETCH=0 OUT="" EMAIL="" COUNTRY="" KEYBOARD="" TIMEZONE="" PASSWORD="" \
  PASSWORD_FILE="" DISK="" FQDN="" FILESYSTEM="zfs" ISO_SHA256=""
SSH_KEYS=()
DISKS=()
LOG="" USE="" PXE_IFACE="" NODE_IP="" BRANCH="" SITE_CODE="" ORG="" DOMAIN="" SIZE=""
# How the target boots the image, the stick, and whether to install: asked up front
# when not given, so nothing is asked once the build has started.
BOOT="" STICK="" YES=0 INSTALL_ANSWER="" SHOW_TOKEN="" SUDO_KEEP="" WANT_INSTALL=0
# A rented server (choice 6), and what the build on its rescue system is given.
RESCUE_IP="" WAN_ADDR="" WAN_MAC="" WAN_GW="" HOSTED_ARGS="" HOSTED_RESUME=0
NET_CIDR="" NET_GW="" NET_DNS="" NET_MAC="" SERIAL_CONSOLE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)           ISO="${2:?}"; shift 2 ;;
    --out)           OUT="${2:?}"; shift 2 ;;
    --email)         EMAIL="${2:?}"; shift 2 ;;
    --country)       COUNTRY="${2:?}"; shift 2 ;;
    --keyboard)      KEYBOARD="${2:?}"; shift 2 ;;
    --timezone)      TIMEZONE="${2:?}"; shift 2 ;;
    --password-file) PASSWORD_FILE="${2:?}"; shift 2 ;;
    --disk)          DISKS+=("${2:?}"); DISK="${DISKS[0]}"; shift 2 ;;
    --fqdn)          FQDN="${2:?}"; shift 2 ;;
    --filesystem)    FILESYSTEM="${2:?}"; shift 2 ;;
    --ssh-key)       SSH_KEYS+=("${2:?}"); shift 2 ;;
    --iso-sha256)    ISO_SHA256="${2:?}"; shift 2 ;;
    --use)           USE="${2:?}"; shift 2 ;;
    --log)           LOG="${2:?}"; shift 2 ;;
    --iface)         PXE_IFACE="${2:?}"; shift 2 ;;
    --node)          NODE_IP="${2:?}"; shift 2 ;;
    --branch)        BRANCH="${2:?}"; shift 2 ;;
    --site)          SITE_CODE="${2:?}"; shift 2 ;;
    --organization)  ORG="${2:?}"; shift 2 ;;
    --domain)        DOMAIN="${2:?}"; shift 2 ;;
    --size)          SIZE="${2:?}"; shift 2 ;;
    --boot)          BOOT="${2:?}"; shift 2 ;;
    --stick)         STICK="${2:?}"; shift 2 ;;
    --yes)           YES=1; shift ;;
    --install)       INSTALL_ANSWER=yes; shift ;;
    --no-install)    INSTALL_ANSWER=no; shift ;;
    --show-token)    SHOW_TOKEN=1; shift ;;
    --rescue)        RESCUE_IP="${2:?}"; BOOT=rescue; shift 2 ;;
    --wan-address)   WAN_ADDR="${2:?}"; shift 2 ;;
    --wan-mac)       WAN_MAC="${2:?}"; shift 2 ;;
    --wan-gateway)   WAN_GW="${2:?}"; shift 2 ;;
    # The build on a rescue system: a static network, the NIC it is pinned to,
    # and the installer's console on the serial port, which the build follows.
    --net-cidr)      NET_CIDR="${2:?}"; shift 2 ;;
    --net-gateway)   NET_GW="${2:?}"; shift 2 ;;
    --net-dns)       NET_DNS="${2:?}"; shift 2 ;;
    --net-mac)       NET_MAC="${2:?}"; shift 2 ;;
    --serial-console) SERIAL_CONSOLE=1; shift ;;
    --no-show-token) SHOW_TOKEN=0; shift ;;
    -h|--help)       usage ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

# >>> media-checks (ADR-033 D7)
# What this script takes from Proxmox is checked against Proxmox's own statement
# before it is used, and a failed check stops the build:
#   - the operator's ISO against Proxmox's published SHA256SUMS (or --iso-sha256
#     when the ISO is not listed there, e.g. an offline build);
#   - the assistant .deb by the SHA-256 in the repository's Packages index, the
#     index by the SHA-256 in InRelease, and InRelease by Proxmox's archive key
#     (download.proxmox.com is plain HTTP, so the hash alone would prove nothing).
# The URLs can be overridden for tests (scripts/test/test-image-hashes.sh).
PVE_ISO_SUMS_URL="${PVE_ISO_SUMS_URL:-https://enterprise.proxmox.com/iso/SHA256SUMS}"
PVE_REPO_BASE="${PVE_REPO_BASE:-http://download.proxmox.com/debian/pve}"
PVE_KEY_BASE="${PVE_KEY_BASE:-https://enterprise.proxmox.com/debian}"

# media_fetch <url> <out>
media_fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  else wget -q "$1" -O "$2"; fi
}

# media_sha256 <file>
media_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# iso_latest — the newest Proxmox VE ISO in Proxmox's checksum list, by name.
iso_latest() {
  local sums name
  sums="$(mktemp)"
  media_fetch "$PVE_ISO_SUMS_URL" "$sums" || { rm -f "$sums"; return 1; }
  name="$(awk '{n=$2; sub(/^\*/, "", n)} n ~ /^proxmox-ve_[0-9.]+-[0-9]+\.iso$/ {print n}' "$sums" | sort -V | tail -1)"
  rm -f "$sums"
  [[ -n "$name" ]] && echo "$name"
}

# iso_download <name> — from beside Proxmox's checksum list, a dot every 5 s on
# the [Info] line; the .part is renamed only when complete.
iso_download() {
  local name="$1" url pid rc=0
  url="${PVE_ISO_SUMS_URL%/*}/${name}"
  printf '%b' "${GN}[Info]${CL} downloading ${name} (about 1.5 GB) "
  media_fetch "$url" "${name}.part" & pid=$!
  while kill -0 "$pid" 2>/dev/null; do sleep 5; kill -0 "$pid" 2>/dev/null && printf '.'; done
  wait "$pid" || rc=$?
  echo ""
  [[ "$rc" == 0 ]] || { rm -f "${name}.part"; die "the download of ${url} failed"; }
  mv "${name}.part" "$name"
}

# iso_check <iso> [<expected hex>] — dies unless the ISO matches.
iso_check() {
  local iso="$1" want="${2:-}" name have sums
  name="$(basename "$iso")"
  if [[ -z "$want" ]]; then
    sums="$(mktemp)"
    media_fetch "$PVE_ISO_SUMS_URL" "$sums" \
      || { rm -f "$sums"; die "cannot fetch Proxmox's ISO checksums (${PVE_ISO_SUMS_URL}) — pass --iso-sha256 <hash from proxmox.com/downloads>."; }
    want="$(awk -v f="$name" '{n=$2; sub(/^\*/, "", n)} n == f {print $1; exit}' "$sums")"
    rm -f "$sums"
    [[ -n "$want" ]] || die "${name} is not listed in ${PVE_ISO_SUMS_URL} — use an ISO under its downloaded name, or pass --iso-sha256 <hash from proxmox.com/downloads>."
  fi
  want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"; want="${want#sha256:}"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "not a SHA-256 hash: ${want}"
  debug "checking ${name} against its published SHA-256"
  have="$(media_sha256 "$iso")"
  [[ "$have" == "$want" ]] || die "${name} does not match its published SHA-256 (expected ${want}, got ${have}) — download it again."
  info "  ${GN:-}✓${CL:-} ${name} matches its published SHA-256"
}

# paia_fetch <dir> — download the newest proxmox-auto-install-assistant .deb into
# <dir>/paia.deb through the signed chain above. Dies when any link fails.
paia_fetch() {
  local dir="$1" codename key comp="pve-no-subscription/binary-amd64/Packages" want line ver file
  command -v gpgv >/dev/null 2>&1 || die "gpgv is needed to check the Proxmox repository signature (apt install gpgv)."
  for codename in trixie bookworm; do
    case "$codename" in
      trixie)   key="proxmox-archive-keyring-trixie.gpg" ;;
      bookworm) key="proxmox-release-bookworm.gpg" ;;
    esac
    media_fetch "${PVE_KEY_BASE}/${key}" "${dir}/${codename}.gpg" 2>/dev/null || continue
    media_fetch "${PVE_REPO_BASE}/dists/${codename}/InRelease" "${dir}/InRelease" 2>/dev/null || continue
    gpgv --keyring "${dir}/${codename}.gpg" --output "${dir}/Release" "${dir}/InRelease" >/dev/null 2>&1 \
      || die "the Proxmox ${codename} InRelease does not verify against ${PVE_KEY_BASE}/${key}."
    want="$(awk -v f="$comp" '/^[A-Za-z0-9]+:/ {sec=$1} sec == "SHA256:" && $3 == f {print $1; exit}' "${dir}/Release")"
    [[ -n "$want" ]] || continue
    media_fetch "${PVE_REPO_BASE}/dists/${codename}/${comp}" "${dir}/Packages" 2>/dev/null || continue
    [[ "$(media_sha256 "${dir}/Packages")" == "$want" ]] \
      || die "the Proxmox ${codename} Packages index does not match its signed InRelease."
    # Pick the LATEST version's .deb — the Packages file lists every pooled
    # version, and grabbing the first Filename yields a STALE build (e.g.
    # 9.0.6, which wants the old underscore answer keys and rejects the
    # kebab-case answer this script writes; the current 9.2.x wants kebab).
    line="$(awk '
        /^Package: proxmox-auto-install-assistant$/ {inpkg=1; ver=""; fn=""; sha=""; next}
        /^Package: / {inpkg=0}
        inpkg && /^Version: /  {ver=$2}
        inpkg && /^Filename: / {fn=$2}
        inpkg && /^SHA256: /   {sha=$2}
        inpkg && /^$/ && fn != "" {print ver"\t"fn"\t"sha; inpkg=0}
        END {if (inpkg && fn != "") print ver"\t"fn"\t"sha}
      ' "${dir}/Packages" | sort -V | tail -1)"
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r ver file want <<<"$line"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "the Packages entry for proxmox-auto-install-assistant ${ver} has no SHA-256."
    media_fetch "${PVE_REPO_BASE}/${file}" "${dir}/paia.deb" || die "assistant .deb download failed."
    [[ "$(media_sha256 "${dir}/paia.deb")" == "$want" ]] \
      || { rm -f "${dir}/paia.deb"; die "the assistant .deb (${ver}) does not match the SHA-256 in the signed Packages index."; }
    info "  ${GN:-}✓${CL:-} proxmox-auto-install-assistant ${ver} (${codename}), signature checked"
    return 0
  done
  die "could not locate proxmox-auto-install-assistant in the Proxmox repo — install it manually."
}
# <<< media-checks

# What is typed reaches the terminal but not the log's tee; passwords stay out of it.
logged() { [[ -z "${LOG:-}" ]] || printf '%s\n' "$1" >>"$LOG"; }
prompt() {
  local v d="${2:-}"
  if [[ -n "$d" ]]; then read -r -p "${IN} $1 [$d]: " v; logged "$v"; printf '%s' "${v:-$d}"
  else read -r -p "${IN} $1: " v; logged "$v"; printf '%s' "$v"; fi
}

# >>> after-the-build
# Everything below runs on the operator's own machine, never in the build
# container: it needs the machine's USB ports and network. What differs by
# platform is kept to net_info, sticks_read, stick_write and pxe_stage; another
# platform is another case in each.
INSTALL_REPO="https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/"

# net_info [<interface>] — NET_IF, NET_IP, NET_PREFIX: default-route interface unless named.
net_info() {
  local cidr mask hex
  NET_IF="${1:-}" NET_IP="" NET_PREFIX=""
  case "$(uname -s)" in
    Darwin)
      [[ -n "$NET_IF" ]] || NET_IF="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
      NET_IP="$(ipconfig getifaddr "$NET_IF" 2>/dev/null || true)"
      hex="$(ifconfig "$NET_IF" 2>/dev/null | awk '/inet / {print $4; exit}')"
      mask=$(( ${hex:-0xffffff00} )); NET_PREFIX=0
      while (( mask & 0x80000000 )); do NET_PREFIX=$(( NET_PREFIX + 1 )); mask=$(( (mask << 1) & 0xffffffff )); done ;;
    *)
      [[ -n "$NET_IF" ]] || NET_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
      cidr="$(ip -4 -o addr show dev "$NET_IF" 2>/dev/null | awk '{print $4; exit}')"
      NET_IP="${cidr%/*}" NET_PREFIX="${cidr#*/}" ;;
  esac
  [[ -n "$NET_IP" ]] || die "no IPv4 address on interface '${NET_IF}'"
}

# The subnet's network address, for dnsmasq's proxy range.
net_address() {
  local a b c d n
  IFS=. read -r a b c d <<<"$NET_IP"
  n=$(( ((a << 24 | b << 16 | c << 8 | d) >> (32 - NET_PREFIX)) << (32 - NET_PREFIX) ))
  echo "$(( n >> 24 & 255 )).$(( n >> 16 & 255 )).$(( n >> 8 & 255 )).$(( n & 255 ))"
}

# sticks_read — one line per USB stick: device|bytes|description|note|refusal.
# The rule is node usb's (site-manager usb.ts): a whole disk on the USB bus, never
# one a pool, volume group, swap or array claims, nor the backup key stick. A
# laptop mounts what is plugged in, so mounted only gets said.
sticks_read() {
  local d inf bytes name note no
  case "$(uname -s)" in
    Darwin)
      local boot; boot="$(diskutil info / 2>/dev/null | awk -F': *' '/Part of Whole/ {print $2}')"
      for d in $(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk/ {print $1}'); do
        inf="$(diskutil info "$d")"
        grep -Eq 'Protocol: +USB' <<<"$inf" || continue
        [[ "$d" != "/dev/${boot}" ]] || continue
        bytes="$(sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p' <<<"$inf" | head -1)"
        name="$(sed -n 's/.*Device \/ Media Name: *//p' <<<"$inf" | head -1)"
        note="" no=""
        mount | grep -q "^${d}s" && note="mounted"
        diskutil list "$d" | grep -q 'TAPPAASKEYS' && no="the backup key stick"
        echo "${d}|${bytes:-0}|${name//|/ }|${note}|${no}"
      done ;;
    *)
      local line tree
      while IFS= read -r line; do
        field() { sed -n "s/.*\b$1=\"\([^\"]*\)\".*/\1/p" <<<"$line"; }
        [[ "$(field TYPE)" == disk && "$(field TRAN)" == usb ]] || continue
        d="$(field PATH)" bytes="$(field SIZE)" name="$(field VENDOR) $(field MODEL) $(field SERIAL)"
        note="" no=""
        tree="$(lsblk -nP -o MOUNTPOINT,FSTYPE,LABEL "$d" 2>/dev/null || true)"
        grep -q 'MOUNTPOINT="[^"]' <<<"$tree" && note="mounted"
        grep -Eq 'MOUNTPOINT="(/|/boot[^"]*|/usr|/var|/home)"' <<<"$tree" && no="this machine runs from it"
        grep -Eq 'FSTYPE="(zfs_member|LVM2_member|swap|linux_raid_member)"' <<<"$tree" && no="in use"
        grep -q 'LABEL="TAPPAASKEYS"' <<<"$tree" && no="the backup key stick"
        [[ "${bytes:-0}" != 0 ]] || no="ejected: unplug it and plug it in again"
        echo "${d}|${bytes:-0}|${name//|/ }|${note}|${no}"
      done < <(lsblk -dnbP -o PATH,SIZE,TRAN,TYPE,VENDOR,MODEL,SERIAL 2>/dev/null)
      ;;
  esac
}

# sudo_ask <what for> — says whose password this is: not the node's root password.
sudo_ask() {
  sudo -v -p "${IN} Your login password on THIS computer (sudo, not the node's root password), to $1: "
}

# stick_write <device> <iso> — erase, write, read back.
stick_write() {
  local d="$1" iso="$2" size p r
  size="$(wc -c <"$iso" | tr -d ' ')"
  sudo_ask "write the stick"
  case "$(uname -s)" in
    Darwin)
      # macOS mounts the image's HFS partition the moment it sees it, and that
      # rewrites the volume's header. So the partition tables go on last: the first
      # MiB is blanked, the rest written and read back, and only then the first
      # MiB, which holds no volume.
      r="${d/\/dev\/disk//dev/rdisk}"
      diskutil unmountDisk "$d" >/dev/null
      sudo dd if=/dev/zero of="$r" bs=1m count=1 2>/dev/null
      sudo dd if="$iso" of="$r" bs=1m skip=1 seek=1 status=progress
      sync
      info "reading it back..."
      sudo cmp -n "$(( size - 1048576 ))" "$iso" "$d" 1048576 1048576 || die "the stick does not match the image: try another stick."
      sudo dd if="$iso" of="$r" bs=1m count=1 2>/dev/null
      sync
      sudo cmp -n 1048576 "$iso" "$d" || die "the stick does not match the image: try another stick."
      info "  ${GN}✓${CL} the stick matches the image"
      diskutil eject "$d" >/dev/null 2>&1 || true
      return 0 ;;
    *)
      for p in $(lsblk -nlo MOUNTPOINT "$d" | grep -v '^$' || true); do sudo umount "$p"; done
      sudo dd if="$iso" of="$d" bs=4M status=progress conv=fsync ;;
  esac
  info "reading it back..."
  sudo cmp -n "$size" "$iso" "$d" || die "the stick does not match the image: try another stick."
  info "  ${GN}✓${CL} the stick matches the image"
  sudo eject "$d" 2>/dev/null || true
}

# The stick's size need: the built image when there is one, else the stock ISO
# and room for what the build adds.
stick_need() {
  if [[ -f "${OUT:-}" ]]; then wc -c <"$OUT" | tr -d ' '
  else echo $(( $(wc -c <"$ISO" | tr -d ' ') + 104857600 )); fi
}

# choose_stick — the stick to erase, chosen and confirmed up front: --stick (and
# --yes), or picked from the list here. Sets STICK.
choose_stick() {
  local size lines line d bytes name note no i pick
  size="$(stick_need)"
  if [[ -n "$STICK" ]]; then
    lines="$(sticks_read)"
    line="$(grep -F "${STICK}|" <<<"$lines" | head -1 || true)"
    [[ -n "$line" ]] || die "--stick ${STICK}: not a USB stick in this machine (plug it in, or leave --stick out to choose one)"
    IFS='|' read -r d bytes name note no <<<"$line"
    (( bytes >= size )) || no="${no:-too small for the image}"
    [[ -z "$no" ]] || die "--stick ${STICK}: ${no}"
    if [[ "$YES" != 1 ]]; then
      [[ -t 0 ]] || die "--stick ${STICK} is erased: say so with --yes"
      read -r -p "${IN} ERASE ${d} (${name}, $(( bytes / 1000000000 )) GB)? Type yes: " pick; logged "$pick"
      [[ "$pick" == yes ]] || die "the stick is not erased: stopped"
    fi
    return 0
  fi
  [[ -t 0 ]] || die "--boot usb without a terminal needs --stick <device> and --yes"
  while :; do
    lines="$(sticks_read)"
    if [[ -z "$lines" ]]; then
      read -r -p "${IN} No USB stick found. Plug one in and press Enter (q to stop): " pick; logged "$pick"
      [[ "$pick" != q ]] || return 1
      continue
    fi
    info "USB sticks in this machine:"
    i=0
    while IFS='|' read -r d bytes name note no; do
      i=$(( i + 1 ))
      (( bytes >= size )) || no="${no:-too small for the image}"
      info "  ${i}) ${d}  $(( bytes / 1000000000 )) GB  ${name}${note:+  (${note})}${no:+  — not offered: ${no}}"
    done <<<"$lines"
    read -r -p "${IN} Which stick is erased? [number, r to rescan, q to stop]: " pick; logged "$pick"
    [[ "$pick" != q ]] || return 1
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )) || continue
    IFS='|' read -r d bytes name note no <<<"$(sed -n "${pick}p" <<<"$lines")"
    (( bytes >= size )) || no="${no:-too small for the image}"
    if [[ -n "$no" ]]; then warn "${d}: ${no}"; continue; fi
    if [[ "$YES" != 1 ]]; then
      read -r -p "${IN} ERASE ${d} (${name}, $(( bytes / 1000000000 )) GB)? Type yes: " pick; logged "$pick"
      [[ "$pick" == yes ]] || continue
    fi
    STICK="$d"
    return 0
  done
}

write_usb() {
  stick_write "$STICK" "$1"
  action "The stick is ready. Boot the target from it, with only the NIC to your upstream router connected."
}

# Runs in the container, or here when this machine has the tools: the installer's
# kernel, and its initrd with the whole ISO appended.
PXE_STAGE='set -e; iso="$1"
  xorriso -osirrox on -indev "$iso" -extract /boot/linux26 pxe/linux26 -extract /boot/initrd.img pxe/initrd >/dev/null 2>&1
  chmod u+w pxe/initrd
  cp "$iso" pxe/proxmox.iso
  sz=$(stat -c %s pxe/initrd); pad=$(( (4 - sz % 4) % 4 ))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero >> pxe/initrd
  ( cd pxe && echo proxmox.iso | cpio -L -H newc -o --quiet >> initrd )
  rm -f pxe/proxmox.iso; chmod 644 pxe/*'

# Staging needs Docker on a Mac (or xorriso and cpio elsewhere): asked before the
# install's questions, so a stopped Docker is found at once, not after them.
pxe_tools_ready() {
  if command -v xorriso >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1 && [[ "$(uname -s)" != Darwin ]]; then return 0; fi
  command -v docker >/dev/null 2>&1 || die "network boot needs Docker here (Docker Desktop, or colima): install it and run this again."
  docker_running || die "Docker is not running and did not start: start it (Docker Desktop, or: colima start) and run this again."
}

# Docker answering, started when it is not: Colima if that is what this machine
# has, else Docker Desktop. A restart of the machine stops both.
docker_running() {
  docker info >/dev/null 2>&1 && return 0
  if command -v colima >/dev/null 2>&1; then
    info "Docker is not running: starting it (colima start), about a minute"
    colima start >/dev/null 2>&1 || true
  elif [[ "$(uname -s)" == Darwin && -d /Applications/Docker.app ]]; then
    info "Docker is not running: starting Docker Desktop"
    open -a Docker >/dev/null 2>&1 || true
  else
    return 1
  fi
  local i
  for i in $(seq 1 60); do docker info >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

pxe_stage() {
  local iso="$1"
  [[ ! -e pxe ]] || die "./pxe exists: move it away, this step makes and removes its own."
  mkdir -p pxe; chmod 700 pxe
  PXE_STAGED=1
  info "Staging the netboot files, this can take up to 5 min. Do not PXE boot the machine yet"
  if command -v xorriso >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1 && [[ "$(uname -s)" != Darwin ]]; then
    bash -c "$PXE_STAGE" stage "$iso"
  else
    command -v docker >/dev/null 2>&1 || die "staging needs xorriso and cpio, or Docker."
    docker run --rm --init -e DEBIAN_FRONTEND=noninteractive -v "$PWD:/work" -w /work debian:trixie bash -c "
      apt-get update -qq >/dev/null && apt-get install -y -qq xorriso cpio >/dev/null 2>&1
      $PXE_STAGE" stage "$iso"
  fi
}

PXE_RUN="" PXE_STAGED="" SCAN_PID=""
pxe_stop_dns() {
  [[ -n "$PXE_RUN" && -f "${PXE_RUN}/dnsmasq.pid" ]] || return 0
  local i
  : >"${PXE_RUN}/stop"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "${PXE_RUN}/dnsmasq.pid" ]] || return 0
    sleep 0.5
  done
}
PXE_HTTP=""
pxe_stop() {
  pxe_stop_dns
  [[ -z "$PXE_HTTP" ]] || kill "$PXE_HTTP" 2>/dev/null || true
  PXE_HTTP=""
  [[ -z "$PXE_RUN" ]] || rm -rf "$PXE_RUN"
  PXE_RUN=""
  # The initrd carries the root password.
  [[ -z "$PXE_STAGED" ]] || rm -rf pxe
  [[ -z "$PXE_STAGED" ]] || rm -f pxe-http.log
  PXE_STAGED=""
}

# dnsmasq in proxy-DHCP + TFTP mode: it hands out no leases, the router keeps
# doing that. The TFTP root holds only iPXE and its script, no secret, so
# dnsmasq can drop to its unprivileged user. The kernel and initrd go over HTTP.
pxe_serve() {
  local iso="$1" dns pick
  dns="$(PATH="/opt/homebrew/sbin:/usr/local/sbin:/usr/sbin:${PATH}" command -v dnsmasq || true)"
  [[ -n "$dns" ]] || die "dnsmasq is needed for the network boot (brew install dnsmasq, or apt install dnsmasq)."
  command -v python3 >/dev/null 2>&1 || die "python3 is needed for the network boot."
  net_info "$PXE_IFACE"   # chosen up front (ask_up_front)
  info "serving on ${NET_IF} (${NET_IP}/${NET_PREFIX})"
  pxe_stage "$iso"
  PXE_RUN="/tmp/tappaas-pxe.$$"
  mkdir -p "$PXE_RUN"; chmod 755 "$PXE_RUN"
  curl -fsSL https://boot.ipxe.org/x86_64-efi/ipxe.efi -o "${PXE_RUN}/ipxe.efi" || die "cannot fetch iPXE from boot.ipxe.org"
  cat >"${PXE_RUN}/boot.ipxe" <<EOF
#!ipxe
echo TAPPaaS: booting the Proxmox VE auto-installer
kernel http://${NET_IP}:8080/linux26 ro ramdisk_size=16777216 rw splash=silent proxmox-start-auto-installer
initrd http://${NET_IP}:8080/initrd
boot
EOF
  cp "${PXE_RUN}/boot.ipxe" "${PXE_RUN}/autoexec.ipxe"
  cat >"${PXE_RUN}/dnsmasq.conf" <<EOF
port=0
interface=${NET_IF}
bind-interfaces
dhcp-range=$(net_address),proxy
enable-tftp
tftp-root=${PXE_RUN}
pid-file=${PXE_RUN}/dnsmasq.pid
log-facility=${PXE_RUN}/dnsmasq.log
dhcp-userclass=set:ipxe,iPXE
pxe-service=tag:!ipxe,x86-64_EFI,"TAPPaaS: iPXE",ipxe.efi
pxe-service=tag:!ipxe,BC_EFI,"TAPPaaS: iPXE",ipxe.efi
pxe-service=tag:ipxe,x86-64_EFI,"TAPPaaS: installer",boot.ipxe
pxe-service=tag:ipxe,BC_EFI,"TAPPaaS: installer",boot.ipxe
EOF
  ( cd pxe && exec python3 -u -m http.server 8080 --bind "$NET_IP" ) >"pxe-http.log" 2>&1 &
  PXE_HTTP=$!
  info "starting the network boot service..."
  sudo_ask "start it"
  # The wait for the node outlasts sudo's few minutes, so a root helper ends dnsmasq:
  # asked to by the stop file, or when this script is gone. No second password.
  sudo sh -c '"$1" --conf-file="$2/dnsmasq.conf" || exit 1
    ( while [ ! -e "$2/stop" ] && kill -0 "$3" 2>/dev/null; do sleep 1; done
      kill "$(cat "$2/dnsmasq.pid")"; rm -f "$2/dnsmasq.pid" ) </dev/null >/dev/null 2>&1 &' \
    sh "$dns" "$PXE_RUN" "$$" || die "dnsmasq did not start: see ${PXE_RUN}/dnsmasq.log"
  [[ "$(uname -s)" != Darwin ]] || info "  macOS firewall: allow dnsmasq and python3 when it asks, or the target gets no answer."
  warn "Until the target has fetched it, anyone on this network can fetch the installer, and the root password in it."
  action "Network boot is on. Pick Network / PXE (IPv4) in the target's one-time UEFI boot menu."
}

# ssh into the node with the key built into the image. Nothing else can log in
# with it, so the key is what identifies the node; no password is sent.
node_ssh() {
  ssh -i "$INSTALL_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=4 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
}

# The addresses with ssh open in this machine's subnet, up to a /20: its 16 blocks
# take 3 seconds each. Plain bash, so it needs no scanner on any platform. A node
# outside that range is named with --node.
scan_ssh() {
  local NET_PREFIX="$NET_PREFIX" a b c d k i blocks=1
  (( NET_PREFIX >= 20 )) || NET_PREFIX=20
  (( NET_PREFIX >= 24 )) || blocks=$(( 1 << (24 - NET_PREFIX) ))
  IFS=. read -r a b c d <<<"$(net_address)"
  for (( k = 0; k < blocks; k++ )); do
    (
      for i in {1..254}; do
        ( exec 3<>"/dev/tcp/${a}.${b}.$(( c + k )).${i}/22" && echo "${a}.${b}.$(( c + k )).${i}" ) 2>/dev/null &
      done
      sleep 3
      kill $(jobs -p) 2>/dev/null || true
    ) 2>/dev/null
  done
}

wait_for_node() {
  local ip ips found
  found="$(mktemp)"
  info "waiting for the installed node to come up on this network: this takes 10-15 minutes. Ctrl-C to stop."
  while :; do
    if [[ -n "$PXE_RUN" ]] && grep -q 'GET /initrd' pxe-http.log 2>/dev/null; then
      # Past this the target needs only the transfer running; left on, its next
      # boot could install it again.
      pxe_stop_dns
    fi
    if [[ -n "$NODE_IP" ]]; then
      ips="$NODE_IP"
    else
      # In the background: wait gives way to Ctrl-C at once, a $( ) would not.
      scan_ssh >"$found" &
      SCAN_PID=$!
      wait "$SCAN_PID" || true
      SCAN_PID=""
      ips="$(cat "$found")"
    fi
    for ip in $ips; do
      if node_ssh -n "root@${ip}" 'command -v pveversion' >/dev/null 2>&1; then
        NODE_IP="$ip"
        rm -f "$found"
        return 0
      fi
    done
    sleep 15
  done
}

# The install runs detached in tmux on the node, unattended like a node add, and its
# log is followed here: it scrolls on in this terminal, and a lost ssh session only
# stops the following.
start_install() {
  local cmd seen state run="./install.sh '${INSTALL_REPO}' '${BRANCH}' --name '${SITE_CODE}'${ORG:+ --organization '${ORG}'}${DOMAIN:+ --domain '${DOMAIN}'}${SIZE:+ --size '${SIZE}'}${HOSTED_ARGS} --non-interactive --no-tmux"
  # apt update fails on the enterprise repository the install has not replaced yet;
  # Debian's own still serves tmux.
  cmd="export LC_ALL=C.UTF-8; command -v tmux >/dev/null || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq tmux >/dev/null 2>&1; }; tmux has-session -t tappaas-install 2>/dev/null && exit 0; curl -fsSL '${INSTALL_REPO}${BRANCH}/src/foundation/install.sh' -o install.sh && chmod +x install.sh || exit 1; rm -f tappaas-install.rc; : > tappaas-install.log; tmux new-session -d -s tappaas-install \"{ ${run} 2>&1; echo \\\$? > tappaas-install.rc.tmp; } | tee -a tappaas-install.log; mv tappaas-install.rc.tmp tappaas-install.rc\""
  info "starting the TAPPaaS install on ${NODE_IP}"
  # A sleeping laptop would drop the session.
  if command -v caffeinate >/dev/null 2>&1; then caffeinate -i -w $$ & fi
  node_ssh -n "root@${NODE_IP}" "$cmd" || die "could not start the install on ${NODE_IP}: see above, and ${LOG:-the output}."
  info "Ctrl-C stops the watching here, not the install. On the node: tail -f tappaas-install.log"
  seen="$(mktemp)"; EXIT_SEEN="$seen"
  while :; do
    node_ssh -n -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "root@${NODE_IP}" "tail -c +$(( $(wc -c <"$seen") + 1 )) -f tappaas-install.log & t=\$!; while tmux has-session -t tappaas-install 2>/dev/null; do sleep 2; done; sleep 1; kill \$t" 2>/dev/null | tee -a "$seen" || true
    state="$(node_ssh -n "root@${NODE_IP}" 'if [ -f tappaas-install.rc ]; then cat tappaas-install.rc; elif tmux has-session -t tappaas-install 2>/dev/null; then echo running; else echo gone; fi' 2>/dev/null || echo lost)"
    case "$state" in
      running|lost) sleep 5 ;;
      *) break ;;
    esac
  done
  rm -f "$seen"
  [[ "$state" == 0 ]] || die "the install stopped on ${NODE_IP}: see above, and ${LOG:-the output}."
  show_token
}

# The console's setup token, on request: read from the mothership through the
# node with the install key, and written to the terminal only, never to the log
# (a secret in a log is a secret for every reader of it, ADR-034 D10).
show_token() {
  local yn tok key
  key="$(cd "$(dirname "$INSTALL_KEY")" && pwd)/$(basename "$INSTALL_KEY")"
  [[ -t 0 && -w /dev/tty ]] || { info "the setup token, from this machine: ssh -i ${key} root@${NODE_IP} 'ssh -i /root/tappaas/tappaas-cicd.key tappaas@tappaas-cicd.mgmt.internal cat config/console-setup-token'"; return 0; }
  # Asked up front (ask_up_front, or --show-token).
  if [[ "${SHOW_TOKEN:-0}" == 1 ]]; then
    tok="$(node_ssh -n "root@${NODE_IP}" 'ssh -i /root/tappaas/tappaas-cicd.key -o StrictHostKeyChecking=accept-new -o BatchMode=yes tappaas@tappaas-cicd.mgmt.internal cat config/console-setup-token' 2>/dev/null || true)"
    if [[ -n "$tok" ]]; then printf '  Setup token: %s\n' "$tok" >/dev/tty
    else warn "the setup token could not be read: the console may have closed setup already"; fi
  fi
  info "To show it again later, from this machine:"
  info "  ssh -i ${key} root@${NODE_IP} 'ssh -i /root/tappaas/tappaas-cicd.key tappaas@tappaas-cicd.mgmt.internal cat config/console-setup-token'"
}

# ── A rented server (choice 6): through its rescue system ─────────────
# The server boots Hetzner's rescue system (a RAM Linux, reached with the
# operator's own SSH key). The install image is built there, the Proxmox installer
# runs there in QEMU on the server's own disks with the server's MAC, then the
# server reboots into Proxmox and the TAPPaaS install runs as on any first node,
# with the firewall's WAN on its own address and MAC.

rescue_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=15 "root@${RESCUE_IP}" "$@"
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# The key that let this computer into the rescue system: also the operator's way
# into the installed node.
operator_pubkey() {
  local k
  k="$(ssh-add -L 2>/dev/null | grep -E '^(ssh-|ecdsa-)' | head -1 || true)"
  [[ -n "$k" ]] || for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do [[ -f "$f" ]] && { k="$(<"$f")"; break; }; done
  printf '%s' "$k"
}

rescue_ask() {
  local tty=0 h
  [[ -t 0 ]] && tty=1
  command -v wg >/dev/null 2>&1 \
    || die "wg is needed to make your WireGuard key on this computer: brew install wireguard-tools (or apt install wireguard-tools)"
  if [[ "$tty" == 1 ]]; then
    [[ -n "$RESCUE_IP" ]] || RESCUE_IP="$(prompt "The server's main IPv4 address")"
    [[ -n "$WAN_ADDR" ]] || WAN_ADDR="$(prompt "The firewall's additional IPv4 address")"
    [[ -n "$WAN_MAC" ]] || WAN_MAC="$(prompt "Its virtual MAC, as Robot shows it")"
  fi
  is_ipv4 "$RESCUE_IP" || die "the server's address is an IPv4 address (--rescue): ${RESCUE_IP:-none}"
  is_ipv4 "$WAN_ADDR" || die "the firewall's address is an IPv4 address (--wan-address): ${WAN_ADDR:-none}"
  [[ "$WAN_ADDR" != "$RESCUE_IP" ]] || die "the firewall needs an address of its own, not the server's"
  [[ -z "$WAN_GW" ]] || is_ipv4 "$WAN_GW" || die "--wan-gateway is an IPv4 address: ${WAN_GW}"
  WAN_MAC="$(printf '%s' "$WAN_MAC" | tr 'A-F-' 'a-f:')"
  [[ "$WAN_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "not a MAC address (--wan-mac): ${WAN_MAC:-none}"
  # Proxmox installed already by this script (its key logs in): the install goes
  # on from there, as after a stop half-way (an outage of the repository's host).
  if [[ -f "$INSTALL_KEY" ]] && node_ssh -n "root@${RESCUE_IP}" 'command -v pveversion' >/dev/null 2>&1; then
    HOSTED_RESUME=1
    info "${RESCUE_IP} runs the Proxmox this script installed: the TAPPaaS install goes on from there"
    return 0
  fi
  info "checking the rescue system on ${RESCUE_IP}"
  h="$(rescue_ssh -n 'hostname; test -e /root/.oldroot -o -e /etc/hetzner-build && echo rescue' 2>/dev/null || true)"
  [[ -n "$h" ]] || die "no ssh to root@${RESCUE_IP} with your key: activate the rescue system in Robot with your key, reset the server, and run this again"
  [[ "$h" == *rescue* ]] || die "${RESCUE_IP} answers, but not as Hetzner's rescue system (${h%%$'\n'*}): activate rescue in Robot and reset the server; its disks are wiped by this install"
}

# remote_dots <what> <command…> — a remote step on one [Info] line, a dot for each
# line it prints; its last lines are shown when it fails.
remote_dots() {
  local what="$1" out rc=0
  shift
  out="$(mktemp)"
  printf '%b' "${GN}[Info]${CL} ${what} "
  "$@" 2>&1 | while IFS= read -r l; do printf '%s\n' "$l" >>"$out"; printf '.'; done
  rc=${PIPESTATUS[0]}
  echo ""
  if [[ "$rc" != 0 ]]; then tail -20 "$out" >&2; rm -f "$out"; return "$rc"; fi
  rm -f "$out"
}

# The QEMU run on the rescue system: the server's disks (with their serials, so the
# boot disk is chosen as on the machine itself), the server's MAC, UEFI when the
# server boots UEFI. Detached, so a lost session does not stop it.
RESCUE_QEMU='set -eu
mac="$1"; cd /root/tappaas
mdadm --stop --scan >/dev/null 2>&1 || true
swapoff -a 2>/dev/null || true
args=(); i=0
for d in $(lsblk -dn -o NAME,TYPE | awk '\''$2=="disk"{print $1}'\''); do
  case "$d" in loop*|ram*|zram*|sr*|fd*) continue ;; esac
  [ "$(lsblk -dn -o TRAN "/dev/$d" | tr -d " ")" = usb ] && continue
  # A disk the rescue system itself uses (mounted, or swap) is never handed over.
  lsblk -nro MOUNTPOINT "/dev/$d" | grep -q . && { echo "skipped $d (in use here)"; continue; }
  ser="$(lsblk -dn -o SERIAL "/dev/$d" | tr -cd "A-Za-z0-9._-" | cut -c1-20)"
  [ -n "$ser" ] || ser="disk$i"
  args+=(-drive "file=/dev/$d,if=none,id=d$i,format=raw,cache=none,aio=native")
  case "$d" in
    nvme*) args+=(-device "nvme,drive=d$i,serial=$ser") ;;
    *) rr=1; [ "$(cat /sys/block/$d/queue/rotational)" = 1 ] && rr=7200
       args+=(-device "scsi-hd,bus=scsi0.0,drive=d$i,serial=$ser,rotation_rate=$rr") ;;
  esac
  echo "disk $d ($ser)"
  i=$((i+1))
done
[ "$i" -gt 0 ] || { echo "no disks found" >&2; exit 1; }
fw=()
if [ -d /sys/firmware/efi ]; then
  code=/usr/share/OVMF/OVMF_CODE_4M.fd; vars=/usr/share/OVMF/OVMF_VARS_4M.fd
  [ -f "$code" ] || { code=/usr/share/OVMF/OVMF_CODE.fd; vars=/usr/share/OVMF/OVMF_VARS.fd; }
  cp "$vars" ovmf-vars.fd
  fw=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=ovmf-vars.fd")
  echo "firmware UEFI"
else
  echo "firmware legacy BIOS"
fi
rm -f install-serial.log qemu.rc
nohup bash -c "qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 $(printf "%q " "${fw[@]}") \
  -device virtio-scsi-pci,id=scsi0 $(printf "%q " "${args[@]}") \
  -drive file=tappaas-auto.iso,media=cdrom,if=none,id=cd -device ide-cd,drive=cd,bootindex=0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=$mac \
  -no-reboot -display none -serial file:install-serial.log; echo \$? > qemu.rc" >qemu.out 2>&1 &
echo started'

# After the installer: the boot disks carry their system, and on UEFI each EFI
# system partition gets the fallback loader, since the installer wrote its boot
# entry into QEMU's firmware, not the server's.
RESCUE_CHECK='set -u
lsblk -ln -o FSTYPE,LABEL | awk '\''($1=="zfs_member" && $2=="rpool") || $1=="LVM2_member" {f=1} END {exit !f}'\'' \
  || { echo "no installed system on the disks"; exit 1; }
if [ -d /sys/firmware/efi ]; then
  mkdir -p /mnt/esp
  for p in $(lsblk -ln -o NAME,PARTTYPE | awk '\''tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1}'\''); do
    mount "/dev/$p" /mnt/esp 2>/dev/null || continue
    if [ ! -f /mnt/esp/EFI/BOOT/BOOTX64.EFI ]; then
      mkdir -p /mnt/esp/EFI/BOOT
      if [ -f /mnt/esp/EFI/systemd/systemd-bootx64.efi ]; then cp /mnt/esp/EFI/systemd/systemd-bootx64.efi /mnt/esp/EFI/BOOT/BOOTX64.EFI
      elif [ -f /mnt/esp/EFI/proxmox/shimx64.efi ]; then cp /mnt/esp/EFI/proxmox/shimx64.efi /mnt/esp/EFI/BOOT/BOOTX64.EFI; cp /mnt/esp/EFI/proxmox/grubx64.efi /mnt/esp/EFI/BOOT/ 2>/dev/null || true
      elif [ -f /mnt/esp/EFI/proxmox/grubx64.efi ]; then cp /mnt/esp/EFI/proxmox/grubx64.efi /mnt/esp/EFI/BOOT/BOOTX64.EFI
      fi
      echo "fallback loader on $p"
    fi
    umount /mnt/esp
  done
fi
echo installed'

# The build on the rescue system: the install assistant needs Debian 13's libc, so
# an older rescue system builds in a Debian 13 chroot made with debootstrap.
RESCUE_BUILD='set -e
cd /root/tappaas
major="$(cut -d. -f1 /etc/debian_version 2>/dev/null || true)"
case "$major" in ""|*[!0-9]*) major=0 ;; esac
rm -f tappaas-auto.iso
if [ "$major" -ge 13 ]; then
  TAPPAAS_MEDIA_CONTAINER=1 TAPPAAS_RESCUE_BUILD=1 ./bootstrap-tappaas.sh "$@"
  exit
fi
root=/root/tappaas/trixie
if [ ! -x "$root/usr/bin/xorriso" ]; then
  echo "[Info] Debian ${major} here: the build runs in a Debian 13 chroot"
  debootstrap --variant=minbase --include=wget,ca-certificates,zstd,cpio,xorriso,gpgv,curl,openssl     trixie "$root" http://deb.debian.org/debian >debootstrap.log 2>&1 || { tail -20 debootstrap.log; exit 1; }
fi
cp /etc/resolv.conf "$root/etc/resolv.conf"
for m in proc sys dev; do mountpoint -q "$root/$m" || mount --bind "/$m" "$root/$m"; done
mkdir -p "$root/work" && cp bootstrap-tappaas.sh "$root/work/"
rm -f "$root/work/tappaas-auto.iso"
chroot "$root" /bin/bash -c "cd /work && TAPPAAS_MEDIA_CONTAINER=1 TAPPAAS_RESCUE_BUILD=1 ./bootstrap-tappaas.sh \"\$@\"" _ "$@"
mv "$root/work/tappaas-auto.iso" tappaas-auto.iso'

hosted_install() {
  local net dev cidr gw dns mac uefi opkey cmd lines=0 state rc t t0 out l
  WG_PRIV="$(wg genkey)"
  WG_PUB="$(printf '%s' "$WG_PRIV" | wg pubkey)"
  info "your WireGuard key is made on this computer; its private half stays here"
  if [[ "$HOSTED_RESUME" == 1 ]]; then
    # The provider's gateway, as the node's network has it (before or after the cutover).
    [[ -n "$WAN_GW" ]] || WAN_GW="$(node_ssh -n "root@${RESCUE_IP}" 'ip -4 route show table 200 default 2>/dev/null | awk "{print \$3; exit}"; awk "/^iface (wan|vmbr0)/{f=1} f&&/gateway/{print \$2; exit}" /etc/network/interfaces' 2>/dev/null | head -1)"
    [[ -n "$WAN_GW" ]] || die "the provider's gateway could not be read from ${RESCUE_IP}: give --wan-gateway"
    hosted_tappaas
    return
  fi

  # The server's network, as its rescue system runs on it.
  net="$(rescue_ssh -n 'dev="$(ip -4 route show default | awk "{print \$5; exit}")"; echo "$dev"; ip -4 -o addr show dev "$dev" scope global | awk "{print \$4; exit}"; ip -4 route show default | awk "{print \$3; exit}"; cat "/sys/class/net/$dev/address"; awk "/^nameserver/ && \$2 !~ /:/ {print \$2; exit}" /etc/resolv.conf; [ -d /sys/firmware/efi ] && echo uefi || echo bios')" \
    || die "could not read the server's network from its rescue system"
  { read -r dev; read -r cidr; read -r gw; read -r mac; read -r dns; read -r uefi; } <<<"$net"
  [[ -n "$cidr" && -n "$gw" && -n "$mac" ]] || die "the rescue system's network is incomplete: ${net//$'\n'/ }"
  [[ "${cidr%/*}" == "$RESCUE_IP" ]] || warn "the rescue system's address is ${cidr%/*}, not ${RESCUE_IP}: the node gets ${cidr}"
  [[ -n "$dns" ]] || dns=185.12.64.1
  [[ -n "$WAN_GW" ]] || WAN_GW="$gw"
  info "the server: ${cidr} via ${gw} on ${dev} (${mac}), DNS ${dns}, ${uefi}; the firewall: ${WAN_ADDR} via ${WAN_GW} (${WAN_MAC})"

  remote_dots "preparing the rescue system (QEMU, the build tools)" rescue_ssh -n \
    'mkdir -p /root/tappaas && export DEBIAN_FRONTEND=noninteractive && find /var/lib/apt/lists -maxdepth 1 -type f ! -name lock -delete && apt-get update && apt-get install -y qemu-system-x86 ovmf xorriso cpio zstd wget gpgv curl ca-certificates debootstrap' \
    || die "the rescue system could not install QEMU and the build tools"
  rescue_ssh 'cat > /root/tappaas/bootstrap-tappaas.sh && chmod 755 /root/tappaas/bootstrap-tappaas.sh' <"$0" \
    && rescue_ssh 'cat > /root/tappaas/rescue-build.sh' <<<"$RESCUE_BUILD" \
    || die "could not copy this script to the rescue system"

  # The build: the stock ISO fetched there, the answer with the server's static
  # network, the install key and the operator's own key for root.
  opkey="$(operator_pubkey)"
  cmd="bash /root/tappaas/rescue-build.sh --out tappaas-auto.iso"
  cmd+=" --email $(printf %q "$EMAIL") --country $(printf %q "$COUNTRY") --keyboard $(printf %q "$KEYBOARD") --timezone $(printf %q "$TIMEZONE") --fqdn $(printf %q "$FQDN")"
  cmd+=" --password-file /dev/stdin --ssh-key $(printf %q "$(<"${INSTALL_KEY}.pub")")"
  [[ -z "$opkey" ]] || cmd+=" --ssh-key $(printf %q "$opkey")"
  if [[ ${#DISKS[@]} -gt 0 ]]; then for _d in "${DISKS[@]}"; do cmd+=" --disk $(printf %q "$_d")"; done; fi
  cmd+=" --net-cidr ${cidr} --net-gateway ${gw} --net-dns ${dns} --net-mac ${mac} --serial-console"
  info "building the install image on the rescue system"
  printf '%s' "$PASSWORD" | rescue_ssh "$cmd" || die "the build on the rescue system failed: see above"

  # The installer, in QEMU on the server's own disks.
  out="$(rescue_ssh "bash -s -- ${mac}" <<<"$RESCUE_QEMU" 2>&1)" || { echo "$out" >&2; die "QEMU could not be started on the rescue system"; }
  while IFS= read -r l; do [[ "$l" == started ]] || info "  ${l}"; done <<<"$out"
  printf '%b' "${GN}[Info]${CL} installing Proxmox on the server's disks (the installer in QEMU, about 10 minutes) "
  t0=$SECONDS
  while :; do
    state="$(rescue_ssh -n "cd /root/tappaas; wc -l < install-serial.log 2>/dev/null || echo 0; cat qemu.rc 2>/dev/null || echo running")" || state=""
    if [[ -n "$state" ]]; then
      { read -r t; read -r rc; } <<<"$state"
      while (( lines < ${t:-0} )); do printf '.'; lines=$(( lines + 1 )); done
      [[ "$rc" == running ]] || break
    fi
    if (( SECONDS - t0 > 3600 )); then
      echo ""
      rescue_ssh -n 'pkill -f qemu-system-x86_64' || true
      die "the installer did not finish within an hour: its console is in /root/tappaas/install-serial.log on the rescue system"
    fi
    sleep 10
  done
  echo ""
  out=""
  [[ "$rc" != 0 ]] || out="$(rescue_ssh -n "$RESCUE_CHECK" 2>&1)" || rc=check
  [[ -z "$out" ]] || while IFS= read -r l; do info "  ${l}"; done <<<"$out"
  if [[ "$rc" != 0 ]]; then
    rescue_ssh -n 'tail -25 /root/tappaas/install-serial.log; cat /root/tappaas/qemu.out' 2>/dev/null >&2 || true
    die "the Proxmox install in QEMU did not complete: see above, and /root/tappaas/install-serial.log on the rescue system"
  fi
  info "${GN}✓${CL} Proxmox is installed; the server reboots into it"
  rescue_ssh -n 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' || true
  sleep 30

  hosted_tappaas
}

# The TAPPaaS install on the rented server, then the operator's VPN peer.
hosted_tappaas() {
  local peer conf cicd_ip
  # From here as for any first node, with the firewall's own WAN.
  NODE_IP="$RESCUE_IP"
  HOSTED_ARGS=" --wan-address ${WAN_ADDR} --wan-gateway ${WAN_GW} --wan-mac ${WAN_MAC}"
  wait_for_node
  start_install

  # The operator's VPN peer, enrolled with the key made here.
  peer="$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-\n' '-' | cut -c1-24)"
  peer="${peer:-operator}-admin"
  conf="${SITE_CODE}.conf"
  if ! node_ssh -n "root@${NODE_IP}" "ssh -i /root/tappaas/tappaas-cicd.key -o StrictHostKeyChecking=accept-new -o BatchMode=yes tappaas@tappaas-cicd.mgmt.internal /home/tappaas/bin/network-manager wgvpn add-peer --name $(printf %q "$peer") --pubkey $(printf %q "$WG_PUB") --endpoint ${WAN_ADDR}:51821" >"${conf}.tmp" 2>/dev/null \
     || ! grep -q '^\[Interface\]' "${conf}.tmp"; then
    rm -f "${conf}.tmp"
    warn "your WireGuard key could not be enrolled: enrol this computer on the console's Day 1 page (The admin VPN), through the ssh tunnel above"
    return 0
  fi
  ( umask 077; WG_PRIV="$WG_PRIV" awk '/^PrivateKey[[:space:]]*=/ {print "PrivateKey = " ENVIRON["WG_PRIV"]; next} {print}' "${conf}.tmp" >"$conf" )
  rm -f "${conf}.tmp"
  cicd_ip="$(node_ssh -n "root@${NODE_IP}" 'getent hosts tappaas-cicd.mgmt.internal' 2>/dev/null | awk '{print $1; exit}')"
  info "${GN}✓${CL} this computer is enrolled in the site's admin VPN as ${peer}"
  action "Import ${conf} into the WireGuard app and turn it on, then open http://${cicd_ip:-<tappaas-cicd>}:9097/setup/day1"
  warn "${conf} holds your WireGuard private key: keep it on this computer only"
  warn "${INSTALL_KEY} logs in to the node as root: keep it safe, or delete it and the node's line for it in /root/.ssh/authorized_keys."
}

# ask_up_front — everything after the build, asked before it: how the target
# boots the image (and the stick, or the interface), whether to start the TAPPaaS
# install and its names, whether to show the setup token at the end, and this
# computer's password for sudo, kept alive until the script ends. What the options
# gave is not asked; without a terminal a missing mandatory value stops the script.
ask_up_front() {
  local c yn tty=0
  [[ -t 0 ]] && tty=1
  [[ -n "$BOOT" ]] || BOOT=none
  case "$BOOT" in usb|network|booted|none|rescue) ;; *) die "--boot is usb, network, booted or none" ;; esac
  [[ "$BOOT" != none ]] || return 0

  case "$BOOT" in
    rescue) rescue_ask; INSTALL_ANSWER=yes ;;
    usb) choose_stick || { BOOT=none; return 0; } ;;
    network)
      pxe_tools_ready
      PATH="/opt/homebrew/sbin:/usr/local/sbin:/usr/sbin:${PATH}" command -v dnsmasq >/dev/null 2>&1 \
        || die "dnsmasq is needed for the network boot (brew install dnsmasq, or apt install dnsmasq)."
      command -v python3 >/dev/null 2>&1 || die "python3 is needed for the network boot."
      net_info "$PXE_IFACE"
      if [[ -z "$PXE_IFACE" && "$tty" == 1 ]]; then
        read -r -p "${IN} Interface on this machine that is wired to the target's network [${NET_IF}]: " c; logged "$c"
        [[ -z "$c" ]] || net_info "$c"
      fi
      PXE_IFACE="$NET_IF" ;;
  esac

  # The TAPPaaS install, and its three names.
  if [[ -n "$USE" && ! -f "$INSTALL_KEY" ]]; then
    warn "no ${INSTALL_KEY} beside the image, so this script cannot log in to the node: build the image again, or run the install from the node's console."
    INSTALL_ANSWER=no
  fi
  if [[ -z "$INSTALL_ANSWER" ]]; then
    if [[ "$tty" == 1 ]]; then
      read -r -p "${IN} Start the TAPPaaS install over ssh when the node is up? [Y/n]: " yn; logged "$yn"
      [[ "$yn" == [nN]* ]] && INSTALL_ANSWER=no || INSTALL_ANSWER=yes
    else
      INSTALL_ANSWER=no
    fi
  fi
  if [[ "$INSTALL_ANSWER" == yes ]]; then
    WANT_INSTALL=1
    if [[ "$tty" == 1 ]]; then
      [[ -n "$BRANCH"    ]] || BRANCH="$(prompt 'Branch (stable, or main for the newest work)' stable)"
      [[ -n "$SITE_CODE" ]] || SITE_CODE="$(prompt 'The TAPPaaS Site name (lowercase, at most 15 characters)')"
      [[ -n "$ORG"       ]] || ORG="$(prompt 'Name of Organisation controlling the Site' "$SITE_CODE")"
      # Blank: <site>.home.arpa, the site's own names with no public DNS; going
      # public later is Day 1's "Make it public".
      [[ -n "$DOMAIN"    ]] || DOMAIN="$(prompt 'Domain for the Site (blank: <site>.home.arpa, nothing public needed)')"
      [[ -n "$SIZE"      ]] || SIZE="$(prompt 'Size of the Site: small (a few users, one node or a test system), medium (up to ~50 users), large (100+ users, 3+ large nodes)' medium)"
      [[ -n "$SHOW_TOKEN" ]] || { read -r -p "${IN} At the end, show the console's access token on this screen (not in the log)? [Y/n]: " yn; logged "$yn"; [[ "$yn" == [nN]* ]] && SHOW_TOKEN=0 || SHOW_TOKEN=1; }
    else
      [[ -n "$SITE_CODE" ]] || die "--install without a terminal needs --site <name>"
      [[ -n "$BRANCH" ]] || BRANCH=stable
      [[ -n "$ORG" ]] || ORG="$SITE_CODE"
      [[ -n "$SIZE" ]] || SIZE=medium
      [[ -n "$SHOW_TOKEN" ]] || SHOW_TOKEN=0
    fi
    [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "not a branch: ${BRANCH}"
    [[ "$SITE_CODE" =~ ^[a-z0-9-]{1,15}$ ]] || die "the Site name is lowercase, at most 15 characters: ${SITE_CODE}"
    [[ "$ORG" =~ ^[a-z0-9-]+$ ]] || die "the Organisation name is lowercase: ${ORG}"
    [[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "not a domain: ${DOMAIN}"
    [[ "$SIZE" =~ ^(small|medium|large)$ ]] || die "the Size is small, medium or large: ${SIZE}"
  fi

  # This computer's password, once, for the stick or the network boot: kept alive
  # until the script ends, so the write and the boot service ask nothing later.
  if [[ "$BOOT" == usb || "$BOOT" == network ]]; then
    sudo_ask "$([[ "$BOOT" == usb ]] && echo "write the stick" || echo "serve the network boot")"
    ( while sleep 50; do sudo -n -v 2>/dev/null || exit 0; kill -0 $$ 2>/dev/null || exit 0; done ) &
    SUDO_KEEP=$!
  fi
  info "All asked. From here on the script runs without questions."
}

after_build() {
  local c
  case "$BOOT" in
    none)
      info "${GN}✓ ${OUT} is ready.${CL} Write it to a USB stick, or see INSTALL.md, Step 1 Option C for the network."
      warn "The ISO embeds the root password — treat the media like a credential, and delete it after the install."
      return 0 ;;
    usb) write_usb "$OUT" ;;
    network) pxe_serve "$OUT" ;;
  esac
  if [[ "$WANT_INSTALL" == 1 ]]; then
    net_info "${NET_IF:-}"
    [[ "$NET_IP" != 10.* ]] || warn "this machine is on 10.x: the cut-over puts the management network 10.0.0.0/24 on the node, and this session can freeze. Drive it from your upstream network."
    wait_for_node
    pxe_stop
    start_install
    warn "${INSTALL_KEY} logs in to the node as root: keep it safe, or delete it and the node's line for it in /root/.ssh/authorized_keys."
  elif [[ -n "$PXE_RUN" ]]; then
    read -r -p "${IN} Press Enter when the target has rebooted into Proxmox, to end the network boot: " c; logged "$c"
  fi
  warn "The ISO embeds the root password — treat the media like a credential, and delete it after the install."
}
# <<< after-the-build

if [[ -z "${TAPPAAS_MEDIA_CONTAINER:-}" ]]; then
  [[ -n "$LOG" ]] || LOG="bootstrap-tappaas-$(date +%Y%m%d-%H%M%S).log"
  ( umask 077; : >>"$LOG" )
  chmod 600 "$LOG"
  # tee -i: Ctrl-C ends the script, and the log takes its last lines first.
  exec > >(tee -i -a "$LOG") 2>&1
  info "log: ${LOG}"
fi

EXIT_WORK="" EXIT_SEEN=""
trap '[[ -z "$SCAN_PID" ]] || kill "$SCAN_PID" 2>/dev/null || true; [[ -z "$SUDO_KEEP" ]] || kill "$SUDO_KEEP" 2>/dev/null || true; pxe_stop; [[ -z "$EXIT_WORK" ]] || rm -rf "$EXIT_WORK"; rm -f "$EXIT_SEEN"' EXIT
trap 'exit 130' INT TERM

# choose_mode — the first question: what to do. It sets how the target boots the
# image and whether to install, so neither is asked again. Skipped when --boot is
# given.
choose_mode() {
  local c
  [[ -z "$BOOT" && -t 0 ]] || return 0
  info "This installs TAPPaaS on a first node. All questions come first; then it runs without any."
  info "What do you want to do?"
  info "  1) Make the install image and write it to a USB stick (install later, with 3)"
  info "  2) Make the install image, write it to a USB stick, and install TAPPaaS on the machine booted from it"
  info "  3) The stick is made already: install TAPPaaS on the machine booted from it"
  info "  4) Make the install image, boot the machine over the network from this computer, and install TAPPaaS"
  info "  5) Only make the install image file"
  info "  6) Install TAPPaaS on a rented server (Hetzner), through its rescue system"
  read -r -p "${IN} Choice [2]: " c; logged "$c"
  case "${c:-2}" in
    1) BOOT=usb;     INSTALL_ANSWER=no ;;
    2) BOOT=usb;     INSTALL_ANSWER=yes ;;
    3) BOOT=booted;  INSTALL_ANSWER=yes ;;
    4) BOOT=network; INSTALL_ANSWER=yes ;;
    5) BOOT=none;    INSTALL_ANSWER=no ;;
    6) BOOT=rescue;  INSTALL_ANSWER=yes ;;
    *) die "choose 1 to 6" ;;
  esac
}

# The image this script built earlier, in this directory: for "the stick is made
# already", whose image carries the key the node is logged in to with.
built_image() {
  local f found=()
  for f in *-tappaas-auto.iso; do [[ -f "$f" && -f "${f%.iso}.key" ]] && found+=("$f"); done
  [[ ${#found[@]} -gt 0 ]] || die "no image made by this script here (an *-tappaas-auto.iso with its .key): run this in the directory it was made in, or give --use <image>"
  [[ ${#found[@]} -eq 1 ]] || die "more than one image here (${found[*]}): give --use <image>"
  echo "${found[0]}"
}

# ── This machine: the ISO, the questions, the key ─────────────────────
if [[ -z "${TAPPAAS_MEDIA_CONTAINER:-}" ]]; then
  choose_mode
  if [[ "$BOOT" == booted && -z "$USE" ]]; then
    USE="$(built_image)"
    info "the image made earlier: ${USE}"
  fi
fi
if [[ -n "$USE" ]]; then
  [[ -f "$USE" ]] || die "--use: no such image: ${USE}"
  OUT="$USE"
  INSTALL_KEY="${OUT%.iso}.key"
  ask_up_front
  after_build
  exit 0
fi
if [[ "$BOOT" == rescue ]]; then
  # The ISO is fetched and built on the server's rescue system (hosted_install).
  OUT="tappaas-hetzner.iso"
else
if [[ -z "$ISO" ]]; then
  _isos=()
  for _f in proxmox-ve_*.iso; do [[ -f "$_f" && "$_f" != *-tappaas-auto.iso ]] && _isos+=("$_f"); done
  [[ ${#_isos[@]} -le 1 ]] || die "more than one Proxmox VE ISO here (${_isos[*]}): give --iso <iso>"
  if [[ ${#_isos[@]} -eq 1 ]]; then
    ISO="${_isos[0]}"
  elif [[ -z "${TAPPAAS_MEDIA_CONTAINER:-}" || -n "${TAPPAAS_RESCUE_BUILD:-}" ]]; then
    # None here: the newest Proxmox lists, downloaded after the questions.
    ISO="$(iso_latest)" || die "no Proxmox VE ISO here, and Proxmox's list (${PVE_ISO_SUMS_URL}) could not be read: download one, or give --iso <iso>"
    ISO_FETCH=1
    info "no Proxmox VE ISO here: ${ISO} is downloaded after the questions"
  fi
fi
[[ -n "$ISO" ]] || die "--iso <proxmox-ve.iso> is required (download from proxmox.com)."
[[ "$ISO_FETCH" == 1 || -f "$ISO" ]] || die "--iso: no such file: ${ISO}"
[[ -n "$OUT" ]] || OUT="${ISO%.iso}-tappaas-auto.iso"
# Checked here on the operator's machine, and again by the build in its container
# when there is one: only then is the file known to be the one this build reads.
[[ "$ISO_FETCH" == 1 ]] || iso_check "$ISO" "$ISO_SHA256"
fi

# ── The four #404 operator answers (prompt for whatever is missing) ────
#
# On the FIRST node there is no site yet, so these are asked and that answer
# becomes the site's master data (#408). On a later USB install a site.json
# exists, and its location is offered as the default — a second node that
# silently came up with another layout is exactly what #408 reported.
SITE_JSON="${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json"
# keyboard is site-wide, country and timezone the primary location's (or the retired .location's).
site_location() { [[ -f "$SITE_JSON" ]] && jq -r --arg k "$1" 'if $k == "keyboard" then (.keyboard // .location.keyboard // "") else ((.locations[.primaryLocation // ""] // .location // {})[$k] // "") end' "$SITE_JSON" 2>/dev/null || true; }
# The default of each question: the site's answer, then this machine's own setting,
# then a plain value. A blank return takes it.
host_country() {
  local v
  case "$(uname -s)" in
    Darwin) v="$(defaults read -g AppleLocale 2>/dev/null || true)"
            # en_US@rg=dkzzzz: the Region setting, when it differs from the language's.
            if [[ "$v" == *rg=* ]]; then v="${v##*rg=}"; v="${v:0:2}"; else v="${v#*_}"; v="${v:0:2}"; fi ;;
    *)      v="${LC_ALL:-${LC_TIME:-${LANG:-}}}"; v="${v%%.*}"; [[ "$v" != *_* ]] && v="" || { v="${v#*_}"; v="${v:0:2}"; } ;;
  esac
  printf '%s' "$v" | tr '[:upper:]' '[:lower:]'
}
host_timezone() {
  local v=""
  command -v timedatectl >/dev/null 2>&1 && v="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -n "$v" ]] || v="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*zoneinfo/##p')"
  printf '%s' "$v"
}
# The Proxmox installer's keyboard for a country; en-us for the rest.
keyboard_of() {
  case "$1" in
    dk|de|es|fi|fr|hu|is|it|jp|lt|mk|nl|no|pl|pt|se|si|tr) echo "$1" ;;
    gb|uk) echo en-gb ;; br) echo pt-br ;; ch) echo de-ch ;; be) echo fr-be ;;
    *) echo en-us ;;
  esac
}
# Mandatory: the email and the root password, asked when not given. The rest has a
# right default and is not asked: the site's (or this machine's) country, keyboard
# and timezone, and the first node's name; each can still be given as an option.
if [[ -z "$EMAIL" ]]; then
  [[ -t 0 ]] || die "--email is needed (the admin's address, for email alerting)"
  EMAIL="$(prompt 'Admin email (for email alerting)' "$([[ -f "$SITE_JSON" ]] && jq -r '.email // ""' "$SITE_JSON" 2>/dev/null)")"
fi
[[ -n "$EMAIL" ]] || die "an admin email is needed (--email)"
[[ -n "$COUNTRY"  ]] || { _d="$(site_location country)"; COUNTRY="${_d:-$(_h="$(host_country)"; echo "${_h:-dk}")}"; }
[[ -n "$KEYBOARD" ]] || { _d="$(site_location keyboard)"; KEYBOARD="${_d:-$(keyboard_of "$COUNTRY")}"; }
[[ -n "$TIMEZONE" ]] || { _d="$(site_location timezone)"; TIMEZONE="${_d:-$(_h="$(host_timezone)"; echo "${_h:-Europe/Copenhagen}")}"; }
[[ -n "$FQDN"     ]] || FQDN="tappaas1.mgmt.internal"
[[ -n "${TAPPAAS_MEDIA_CONTAINER:-}" ]] || info "country ${COUNTRY}, keyboard ${KEYBOARD}, timezone ${TIMEZONE}, node ${FQDN} (--country, --keyboard, --timezone, --fqdn to change)"
if [[ -n "$PASSWORD_FILE" ]]; then
  PASSWORD="$(<"$PASSWORD_FILE")"
else
  [[ -t 0 ]] || die "--password-file is needed without a terminal (the node's root password)"
  read -r -s -p "${IN} Root password: " PASSWORD; echo ""
  read -r -s -p "${IN} Root password (again): " PASSWORD2; echo ""
  [[ "$PASSWORD" == "$PASSWORD2" ]] || die "Passwords do not match."
fi
[[ ${#PASSWORD} -ge 8 ]] || die "Root password must be at least 8 characters."
case "$FILESYSTEM" in ext4|zfs) ;; *) die "--filesystem must be zfs or ext4" ;; esac
is_kernel_name() { [[ "$1" == /* || "$1" =~ ^(sd[a-z]+|vd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$ ]]; }
[[ ${#DISKS[@]} -le 2 ]] || die "--disk at most twice: one boot disk, or a mirrored pair"
# ADR-037 D4: the disk is chosen on the target unless kernel names are given —
# the answer carries a placeholder the injected hook rewrites in the installer's
# own boot. FIELD_BOOT / FIELD_MIRROR are what it matches.
ASK_DISK=0 FIELD_BOOT="" FIELD_MIRROR=""
if [[ ${#DISKS[@]} -eq 2 ]] && is_kernel_name "${DISKS[0]}" && is_kernel_name "${DISKS[1]}"; then
  [[ "$FILESYSTEM" == "zfs" ]] || die "two --disk mirror the boot disk, which needs --filesystem zfs"
  [[ "${DISKS[0]}" != "${DISKS[1]}" ]] || die "the two --disk are the same disk"
  info "boot disk mirrored (zfs raid1) on ${DISKS[0]} and ${DISKS[1]} — give two disks of the same size"
elif [[ ${#DISKS[@]} -eq 1 ]] && is_kernel_name "$DISK"; then
  warn "--disk ${DISK} is a kernel name: it names the disk the installer's boot calls ${DISK}, which need not be the one you read it on"
else
  ASK_DISK=1
  FIELD_BOOT="${DISKS[0]:-auto}" FIELD_MIRROR="${DISKS[1]:-}"
  for _f in "$FIELD_BOOT" "$FIELD_MIRROR"; do
    [[ -z "$_f" || "$_f" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._:-]{0,63}$ ]] || die "--disk '$_f': a size (2TB), a model or a serial, auto, ask"
  done
  if [[ -n "$FIELD_MIRROR" && "$FIELD_MIRROR" != none ]]; then
    [[ "$FILESYSTEM" == "zfs" ]] || die "two --disk mirror the boot disk, which needs --filesystem zfs"
    [[ "$FIELD_BOOT" != auto && "$FIELD_BOOT" != ask ]] || die "a named mirror needs a named first --disk"
    [[ "$FIELD_MIRROR" != "$FIELD_BOOT" ]] || die "the two --disk are the same disk"
  fi
  # ext4 has no mirror: an identical smallest pair stays one disk.
  [[ "$FILESYSTEM" == "zfs" ]] || FIELD_MIRROR=none
  DISK="ASKDISK"
  say() { [[ -n "${TAPPAAS_MEDIA_CONTAINER:-}" ]] || info "$@"; }
  case "$FIELD_BOOT" in
    auto) say "boot disk chosen on the target: the smallest SSD/NVMe disk$([[ "$FIELD_MIRROR" == none ]] || echo ", both of an identical smallest pair (mirrored)") — its console asks when there is none" ;;
    ask)  say "boot disk asked on the target's console at install time" ;;
    *)    say "boot disk on the target: the one matching '${FIELD_BOOT}'${FIELD_MIRROR:+ + '${FIELD_MIRROR}'} — its console asks when none matches" ;;
  esac
fi
[[ "$FILESYSTEM" == "ext4" ]] && warn "ext4 boot disk: only for a node with data disks — without one there is no pool for the guests; use zfs unless the node has a data disk"

INSTALL_KEY="${OUT%.iso}.key"
if [[ -z "${TAPPAAS_MEDIA_CONTAINER:-}" ]]; then
  [[ -f "$INSTALL_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "tappaas-install" -f "$INSTALL_KEY"
  SSH_KEYS+=("${INSTALL_KEY}.pub")
  # Everything after the build, asked now, before it.
  ask_up_front
  if [[ "$BOOT" == rescue ]]; then hosted_install; exit 0; fi
  [[ "$ISO_FETCH" != 1 ]] || { iso_download "$ISO"; iso_check "$ISO" "$ISO_SHA256"; }
fi
if [[ -n "${TAPPAAS_RESCUE_BUILD:-}" && "$ISO_FETCH" == 1 ]]; then
  iso_download "$ISO"; iso_check "$ISO" "$ISO_SHA256"
fi

# ── Assistant bootstrap (first-node chicken-and-egg) ───────────────────
if ! command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin)
      command -v docker >/dev/null 2>&1 \
        || die "proxmox-auto-install-assistant is Linux-only and Docker is not available — install Docker Desktop, or run this script on any Linux box."
      docker_running || die "Docker is not running and did not start: start it (Docker Desktop, or: colima start) and run this again."
      info "assistant not found — building inside a Debian container (mounting \$PWD)..."
      # Force linux/amd64: the assistant and prepare-iso ship amd64-only, so on
      # Apple-Silicon Macs the container must run x86_64 (via Docker/Colima
      # emulation — slower, but this is a one-off build). Harmless on Intel Macs.
      # Install only the base tools here, then re-exec: inside the container the
      # script hits the Linux branch below, which fetches the assistant .deb
      # DIRECTLY (no apt repo). We do NOT add the Proxmox apt repo — Debian
      # trixie's apt (sqv verifier) rejects '[trusted=yes]', and Proxmox ships no
      # 'proxmox-release-trixie.gpg' key to pin with 'signed-by', so an apt
      # install of the assistant fails. The direct .deb fetch checks the
      # repository's signature itself (paia_fetch), with gpgv.
      # apt's own chatter (and debconf's, without a terminal frontend) is shown
      # only when it fails.
      _build=(--iso "$ISO" --out "$OUT" --email "$EMAIL" --country "$COUNTRY" --keyboard "$KEYBOARD"
        --timezone "$TIMEZONE" --fqdn "$FQDN" --filesystem "$FILESYSTEM" --password-file /dev/stdin)
      if [[ ${#DISKS[@]} -gt 0 ]]; then for _d in "${DISKS[@]}"; do _build+=(--disk "$_d"); done; fi
      if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then for _k in "${SSH_KEYS[@]}"; do [[ ! -f "$_k" ]] || _k="$(<"$_k")"; _build+=(--ssh-key "$_k"); done; fi
      # The password goes in on stdin, so it is on no command line and in no file.
      printf '%s' "$PASSWORD" | docker run --rm -i --init --platform linux/amd64 -e DEBIAN_FRONTEND=noninteractive -e TAPPAAS_MEDIA_CONTAINER=1 \
        -v "$PWD:/work" -w /work debian:trixie bash -c "
        { apt-get update -qq && apt-get install -y -qq wget ca-certificates zstd cpio xorriso gpgv; } </dev/null >/tmp/apt.log 2>&1 \
          || { cat /tmp/apt.log; echo 'installing the build tools in the container failed' >&2; exit 1; }
        exec ./$(basename "$0") $(printf '%q ' "${_build[@]}")"
      after_build
      exit 0
      ;;
    Linux)
      # In the macOS container this is the expected path, said once above.
      if [[ -n "${TAPPAAS_MEDIA_CONTAINER:-}" ]]; then debug "fetching the assistant .deb"
      else info "assistant not found — fetching the .deb from the Proxmox repo (no install needed)..."; fi
      _PAIA_DIR="$(mktemp -d)"
      paia_fetch "${_PAIA_DIR}"
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
# ── Build the answer file ──────────────────────────────────────────────
WORK="$(mktemp -d)"
EXIT_WORK="$WORK"
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
  if [[ -n "$NET_CIDR" ]]; then
    # A rented server: no DHCP, the address read from its rescue system, on the
    # NIC with the server's MAC (the installer runs in QEMU with that MAC).
    echo 'source = "from-answer"'
    echo "cidr = \"${NET_CIDR}\""
    echo "gateway = \"${NET_GW}\""
    echo "dns = \"${NET_DNS}\""
    echo "filter.ID_NET_NAME_MAC = \"*$(printf '%s' "${NET_MAC//:/}" | tr 'A-F' 'a-f')\""
  else
    echo 'source = "from-dhcp"'
  fi
  echo ''
  echo '[disk-setup]'
  echo "filesystem = \"${FILESYSTEM}\""
  if [[ "$FILESYSTEM" == "zfs" ]]; then
    if [[ ${#DISKS[@]} -eq 2 ]]; then echo 'zfs.raid = "raid1"'; else echo 'zfs.raid = "raid0"'; fi
  fi
  # Kernel names are baked in as given; otherwise the ASKDISK placeholder,
  # which the injected hook rewrites in the installer's own boot.
  if [[ ${#DISKS[@]} -eq 2 && "$DISK" != ASKDISK ]]; then
    echo "disk-list = [\"${DISKS[0]}\", \"${DISKS[1]}\"]"
  else
    echo "disk-list = [\"${DISK}\"]"
  fi
  if [[ -n "$NET_MAC" ]]; then
    echo ''
    echo '[first-boot]'
    echo 'source = "from-iso"'
    echo 'ordering = "before-network"'
  fi
} > "$ANSWER"

# The first boot of a server installed in QEMU: QEMU's NIC had another name than
# the real one, so the bridge is moved to the port with the server's MAC before
# the network comes up.
FIRST_BOOT=()
if [[ -n "$NET_MAC" ]]; then
  { printf '#!/bin/sh\nmac="%s"\n' "$(printf %s "$NET_MAC" | tr A-F a-f)"; cat <<'FIRSTBOOT'; } > "${WORK}/first-boot.sh"
real=""
for d in /sys/class/net/*; do
  [ -e "$d/device" ] || continue
  [ "$(cat "$d/address")" = "$mac" ] && real="${d##*/}"
done
old="$(awk '/bridge-ports/ {print $2; exit}' /etc/network/interfaces)"
if [ -n "$real" ] && [ -n "$old" ] && [ "$real" != "$old" ]; then
  sed -i "s/\b${old}\b/${real}/g" /etc/network/interfaces
  echo "TAPPaaS: the bridge moved from ${old} to ${real}"
fi
FIRSTBOOT
  FIRST_BOOT=(--on-first-boot "${WORK}/first-boot.sh")
fi

# The assistant's own progress lines are shown only when it fails.
if ! _out="$(proxmox-auto-install-assistant validate-answer "$ANSWER" 2>&1)"; then
  echo "$_out" >&2
  die "Answer file failed validation — see above (PVE version schema mismatch?)."
fi
info "  ${GN}✓${CL} answer file valid"

# ── Prepare the ISO (answer embedded — no network needed at install) ──
if ! _out="$(proxmox-auto-install-assistant prepare-iso "$ISO" --fetch-from iso --answer-file "$ANSWER" ${FIRST_BOOT[@]+"${FIRST_BOOT[@]}"} --output "$OUT" 2>&1)"; then
  echo "$_out" >&2
  die "prepare-iso failed — see above."
fi
info "  ${GN}✓${CL} answer embedded in ${OUT}"

# ── The boot disk on the target: inject the matcher and prompt into the initrd ──
# Same mechanism as the PXE flow (node-provisioner assets.py): the kernel
# accepts a LATER initramfs segment overriding /init, so we append a cpio
# with a patched init that (a) shows the machine's real disks and reads the
# choice on the console, (b) bind-mounts a rewritten answer.toml (the
# ASKDISK placeholder replaced) over the ISO's copy before switch_root.
if [[ "$ASK_DISK" -eq 1 ]]; then
  for _tool in xorriso cpio; do
    command -v "$_tool" >/dev/null 2>&1 || die "$_tool is required for the ask-at-install disk prompt (apt/brew install $_tool) — or pass --disk <dev> to bake the disk in."
  done
  debug "injecting the boot-disk matcher and console prompt into the installer initrd"
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
  # The fields go in as shell words: '.' stands for a model's space, which the
  # matcher's grep reads as any character.
  _fb="${FIELD_BOOT// /.}" _fm="${FIELD_MIRROR// /.}"
  {
    echo "    # TAPPaaS bootstrap-tappaas: the boot disk(s), chosen in the installer's"
    echo "    # own boot (ADR-037 D4) — the answer's ASKDISK placeholder is rewritten."
    echo "    _tap_bd='${_fb}'; _tap_bm='${_fm}'"
    echo "# >>> boot-disk matcher: node-provisioner assets.RESOLVE_SH, kept identical (test_boot_disk_resolve.py)"
    cat <<'RESOLVE'
_tap_sys="${TAPPAAS_SYS:-/sys}"
_tap_disks() {
    for _d in "$_tap_sys"/block/*; do
        _b="${_d##*/}"
        case "$_b" in loop*|ram*|sr*|dm-*|zram*|zd*|md*|nbd*|*boot[0-9]*|*rpmb) continue ;; esac
        [ -e "$_d/device" ] || continue
        [ "$(cat "$_d/size" 2>/dev/null || echo 0)" -ge 31250000 ] || continue
        case "$(cd "$_d" 2>/dev/null && pwd -P)" in */usb*) continue ;; esac
        echo "$_b"
    done
}
_tap_sectors() { cat "$_tap_sys/block/$1/size" 2>/dev/null || echo 0; }
_tap_model() { cat "$_tap_sys/block/$1/device/model" 2>/dev/null; }
_tap_ssd() { [ "$(cat "$_tap_sys/block/$1/queue/rotational" 2>/dev/null)" = 0 ]; }
_tap_hay() {
    echo "$(_tap_model "$1") $(cat "$_tap_sys/block/$1/device/serial" 2>/dev/null) $(cat "$_tap_sys/block/$1/device/wwid" 2>/dev/null)"
}
_tap_size_mb() {
    _v="$1"
    case "$_v" in
        *[Tt][Bb]) _v="${_v%??}"; _m=1000000 ;;
        *[Tt]) _v="${_v%?}"; _m=1000000 ;;
        *[Gg][Bb]) _v="${_v%??}"; _m=1000 ;;
        *[Gg]) _v="${_v%?}"; _m=1000 ;;
        *) return 1 ;;
    esac
    case "$_v" in ''|.*|*.|*[!0-9.]*|*.*.*) return 1 ;; esac
    _i="${_v%%.*}"; _f=""
    case "$_v" in *.*) _f="${_v#*.}" ;; esac
    _f="${_f}000"; _f="${_f%"${_f#???}"}"
    while case "$_f" in 0?*) true ;; *) false ;; esac; do _f="${_f#0}"; done
    while case "$_i" in 0?*) true ;; *) false ;; esac; do _i="${_i#0}"; done
    echo $(( _i * _m + _f * _m / 1000 ))
}
_tap_match() {
    if [ -e "$_tap_sys/block/$1/device" ]; then echo "$1"; return 0; fi
    _want="$(_tap_size_mb "$1")" || _want=""
    for _b in $(_tap_disks); do
        if [ -n "$_want" ]; then
            _mb=$(( $(_tap_sectors "$_b") * 512 / 1000000 ))
            _dd=$(( _mb - _want )); [ "$_dd" -lt 0 ] && _dd=$(( 0 - _dd ))
            [ "$_dd" -le $(( _want / 10 )) ] && echo "$_b"
        elif _tap_hay "$_b" | grep -qi -- "$1"; then
            echo "$_b"
        fi
    done
    return 0
}
_tap_alike() {
    [ "$(_tap_sectors "$1")" = "$(_tap_sectors "$2")" ] && [ "$(_tap_model "$1")" = "$(_tap_model "$2")" ]
}
_tap_resolve() {
    _tap_disk=""; _tap_mirror=""; _tap_why=""
    case "$1" in
        ask) _tap_why="asked for on the console"; return 1 ;;
        auto|"")
            _s1=""; _s2=""
            for _c in $(_tap_disks); do
                _tap_ssd "$_c" || continue
                _z=$(_tap_sectors "$_c")
                if [ -z "$_s1" ] || [ "$_z" -lt "$(_tap_sectors "$_s1")" ]; then _s2="$_s1"; _s1="$_c"
                elif [ -z "$_s2" ] || [ "$_z" -lt "$(_tap_sectors "$_s2")" ]; then _s2="$_c"; fi
            done
            if [ -z "$_s1" ]; then _tap_why="no SSD or NVMe disk to choose automatically"; return 1; fi
            _tap_disk="$_s1"
            if [ -n "$_s2" ] && [ "$2" != none ] && _tap_alike "$_s1" "$_s2"; then
                _tap_mirror="$_s2"; _tap_why="automatic: the smallest SSD/NVMe disks, a pair alike"
            else
                _tap_why="automatic: the smallest SSD/NVMe disk"
            fi
            return 0 ;;
    esac
    _m1="$(_tap_match "$1")"; _n1=0; _a=""; _o=""
    for _x in $_m1; do _n1=$((_n1 + 1)); if [ -z "$_a" ]; then _a="$_x"; else _o="$_x"; fi; done
    if [ -z "$2" ] || [ "$2" = none ]; then
        if [ "$_n1" = 1 ]; then _tap_disk="$_a"; _tap_why="'$1'"; return 0; fi
        if [ "$_n1" = 2 ] && [ -z "$2" ] && _tap_alike "$_a" "$_o"; then
            _tap_disk="$_a"; _tap_mirror="$_o"; _tap_why="'$1': two disks alike, mirrored"; return 0
        fi
        _tap_why="'$1' matches $_n1 disks"; return 1
    fi
    _m2="$(_tap_match "$2")"; _n2=0; _p=""
    for _x in $_m2; do _n2=$((_n2 + 1)); _p="$_x"; done
    if [ "$_n1" = 1 ] && [ "$_n2" = 1 ] && [ "$_a" != "$_p" ]; then
        _tap_disk="$_a"; _tap_mirror="$_p"; _tap_why="'$1' + '$2'"; return 0
    fi
    _tap_why="'$1' matches $_n1 disk(s), '$2' $_n2"; return 1
}
RESOLVE
    echo "# <<< boot-disk matcher"
    cat <<'ASKBLOCK'
    _tap_ans=""
    for _tap_f in /mnt/.installer-mp/cdrom/answer.toml /mnt/.installer-mp/cdrom/*.toml; do
        [ -f "$_tap_f" ] && grep -q "ASKDISK" "$_tap_f" 2>/dev/null && _tap_ans="$_tap_f" && break
    done
    if [ -n "$_tap_ans" ]; then
    {
        sleep 3
        echo "1 1 1 7" > /proc/sys/kernel/printk 2>/dev/null || true
        if _tap_resolve "$_tap_bd" "$_tap_bm"; then
            echo "TAPPaaS: boot disk ${_tap_disk}${_tap_mirror:+, mirrored onto ${_tap_mirror}} (${_tap_why})"
        else
            echo ""
            echo "==== TAPPaaS install: choose the BOOT disk ===="
            [ "$_tap_bd" = ask ] || echo "(${_tap_why})"
            echo "The chosen disk is WIPED (PVE system). Disks found:"
            for _tap_d in /sys/block/*; do
                _tap_b="${_tap_d##*/}"
                case "$_tap_b" in loop*|ram*|sr*|dm-*|zram*) continue ;; esac
                _tap_sz=$(cat "$_tap_d/size" 2>/dev/null || echo 0)
                echo "  $_tap_b  ($((_tap_sz / 2097152)) GB)  $(cat "$_tap_d/device/model" 2>/dev/null)"
            done
            _tap_disk=""; _tap_mirror=""
            while [ ! -e "/sys/block/$_tap_disk" ] || [ -z "$_tap_disk" ]; do
                printf "TAPPaaS boot disk> "
                read -r _tap_disk
            done
        fi
        while IFS= read -r _tap_l; do
            case "$_tap_l" in
                *ASKDISK*) if [ -n "$_tap_mirror" ]; then echo "disk-list = [\"${_tap_disk}\", \"${_tap_mirror}\"]"; else echo "disk-list = [\"${_tap_disk}\"]"; fi ;;
                zfs.raid*) if [ -n "$_tap_mirror" ]; then echo 'zfs.raid = "raid1"'; else echo 'zfs.raid = "raid0"'; fi ;;
                *) echo "$_tap_l" ;;
            esac
        done < "$_tap_ans" > /tappaas-answer.toml
        mount --bind /tappaas-answer.toml "$_tap_ans"
        # Left mounted it keeps /cdrom busy and the installer's unmount retries
        # for 25 s before the reboot; released by the installer's own script.
        sed -i "s#^\( *\)iso_dev=\$(awk#\1umount ${_tap_ans#/mnt/.installer-mp} || true; &#" \
            /mnt/.installer-mp/sbin/unconfigured.sh || true
        echo "TAPPaaS: installing to '${_tap_disk}'${_tap_mirror:+ + '${_tap_mirror}'}"
    } < "/dev/${console:-console}" > "/dev/${console:-console}" 2>&1
    fi
ASKBLOCK
  } > "${AW}/askblock"
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
  # Reseal the ISO with the patched initrd. PVE 9.2 ships a hybrid MBR+GPT+APM
  # installer ISO for which the old in-place swap (`xorriso -map ... -boot_image
  # any replay`) — and even a verbatim replay of the ISO's own build options —
  # aborts with "libisofs: Overlapping MBR partition entries requested". So we
  # rebuild instead: read the ISO's boot layout from its own -report_el_torito,
  # drop the single option that triggers the overlap (-part_like_isohybrid; the
  # resulting MBR/GPT/APM boot structure is otherwise identical — verified), then
  # extract the tree, swap in the patched initrd, and re-author. Reading the
  # options from the ISO keeps this robust across PVE ISO-layout changes.
  # The tree extract lands in a temp dir (container-internal /tmp on macOS, i.e.
  # off the slow Docker bind mount).
  _bootopts=()
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    # Split the ISO's own report line into args. xorriso single-quotes each value
    # (paths, volume id), so shell tokenisation via eval is the reliable parse —
    # `xargs -n1` silently mangles the `-e '/efi.img'` pair. Trusted input: it is
    # the ISO we just built from a stock Proxmox ISO.
    # shellcheck disable=SC2294
    eval "_toks=( $_line )"
    for _tok in "${_toks[@]}"; do
      [[ "$_tok" == "-part_like_isohybrid" ]] && continue
      _bootopts+=("$_tok")
    done
  done < <(xorriso -indev "$OUT" -report_el_torito as_mkisofs 2>/dev/null)
  [[ ${#_bootopts[@]} -gt 0 ]] || die "could not read the ISO boot layout (xorriso -report_el_torito)."
  _tree="$(mktemp -d)"
  xorriso -osirrox on -indev "$OUT" -extract / "$_tree" >/dev/null 2>&1 \
    || die "could not extract the ISO tree for reseal."
  cp "${AW}/initrd.img" "${_tree}/boot/initrd.img"
  if [[ "$SERIAL_CONSOLE" == 1 ]]; then
    # The installer's console also on the serial port, which QEMU on a rescue
    # system writes to a file the build follows.
    chmod -R u+w "${_tree}/boot/grub"
    sed -i -E '/proxmox-start-auto-installer/ s/$/ console=tty0 console=ttyS0,115200/' "${_tree}/boot/grub/grub.cfg"
  fi
  xorriso -as mkisofs "${_bootopts[@]}" -o "${OUT}.tmp.iso" "$_tree" >/dev/null 2>&1 \
    || die "ISO reseal (rebuild) failed."
  mv "${OUT}.tmp.iso" "$OUT"
  rm -rf "$_tree" "$AW"
  info "  ${GN}✓${CL} boot-disk matcher injected (the disk is picked on the target)"
fi

if [[ "$ASK_DISK" -eq 1 ]]; then
  info "  The install picks the boot disk on the target (its console asks only when nothing matches), then runs unattended and WIPES it."
else
  info "  The install runs UNATTENDED and WIPES ${DISK} on the target machine."
fi
[[ -n "${TAPPAAS_MEDIA_CONTAINER:-}" ]] || after_build
