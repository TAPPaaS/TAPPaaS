#!/usr/bin/env bash
#
# TAPPaaS Cluster NFS Manager
#
# Admin-side provisioning for cluster:storage's NFS backend. Named shares are
# provisioned independently (once, by an operator) and mountable by any
# module via cluster:storage's dispatcher. No module owns the disk.
#
# Two share types, registered in config/nfs-shares.json:
#   local    - TAPPaaS-managed ZFS dataset + kernel NFS export on a Proxmox node.
#   external - an already-existing NAS/network share (e.g. Synology), configured
#              out-of-band by the operator on the NAS itself. This script never
#              provisions or owns an external export — only registers it and
#              verifies it's reachable.
#
# Usage:
#   nfs-manager.sh init-zone [--vlan-tag <N>]
#   nfs-manager.sh wire-module <module.json> <share-name> [--mount-point </path>] [--access rw|ro]
#   nfs-manager.sh add <name> --node <node> --tank <tank> [--quota <size>] [--backup [--keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N]] [--layout <path1,path2,...>]
#   nfs-manager.sh add-external <name> --host <ip> --export <path>
#   nfs-manager.sh remove <name>
#   nfs-manager.sh list
#   nfs-manager.sh resize <name> --quota <size>
#   nfs-manager.sh update <name> --node <node>
#   nfs-manager.sh update <name> --host <ip>
#   nfs-manager.sh backup <name> --enable [--keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N]
#   nfs-manager.sh backup <name> --disable
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../backup/lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../backup/lib/pbs-job.sh"
# shellcheck source=../backup/lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../backup/lib/pbs-namespace.sh"

SHARES_FILE="${CONFIG_DIR}/nfs-shares.json"

# Backstop only — the real gate is the firewall's zone `access-to` rules
# (cluster:storage's `storage` zone), not this export ACL. See
# cluster/DESIGN.md's "Security model" for the full picture.
EXPORT_ACL_SUPERNET="10.0.0.0/8"

usage() {
    cat <<'EOF'
Usage:
  nfs-manager.sh init-zone [--vlan-tag <N>]
  nfs-manager.sh wire-module <module.json> <share-name> [--mount-point </path>] [--access rw|ro]
  nfs-manager.sh add <name> --node <node> --tank <tank> [--quota <size>] [--backup [--keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N]] [--layout <path1,path2,...>]
  nfs-manager.sh add-external <name> --host <ip> --export <path>
  nfs-manager.sh remove <name>
  nfs-manager.sh list
  nfs-manager.sh resize <name> --quota <size>
  nfs-manager.sh update <name> --node <node>
  nfs-manager.sh update <name> --host <ip>
  nfs-manager.sh backup <name> --enable [--keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N]
  nfs-manager.sh backup <name> --disable
EOF
}

ensure_shares_file() {
    [[ -f "${SHARES_FILE}" ]] || echo '{}' > "${SHARES_FILE}"
}

share_exists() {
    local name="$1"
    jq -e --arg n "${name}" 'has($n)' "${SHARES_FILE}" >/dev/null 2>&1
}

reject_single_quote() {
    local label="$1" value="$2"
    [[ "${value}" == *"'"* ]] && die "${label} must not contain a single quote: ${value}"
    return 0
}

update_share_field() {
    local name="$1" field="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" --arg f "${field}" --arg v "${value}" \
        '.[$n][$f] = $v' "${SHARES_FILE}" > "${tmp}"
    mv "${tmp}" "${SHARES_FILE}"
}

# Same as update_share_field but writes a real JSON boolean (--arg would
# always produce a string, e.g. "backup": "true" instead of true).
update_share_bool_field() {
    local name="$1" field="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" --arg f "${field}" --argjson v "${value}" \
        '.[$n][$f] = $v' "${SHARES_FILE}" > "${tmp}"
    mv "${tmp}" "${SHARES_FILE}"
}

# ── PBS backup provisioning (opt-in, per-share) ──────────────────────
#
# Reuses backup/lib/pbs-job.sh + pbs-namespace.sh unchanged (the exact same
# helpers services/external/install-service.sh already uses to onboard a
# non-VM backup source) — a raw ZFS dataset has no VMID, so pbs_ensure_vmid()
# (VZDump-based) doesn't apply; this is proxmox-backup-client's OTHER,
# directory-backup mode instead, isolated in its own PBS namespace.
#
# Deliberately does NOT use the module-level "7y"-string retention cascade —
# that convention is specific to backup:vm's VZDump jobs. This talks to PBS
# directly the same way services/external already does, using PBS's own
# --keep-* vocabulary.


# Ensure the shared systemd service/timer TEMPLATE units exist on a node
# (one shared pair, parameterised by %i = share name — not duplicated per
# share). Idempotent: only writes/reloads when the content actually differs.
_ensure_backup_unit_templates() {
    local node_fqdn="$1"
    ssh -o BatchMode=yes "root@${node_fqdn}" 'bash -s' <<'REMOTE'
set -euo pipefail
changed=0
svc=/etc/systemd/system/cluster-storage-backup@.service
want_svc='[Unit]
Description=cluster:storage PBS backup for share '"'"'%i'"'"'
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/root/.cluster-storage-pbs/%i.env
ExecStart=/bin/sh -c '"'"'proxmox-backup-client backup %i.pxar:${SHARE_PATH} --repository ${PBS_REPOSITORY} --ns ${PBS_NAMESPACE}'"'"''
if [[ ! -f "$svc" ]] || [[ "$(cat "$svc")" != "$want_svc" ]]; then
    printf '%s\n' "$want_svc" > "$svc"
    changed=1
fi
timer=/etc/systemd/system/cluster-storage-backup@.timer
want_timer='[Unit]
Description=Daily cluster:storage PBS backup for share '"'"'%i'"'"'

[Timer]
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target'
if [[ ! -f "$timer" ]] || [[ "$(cat "$timer")" != "$want_timer" ]]; then
    printf '%s\n' "$want_timer" > "$timer"
    changed=1
fi
[[ "$changed" -eq 1 ]] && systemctl daemon-reload
echo "  backup unit templates ensured"
REMOTE
}

# Provision (or reconcile) PBS backup for one share: dedicated PBS user
# scoped to its own namespace, admin-owned prune-job, and a scheduled
# systemd timer on the node that actually pushes the data. Safe to re-run —
# password generation/user creation is skipped once the node-local
# credential file exists; namespace/ACL/prune-job/timer are all
# individually idempotent already (pbs-namespace.sh, systemd enable --now).
#   provision_share_backup <name> <node> <tank> [keepDaily keepWeekly keepMonthly keepYearly]
provision_share_backup() {
    local name="$1" node="$2" tank="$3"
    local keep_daily="${4:-7}" keep_weekly="${5:-4}" keep_monthly="${6:-6}" keep_yearly="${7:-1}"
    local node_fqdn="${node}.mgmt.internal"
    local store ns userid pbs_host cred_dir cred_file dataset_path

    store="$(pbs_storage_name)"
    ns="cluster-storage/${name}"
    userid="nfs-${name}@pbs"
    pbs_host="$(pbs_node).mgmt.internal"
    cred_dir="/root/.cluster-storage-pbs"
    cred_file="${cred_dir}/${name}.env"
    dataset_path="${tank}/${name}"

    info "Linking share '${name}' to PBS backup (namespace ${store}/${ns})"

    if ssh -o BatchMode=yes "root@${node_fqdn}" "test -f '${cred_file}'"; then
        debug "  ${cred_file} already present on ${node} — reusing existing PBS credential"
    else
        local password fingerprint
        password="$(head -c 18 /dev/urandom | base64)"
        pbs_user_ensure "${userid}" "${password}"

        fingerprint="$(_pbs_node_run proxmox-backup-manager cert info \
            | grep -i '^Fingerprint' | sed -E 's/^[^:]*:\s*//')"
        [[ -n "${fingerprint}" ]] || die "Could not read PBS certificate fingerprint from $(pbs_node)"

        ssh -o BatchMode=yes "root@${node_fqdn}" "install -d -m 0700 '${cred_dir}'"
        ssh -o BatchMode=yes "root@${node_fqdn}" "umask 077; cat > '${cred_file}'" <<EOF
PBS_PASSWORD=${password}
PBS_REPOSITORY=${userid}@${pbs_host}:${store}
PBS_NAMESPACE=${ns}
PBS_FINGERPRINT=${fingerprint}
SHARE_PATH=/${dataset_path}
EOF
        info "  ${GN}✓${CL} PBS user ${userid} created; credential written to ${cred_file} on ${node}"
    fi

    pbs_ns_ensure "${ns}"
    pbs_acl_ensure "$(_pbs_ns_acl_path "${store}" "${ns}")" DatastoreBackup "${userid}"

    local retention
    retention="$(jq -nc --argjson d "${keep_daily}" --argjson w "${keep_weekly}" \
        --argjson m "${keep_monthly}" --argjson y "${keep_yearly}" \
        '{keepDaily: $d, keepWeekly: $w, keepMonthly: $m, keepYearly: $y}')"
    local -a ret
    read -ra ret <<< "$(_pbs_retention_args "${retention}")"
    pbs_prunejob_ensure_ns "prune-cluster-storage-${name}" "${store}" "${ns}" "02:45" "${ret[@]}"

    _ensure_backup_unit_templates "${node_fqdn}"
    ssh -o BatchMode=yes "root@${node_fqdn}" \
        "systemctl enable --now 'cluster-storage-backup@${name}.timer'"

    info "  ${GN}✓${CL} PBS backup active for '${name}': daily 03:15 (±10m), retention ${keep_daily}d/${keep_weekly}w/${keep_monthly}m/${keep_yearly}y"
}

# Disable ONLY the schedule — deliberately never touches the PBS namespace,
# user, prune-job, or existing backup history. A share's backup history must
# survive a --disable; only re-enabling adds new snapshots again.
disable_share_backup_schedule() {
    local name="$1" node="$2"
    local node_fqdn="${node}.mgmt.internal"
    ssh -o BatchMode=yes "root@${node_fqdn}" \
        "systemctl disable --now 'cluster-storage-backup@${name}.timer'" 2>/dev/null || true
    info "  ${GN}✓${CL} backup schedule for '${name}' disabled (existing PBS history kept)"
}

# ── Zone bootstrap (one-time, before the first share) ────────────────
#
# `add`/`add-external` both need the foundation `storage` zone to already
# exist in zones.json (config-storage-zone.sh dies with a clear message
# otherwise) — but nothing previously automated CREATING that zone entry;
# an operator had to hand-edit zones.json and know the VLAN-numbering
# convention (see network-manager/ZONES.md: vlantag = typeId*100 + subId,
# ip = 10.<typeId>.<subId>.0/24). This wrapper removes that manual step,
# matching the UX of every other nfs-manager.sh command.
#
#   nfs-manager.sh init-zone [--vlan-tag <N>]
#
# --vlan-tag lets an operator pin a specific tag (e.g. to match an existing
# switch/VLAN plan); omitted, it auto-picks the first free subId in the
# Service band's (typeId=2) documented 60-99 auto-allocated window.
# Idempotent: a pre-existing 'storage' zone is left untouched and reported,
# never re-tagged (retagging a live zone means re-cabling traffic — not
# something to do implicitly).
cmd_init_zone() {
    local vlan_tag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vlan-tag) vlan_tag="$2"; shift 2 ;;
            *) die "init-zone: unknown flag '$1'" ;;
        esac
    done

    local zones_file="${CONFIG_DIR}/zones.json"
    [[ -f "${zones_file}" ]] || die "zones.json not found at ${zones_file}"

    if jq -e 'has("storage")' "${zones_file}" >/dev/null 2>&1; then
        local existing_tag existing_ip
        existing_tag="$(jq -r '.storage.vlantag' "${zones_file}")"
        existing_ip="$(jq -r '.storage.ip' "${zones_file}")"
        info "${GN}✓${CL} 'storage' zone already provisioned (VLAN ${existing_tag}, ${existing_ip}) — nothing to do"
        return 0
    fi

    local type_id=2 sub_id="" vlan ip
    if [[ -n "${vlan_tag}" ]]; then
        [[ "${vlan_tag}" =~ ^[0-9]+$ ]] || die "init-zone: --vlan-tag must be numeric"
        if jq -e --argjson t "${vlan_tag}" '[.[] | select(.vlantag == $t)] | length > 0' "${zones_file}" >/dev/null 2>&1; then
            die "init-zone: VLAN tag ${vlan_tag} is already used by another zone"
        fi
        vlan="${vlan_tag}"
        type_id=$((vlan_tag / 100))
        sub_id=$((vlan_tag % 100))
    else
        local used_subids candidate
        used_subids="$(jq -r --arg t "2" 'to_entries[] | select(.value.typeId == $t) | .value.subId' "${zones_file}")"
        for candidate in $(seq 60 99); do
            if ! grep -qx "${candidate}" <<<"${used_subids}"; then
                sub_id="${candidate}"
                break
            fi
        done
        [[ -n "${sub_id}" ]] || die "init-zone: no free subId in the Service band's 60-99 auto-allocated window — pass --vlan-tag explicitly"
        vlan=$((type_id * 100 + sub_id))
    fi
    ip="10.${type_id}.${sub_id}.0/24"

    info "Provisioning the 'storage' zone: VLAN ${vlan}, ${ip}"

    local tmp
    tmp="$(mktemp)"
    jq --argjson tag "${vlan}" --arg ip "${ip}" --arg tid "${type_id}" --arg sid "${sub_id}" \
        '.storage = {
            type: "Service",
            state: "Active",
            typeId: $tid,
            subId: $sid,
            vlantag: $tag,
            ip: $ip,
            bridge: "lan",
            "access-to": [],
            "pinhole-allowed-from": [],
            _comment: "Foundation shared-storage plane (cluster:storage NFS/CephFS exports). Inbound-only from consumer service zones via their own access-to; does not need to originate outbound traffic.",
            description: "Foundation shared storage (cluster:storage)"
        }' "${zones_file}" > "${tmp}"
    mv "${tmp}" "${zones_file}"
    info "  ${GN}✓${CL} 'storage' zone added to zones.json"

    if command -v zone-manager >/dev/null 2>&1; then
        info "  Applying via zone-manager..."
        zone-manager --no-ssl-verify --zones-file "${zones_file}" --execute \
            || die "zone-manager --execute failed — check its output above (zones.json already has the entry; re-run 'zone-manager --no-ssl-verify --execute' once fixed)"
    else
        warn "  zone-manager not on PATH — zone written to zones.json but not yet applied. Run 'zone-manager --execute' manually."
    fi

    info "${GN}✓${CL} 'storage' zone provisioned (VLAN ${vlan}, ${ip})"
}

# ── Module wiring (one-time per module) ──────────────────────────────
#
# Declaring cluster:storage in a module currently means hand-editing two
# files: the module's own JSON (dependsOn + sharedStorage) and pasting a
# marker comment pair into its .nix source. This automates both halves.
#
#   nfs-manager.sh wire-module <module.json> <share-name> [--mount-point </path>] [--access rw|ro]
#
# The .nix file is derived from the JSON's own .vmname, in the same
# directory — matching every TAPPaaS module's own naming convention
# (vmname.json + vmname.nix side by side). Idempotent: an already-declared
# dependsOn entry, sharedStorage entry (by name), or existing marker is left
# alone and reported, never duplicated.
#
# Nix insertion strategy: every TAPPaaS module (00-Template's own shape) is a
# single flat `{ ... }` attribute set closed by one unindented `}` as the
# LAST line of the file. The marker is inserted immediately before that
# line. This is a text heuristic, not a real Nix parser, so it is backed by
# a hard safety net: `nix-instantiate --parse` on the result. If that fails
# for any reason (a module that doesn't fit the expected shape), the edit is
# rolled back from the backup and the command dies with instructions to add
# the marker by hand — it never leaves a module with unverified/possibly-
# broken Nix.
cmd_wire_module() {
    local module_json="${1:-}" share_name="${2:-}"
    [[ -n "${module_json}" ]] || die "wire-module: <module.json> path is required"
    [[ -n "${share_name}" ]] || die "wire-module: <share-name> is required"
    shift 2 || true

    local mount_point="/media" access="rw"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mount-point) mount_point="$2"; shift 2 ;;
            --access)      access="$2"; shift 2 ;;
            *) die "wire-module: unknown flag '$1'" ;;
        esac
    done
    [[ "${access}" == "rw" || "${access}" == "ro" ]] || die "wire-module: --access must be 'rw' or 'ro'"

    [[ -f "${module_json}" ]] || die "wire-module: ${module_json} not found"
    jq empty "${module_json}" 2>/dev/null || die "wire-module: ${module_json} is not valid JSON"

    local module_dir vmname nix_file
    module_dir="$(cd "$(dirname "${module_json}")" && pwd)"
    vmname="$(jq -r '.vmname // empty' "${module_json}")"
    [[ -n "${vmname}" ]] || die "wire-module: ${module_json} has no .vmname"
    nix_file="${module_dir}/${vmname}.nix"
    [[ -f "${nix_file}" ]] || die "wire-module: expected ${nix_file} alongside ${module_json}, not found"

    # Conflict check: a mountPoint already defined elsewhere in the module's
    # OWN .nix (its own disk, an existing NAS mount, etc.) is a real problem
    # nix-instantiate --parse cannot catch — Nix syntax allows the same
    # attribute path to appear twice; it is only a hard "attribute already
    # defined" failure at actual EVALUATION time (nixos-rebuild), a much
    # more confusing place to discover it than right here. Skip past our own
    # marker block if it already exists (that's this module's own prior
    # cluster:storage declaration, not a conflict) — everything else in the
    # file is fair game to check.
    if awk -v mp="fileSystems.\"${mount_point}\"" '
            /# BEGIN cluster:storage/ { skip=1 }
            /# END cluster:storage/   { skip=0; next }
            !skip && index($0, mp) { found=1 }
            END { exit !found }
        ' "${nix_file}"; then
        die "wire-module: ${nix_file} already defines fileSystems.\"${mount_point}\" outside the cluster:storage marker — this module already mounts something else there. Pick a different --mount-point, or resolve the existing mount first."
    fi

    info "Wiring cluster:storage into ${vmname} (share '${share_name}' at ${mount_point}, ${access})"

    # ── JSON: dependsOn + sharedStorage (idempotent) ─────────────────
    local changed_json=0 tmp
    tmp="$(mktemp)"
    if jq -e '.dependsOn // [] | index("cluster:storage")' "${module_json}" >/dev/null 2>&1; then
        debug "  dependsOn already has cluster:storage"
        cp "${module_json}" "${tmp}"
    else
        jq '.dependsOn = ((.dependsOn // []) + ["cluster:storage"])' "${module_json}" > "${tmp}"
        changed_json=1
        info "  ${GN}✓${CL} dependsOn: added cluster:storage"
    fi

    if jq -e --arg n "${share_name}" '.sharedStorage // [] | map(.name) | index($n)' "${tmp}" >/dev/null 2>&1; then
        info "  share '${share_name}' already declared in sharedStorage — leaving as-is"
    else
        local tmp2
        tmp2="$(mktemp)"
        jq --arg n "${share_name}" --arg mp "${mount_point}" --arg acc "${access}" \
            '.sharedStorage = ((.sharedStorage // []) + [{name: $n, mountPoint: $mp, access: $acc}])' \
            "${tmp}" > "${tmp2}"
        mv "${tmp2}" "${tmp}"
        changed_json=1
        info "  ${GN}✓${CL} sharedStorage: added '${share_name}' at ${mount_point} (${access})"
    fi

    if [[ "${changed_json}" -eq 1 ]]; then
        mv "${tmp}" "${module_json}"
    else
        rm -f "${tmp}"
    fi

    # ── Nix: marker insertion (idempotent + parse-verified) ──────────
    if grep -q '# BEGIN cluster:storage' "${nix_file}"; then
        info "  ${nix_file} already has the cluster:storage marker — leaving as-is"
        info "${GN}✓${CL} ${vmname} wiring complete"
        return 0
    fi

    local backup last_brace_line
    backup="${nix_file}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "${nix_file}" "${backup}"

    last_brace_line="$(grep -n '^}$' "${nix_file}" | tail -1 | cut -d: -f1)"
    [[ -n "${last_brace_line}" ]] || die "wire-module: could not find a top-level closing brace ('}' alone on its own line) in ${nix_file} — add the marker manually (see cluster/DESIGN.md)"

    local tmp_nix
    tmp_nix="$(mktemp)"
    awk -v ln="${last_brace_line}" '
        NR == ln {
            print "  # BEGIN cluster:storage (managed by cluster:storage -- do not edit by hand)"
            print "  # END cluster:storage"
        }
        { print }
    ' "${nix_file}" > "${tmp_nix}"
    mv "${tmp_nix}" "${nix_file}"

    if command -v nix-instantiate >/dev/null 2>&1; then
        if ! nix-instantiate --parse "${nix_file}" >/dev/null 2>&1; then
            cp -a "${backup}" "${nix_file}"
            die "wire-module: inserting the marker broke Nix syntax in ${nix_file} (restored from ${backup}) — add the marker manually (see cluster/DESIGN.md)"
        fi
        info "  ${GN}✓${CL} marker inserted into ${nix_file} (verified: nix-instantiate --parse passed)"
    else
        warn "  nix-instantiate not on PATH — marker inserted into ${nix_file} but NOT syntax-verified. Check it manually."
    fi

    info "${GN}✓${CL} ${vmname} wiring complete — run install-module.sh/update-module.sh ${vmname} to apply"
}

cmd_add() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "add: share name is required"
    shift || true

    local node="" tank="" quota="" backup=0 layout=""
    local keep_daily=7 keep_weekly=4 keep_monthly=6 keep_yearly=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node)          node="$2"; shift 2 ;;
            --tank)          tank="$2"; shift 2 ;;
            --quota)         quota="$2"; shift 2 ;;
            --backup)        backup=1; shift ;;
            --layout)        layout="$2"; shift 2 ;;
            --keep-daily)    keep_daily="$2"; shift 2 ;;
            --keep-weekly)   keep_weekly="$2"; shift 2 ;;
            --keep-monthly)  keep_monthly="$2"; shift 2 ;;
            --keep-yearly)   keep_yearly="$2"; shift 2 ;;
            *) die "add: unknown flag '$1'" ;;
        esac
    done
    [[ -n "${node}" ]] || die "add: --node is required"
    [[ -n "${tank}" ]] || die "add: --tank is required"
    reject_single_quote "--node" "${node}"
    reject_single_quote "--tank" "${tank}"
    reject_single_quote "--layout" "${layout}"

    ensure_shares_file
    share_exists "${name}" && die "Share '${name}' already exists (in ${SHARES_FILE})"

    local node_fqdn="${node}.mgmt.internal"
    local dataset_path="${tank}/${name}"
    local export_path="/${dataset_path}"

    # Ensure the node can actually serve this export to consumer service
    # zones before provisioning anything — idempotent, safe to re-run.
    "${SCRIPT_DIR}/config-storage-zone.sh" "${node}"

    info "Provisioning local share '${name}' on ${node} (${dataset_path})"

    ssh -o BatchMode=yes "root@${node_fqdn}" \
        "dpkg -s nfs-kernel-server >/dev/null 2>&1 || apt-get install -y nfs-kernel-server"

    ssh -o BatchMode=yes "root@${node_fqdn}" \
        "zfs list '${dataset_path}' >/dev/null 2>&1 || zfs create '${dataset_path}'"

    if [[ -n "${quota}" ]]; then
        ssh -o BatchMode=yes "root@${node_fqdn}" "zfs set quota='${quota}' '${dataset_path}'"
    fi

    if [[ -n "${layout}" ]]; then
        local mountpoint
        mountpoint="$(ssh -o BatchMode=yes "root@${node_fqdn}" "zfs get -H -o value mountpoint '${dataset_path}'")"
        local -a layout_paths
        IFS=',' read -ra layout_paths <<< "${layout}"
        local p
        for p in "${layout_paths[@]}"; do
            # 1777 (world rwx + sticky, like /tmp): shares are consumed by
            # multiple modules, each running its own unprivileged service
            # account (uid/gid not coordinated across VMs) — root:root 755
            # would let only root write, defeating the point of a share
            # multiple non-root modules write into. Sticky bit still stops
            # one module's account from deleting another's files it doesn't own.
            ssh -o BatchMode=yes "root@${node_fqdn}" "mkdir -p '${mountpoint}/${p}' && chmod 1777 '${mountpoint}/${p}'"
        done
    fi

    ssh -o BatchMode=yes "root@${node_fqdn}" \
        "grep -qF '${export_path} ' /etc/exports 2>/dev/null || echo '${export_path}  ${EXPORT_ACL_SUPERNET}(rw,no_subtree_check,no_root_squash)' >> /etc/exports"
    ssh -o BatchMode=yes "root@${node_fqdn}" "exportfs -ra"

    local backup_json="false"
    [[ "${backup}" -eq 1 ]] && backup_json="true"

    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" --arg node "${node}" --arg tank "${tank}" \
        --arg quota "${quota}" --argjson backup "${backup_json}" \
        '.[$n] = {type: "local", node: $node, tank: $tank, dataset: ($n), quota: $quota, backup: $backup}' \
        "${SHARES_FILE}" > "${tmp}"
    mv "${tmp}" "${SHARES_FILE}"

    if [[ "${backup}" -eq 1 ]]; then
        provision_share_backup "${name}" "${node}" "${tank}" \
            "${keep_daily}" "${keep_weekly}" "${keep_monthly}" "${keep_yearly}"
    fi

    info "${GN}✓${CL} Share '${name}' provisioned"
}

cmd_add_external() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "add-external: share name is required"
    shift || true

    local host="" export_path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)   host="$2"; shift 2 ;;
            --export) export_path="$2"; shift 2 ;;
            *) die "add-external: unknown flag '$1'" ;;
        esac
    done
    [[ -n "${host}" ]] || die "add-external: --host is required"
    [[ -n "${export_path}" ]] || die "add-external: --export is required"
    reject_single_quote "--host" "${host}"
    reject_single_quote "--export" "${export_path}"

    ensure_shares_file
    share_exists "${name}" && die "Share '${name}' already exists (in ${SHARES_FILE})"

    if command -v showmount >/dev/null 2>&1; then
        showmount -e "${host}" 2>/dev/null | grep -qF "${export_path}" \
            || warn "  ${export_path} not seen in ${host}'s export list — continuing anyway"
    fi

    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" --arg host "${host}" --arg export "${export_path}" \
        '.[$n] = {type: "external", host: $host, export: $export, backup: false}' \
        "${SHARES_FILE}" > "${tmp}"
    mv "${tmp}" "${SHARES_FILE}"

    info "${GN}✓${CL} External share '${name}' registered (${host}:${export_path})"
}

cmd_remove() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "remove: share name is required"
    ensure_shares_file
    share_exists "${name}" || die "Share '${name}' not found"

    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" 'del(.[$n])' "${SHARES_FILE}" > "${tmp}"
    mv "${tmp}" "${SHARES_FILE}"
    info "${GN}✓${CL} Share '${name}' removed from the registry (export/dataset left untouched — clean up manually if desired)"
}

cmd_list() {
    ensure_shares_file
    jq -r 'to_entries[] | "\(.key): \(.value | tostring)"' "${SHARES_FILE}"
}

cmd_resize() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "resize: share name is required"
    shift || true
    local quota=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quota) quota="$2"; shift 2 ;;
            *) die "resize: unknown flag '$1'" ;;
        esac
    done
    [[ -n "${quota}" ]] || die "resize: --quota is required"

    ensure_shares_file
    share_exists "${name}" || die "Share '${name}' not found"

    local node tank
    node="$(jq -r --arg n "${name}" '.[$n].node' "${SHARES_FILE}")"
    tank="$(jq -r --arg n "${name}" '.[$n].tank' "${SHARES_FILE}")"
    [[ "${node}" != "null" ]] || die "resize: '${name}' is an external share, not resizable here"

    ssh -o BatchMode=yes "root@${node}.mgmt.internal" "zfs set quota='${quota}' '${tank}/${name}'"
    update_share_field "${name}" "quota" "${quota}"
    info "${GN}✓${CL} Share '${name}' resized to ${quota}"
}

cmd_update() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "update: share name is required"
    shift || true
    local node="" host=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) node="$2"; shift 2 ;;
            --host) host="$2"; shift 2 ;;
            *) die "update: unknown flag '$1'" ;;
        esac
    done

    ensure_shares_file
    share_exists "${name}" || die "Share '${name}' not found"

    if [[ -n "${node}" ]]; then
        update_share_field "${name}" "node" "${node}"
        info "${GN}✓${CL} Share '${name}' node updated to ${node}"
    fi
    if [[ -n "${host}" ]]; then
        update_share_field "${name}" "host" "${host}"
        info "${GN}✓${CL} Share '${name}' host updated to ${host}"
    fi
}

cmd_backup() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "backup: share name is required"
    shift || true

    local enable=0 disable=0
    local keep_daily=7 keep_weekly=4 keep_monthly=6 keep_yearly=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --enable)       enable=1; shift ;;
            --disable)      disable=1; shift ;;
            --keep-daily)   keep_daily="$2"; shift 2 ;;
            --keep-weekly)  keep_weekly="$2"; shift 2 ;;
            --keep-monthly) keep_monthly="$2"; shift 2 ;;
            --keep-yearly)  keep_yearly="$2"; shift 2 ;;
            *) die "backup: unknown flag '$1'" ;;
        esac
    done
    [[ "${enable}" -eq 1 || "${disable}" -eq 1 ]] || die "backup: --enable or --disable is required"
    [[ "${enable}" -eq 1 && "${disable}" -eq 1 ]] && die "backup: --enable and --disable are mutually exclusive"

    ensure_shares_file
    share_exists "${name}" || die "Share '${name}' not found"

    local node tank
    node="$(jq -r --arg n "${name}" '.[$n].node' "${SHARES_FILE}")"
    tank="$(jq -r --arg n "${name}" '.[$n].tank' "${SHARES_FILE}")"
    [[ "${node}" != "null" ]] || die "backup: '${name}' is an external share — backup is the NAS's own concern, not managed here"

    if [[ "${enable}" -eq 1 ]]; then
        provision_share_backup "${name}" "${node}" "${tank}" \
            "${keep_daily}" "${keep_weekly}" "${keep_monthly}" "${keep_yearly}"
        update_share_bool_field "${name}" "backup" "true"
    else
        disable_share_backup_schedule "${name}" "${node}"
        update_share_bool_field "${name}" "backup" "false"
    fi
}

main() {
    local cmd="${1:-}"
    [[ -n "${cmd}" ]] || { usage; exit 1; }
    shift || true

    case "${cmd}" in
        init-zone)    cmd_init_zone "$@" ;;
        wire-module)  cmd_wire_module "$@" ;;
        add)          cmd_add "$@" ;;
        add-external) cmd_add_external "$@" ;;
        remove)       cmd_remove "$@" ;;
        list)         cmd_list "$@" ;;
        resize)       cmd_resize "$@" ;;
        update)       cmd_update "$@" ;;
        backup)       cmd_backup "$@" ;;
        -h|--help)    usage; exit 0 ;;
        *) error "Unknown command: ${cmd}"; usage; exit 1 ;;
    esac
}

main "$@"
