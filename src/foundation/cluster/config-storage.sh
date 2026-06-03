#!/usr/bin/env bash
#
# TAPPaaS Storage Configuration (config-storage.sh)
#
# Interactively builds the TAPPaaS ZFS data pools (tanka1, tankb1, tankc1, ...)
# on a Proxmox VE node from the disks present in the machine, and registers
# each pool with PVE storage. Can also be driven non-interactively via flags
# for repeatable/unattended installs.
#
# Naming convention (CLAUDE.md): tankXY — X is the storage type/tier (a, b, c),
# Y a sequence number. tanka1 is the primary/fast pool.
#
# SAFETY
#   - The boot disk (the disk(s) backing / and /boot/efi) is NEVER offered and
#     never touched.
#   - Every other disk IS offered, INCLUDING disks that already belong to an
#     existing tanka1/b1/c1 — this is deliberate, so a machine that used to be
#     part of another TAPPaaS cluster can be wiped and re-provisioned.
#   - Any disk that already contains data (partition table, filesystem or ZFS
#     label) requires an explicit confirmation before it is wiped.
#
# Usage:
#   config-storage.sh [options]
#
# Options:
#   --pool <name>=<topology>:<disk>[,<disk>...]
#                     Define a pool non-interactively. May be repeated.
#                     topology ∈ { single, stripe, mirror, raidz, raidz2 }.
#                     single=1 disk; stripe=2+ disks, no redundancy.
#                     disks are kernel names (sdb) or by-id paths.
#                     e.g. --pool tanka1=mirror:sdb,sdc --pool tankb1=single:sdd
#   --yes             Assume "yes" to wipe confirmations (DANGEROUS; for
#                     unattended installs only). Implies non-interactive.
#   --non-interactive Fail instead of prompting (requires --pool for any work).
#   --no-pve-register Create the pools but do not add them to PVE storage.
#   -h, --help        Show this help.
#
# Exit codes: 0 success/no-op, 1 error, 2 bad usage.

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────
readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[storage]${CL} $*"; }
warn()  { echo -e "${YW}[storage][warn]${CL} $*"; }
error() { echo -e "${RD}[storage][error]${CL} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── Cleanup trap ─────────────────────────────────────────────────────
TMPFILES=()
cleanup() { local f; for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do rm -f "$f"; done; }
trap cleanup EXIT INT TERM

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# ── Arguments ────────────────────────────────────────────────────────
declare -a POOL_SPECS=()
declare -a SESSION_SELECTED_DISKS=()  # Track disks selected in this session (issue #271)
ASSUME_YES=0
INTERACTIVE=1
PVE_REGISTER=1
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)            POOL_SPECS+=("${2:-}"); shift 2 ;;
    --yes)             ASSUME_YES=1; INTERACTIVE=0; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    --no-pve-register) PVE_REGISTER=0; shift ;;
    --list)            LIST_ONLY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

command -v zpool  >/dev/null || die "zpool not found — is this a Proxmox/ZFS host?"
command -v lsblk  >/dev/null || die "lsblk not found"
HAVE_WHIPTAIL=0; command -v whiptail >/dev/null && HAVE_WHIPTAIL=1
# A TTY is required for interactive menus (e.g. when piped via curl|bash there
# is none — the bootstrap downloads then runs this so stdin stays a TTY).
[[ -t 0 && -t 1 ]] || INTERACTIVE=0

# ── Boot-disk discovery (never offered/touched) ──────────────────────
# Resolve the physical disk(s) backing / and /boot/efi by walking the device
# tree upwards (lsblk --inverse) and keeping whole disks.
# A "real" physical disk has a backing device node; ZFS zvols (zd*), device
# mapper (dm-*) and loop devices do not — this cleanly excludes them.
is_real_disk() { [[ -e "/sys/block/$1/device" ]]; }

boot_disks() {
  local src mp pool d
  for mp in / /boot /boot/efi; do
    src="$(findmnt -no SOURCE "$mp" 2>/dev/null || true)"
    [[ -z "$src" ]] && continue
    # ZFS root mounts read like "rpool/ROOT/..."; resolve via the pool's vdevs.
    if [[ "$src" != /dev/* ]]; then
      pool="${src%%/*}"
      zpool status -P "$pool" 2>/dev/null \
        | grep -oE '/dev/[a-zA-Z0-9/_-]+' \
        | while read -r d; do lsblk -nsro NAME "$d" 2>/dev/null; done
      continue
    fi
    # -s inverse deps, -r raw (no tree art) → clean names up to the disk.
    lsblk -nsro NAME "$src" 2>/dev/null
  done | while read -r n; do
    is_real_disk "$n" && echo "$n"
  done | sort -u
}

mapfile -t BOOT_DISKS < <(boot_disks)
info "Boot disk(s) (protected, never offered): ${BOLD}${BOOT_DISKS[*]:-none-detected}${CL}"
[[ ${#BOOT_DISKS[@]} -eq 0 ]] && warn "Could not detect the boot disk — be extra careful selecting disks."

is_boot_disk() {
  local d="$1" b
  for b in "${BOOT_DISKS[@]+"${BOOT_DISKS[@]}"}"; do [[ "$d" == "$b" ]] && return 0; done
  return 1
}

# ── Candidate disk inventory ─────────────────────────────────────────
# A disk "has data" if it carries any partition, filesystem signature, or ZFS
# member label. We surface that so the operator confirms before wiping it.
disk_has_data() {
  local d="/dev/$1"
  # children (partitions) present? (-r raw → no tree art; skip the disk itself)
  [[ -n "$(lsblk -rno NAME "$d" 2>/dev/null | tail -n +2)" ]] && return 0
  # filesystem / raid / zfs signature on the whole device?
  [[ -n "$(lsblk -rno FSTYPE "$d" 2>/dev/null | grep -v '^$' || true)" ]] && return 0
  blkid "$d" >/dev/null 2>&1 && return 0
  return 1
}

# Which existing zpool (if any) claims this disk — informational, helps the
# operator recognise an old tanka1/b1/c1 they are about to overwrite. Pool
# vdevs are typically /dev/disk/by-id/...-partN, so resolve each vdev path
# back to its parent disk before comparing.
disk_zpool() {
  local want="$1" pool="" a b real parent
  while read -r a b; do
    [[ "$a" == "pool:" ]] && { pool="$b"; continue; }
    case "$a" in
      /dev/*)
        real="$(readlink -f "$a" 2>/dev/null)"
        [[ -z "$real" ]] && continue
        parent="$(lsblk -no pkname "$real" 2>/dev/null | head -1)"
        [[ -z "$parent" ]] && parent="$(basename "$real")"
        if [[ "$parent" == "$want" || "$(basename "$real")" == "$want" ]]; then
          echo "$pool"; return 0
        fi
        ;;
    esac
  done < <(zpool status -P 2>/dev/null)
  # Always succeed (echo empty when not found) — a non-zero return would abort
  # callers under `set -e` when used as `pool="$(disk_zpool ...)"`.
  return 0
}

declare -a CAND_NAME CAND_DESC
# Check if a disk was selected earlier in this session (issue #271)
is_session_selected() {
  local d="$1" sd
  for sd in "${SESSION_SELECTED_DISKS[@]+"${SESSION_SELECTED_DISKS[@]}"}"; do
    [[ "$d" == "$sd" ]] && return 0
  done
  return 1
}

build_inventory() {
  CAND_NAME=(); CAND_DESC=()
  local name type size model rota spin tag pool
  # NAME,TYPE is space-safe (single-word fields). Per-disk attributes are then
  # queried individually so a MODEL string with spaces can't shift columns.
  while read -r name type; do
    [[ "$type" == "disk" ]] || continue
    is_real_disk "$name" || continue          # skip zvols (zd*), dm-*, loop*
    is_boot_disk "$name"  && continue
    is_session_selected "$name" && continue   # skip disks selected earlier in this session (#271)
    size="$(lsblk -dno SIZE  "/dev/$name" 2>/dev/null | tr -d ' ')"
    model="$(lsblk -dno MODEL "/dev/$name" 2>/dev/null | sed 's/[[:space:]]*$//')"
    rota="$(lsblk -dno ROTA  "/dev/$name" 2>/dev/null | tr -d ' ')"
    spin="SSD"; [[ "$rota" == "1" ]] && spin="HDD"
    pool="$(disk_zpool "$name")"
    if [[ -n "$pool" ]]; then        tag=" [in zpool ${pool}]"
    elif disk_has_data "$name"; then tag=" [has data]"
    else                             tag=" [blank]"
    fi
    CAND_NAME+=("$name")
    CAND_DESC+=("${size} ${spin} ${model:-unknown}${tag}")
  done < <(lsblk -dn -o NAME,TYPE)
}

build_inventory
if [[ "$LIST_ONLY" == "1" ]]; then
  info "Selectable disks (boot disk excluded):"
  if [[ ${#CAND_NAME[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    for i in "${!CAND_NAME[@]}"; do printf '  %-10s %s\n' "${CAND_NAME[$i]}" "${CAND_DESC[$i]}"; done
  fi
  exit 0
fi
if [[ ${#CAND_NAME[@]} -eq 0 ]]; then
  warn "No selectable data disks found (only the boot disk is present)."
  exit 0
fi

# ── Wipe helper (destructive; gated by confirmation) ─────────────────
wipe_disk() {
  local d="$1"
  info "  Wiping ${BL}/dev/${d}${CL} ..."
  # Tear down any ZFS label first, then signatures + partition table.
  zpool labelclear -f "/dev/${d}" >/dev/null 2>&1 || true
  local p
  for p in $(lsblk -rno NAME "/dev/${d}" | tail -n +2); do
    zpool labelclear -f "/dev/${p}" >/dev/null 2>&1 || true
  done
  wipefs -a "/dev/${d}" >/dev/null 2>&1 || true
  sgdisk --zap-all "/dev/${d}" >/dev/null 2>&1 || true
  command -v partprobe >/dev/null && partprobe "/dev/${d}" >/dev/null 2>&1 || true
}

confirm() {
  # confirm <prompt>  → returns 0 for yes
  local prompt="$1"
  [[ "$ASSUME_YES" == "1" ]] && return 0
  if [[ "$INTERACTIVE" == "1" && "$HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "TAPPaaS storage" --yesno "$prompt" 14 78
    return $?
  fi
  local ans
  read -r -p "$prompt [type YES to confirm]: " ans
  [[ "$ans" == "YES" ]]
}

# ── Pool creation ────────────────────────────────────────────────────
pool_exists() { zpool list -H -o name 2>/dev/null | grep -qx "$1"; }

create_pool() {
  # create_pool <name> <topology> <disk...>
  local name="$1" topo="$2"; shift 2
  local -a disks=("$@")

  if pool_exists "$name"; then
    warn "Pool '${name}' already exists — skipping creation."
    return 0
  fi

  # Map topology → zpool vdev keyword. 'single' (1 disk) and 'stripe' (2+ disks
  # concatenated with NO redundancy) both use an empty vdev keyword — ZFS
  # stripes across all top-level vdevs.
  local vdev=""
  case "$topo" in
    single) vdev="" ;;
    stripe) vdev="" ;;
    mirror) vdev="mirror" ;;
    raidz)  vdev="raidz" ;;
    raidz2) vdev="raidz2" ;;
    *) error "Unknown topology '${topo}' for pool ${name}"; return 1 ;;
  esac
  if [[ "$topo" == "single" && ${#disks[@]} -ne 1 ]]; then
    error "topology 'single' needs exactly 1 disk (got ${#disks[@]})"; return 1
  fi
  if [[ "$topo" == "stripe" && ${#disks[@]} -lt 2 ]]; then
    error "topology 'stripe' needs at least 2 disks (got ${#disks[@]})"; return 1
  fi
  if [[ "$topo" == "mirror" && ${#disks[@]} -lt 2 ]]; then
    error "topology 'mirror' needs at least 2 disks"; return 1
  fi
  if [[ "$topo" == "stripe" ]]; then
    warn "Pool '${name}' is a STRIPE (${#disks[@]} disks) — NO redundancy; a single disk failure loses the pool."
  fi

  # Confirm + wipe each disk that carries data.
  local d had_data=0 listing="" pool_tag extra dinfo
  for d in "${disks[@]}"; do
    [[ -b "/dev/$d" ]] || { error "Not a block device: /dev/$d"; return 1; }
    if is_boot_disk "$d"; then error "Refusing to use boot disk /dev/$d"; return 1; fi
    pool_tag="$(disk_zpool "$d")"
    if [[ -n "$pool_tag" ]] || disk_has_data "$d"; then
      had_data=1
      extra=""
      if [[ -n "$pool_tag" ]]; then extra="  [zpool ${pool_tag}]"; fi
      dinfo="$(lsblk -dn -o SIZE,MODEL "/dev/$d" 2>/dev/null || true)"
      listing+="  /dev/${d}  (${dinfo})${extra}"$'\n'
    fi
  done
  if [[ "$had_data" == "1" ]]; then
    if ! confirm "Pool '${name}' (${topo}) will ERASE these disks — all existing data is lost:

${listing}
Proceed?"; then
      warn "Skipped pool '${name}' (not confirmed)."
      return 0
    fi
  fi
  for d in "${disks[@]}"; do wipe_disk "$d"; done

  info "Creating pool ${BOLD}${name}${CL} (${topo}: ${disks[*]}) ..."
  # Reference disks by stable /dev/disk/by-id where possible for resilience.
  local -a refs=()
  for d in "${disks[@]}"; do
    local byid; byid="$(byid_for "$d")"
    refs+=("${byid:-/dev/$d}")
  done
  # shellcheck disable=SC2086
  zpool create -f -o ashift=12 -o autotrim=on \
      -O compression=lz4 -O atime=off -O xattr=sa \
      "$name" $vdev "${refs[@]}" \
    || { error "zpool create ${name} failed"; return 1; }
  info "  ${GN}✓${CL} Pool '${name}' created."

  if [[ "$PVE_REGISTER" == "1" ]]; then register_pve "$name"; fi
}

byid_for() {
  local d="$1" link
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" ]] || continue
    [[ "$(readlink -f "$link")" == "/dev/$d" ]] || continue
    case "$link" in *"/wwn-"*) echo "$link"; return 0;; esac   # prefer wwn-
  done
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" ]] || continue
    if [[ "$(readlink -f "$link")" == "/dev/$d" ]]; then echo "$link"; return 0; fi
  done
  return 0   # not found → empty (caller falls back to /dev/<name>)
}

register_pve() {
  local name="$1"
  local thisnode
  thisnode="$(hostname -s)"
  command -v pvesm >/dev/null || { warn "pvesm not found — skipping PVE registration of ${name}"; return 0; }

  # ZFS pools are node-local: the pool just created exists only on THIS node
  # (until another node's run of this script creates a same-named pool). But
  # storage.cfg is cluster-wide, so a zfspool with no 'nodes' restriction makes
  # Proxmox try to activate it on every node and fail with "cannot open '<pool>':
  # no such pool" on the nodes that lack it. Scope each storage to the node(s)
  # that actually hold the pool, accumulating nodes as the per-node runs register
  # the same-named pool (e.g. tanka1 ends up on all nodes; tankc1 stays on one).
  if pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    local cur
    cur="$(awk -v s="$name" '
      $1=="zfspool:" && $2==s {f=1; next}
      f && $1=="nodes" {print $2; exit}
      f && $1 ~ /:$/ {exit}
    ' /etc/pve/storage.cfg 2>/dev/null)"
    if [[ -z "$cur" ]]; then
      info "  PVE storage '${name}' already registered (all nodes) — leaving unrestricted."
    elif grep -qw "$thisnode" <<<"${cur//,/ }"; then
      info "  PVE storage '${name}' already scoped to ${thisnode}."
    elif pvesm set "$name" --nodes "${cur},${thisnode}" >/dev/null 2>&1; then
      info "  ${GN}✓${CL} Extended PVE storage '${name}' to ${thisnode} (nodes: ${cur},${thisnode})."
    else
      warn "  Could not extend node list for PVE storage '${name}'."
    fi
    return 0
  fi
  if pvesm add zfspool "$name" -pool "$name" -content images,rootdir -nodes "$thisnode" >/dev/null 2>&1; then
    info "  ${GN}✓${CL} Registered PVE storage '${name}' on ${thisnode} (images,rootdir)."
  else
    warn "  Could not register PVE storage '${name}' (may already exist cluster-wide)."
  fi
}

# ── Non-interactive path: --pool specs ───────────────────────────────
process_spec() {
  # name=topology:disk1,disk2
  local spec="$1"
  local name="${spec%%=*}" rest="${spec#*=}"
  local topo="${rest%%:*}" disks_csv="${rest#*:}"
  [[ "$name" == "$spec" || "$rest" == "$spec" ]] && die "Bad --pool spec '${spec}' (want name=topology:disk,disk)"
  IFS=',' read -r -a disks <<<"$disks_csv"
  create_pool "$name" "$topo" "${disks[@]}"
}

if [[ ${#POOL_SPECS[@]} -gt 0 ]]; then
  for spec in "${POOL_SPECS[@]}"; do process_spec "$spec"; done
  info "${GN}Storage configuration complete.${CL}"
  exit 0
fi

if [[ "$INTERACTIVE" != "1" ]]; then
  warn "Non-interactive and no --pool specs given — nothing to do."
  exit 0
fi

# ── Interactive path ─────────────────────────────────────────────────
# Loop offering to build the standard pools. The operator picks disks and a
# topology for each; an empty selection skips that pool.
interactive_select_disks() {
  # echoes selected kernel names (space separated) on stdout; menus to stderr
  local title="$1"; shift
  local -a wt_args=()
  local i
  for i in "${!CAND_NAME[@]}"; do
    wt_args+=("${CAND_NAME[$i]}" "${CAND_DESC[$i]}" "off")
  done
  if [[ "$HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "TAPPaaS storage" --separate-output \
      --checklist "${title}\n(space to toggle, enter to confirm; leave empty to skip)" \
      22 78 12 "${wt_args[@]}" 3>&1 1>&2 2>&3
  else
    echo "${title}" >&2
    for i in "${!CAND_NAME[@]}"; do echo "  ${CAND_NAME[$i]} — ${CAND_DESC[$i]}" >&2; done
    read -r -p "Enter disks for this pool (space separated, blank to skip): " line >&2
    echo "$line"
  fi
}

interactive_topology() {
  local n="$1"
  if [[ "$n" -eq 1 ]]; then echo "single"; return; fi
  if [[ "$HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "TAPPaaS storage" --menu \
      "Topology for ${n} disks:" 16 70 5 \
      mirror "Mirror (recommended; n-way redundancy)" \
      raidz  "RAIDZ (single parity)" \
      raidz2 "RAIDZ2 (double parity)" \
      stripe "Stripe (NO redundancy; capacity = sum)" \
      3>&1 1>&2 2>&3
  else
    local t
    read -r -p "Topology [mirror/raidz/raidz2/stripe] (default mirror): " t >&2
    echo "${t:-mirror}"
  fi
}

# Pool descriptions for the interactive dialogs (issue #271)
pool_description() {
  case "$1" in
    tanka1) echo "Primary VM storage pool. VMs are placed here by default and VM data resides here. Recommended: fast and redundant disk setup (SSD mirror)." ;;
    tankb1) echo "Secondary storage pool for less important services and data. Optional. Typically not using disk redundancy and not participating in HA replication." ;;
    tankc1) echo "Backup storage pool. Where backups are stored. Typically configured on only one node (tappaas1 for single machine, tappaas3 for 3-node cluster)." ;;
    *)      echo "Additional storage tier." ;;
  esac
}

for POOL in tanka1 tankb1 tankc1; do
  if pool_exists "$POOL"; then
    info "Pool '${POOL}' already exists — skipping (use a fresh disk set to rebuild)."
    continue
  fi
  POOL_DESC="$(pool_description "$POOL")"
  if [[ "$HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "TAPPaaS storage" --yesno \
      "Configure pool '${POOL}'?\n\n${POOL_DESC}" 14 78 \
      || { info "Skipping ${POOL}."; continue; }
  else
    echo ""
    echo "${POOL}: ${POOL_DESC}"
    read -r -p "Configure pool '${POOL}'? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || { info "Skipping ${POOL}."; continue; }
  fi
  mapfile -t SEL < <(interactive_select_disks "Select disks for ${POOL}" | tr ' ' '\n' | grep -v '^$')
  if [[ ${#SEL[@]} -eq 0 ]]; then info "No disks selected — skipping ${POOL}."; continue; fi
  TOPO="$(interactive_topology "${#SEL[@]}" || true)"
  [[ -z "$TOPO" ]] && { info "No topology chosen — skipping ${POOL}."; continue; }
  create_pool "$POOL" "$TOPO" "${SEL[@]}"
  # Track selected disks so they won't appear in subsequent pool selections (issue #271)
  SESSION_SELECTED_DISKS+=("${SEL[@]}")
  build_inventory   # refresh so used disks show their new pool / are not re-picked
done

info "${GN}Storage configuration complete.${CL}"
zpool list 2>/dev/null || true
