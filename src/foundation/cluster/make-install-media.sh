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
#       [--password-file <f>] [--disk <d>] [--disk <d>] [--fqdn <host.domain>] \
#       [--filesystem zfs|ext4] [--ssh-key <pubkey-file>] [--out <out.iso>] \
#       [--iso-sha256 <hex>]
#
# The boot disk is ZFS by default (ADR-037 D1): the boot pool then carries the
# guests on a node with no data disk. A second --disk mirrors it (zfs raid1);
# each disk then gets its own EFI system partition, and config-storage.sh makes
# sure proxmox-boot-tool keeps both, so the node boots from either. ext4 is for
# a node that has data disks: config-storage.sh refuses an ext4 boot disk alone.
#
# Anything not given is prompted for — EXCEPT the boot disk, which is chosen ON
# THE TARGET at install time, like the PXE flow (ADR-037 D4): a hook injected
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

RD="\033[01;31m"; GN="\033[1;92m"; YW="\033[33m"; CL="\033[m"
info()  { echo -e "${GN}[Info]${CL} $*"; }
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
die()   { echo -e "${RD}[Error]${CL} $*" >&2; exit 1; }
debug() { [[ "${TAPPAAS_DEBUG:-0}" == 1 ]] || return 0; echo "[Debug] $*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0; }

ISO="" OUT="" EMAIL="" COUNTRY="" KEYBOARD="" TIMEZONE="" PASSWORD="" \
  PASSWORD_FILE="" DISK="" FQDN="" FILESYSTEM="zfs" ISO_SHA256=""
SSH_KEYS=()
DISKS=()

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
  info "Checking ${name} against its published SHA-256..."
  have="$(media_sha256 "$iso")"
  [[ "$have" == "$want" ]] || die "${name} does not match its published SHA-256 (expected ${want}, got ${have}) — download it again."
  info "ISO verified: ${name}"
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
    info "proxmox-auto-install-assistant ${ver} verified (${codename})"
    return 0
  done
  die "could not locate proxmox-auto-install-assistant in the Proxmox repo — install it manually."
}
# <<< media-checks

# ── Assistant bootstrap (first-node chicken-and-egg) ───────────────────
if ! command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin)
      command -v docker >/dev/null 2>&1 \
        || die "proxmox-auto-install-assistant is Linux-only and Docker is not available — install Docker Desktop, or run this script on any Linux box."
      info "assistant not found — re-running inside a Debian container (mounting \$PWD)..."
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
      exec docker run --rm -it --platform linux/amd64 -v "$PWD:/work" -w /work debian:trixie bash -c "
        apt-get update -qq >/dev/null &&
        apt-get install -y -qq wget ca-certificates zstd cpio xorriso gpgv >/dev/null &&
        exec ./$(basename "$0") $(printf '%q ' "${ORIG_ARGS[@]}")"
      ;;
    Linux)
      info "assistant not found — fetching the .deb from the Proxmox repo (no install needed)..."
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
[[ -n "$ISO" && -f "$ISO" ]] || die "--iso <proxmox-ve.iso> is required (download from proxmox.com)."
iso_check "$ISO" "$ISO_SHA256"

# ── The four #404 operator answers (prompt for whatever is missing) ────
#
# On the FIRST node there is no site yet, so these are asked and that answer
# becomes the site's master data (#408). On a later USB install a site.json
# exists, and its location is offered as the default — a second node that
# silently came up with another layout is exactly what #408 reported.
SITE_JSON="${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json"
# keyboard is site-wide, country and timezone the primary location's (or the retired .location's).
site_location() { [[ -f "$SITE_JSON" ]] && jq -r --arg k "$1" 'if $k == "keyboard" then (.keyboard // .location.keyboard // "") else ((.locations[.primaryLocation // ""] // .location // {})[$k] // "") end' "$SITE_JSON" 2>/dev/null || true; }
prompt() {
  local v d="${2:-}"
  if [[ -n "$d" ]]; then read -r -p "  $1 [$d]: " v; printf '%s' "${v:-$d}"
  else read -r -p "  $1: " v; printf '%s' "$v"; fi
}
[[ -n "$EMAIL"    ]] || EMAIL="$(prompt 'Admin email (Proxmox mailto)' "$([[ -f "$SITE_JSON" ]] && jq -r '.email // ""' "$SITE_JSON" 2>/dev/null)")"
[[ -n "$COUNTRY"  ]] || COUNTRY="$(prompt 'Country code (e.g. dk)' "$(site_location country)")"
[[ -n "$KEYBOARD" ]] || KEYBOARD="$(prompt 'Keyboard layout (e.g. en-us, dk)' "$(site_location keyboard)")"
[[ -n "$TIMEZONE" ]] || TIMEZONE="$(prompt 'Timezone (e.g. Europe/Copenhagen)' "$(site_location timezone)")"
[[ -n "$FQDN"     ]] || FQDN="$(prompt 'Node FQDN (e.g. tappaas1.mgmt.internal)')"
if [[ -n "$PASSWORD_FILE" ]]; then
  PASSWORD="$(<"$PASSWORD_FILE")"
else
  read -r -s -p "  Root password: " PASSWORD; echo ""
  read -r -s -p "  Root password (again): " PASSWORD2; echo ""
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
  case "$FIELD_BOOT" in
    auto) info "boot disk chosen on the target: the smallest SSD/NVMe disk$([[ "$FIELD_MIRROR" == none ]] || echo ", both of an identical smallest pair (mirrored)") — its console asks when there is none" ;;
    ask)  info "boot disk asked on the target's console at install time" ;;
    *)    info "boot disk on the target: the one matching '${FIELD_BOOT}'${FIELD_MIRROR:+ + '${FIELD_MIRROR}'} — its console asks when none matches" ;;
  esac
fi
[[ "$FILESYSTEM" == "ext4" ]] && warn "ext4 boot disk: only for a node with data disks — without one there is no pool for the guests (ADR-037 D1)"

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
    if [[ ${#DISKS[@]} -eq 2 ]]; then echo 'zfs.raid = "raid1"'; else echo 'zfs.raid = "raid0"'; fi
  fi
  # Kernel names are baked in as given; otherwise the ASKDISK placeholder,
  # which the injected hook rewrites in the installer's own boot.
  if [[ ${#DISKS[@]} -eq 2 && "$DISK" != ASKDISK ]]; then
    echo "disk-list = [\"${DISKS[0]}\", \"${DISKS[1]}\"]"
  else
    echo "disk-list = [\"${DISK}\"]"
  fi
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
  info "Injecting the boot-disk matcher and console prompt into the installer initrd..."
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
    echo "    # TAPPaaS make-install-media: the boot disk(s), chosen in the installer's"
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
  xorriso -as mkisofs "${_bootopts[@]}" -o "${OUT}.tmp.iso" "$_tree" >/dev/null 2>&1 \
    || die "ISO reseal (rebuild) failed."
  mv "${OUT}.tmp.iso" "$OUT"
  rm -rf "$_tree" "$AW"
  info "boot-disk matcher and console prompt injected."
fi

info "${GN}✓${CL} Done. Write it to USB:  dd if='${OUT}' of=/dev/<usb> bs=4M status=progress"
if [[ "$ASK_DISK" -eq 1 ]]; then
  info "The install picks the boot disk on the target (its console asks only when nothing matches), then runs unattended and WIPES it."
else
  info "The install runs UNATTENDED and WIPES ${DISK} on the target machine."
fi
warn "The ISO embeds the root password — treat the media like a credential."
