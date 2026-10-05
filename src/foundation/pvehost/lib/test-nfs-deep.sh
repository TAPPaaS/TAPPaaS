#!/usr/bin/env bash
#
# test-nfs-deep.sh — the pvehost:nfs end-to-end suite (ADR-029 v0.8), run by
# `pvehost/test.sh <node> --deep` against a real node of the running site.
#
# Brings its own consumer (the fixture module ../test-nfsconsumer: a disposable
# NixOS clone in a service zone, with a writer unit holding a file open), uses a
# throwaway share `nfsdeeptest` (1G quota) and edits node configs it backs up and
# restores. Every step asserts; the teardown runs on any exit — also when a step
# fails — and a leftover check fails the run if anything remains.
#
#   1 pending      the share is undeclared: the install succeeds, the directory is
#                  local, the fragment has no entry, validate warns, no rule
#   2 not granted  the share exists without the grant: validate and the service refuse
#   3 granted      the node builds it at /tappaas-nfs/<share>, the alias follows the
#                  node, the consumer's update runs and — without consent — waits
#   4 guard        a holder outside stopUnits: the migration aborts, nothing changes
#   5 migration    with consent: two passes, the writer stopped and started, the
#                  directory mounted through the alias, files owned by the owner
#   6 healthy      a rebuild keeps the mount; the next update removes .pre-nfs
#   7 subdir       the second mount: its own subdir, owned by the owner, mounted
#   8 firewall     one rule, to the share alias; the client list holds only the consumer
#   9 delete gap   the consumer's delete takes its address out of the client list at
#                  once (D16); reinstalling the mounts puts it back
#  10 move         the share is sent to another node and redeclared there: the alias
#                  follows it, and the consumer mounts it with its config unchanged
#  11 gone         a migrated share that is undeclared: the service errors, no fallback
#  12 teardown     always; then the leftover check
#
# Usage: test-nfs-deep.sh <node-instance>     (exit 0 = all passed)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/pvehost-lib.sh"
. "${HERE}/nfs-lib.sh"
. "${HERE}/nfs-guest.sh"

NODE="${1:?usage: test-nfs-deep.sh <node-instance>}"
SHARE="nfsdeeptest"
FIX="test-nfsconsumer"
SVC="${HERE}/../services/nfs"
CFG="${CONFIG_DIR:-/home/tappaas/config}"
WORK="$(mktemp -d)"
PASS=0; FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }
ok()   { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }
step() { info "${BOLD}── $1${CL}"; }

node_ssh()  { ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR "root@$(nfs_instance_address_of "$1")" "${@:2}"; }
# node_ssh_in — the same, reading stdin: the receiving end of a zfs send pipe.
node_ssh_in() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR "root@$(nfs_instance_address_of "$1")" "${@:2}"; }
nfs_instance_address_of() { jq -r '.address // empty' "${CFG}/$1.json"; }
guest()     { tappaas_ssh_guest -o BatchMode=yes -o ConnectTimeout=15 "tappaas@${FIX}.${ZONE}.internal" "$@"; }
fw()        { ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR -i /home/tappaas/.ssh/tappaas-fw root@firewall.mgmt.internal "$@"; }
set_export() {   # set_export <node> <json-or-null>: replace the test share's declaration
    local f="${CFG}/$1.json" tmp
    tmp="$(mktemp "${f}.XXXX")"
    jq --arg n "${SHARE}" --argjson e "$2" \
       '.nfs.exports = ([.nfs.exports // [] | .[] | select(.name != $n)] + (if $e == null then [] else [$e] end))' \
       "${f}" > "${tmp}" && mv "${tmp}" "${f}"
}
dataset_on() { echo "$2/${NFS_PARENT}/${SHARE}"; }
pool_on() {      # tankb1 when the node has it, else its first pool
    local pools; pools="$(node_ssh "$1" "zpool list -H -o name")"
    grep -qx tankb1 <<< "${pools}" && echo tankb1 || head -1 <<< "${pools}"
}

# ── preconditions and choices ─────────────────────────────────────────
pn_load "${NODE}"
[[ -z "$(nfs_share_servers "${SHARE}")" ]] || { error "a share named ${SHARE} is already declared — refusing to run"; exit 1; }
[[ ! -f "${CFG}/${FIX}.json" ]] || { error "${FIX} is already installed — a previous run left it; delete it first"; exit 1; }
POOL="$(pool_on "${NODE}")"
ZONE="$(jq -r 'to_entries[] | select(.value|type=="object") | select(.value.type=="Service" and .value.state=="Active") | .key' "${CFG}/zones.json" | head -1)"
[[ -n "${ZONE}" ]] || { error "no Active Service zone to put the consumer in"; exit 1; }
mapfile -t NODES < <(jq -r '.hardware.nodes[]?.name' "${CFG}/site.json")
CNODE="${NODE}"; NODE2=""
for n in "${NODES[@]}"; do [[ "${n}" != "${NODE}" ]] && { CNODE="${n}"; break; }; done
for n in "${NODES[@]}"; do [[ "${n}" != "${NODE}" && -f "${CFG}/${n}.json" ]] && { NODE2="${n}"; break; }; done
VMID=""; used="$(for n in "${NODES[@]}"; do node_ssh "${n}" "qm list 2>/dev/null | awk 'NR>1{print \$1}'" 2>/dev/null; done)"
for v in $(seq 990 999); do grep -qx "${v}" <<< "${used}" || { VMID="${v}"; break; }; done
[[ -n "${VMID}" ]] || { error "no free VMID in 990-999"; exit 1; }
info "${BOLD}pvehost:nfs deep suite${CL}: share ${SHARE} on ${NODE}:${POOL}, consumer ${FIX} (vmid ${VMID}) on ${CNODE} in ${ZONE}${NODE2:+, move target ${NODE2}}"

declare -A HAD_NFSD=() TOUCHED=()
for n in "${NODE}" ${NODE2}; do
    cp -p "${CFG}/${n}.json" "${WORK}/${n}.json.orig"; TOUCHED["${n}"]=1
    node_ssh "${n}" "dpkg-query -W -f='\${Status}' nfs-kernel-server 2>/dev/null | grep -q 'install ok installed'" && HAD_NFSD["${n}"]=1
done

# ── 12 teardown, on any exit ──────────────────────────────────────────
teardown() {
    step "12 teardown"
    [[ -f "${CFG}/${FIX}.json" ]] && /home/tappaas/bin/delete-module.sh "${FIX}" --force >/dev/null 2>&1
    dns-manager --no-ssl-verify delete "${FIX}" "${ZONE}.internal" >/dev/null 2>&1
    local n p
    for n in "${!TOUCHED[@]}"; do
        cp -p "${WORK}/${n}.json.orig" "${CFG}/${n}.json"
        p="$(pool_on "${n}")"
        # Unshare, and let nfsd let go, before the destroy: a dataset nfsd still
        # holds is "busy" and survives.
        node_ssh "${n}" "zfs set sharenfs=off '$(dataset_on "${n}" "${p}")' 2>/dev/null; exportfs -ra 2>/dev/null; sleep 2;
            zfs destroy -r '$(dataset_on "${n}" "${p}")' 2>/dev/null;
            zfs list -H -o name -r '${p}/${NFS_PARENT}' 2>/dev/null | grep -q /${NFS_PARENT}/ || zfs destroy '${p}/${NFS_PARENT}' 2>/dev/null;
            rmdir '/tappaas-nfs/${SHARE}' /tappaas-nfs 2>/dev/null; true"
        if [[ -z "${HAD_NFSD[${n}]:-}" && -z "$(nfs_exports "${n}")" ]]; then
            # /etc/nfs.conf.d belongs to nfs-common, which every node has: only
            # our file goes. /etc/exports.d is libshare's, made for our share.
            node_ssh "${n}" "systemctl stop nfs-server 2>/dev/null; DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq nfs-kernel-server >/dev/null 2>&1;
                apt-get autoremove -y -qq >/dev/null 2>&1; rm -f /etc/nfs.conf.d/tappaas.conf /etc/exports.d/zfs.exports /etc/exports.d/zfs.exports.lock;
                rmdir /etc/exports.d 2>/dev/null; true"
        fi
    done
    dns-manager --no-ssl-verify alias delete "$(nfs_share_alias "${SHARE}")" >/dev/null 2>&1
    rules-manager --no-ssl-verify remove-alias "nfs_share_${SHARE}" >/dev/null 2>&1
    ssh -o BatchMode=yes -i /home/tappaas/.ssh/tappaas-fw root@firewall.mgmt.internal "sh -s" >/dev/null 2>&1 <<EOF
for t in tm_${FIX//-/_} nfs_share_${SHARE}; do pfctl -t \$t -T kill; rm -f /var/db/aliastables/\$t.*; done
EOF
    step "leftover check"
    local left=0
    [[ -f "${CFG}/${FIX}.json" ]] && { fail "leftover: config/${FIX}.json"; left=1; }
    for n in "${NODES[@]}"; do
        node_ssh "${n}" "qm status ${VMID}" >/dev/null 2>&1 && { fail "leftover: VM ${VMID} on ${n}"; left=1; }
    done
    for n in "${!TOUCHED[@]}"; do
        cmp -s "${WORK}/${n}.json.orig" "${CFG}/${n}.json" || { fail "leftover: config/${n}.json differs from before"; left=1; }
        node_ssh "${n}" "zfs list -H -o name -r 2>/dev/null | grep -q '/${NFS_PARENT}/${SHARE}\$'" && { fail "leftover: a ${SHARE} dataset on ${n}"; left=1; }
        if [[ -z "${HAD_NFSD[${n}]:-}" && -z "$(nfs_exports "${n}")" ]]; then
            node_ssh "${n}" "dpkg-query -W -f='\${Status}' nfs-kernel-server 2>/dev/null | grep -q 'install ok installed'" \
                && { fail "leftover: nfs-kernel-server on ${n} (the suite installed it)"; left=1; }
        fi
    done
    dns-manager --no-ssl-verify alias list 2>/dev/null | grep -q "$(nfs_share_alias "${SHARE}")" && { fail "leftover: the share alias"; left=1; }
    rules-manager --no-ssl-verify list-rules 2>/dev/null | grep -q "tappaas-module:${FIX}:" && { fail "leftover: firewall rules of ${FIX}"; left=1; }
    for n in "${NODES[@]}"; do
        node_ssh "${n}" "dpkg-query -W -f='\${Status}' nfs-common 2>/dev/null | grep -q 'install ok installed' && ! test -d /etc/nfs.conf.d" \
            && { fail "leftover: /etc/nfs.conf.d (nfs-common's) missing on ${n}"; left=1; }
        node_ssh "${n}" "test -e /tappaas-nfs/${SHARE}" && { fail "leftover: /tappaas-nfs/${SHARE} on ${n}"; left=1; }
    done
    [[ "$(fw "ls /var/db/aliastables" 2>/dev/null | grep -cE "^(nfs_share_${SHARE}|tm_${FIX//-/_})\.")" -eq 0 ]] \
        || { fail "leftover: OPNsense alias cache files"; left=1; }
    [[ "${left}" -eq 0 ]] && pass "nothing left behind"
    rm -rf "${WORK}"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    [[ "${FAIL}" -eq 0 ]]
}
trap 'teardown; exit $?' EXIT

# ── 1 pending ─────────────────────────────────────────────────────────
step "1 pending — install with the share undeclared"
mkdir -p "${WORK}/fixture/${FIX}"
cp "${HERE}/../${FIX}/"* "${WORK}/fixture/${FIX}/"
jq --argjson v "${VMID}" --arg n "${CNODE}" --arg z "${ZONE}" '.vmid = $v | .node = $n | .zone0 = $z' \
    "${HERE}/../${FIX}/${FIX}.json" > "${WORK}/fixture/${FIX}/${FIX}.json"
( cd "${WORK}/fixture/${FIX}" && /home/tappaas/bin/install-module.sh "${FIX}" ) > "${WORK}/install.log" 2>&1
if [[ ! -f "${CFG}/${FIX}.json" ]]; then
    # Nothing after this can run without the consumer; stop here and tear down
    # rather than let every later step time out against a VM that is gone.
    fail "the consumer installs with its share undeclared — the rest is skipped:"
    grep -E "Error|✗" "${WORK}/install.log" | head -5 | sed 's/^/      /' >&2
    exit 1
fi
pass "the consumer installs with its share undeclared"
grep -q "pending" "${WORK}/install.log" && pass "the install reports the mount pending" || fail "the install reports the mount pending"
( cd "${WORK}/fixture/${FIX}" && /home/tappaas/bin/update-os.sh "${FIX}" "${VMID}" "${CNODE}" ) > "${WORK}/rebuild1.log" 2>&1 \
    || fail "rebuild after install (see ${WORK}/rebuild1.log)"
guest "for i in \$(seq 1 20); do echo seed-\$i | sudo tee /srv/deep/a/seed-\$i >/dev/null; done"
ok "the directory is local and holds data" "guest 'test -f /srv/deep/a/seed-1 && ! findmnt -n --mountpoint /srv/deep/a'"
ok "the fragment carries NFS support but no entry for a pending mount" \
   "guest 'grep -q supportedFilesystems ${NFS_GUEST_FRAGMENT} && ! grep -q /srv/deep/a ${NFS_GUEST_FRAGMENT}'"
ok "the guest can mount NFS for a later migration" "guest 'command -v mount.nfs && command -v rsync'"
module-manager validate "${FIX}" > "${WORK}/validate1.log" 2>&1; vrc=$?
[[ "${vrc}" -eq 0 ]] && grep -q "pending" "${WORK}/validate1.log" && pass "validate warns pending, passes" || fail "validate warns pending, passes (rc ${vrc})"
rules-manager --no-ssl-verify list-rules 2>/dev/null | grep -q "tappaas-module:${FIX}:egress:alias:nfs_share" \
    && fail "a pending mount has no firewall rule" || pass "a pending mount has no firewall rule"

# ── 2 not granted ─────────────────────────────────────────────────────
step "2 not granted — the share exists without the grant"
set_export "${NODE}" "{\"name\":\"${SHARE}\",\"pool\":\"${POOL}\",\"quota\":\"1G\",\"backup\":{\"enabled\":false},\"grants\":[]}"
module-manager validate "${FIX}" > "${WORK}/validate2.log" 2>&1 && fail "validate refuses the ungranted share" || pass "validate refuses the ungranted share"
"${SVC}/update-service.sh" "${FIX}" > "${WORK}/svc2.log" 2>&1 && fail "the service refuses the ungranted share" \
    || { grep -q "grants ${FIX} nothing" "${WORK}/svc2.log" && pass "the service refuses, printing the grant to add" || fail "the service refuses, printing the grant to add"; }

# ── 3 granted, no consent ─────────────────────────────────────────────
step "3 granted — the node builds the share, the consumer waits for consent"
set_export "${NODE}" "{\"name\":\"${SHARE}\",\"pool\":\"${POOL}\",\"quota\":\"1G\",\"backup\":{\"enabled\":false},\"grants\":[{\"consumer\":\"${FIX}\",\"access\":\"rw\"}]}"
TAPPAAS_ALLOW_DISRUPTION="" bash "${HERE}/../update.sh" "${NODE}" > "${WORK}/node3.log" 2>&1 || fail "the node's update (see ${WORK}/node3.log)"
DS="$(dataset_on "${NODE}" "${POOL}")"
ok "the dataset is at /tappaas-nfs/${SHARE}" "[ \"\$(node_ssh '${NODE}' 'zfs get -H -o value mountpoint ${DS}')\" = '/tappaas-nfs/${SHARE}' ]"
ok "the share alias follows ${NODE}" "dns-manager --no-ssl-verify alias list | grep -q '$(nfs_share_alias "${SHARE}") *-> *$(nfs_instance_address_of "${NODE}")'"
grep -q "migration pending" "${WORK}/node3.log" && pass "the node ran the consumer's update; without consent it waits" || fail "the node ran the consumer's update; without consent it waits"
ok "the directory is still local" "guest '! findmnt -n --mountpoint /srv/deep/a && test -f /srv/deep/a/seed-1'"
rules-manager --no-ssl-verify reconcile "${FIX}" > "${WORK}/rules3.log" 2>&1 || fail "rules-manager reconcile (see ${WORK}/rules3.log)"

# ── 4 the open-files guard ────────────────────────────────────────────
step "4 guard — a holder outside stopUnits stops the migration"
guest "sudo bash -c 'nohup sleep 900 < /srv/deep/a/seed-1 >/dev/null 2>&1 &'"
TAPPAAS_ALLOW_DISRUPTION=1 NFS_NO_REVERSE=1 "${SVC}/update-service.sh" "${FIX}" > "${WORK}/svc4.log" 2>&1
grep -q "open-files guard" "${WORK}/svc4.log" && pass "the guard aborts and names the holder" || fail "the guard aborts and names the holder"
ok "nothing changed: local data, writer running" "guest '! findmnt -n --mountpoint /srv/deep/a && test -f /srv/deep/a/seed-20 && systemctl is-active -q nfs-deep-writer'"
guest "sudo pkill -f 'sleep 900'"

# ── 5 migration ───────────────────────────────────────────────────────
step "5 migration — with consent"
TAPPAAS_ALLOW_DISRUPTION=1 NFS_NO_REVERSE=1 "${SVC}/update-service.sh" "${FIX}" > "${WORK}/svc5.log" 2>&1 || fail "the migrating update (see ${WORK}/svc5.log)"
SRC_A="$(nfs_share_alias "${SHARE}"):/tappaas-nfs/${SHARE}/a"
ok "/srv/deep/a is mounted through the alias" "[ \"\$(guest 'findmnt -n -t nfs,nfs4 -o SOURCE --mountpoint /srv/deep/a' | tail -1)\" = '${SRC_A}' ]"
ok "the seeded files are on the share" "guest 'test -f /srv/deep/a/seed-20' && node_ssh '${NODE}' 'test -f /tappaas-nfs/${SHARE}/a/seed-20'"
OWNER="$(jq -r --arg n "${SHARE}" '.nfs.exports[] | select(.name == $n) | .owner.uid' "${CFG}/${NODE}.json")"
ok "files on the node belong to the owner ${OWNER}" "[ \"\$(node_ssh '${NODE}' 'stat -c %u /tappaas-nfs/${SHARE}/a/seed-1')\" = '${OWNER}' ]"
ok "the local copy is kept as .pre-nfs" "guest 'test -d /srv/deep/a.pre-nfs'"
ok "the writer runs again, writing to the share" "guest 'systemctl is-active -q nfs-deep-writer' && sleep 12 && node_ssh '${NODE}' 'test -s /tappaas-nfs/${SHARE}/a/writer.log'"

# ── 6 healthy update ──────────────────────────────────────────────────
step "6 healthy — a rebuild keeps the mount; the next update removes .pre-nfs"
( cd "${WORK}/fixture/${FIX}" && /home/tappaas/bin/update-os.sh "${FIX}" "${VMID}" "${CNODE}" ) > "${WORK}/rebuild6.log" 2>&1 \
    || fail "rebuild after migration (see ${WORK}/rebuild6.log)"
guest "timeout 40 ls /srv/deep/a /srv/deep/b >/dev/null"
ok "the mount survives the rebuild and reboot" "[ \"\$(guest 'findmnt -n -t nfs,nfs4 -o SOURCE --mountpoint /srv/deep/a' | tail -1)\" = '${SRC_A}' ]"
NFS_NO_REVERSE=1 "${SVC}/update-service.sh" "${FIX}" > "${WORK}/svc6.log" 2>&1 || fail "the healthy update (see ${WORK}/svc6.log)"
ok ".pre-nfs is removed" "guest '! test -e /srv/deep/a.pre-nfs'"
"${SVC}/test-service.sh" "${FIX}" > "${WORK}/test6.log" 2>&1 && pass "the service's test passes" || fail "the service's test passes (see ${WORK}/test6.log)"

# ── 7 subdir ──────────────────────────────────────────────────────────
step "7 subdir — the second mount"
ok "subdir b exists, owned by the owner" "[ \"\$(node_ssh '${NODE}' 'stat -c %u /tappaas-nfs/${SHARE}/b')\" = '${OWNER}' ]"
ok "/srv/deep/b is mounted from subdir b" "[ \"\$(guest 'findmnt -n -t nfs,nfs4 -o SOURCE --mountpoint /srv/deep/b' | tail -1)\" = '$(nfs_share_alias "${SHARE}"):/tappaas-nfs/${SHARE}/b' ]"
guest "sudo touch /srv/deep/b/only-in-b"
ok "the subdirs are separate" "node_ssh '${NODE}' 'test -f /tappaas-nfs/${SHARE}/b/only-in-b && ! test -e /tappaas-nfs/${SHARE}/a/only-in-b'"

# ── 8 firewall and client list ────────────────────────────────────────
step "8 firewall — one rule to the alias; the client list holds only the consumer"
nrules="$(rules-manager --no-ssl-verify list-rules 2>/dev/null | grep -c "tappaas-module:${FIX}:egress:alias:nfs_share_${SHARE}:2049")"
[[ "${nrules}" -eq 1 ]] && pass "exactly one rule: ${FIX} → nfs_share_${SHARE}, tcp/2049" || fail "exactly one rule to the share alias (found ${nrules})"
CIP="$(getent ahostsv4 "${FIX}.${ZONE}.internal" | awk 'NR==1{print $1}')"
live="$(node_ssh "${NODE}" "zfs get -H -o value sharenfs ${DS}")"
[[ "${live}" == "rw=@${CIP}/32,"* && "$(grep -o '@[0-9.]*/32' <<< "${live}" | wc -l)" -eq 1 ]] \
    && pass "the client list is exactly ${CIP}" || fail "the client list is exactly ${CIP} (live: ${live})"
bash "${HERE}/../test.sh" "${NODE}" > "${WORK}/nodetest8.log" 2>&1 && pass "the node's test passes (alias, mountpoint, no drift)" \
    || fail "the node's test passes (see ${WORK}/nodetest8.log)"

# ── 9 the delete gap (D16) ────────────────────────────────────────────
step "9 delete gap — the consumer's delete takes its address out at once"
NFS_NO_REVERSE=1 "${SVC}/delete-service.sh" "${FIX}" > "${WORK}/del9.log" 2>&1
ok "after delete-service the export shares to nobody" "[ \"\$(node_ssh '${NODE}' 'zfs get -H -o value sharenfs ${DS}')\" = off ]"
TAPPAAS_ALLOW_DISRUPTION=1 NFS_NO_REVERSE=1 "${SVC}/install-service.sh" "${FIX}" > "${WORK}/inst9.log" 2>&1
( cd "${WORK}/fixture/${FIX}" && /home/tappaas/bin/update-os.sh "${FIX}" "${VMID}" "${CNODE}" ) > "${WORK}/rebuild9.log" 2>&1
guest "timeout 40 ls /srv/deep/a >/dev/null"
ok "reinstalling the mounts restores the client list and the mount" \
   "[ \"\$(node_ssh '${NODE}' 'zfs get -H -o value sharenfs ${DS}')\" != off ] && guest 'findmnt -n --mountpoint /srv/deep/a'"

# ── 10 move ───────────────────────────────────────────────────────────
if [[ -n "${NODE2}" ]]; then
    step "10 move — the share goes to ${NODE2}; the consumer's config does not change"
    POOL2="$(pool_on "${NODE2}")"
    before="$(md5sum "${CFG}/${FIX}.json" | cut -d' ' -f1)"
    guest "sudo systemctl stop nfs-deep-writer; sudo umount -l /srv/deep/a /srv/deep/b; true"
    e="$(jq -c --arg n "${SHARE}" '.nfs.exports[] | select(.name == $n) | .pool = "'"${POOL2}"'"' "${CFG}/${NODE}.json")"
    node_ssh "${NODE}" "zfs snapshot ${DS}@move && zfs send ${DS}@move" \
        | node_ssh_in "${NODE2}" "zfs list ${POOL2}/${NFS_PARENT} >/dev/null 2>&1 || zfs create -o sharenfs=off ${POOL2}/${NFS_PARENT};
            zfs recv -x sharenfs -o mountpoint=/tappaas-nfs/${SHARE} $(dataset_on "${NODE2}" "${POOL2}") && zfs destroy $(dataset_on "${NODE2}" "${POOL2}")@move" \
        || fail "zfs send/recv to ${NODE2}"
    set_export "${NODE}" null
    set_export "${NODE2}" "${e}"
    bash "${HERE}/../update.sh" "${NODE}" > "${WORK}/node10a.log" 2>&1 || fail "the old node's update (see ${WORK}/node10a.log)"
    NFS_NO_REVERSE=1 bash "${HERE}/../update.sh" "${NODE2}" > "${WORK}/node10b.log" 2>&1 || fail "the new node's update (see ${WORK}/node10b.log)"
    ok "the alias now follows ${NODE2}" "dns-manager --no-ssl-verify alias list | grep -q '$(nfs_share_alias "${SHARE}") *-> *$(nfs_instance_address_of "${NODE2}")'"
    # OPNsense caches a host alias's resolution for its TTL (300 s) and re-resolves
    # only after that, on its refresh: a consumer behind the firewall reaches a
    # moved share within about five minutes (ADR-029 D2b). Wait for it.
    N2IP="$(getent ahostsv4 "$(nfs_instance_address_of "${NODE2}")" | awk 'NR==1{print $1}')"
    t0=$SECONDS
    until fw "pfctl -t nfs_share_${SHARE} -T show" 2>/dev/null | grep -qw "${N2IP}"; do
        (( SECONDS - t0 > 600 )) && break
        fw "configctl filter refresh_aliases" >/dev/null 2>&1; sleep 15
    done
    if fw "pfctl -t nfs_share_${SHARE} -T show" 2>/dev/null | grep -qw "${N2IP}"; then
        pass "the firewall follows the alias to ${NODE2} after $(( SECONDS - t0 )) s"
    else
        fail "the firewall follows the alias to ${NODE2} within 10 minutes"
    fi
    guest "sudo systemctl reset-failed 'srv-deep-*' 2>/dev/null; sudo systemctl start nfs-deep-writer; timeout 60 ls /srv/deep/a >/dev/null"
    if guest 'findmnt -n --mountpoint /srv/deep/a && test -f /srv/deep/a/seed-20' >/dev/null 2>&1; then
        pass "the consumer mounts the moved share, its data intact"
    else
        fail "the consumer mounts the moved share, its data intact — diagnostics:"
        {
            echo "guest resolves: $(guest "getent hosts $(nfs_share_alias "${SHARE}")" 2>&1)"
            echo "guest mount units:"; guest "systemctl list-units --all --no-legend 'srv-deep-a*'; journalctl -n 15 --no-pager -u srv-deep-a.mount -u srv-deep-a.automount" 2>&1 | sed 's/^/    /'
            echo "guest manual mount:"; guest "sudo timeout 40 mount -t nfs -o vers=4.2 $(nfs_share_alias "${SHARE}"):/tappaas-nfs/${SHARE}/a /mnt 2>&1; sudo umount /mnt 2>/dev/null" 2>&1 | sed 's/^/    /'
            echo "${NODE2} exports:"; node_ssh "${NODE2}" "exportfs -s; zfs get -H -o value mountpoint,sharenfs $(dataset_on "${NODE2}" "${POOL2}"); systemctl is-active nfs-server" 2>&1 | sed 's/^/    /'
            echo "firewall alias table:"; ssh -o BatchMode=yes -i /home/tappaas/.ssh/tappaas-fw root@firewall.mgmt.internal "pfctl -t nfs_share_${SHARE} -T show" 2>&1 | sed 's/^/    /'
        } >&2
    fi
    ok "and reaches it on ${NODE2}" "node_ssh '${NODE2}' \"ss -tn state established '( sport = :2049 )' | grep -q '${CIP}:'\""
    [[ "$(md5sum "${CFG}/${FIX}.json" | cut -d' ' -f1)" == "${before}" ]] && pass "the consumer's config did not change" || fail "the consumer's config did not change"
    DS="$(dataset_on "${NODE2}" "${POOL2}")"; HOLDER="${NODE2}"
else
    info "  10 move: skipped — no second node instance"
    HOLDER="${NODE}"
fi

# ── 11 gone after migration ───────────────────────────────────────────
step "11 gone — the migrated share is undeclared"
set_export "${HOLDER}" null
NFS_NO_REVERSE=1 bash "${HERE}/../update.sh" "${HOLDER}" > "${WORK}/node11.log" 2>&1
NFS_NO_REVERSE=1 "${SVC}/update-service.sh" "${FIX}" > "${WORK}/svc11.log" 2>&1 \
    && fail "the service errors for a share that vanished under a mount" \
    || { grep -q "never a silent fallback" "${WORK}/svc11.log" && pass "the service errors; no fallback to a local directory" || fail "the service errors; no fallback to a local directory"; }

exit 0
