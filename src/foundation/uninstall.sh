#!/usr/bin/env bash
#
# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# foundation/uninstall.sh — TEAR A NODE BACK DOWN toward a clean Proxmox install.
#
# The counterpart to foundation/install.sh. It removes everything TAPPaaS layered
# onto a Proxmox VE node so the box is as close as practical to a verbatim PVE
# install — for fast re-test cycles. It does NOT reinstall Proxmox or undo the
# apt/package state (repos, dist-upgrade); it removes the TAPPaaS-specific layer:
#
#   1. TAPPaaS VMs            (every VM tagged 'TAPPaaS', incl. the nixos template)
#   2. Proxmox Backup Server  (datastore, pvesm entry, the proxmox-backup pkg)
#   3. ZFS data pools         (tank*: pvesm entry + zpool destroy)         [--keep-pools]
#   4. The Proxmox cluster    (dissolve back to standalone)
#   5. Network bridges        (restore the pre-TAPPaaS /etc/network/interfaces)[--keep-network]
#   6. The tappaas user       (+ /home/tappaas, /root/tappaas, credentials)  [--keep-user]
#   7. TAPPaaS markers        (step1 marker, r8127 conf, rollback unit, snippets, /etc/secrets)
#
# SAFETY
#   - DRY-RUN BY DEFAULT: with no flags it only PRINTS what it would do.
#   - --yes is required to actually erase; an interactive run then asks you to
#     type ERASE to confirm (skip with --force).
#   - Every step is best-effort and idempotent: failures warn and continue so a
#     partial previous run can be finished by re-running.
#
# Usage:
#   uninstall.sh [--yes] [--force] [--keep-pools] [--keep-network] [--keep-user]
#                [--only <step>[,<step>...]] [-h|--help]
#     steps: vms,pbs,pools,cluster,network,user,markers
#
#   uninstall.sh                 # dry-run: show the teardown plan, change nothing
#   uninstall.sh --yes           # execute (asks to type ERASE on a TTY)
#   uninstall.sh --yes --keep-pools --keep-network   # keep the ZFS data + NIC config
#
# Run as root on the Proxmox node. Exit: 0 ok, 1 error, 2 bad usage.
#
set -uo pipefail   # NOT -e: this is a best-effort cleanup; steps must not abort it.

readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[uninstall]${CL} $*"; }
warn()  { echo -e "${YW}[uninstall][warn]${CL} $*"; }
error() { echo -e "${RD}[uninstall][error]${CL} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────
DRY_RUN=1 FORCE=0 KEEP_POOLS=0 KEEP_NETWORK=0 KEEP_USER=0
ONLY=""
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)          DRY_RUN=0 ;;
    --force)        FORCE=1 ;;
    --keep-pools)   KEEP_POOLS=1 ;;
    --keep-network) KEEP_NETWORK=1 ;;
    --keep-user)    KEEP_USER=1 ;;
    --only)         ONLY="${2:-}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              error "Unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] || die "Run as root on the Proxmox node."
command -v qm >/dev/null 2>&1 || warn "qm not found — is this a Proxmox VE node? (continuing)"

# step <name> → is this step enabled? (respects --only)
step() { [[ -z "$ONLY" ]] && return 0; [[ ",${ONLY}," == *",$1,"* ]]; }

# run <cmd...> : print under dry-run, execute (best-effort) otherwise.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '   %b[would]%b %s\n' "$BL" "$CL" "$*"; return 0; fi
  if ! "$@"; then warn "   command failed (continuing): $*"; fi
}

# ── Inventory (always shown) ─────────────────────────────────────────
mapfile -t TAPPAAS_VMS < <(
  qm list 2>/dev/null | awk 'NR>1{print $1}' | while read -r id; do
    tags="$(qm config "$id" 2>/dev/null | sed -n 's/^tags: //p')"
    [[ "${tags,,}" == *tappaas* ]] && echo "$id"
  done
)
mapfile -t TANK_POOLS    < <(zpool list -H -o name 2>/dev/null | grep -E '^tank' || true)
mapfile -t PBS_STORAGES  < <(awk '/^pbs: /{print $2}' /etc/pve/storage.cfg 2>/dev/null || true)
IN_CLUSTER=0; pvecm status >/dev/null 2>&1 && IN_CLUSTER=1

echo ""
info "${BOLD}TAPPaaS node teardown — inventory${CL}  (host: $(hostname -s))"
info "  TAPPaaS VMs : ${TAPPAAS_VMS[*]:-<none>}"
info "  ZFS pools   : ${TANK_POOLS[*]:-<none>}$( [[ $KEEP_POOLS -eq 1 ]] && echo '   (KEPT: --keep-pools)')"
info "  PBS storage : ${PBS_STORAGES[*]:-<none>}"
info "  In cluster  : $( [[ $IN_CLUSTER -eq 1 ]] && echo yes || echo no )"
info "  Network     : $( [[ $KEEP_NETWORK -eq 1 ]] && echo 'KEPT (--keep-network)' || echo 'restore pre-TAPPaaS /etc/network/interfaces' )"
info "  tappaas user: $( [[ $KEEP_USER -eq 1 ]] && echo 'KEPT (--keep-user)' || (id tappaas >/dev/null 2>&1 && echo 'remove' || echo '<absent>') )"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  warn "DRY-RUN — nothing will be changed. Re-run with ${BOLD}--yes${CL} to execute."
else
  warn "${BOLD}This ERASES the TAPPaaS layer on this node (VMs, pools, cluster, network).${CL}"
  if [[ $FORCE -eq 0 && -t 0 ]]; then
    read -r -p "Type ${BOLD}ERASE${CL} to proceed: " _c
    [[ "$_c" == "ERASE" ]] || { info "Aborted (nothing changed)."; exit 0; }
  fi
fi

# ── Step 1: destroy TAPPaaS VMs ──────────────────────────────────────
if step vms; then
  info "${BOLD}[1] TAPPaaS VMs${CL}"
  if [[ ${#TAPPAAS_VMS[@]} -eq 0 ]]; then info "  none."; else
    for id in "${TAPPAAS_VMS[@]}"; do
      info "  VM ${id} ($(qm config "$id" 2>/dev/null | sed -n 's/^name: //p'))"
      # NB: the flag is --skiplock (one word); --skip-lock is rejected by qm.
      # Stop must complete before destroy, else the VM keeps its zvols open and a
      # later `zpool destroy` blocks. `qm stop` is a hard stop (fine for teardown).
      run qm stop "$id" --skiplock
      run qm destroy "$id" --purge --destroy-unreferenced-disks --skiplock
    done
  fi
fi

# ── Step 2: Proxmox Backup Server ────────────────────────────────────
if step pbs; then
  info "${BOLD}[2] Proxmox Backup Server${CL}"
  for s in "${PBS_STORAGES[@]:-}"; do [[ -n "$s" ]] && run pvesm remove "$s"; done
  if command -v proxmox-backup-manager >/dev/null 2>&1; then
    # Remove each datastore by NAME (best-effort; the on-disk dir goes with the
    # pool anyway). Use JSON + jq — the `text` output is a bordered table whose
    # box-drawing chars would otherwise be fed to `datastore remove`.
    while read -r ds; do [[ -n "$ds" ]] && run proxmox-backup-manager datastore remove "$ds"; done \
      < <(proxmox-backup-manager datastore list --output-format json 2>/dev/null | jq -r '.[].name' 2>/dev/null)
    run systemctl disable --now proxmox-backup proxmox-backup-proxy
    run apt-get -y purge proxmox-backup-server
    run rm -rf /etc/proxmox-backup
  else
    info "  PBS not installed on this node."
  fi
fi

# ── Step 3: ZFS data pools ───────────────────────────────────────────
if step pools; then
  info "${BOLD}[3] ZFS data pools${CL}"
  if [[ $KEEP_POOLS -eq 1 ]]; then info "  kept (--keep-pools)."
  elif [[ ${#TANK_POOLS[@]} -eq 0 ]]; then info "  none."
  else
    for p in "${TANK_POOLS[@]}"; do
      info "  pool ${p}"
      # Unregister from PVE storage if present (name == pool name by convention).
      grep -qE "^zfspool: ${p}\$" /etc/pve/storage.cfg 2>/dev/null && run pvesm remove "$p"
      # Member devices, for a label wipe so a re-install sees clean disks.
      mapfile -t _members < <(zpool list -vH "$p" 2>/dev/null | awk 'NF>1 && $1 ~ /\/dev\/|^nvme|^sd|^ata-|^wwn-/{print $1}')
      run zpool destroy -f "$p"
      for d in "${_members[@]:-}"; do [[ -n "$d" ]] && run zpool labelclear -f "$d"; done
    done
  fi
fi

# ── Step 4: dissolve the Proxmox cluster → standalone ────────────────
if step cluster; then
  info "${BOLD}[4] Proxmox cluster${CL}"
  if [[ $IN_CLUSTER -eq 0 ]]; then info "  not in a cluster — nothing to do."
  else
    # Standard single-node dissolve: stop the cluster stack, run pmxcfs in local
    # mode, drop corosync config, restart pmxcfs normally → node is standalone.
    run systemctl stop pve-ha-lrm pve-ha-crm
    run systemctl stop corosync
    run systemctl stop pve-cluster
    run pmxcfs -l
    run rm -f /etc/pve/corosync.conf
    # Clear /etc/corosync but KEEP the directory: a fresh Proxmox ships an
    # (empty) /etc/corosync, and `corosync-keygen` (run by a later `pvecm create`)
    # refuses to create the parent dir — so `rm -rf /etc/corosync` would leave the
    # node unable to re-create a cluster ("Could not create /etc/corosync/authkey:
    # No such file or directory"). Remove the contents, then re-create the dir.
    run rm -rf /etc/corosync
    run mkdir -p /etc/corosync
    run pkill -9 pmxcfs
    run systemctl start pve-cluster
    info "  → after this the node should report no cluster (verify: pvecm status)."
  fi
fi

# ── Step 5: restore the pre-TAPPaaS network config ───────────────────
if step network; then
  info "${BOLD}[5] Network bridges${CL}"
  if [[ $KEEP_NETWORK -eq 1 ]]; then info "  kept (--keep-network)."
  else
    # config-network.sh backs up /etc/network/interfaces on every run; the OLDEST
    # backup is the original (pre-TAPPaaS) single-NIC config.
    oldest="$(ls -1tr /etc/network/interfaces.tappaas.*.bak 2>/dev/null | head -1 || true)"
    if [[ -n "$oldest" ]]; then
      warn "  restoring ${oldest} → /etc/network/interfaces (this can DROP your SSH if you are on the lan/wan)."
      run cp -a "$oldest" /etc/network/interfaces
      run ifreload -a
    else
      warn "  no /etc/network/interfaces.tappaas.*.bak found — leaving the current config (edit by hand to restore a single vmbr0)."
    fi
    # Remove the auto-rollback unit/artifacts config-network may have left.
    run rm -f /usr/local/sbin/tappaas-net-rollback.sh /run/tappaas-net-ok
    # Reset /etc/resolv.conf: the cutover pointed DNS at the firewall (10.0.0.1),
    # which is now destroyed — leaving it would break DNS for the retest install.
    # Point at the restored default gateway (from the interfaces we just wrote),
    # with a public fallback, so the node can resolve names again.
    gw="$(awk '/^[[:space:]]*gateway[[:space:]]/{print $2; exit}' /etc/network/interfaces 2>/dev/null)"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "  would reset /etc/resolv.conf → nameserver ${gw:-<gateway>} + 1.1.1.1"
    else
      { [[ -n "$gw" ]] && printf 'nameserver %s\n' "$gw"; printf 'nameserver 1.1.1.1\n'; } > /etc/resolv.conf
      info "  reset /etc/resolv.conf → ${gw:+nameserver $gw, }nameserver 1.1.1.1"
    fi
  fi
fi

# ── Step 6: the tappaas user + dirs + credentials ────────────────────
if step user; then
  info "${BOLD}[6] tappaas user + dirs + credentials${CL}"
  if [[ $KEEP_USER -eq 1 ]]; then info "  kept (--keep-user)."
  else
    id tappaas >/dev/null 2>&1 && run userdel -r tappaas
    run rm -rf /root/tappaas
    run rm -f /root/.opnsense-credentials.txt /root/.authentik-credentials.txt \
              /root/.acme-dns-credentials.txt /root/.pbs-credentials.txt
    run rm -rf /etc/secrets
  fi
fi

# ── Step 7: TAPPaaS markers + post-install artifacts ─────────────────
if step markers; then
  info "${BOLD}[7] TAPPaaS markers + post-install artifacts${CL}"
  run rm -f /var/log/tappaas.step1
  run rm -f /etc/modprobe.d/tappaas-r8127.conf            # r8127 NIC blacklist (reverts to r8169 on next boot)
  run rm -f /var/lib/vz/snippets/tappaas-debian-vendor.yaml
  # ~/bin TAPPaaS helper symlinks (installed under /home/tappaas/bin; gone with the user).
  info "  (apt repos, the subscription-nag patch and dist-upgrade are intentionally LEFT — they are harmless and non-TAPPaaS-specific.)"
fi

echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  info "${BOLD}Dry-run complete.${CL} Re-run with --yes to perform the teardown."
else
  info "${BOLD}${GN}Teardown complete.${CL} The node is back toward a clean Proxmox install."
  info "  Re-test with: foundation/install.sh \"\$REPO\" \"\$BRANCH\" --name <org> --domain <d> [--non-interactive --lan-port .. --wan-port .. --pool ..]"
  [[ $IN_CLUSTER -eq 1 ]] && warn "  A reboot is recommended (clears the r8169/r8127 driver state and any lingering cluster services)."
fi
exit 0
