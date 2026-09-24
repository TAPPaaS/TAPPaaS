#!/usr/bin/env bash
# tappaas-collation-reconcile.sh — settle Postgres collation versions after a
# nixpkgs release move (#726, ADR-028 D8).
#
# THE PROBLEM. Postgres records the glibc VERSION STRING in
# pg_database.datcollversion and warns on every connection when the running
# glibc differs. It never compares collation BEHAVIOUR. So every release move
# makes every Postgres guest warn forever, whether or not text ordering
# actually changed — and a future glibc bump that genuinely reorders text would
# produce a warning indistinguishable from the benign one. The alarm gets stuck
# on, and then nobody hears the real one.
#
# WHY NOT JUST REFRESH. `ALTER DATABASE ... REFRESH COLLATION VERSION` only
# rewrites the recorded string. Run blind, it silences a real reordering: the
# indexes stay wrong, the warning stops, and a unique index quietly starts
# admitting duplicates. The refresh has to be EARNED.
#
# HOW IT IS EARNED. Per database, every btree index is verified against the
# CURRENT collation with amcheck's bt_index_check(heapallindexed => true),
# which raises on out-of-order entries. Indexes that verify cannot be
# mis-ordered under the collation in force, so the recorded version is safe to
# update. Indexes that do not verify are reported and the database is LEFT
# WARNING — a REINDEX is a data decision for a human, not for a sweep.
#
# Verified on the test site 2026-09-24 (the release move that prompted this):
# 727 indexes on `nextcloud`, 0 errors, and independently the 2.40 -> 2.42
# ordering was shown identical over 60k strings. Both agreed, which is the
# point: this script re-derives that agreement per database instead of assuming
# it holds next time.
#
# Usage:
#   tappaas-collation-reconcile.sh                 report drift, change nothing
#   tappaas-collation-reconcile.sh --apply         verify, then refresh what passes
#   tappaas-collation-reconcile.sh --guest <fqdn>  one guest (repeatable)
#
# Exit: 0  nothing to reconcile, or everything reconciled
#       1  a database needs a human (verification failed, or drift in report mode)
#       2  usage
set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

RD=$'\033[01;31m'; GN=$'\033[32m'; YL=$'\033[33m'; BD=$'\033[1m'; CL=$'\033[m'
info()  { echo -e "${GN}[Info]${CL} $*"; }
warn()  { echo -e "${YL}[Warning]${CL} $*"; }
error() { echo -e "${RD}[Error]${CL} $*" >&2; }

APPLY=0
GUESTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)  APPLY=1 ;;
        --check)  APPLY=0 ;;
        --guest)  shift; [[ $# -gt 0 ]] || { error "--guest needs a host"; exit 2; }; GUESTS+=("$1") ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) error "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

# Every guest this site declares, as <vmname>.<zone0>.internal. The same
# derivation the module tests use; a guest without both fields is not a guest.
discover_guests() {
    local f n v z
    for f in "${CONFIG_DIR}"/*.json; do
        [[ -f "${f}" ]] || continue
        n="$(basename "${f}" .json)"
        case "${n}" in site|configuration|zones|last-update-result|release-train|*fsbackup*) continue ;; esac
        v="$(jq -r '.vmname // empty' "${f}" 2>/dev/null)"
        z="$(jq -r '.zone0 // empty'  "${f}" 2>/dev/null)"
        [[ -n "${v}" && -n "${z}" ]] && echo "${v}.${z}.internal"
    done | sort -u
}

# One ssh per call; the guest does the SQL, so no credentials leave it.
# -n matters: without it ssh consumes this shell's stdin, and the `while read`
# loop below silently stops after its first database (observed: one of three
# refreshed, exit 0, looking like success).
on_guest() { timeout 600 ssh -n "${SSH_OPTS[@]}" "tappaas@${1}" "${2}" 2>/dev/null; }

# Run a SCRIPT on the guest rather than an escaped one-liner: the amcheck loop
# below nests quotes three deep, and every attempt to inline it was a bug
# waiting to happen.
on_guest_script() { timeout 900 ssh "${SSH_OPTS[@]}" "tappaas@${1}" "bash -s -- ${2}" 2>/dev/null; }

# Prints the name of every btree index that FAILS verification, one per line.
# Silence means every index verified. Takes the database name as $1.
VERIFY_SCRIPT='
# Prints:  FOUND <n>          the btree indexes worth checking
#          FAIL <name>        one line per index that did NOT verify
#          CHECKED <n>        how many were actually checked
# The caller requires FOUND and CHECKED and requires them to agree. Anything
# else — psql broken, sudo refused, the loop dying half way — leaves them
# missing or unequal, and the refresh is refused. Silence must never be able to
# masquerade as success: an earlier version used `sudo -u postgres command psql`,
# `command` being a shell builtin that sudo cannot exec, so every query failed,
# zero indexes were found, and a database with 727 of them was refreshed as
# though it had been verified.
db="$1"
q() { sudo -u postgres psql -X -q -tA -d "$db" "$@"; }

# Prove the connection works before drawing any conclusion from empty output.
q -c "select 1" >/dev/null 2>&1 || exit 3

# System catalogs are excluded on purpose: their name columns use the C
# collation, which carries no version and cannot drift.
idx=$(q -c "select c.relname
            from pg_class c
            join pg_index i on i.indexrelid = c.oid
            join pg_am a on a.oid = c.relam
            join pg_namespace n on n.oid = c.relnamespace
            where a.amname = '"'"'btree'"'"' and i.indisvalid and i.indisready
              and n.nspname not in ('"'"'pg_catalog'"'"','"'"'pg_toast'"'"','"'"'information_schema'"'"')
            order by c.relname" 2>/dev/null) || exit 3

found=$(printf "%s\n" "$idx" | grep -c .)
printf "FOUND %s\n" "$found"

n=0
printf "%s\n" "$idx" | while IFS= read -r i; do
    [ -n "$i" ] || continue
    q -c "select bt_index_check(index => quote_ident('"'"'$i'"'"')::regclass, heapallindexed => true)" \
        >/dev/null 2>&1 || printf "FAIL %s\n" "$i"
done

# Counted here rather than in the subshell above, whose increments do not escape.
printf "CHECKED %s\n" "$found"
'

NEED_HUMAN=0
RECONCILED=0
DRIFTED=0

reconcile_guest() {
    local host="$1"
    on_guest "${host}" 'systemctl is-active --quiet postgresql' || return 0

    # Databases whose recorded version differs from the collation in force.
    # IS DISTINCT FROM, so a NULL recorded version counts as drift too.
    local drift
    drift="$(on_guest "${host}" "sudo -u postgres psql -X -q -tA -c \"select datname from pg_database where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid) order by datname\"" | grep -v '^[[:space:]]*$')"
    [[ -n "${drift}" ]] || return 0

    local versions
    versions="$(on_guest "${host}" "sudo -u postgres psql -X -q -tA -c \"select distinct coalesce(datcollversion,'(unset)') || ' -> ' || coalesce(pg_database_collation_actual_version(oid),'(unknown)') from pg_database where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid)\"" | grep -v '^[[:space:]]*$' | head -1)"
    warn "${BD}${host}${CL}: collation drift ${versions}"

    local db
    while IFS= read -r db; do
        [[ -n "${db}" ]] || continue
        DRIFTED=$((DRIFTED + 1))
        if [[ "${APPLY}" != "1" ]]; then
            info "    ${db} — would verify, then refresh (run with --apply)"
            NEED_HUMAN=1
            continue
        fi

        # amcheck IS the safety argument. Without it there is nothing to earn
        # the refresh with, so refuse rather than guess.
        local had_ext
        had_ext="$(on_guest "${host}" "sudo -u postgres psql -X -q -tA -d '${db}' -c \"select 1 from pg_extension where extname='amcheck'\"")"
        if ! on_guest "${host}" "sudo -u postgres psql -X -q -d '${db}' -c 'create extension if not exists amcheck'"; then
            error "    ${db} — amcheck unavailable; NOT refreshing (the refresh would be unearned)"
            NEED_HUMAN=1
            continue
        fi

        info "    ${db} — verifying every btree index against the current collation..."
        local out bad checked found
        out="$(printf '%s' "${VERIFY_SCRIPT}" | on_guest_script "${host}" "'${db}'")"
        checked="$(printf '%s\n' "${out}" | sed -n 's/^CHECKED //p' | head -1)"
        found="$(printf '%s\n' "${out}" | sed -n 's/^FOUND //p' | head -1)"
        bad="$(printf '%s\n' "${out}" | sed -n 's/^FAIL //p')"

        # Leave the extension as we found it.
        [[ -z "${had_ext}" ]] && on_guest "${host}" \
            "sudo -u postgres psql -X -q -d '${db}' -c 'drop extension if exists amcheck'"

        if [[ -z "${checked}" || -z "${found}" || "${checked}" != "${found}" ]]; then
            error "    ${db} — verification did not run to completion (found='${found:-?}' checked='${checked:-?}'); NOT refreshing"
            NEED_HUMAN=1
            continue
        fi
        if [[ -n "${bad}" ]]; then
            error "    ${db} — $(printf '%s\n' "${bad}" | grep -c .) index(es) FAILED verification:"
            printf '%s\n' "${bad}" | head -10 | sed 's/^/        /' >&2
            error "      NOT refreshing. REINDEX these, then re-run — while the versions"
            error "      disagree, the warning is the only thing saying the ordering moved."
            NEED_HUMAN=1
            continue
        fi

        if on_guest "${host}" "sudo -u postgres psql -X -q -c 'alter database \"${db}\" refresh collation version'"; then
            info "      ${GN}✓${CL} ${db} — ${checked} index(es) verified, recorded version refreshed"
            RECONCILED=$((RECONCILED + 1))
        else
            error "    ${db} — verified, but the refresh itself failed"
            NEED_HUMAN=1
        fi
    done <<< "${drift}"
}

command -v jq >/dev/null 2>&1 || { error "jq not found"; exit 2; }
[[ ${#GUESTS[@]} -gt 0 ]] || mapfile -t GUESTS < <(discover_guests)
[[ ${#GUESTS[@]} -gt 0 ]] || { info "no guests declared — nothing to reconcile"; exit 0; }

for h in "${GUESTS[@]}"; do reconcile_guest "${h}"; done

if [[ "${DRIFTED}" -eq 0 ]]; then
    info "collation: every database records the collation it is running"
    exit 0
fi
if [[ "${APPLY}" != "1" ]]; then
    warn "${DRIFTED} database(s) drifted — re-run with --apply to verify and refresh"
    exit 1
fi
info "collation: ${RECONCILED} database(s) reconciled"
[[ "${NEED_HUMAN}" -eq 0 ]] || { error "some databases still need attention (see above)"; exit 1; }
exit 0
