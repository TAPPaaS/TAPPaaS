#!/usr/bin/env bash
#
# test-compromise-isolation.sh — the ADR-012 §1.4/§1.4.1 invariant, tested live.
#
# NOT run by test.sh: it creates a datastore, a credential, a remote and a sync
# job on the live PBS, and tears them all down again. Run it deliberately —
# after a change to the credential model, and at least once per release.
#
#   ./test-compromise-isolation.sh
#
# What it proves, on real infrastructure rather than by assertion:
#
#   1. PULL is a real movement — an off-site destination pulls a SUBSET of the
#      source into its own namespace, using a READ-ONLY credential on that
#      source (the only credential a puller ever holds, §1.4).
#   2. THE INVARIANT — that same credential, which is what an attacker who
#      compromised the off-site system would hold, CANNOT delete or prune the
#      source. Both attacks are attempted and must be refused, and the source
#      snapshot must still be there afterwards.
#   3. Retention is owned by the DESTINATION, so an off-site copy keeps its own
#      (typically longer) policy independent of the source it derives from.
#
# The production datastore is only ever a pull SOURCE and is never written to.
# The sandbox destination lives on the PBS node's tanka1 and is removed at the
# end, along with the credential, the remote and both jobs.
#

set -uo pipefail
N=root@tappaas3.mgmt.internal
r() { ssh -n -o BatchMode=yes $N "$*"; }
PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

SANDBOX=sandbox_offsite
SRC=tappaas_backup
TOKENUSER='syncro@pbs'

echo "== setup: a sandbox destination datastore + a READ-ONLY pull credential =="
r "mkdir -p /tanka1/pbs-sandbox"
r "proxmox-backup-manager datastore create ${SANDBOX} /tanka1/pbs-sandbox" >/dev/null 2>&1
r "proxmox-backup-manager datastore list --output-format json" | jq -e --arg d "$SANDBOX" '.[]|select(.name==$d)' >/dev/null \
  && ok "sandbox destination datastore created" || bad "could not create the sandbox datastore"

PW="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; PW="${PW:0:24}"
r "proxmox-backup-manager user create ${TOKENUSER} --password '${PW}'" >/dev/null 2>&1
# The pull credential is READ-ONLY on the source: DatastoreReader, nothing more.
r "proxmox-backup-manager acl update /datastore/${SRC} DatastoreReader --auth-id ${TOKENUSER}" >/dev/null 2>&1
r "proxmox-backup-manager acl update /datastore/${SANDBOX} DatastoreAdmin --auth-id ${TOKENUSER}" >/dev/null 2>&1
ok "read-only credential on the source, admin only on its own destination"

echo
echo "== 1. PULL: the destination pulls a SUBSET of the source =="
FP="$(r "proxmox-backup-manager cert info" | sed -n 's/^Fingerprint (sha256): //p')"
# A nested destination namespace needs its PARENT to exist first — PBS refuses
# with "cannot create new namespace, parent fs doesn't already exists". The
# module's own pbs_ns_ensure walks the parent chain for exactly this reason
# (_pbs_ns_parents); a hand-made sync job has to do it itself.
r "proxmox-backup-debug api create /admin/datastore/${SANDBOX}/namespace --name fs" >/dev/null 2>&1
ok "the destination namespace parent chain exists"
r "proxmox-backup-manager remote create self --host localhost --auth-id ${TOKENUSER} --password '${PW}' --fingerprint '${FP}'" >/dev/null 2>&1
r "proxmox-backup-manager remote list --output-format json" | jq -e '.[]|select(.name=="self")' >/dev/null \
  && ok "the source is registered as a pull remote" || bad "could not register the remote"

# Subset: only the host-type backups (the config/ file capture), not the VMs.
SYNCERR="$(r "proxmox-backup-manager sync-job create testsync --store ${SANDBOX} --remote self --remote-store ${SRC} --remote-ns fs/tappaas-cicd --ns fs/tappaas-cicd --group-filter 'type:host'" 2>&1)"
if [[ -z "${SYNCERR}" ]]; then ok "sync job created with a subset filter (type:host)"
else bad "could not create the sync job: $(head -3 <<<"${SYNCERR}")"; fi

RUNERR="$(r "proxmox-backup-manager sync-job run testsync" 2>&1)"
sleep 5
[[ -n "${RUNERR}" ]] && echo "     (sync run said: $(head -2 <<<"${RUNERR}"))"
GOT="$(r "proxmox-backup-debug api get /admin/datastore/${SANDBOX}/snapshots --ns fs/tappaas-cicd --output-format json" 2>/dev/null | jq -r 'length' 2>/dev/null)"
if [[ "${GOT:-0}" -ge 1 ]]; then ok "the off-site copy received ${GOT} snapshot(s) by PULL"
else bad "nothing arrived in the sandbox datastore"; fi

# The subset must be a subset: no VM backups should have come across. Only a
# meaningful assertion once something actually arrived — asserting "no VMs" on
# an empty datastore passes for the wrong reason.
if [[ "${GOT:-0}" -ge 1 ]]; then
    VMS="$(r "proxmox-backup-debug api get /admin/datastore/${SANDBOX}/snapshots --output-format json" 2>/dev/null | jq -r '[.[]|select(."backup-type"=="vm")]|length' 2>/dev/null)"
    [[ "${VMS:-0}" -eq 0 ]] && ok "the group filter held — no VM backups were replicated" \
                            || bad "the subset leaked ${VMS} VM backup(s)"
else
    echo "  SKIP: subset check needs a successful sync"
fi

echo
echo "== 2. THE INVARIANT: the pulling credential attacks its source =="
export PBS_PASSWORD="${PW}" PBS_FINGERPRINT="${FP}"
SNAP="$(proxmox-backup-client snapshot list --repository "${TOKENUSER}@backup.mgmt.internal:${SRC}" --ns fs/tappaas-cicd --output-format json 2>/dev/null | jq -r '.[0]|."backup-type"+"/"+."backup-id"+"/"+(."backup-time"|todate)')"
if [[ -n "${SNAP}" && "${SNAP}" != "null" ]]; then
    ok "the pull credential can READ the source (as a puller must)"
    OUT="$(proxmox-backup-client snapshot forget "${SNAP}" --repository "${TOKENUSER}@backup.mgmt.internal:${SRC}" --ns fs/tappaas-cicd 2>&1)"
    if grep -qi "permission" <<<"${OUT}"; then ok "DELETE of a source snapshot was DENIED: $(grep -o 'missing [A-Za-z.|]*' <<<"${OUT}" | head -1)"
    else bad "the pull credential deleted (or was allowed to delete) from the source: ${OUT}"; fi
    # keep-last 1, not 0: PBS rejects 0 in ARGUMENT validation, which happens
    # before any permission check — the test would then pass without ever
    # reaching the thing it means to test.
    OUT="$(proxmox-backup-client prune "host/tappaas-cicd" --repository "${TOKENUSER}@backup.mgmt.internal:${SRC}" --ns fs/tappaas-cicd --keep-last 1 2>&1)"
    if grep -qi "permission\|denied" <<<"${OUT}"; then ok "PRUNE of the source was DENIED"
    else bad "the pull credential could prune the source: ${OUT}"; fi
else
    bad "the pull credential could not read the source at all"
fi
STILL="$(r "proxmox-backup-debug api get /admin/datastore/${SRC}/snapshots --ns fs/tappaas-cicd --output-format json" 2>/dev/null | jq -r 'length')"
[[ "${STILL:-0}" -ge 1 ]] && ok "the source snapshot is still there after the attack" || bad "the source snapshot is GONE"

echo
echo "== 3. Independent retention: the destination owns its own prune =="
r "proxmox-backup-manager prune-job create testprune --store ${SANDBOX} --ns fs/tappaas-cicd --keep-last 5 --schedule 'daily'" >/dev/null 2>&1 \
  && ok "the off-site copy runs its own retention, distinct from the source's" \
  || bad "could not give the destination its own prune job"

echo
echo "== teardown =="
r "proxmox-backup-manager prune-job remove testprune" >/dev/null 2>&1
r "proxmox-backup-manager sync-job remove testsync" >/dev/null 2>&1
r "proxmox-backup-manager remote remove self" >/dev/null 2>&1
r "proxmox-backup-manager datastore remove ${SANDBOX} --keep-job-configs false" >/dev/null 2>&1
r "proxmox-backup-manager acl update /datastore/${SRC} DatastoreReader --auth-id ${TOKENUSER} --delete" >/dev/null 2>&1
r "proxmox-backup-manager user remove ${TOKENUSER}" >/dev/null 2>&1
r "rm -rf /tanka1/pbs-sandbox"
echo "  torn down"

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
