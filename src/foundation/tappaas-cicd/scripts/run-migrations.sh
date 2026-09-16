#!/usr/bin/env bash
# run-migrations.sh — apply the pending config migrations (ADR-025, #652).
#
# Called by tappaas-self-prepare.sh after the control-plane refresh and before
# the hand-over (ADR-025 D2): the migrations it runs are the ones the refresh
# just pulled, it runs before the nixos-rebuild, and it runs before the sweep
# reaches its first module — cluster included. A failure here stops the unit,
# so the site stays on the old code with its config intact (D5).
#
# A migration is migrations/NNNN-<slug>.sh (D1). The runner knows four things
# about one: its number, the summary on line 2 of its header, that `--check`
# writes nothing, and that running it twice is safe (D3). Everything else is
# the migration's own business.
#
# Modes:
#   (none)          apply every pending migration in ascending order
#   --list          print pending ids and summaries; writes nothing (D6)
#   --check         run each pending migration's own --check; writes nothing
#   --rerun NNNN    apply one migration again, applied or not (D13)
#   --baseline      record every shipped migration as applied WITHOUT running
#                   it — for a fresh install, whose config already has today's
#                   shapes (D4)
#
# The ledger is config/.migrations/applied: one line per event,
# `NNNN  <ISO date>  <commit>  <reason>`, appended after the migration
# succeeds. A migration interrupted mid-apply leaves no line and is re-run next
# sweep, which D3's idempotence makes safe.
#
# Backups (D13): the whole of config/ is snapshotted to
# .migrations/backup/run-<stamp>/config/ before the first migration of a run,
# on top of whatever per-migration pre-images the migrations themselves write
# to .migrations/backup/NNNN/. Only the run snapshots grow without bound, so
# only those are pruned — the two most recent are kept.
#
# Exit: 0 nothing to do or everything applied · 1 a migration failed · 2 usage
#
# Environment (tests): TAPPAAS_CONFIG_DIR, TAPPAAS_MIGRATIONS_DIR

set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
MIG_DIR="${TAPPAAS_MIGRATIONS_DIR:-${_here}/../migrations}"
STATE_DIR="${CONFIG_DIR}/.migrations"
LEDGER="${STATE_DIR}/applied"
BACKUP_DIR="${STATE_DIR}/backup"
KEEP_RUNS=2

log()  { echo "${SCRIPT_NAME}: $*"; }
fail() { echo "${SCRIPT_NAME}: $*" >&2; }

MODE=apply
RERUN_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)     MODE=list ;;
        --check)    MODE=check ;;
        --baseline) MODE=baseline ;;
        --rerun)    MODE=rerun; RERUN_ID="${2:-}"; shift ;;
        -h|--help)  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          fail "unknown option '$1'"; exit 2 ;;
    esac
    shift
done
if [[ "${MODE}" == "rerun" ]]; then
    [[ "${RERUN_ID}" =~ ^[0-9]{4}$ ]] || { fail "--rerun takes a four-digit id (e.g. --rerun 0003)"; exit 2; }
fi

# ── the shipped set ──────────────────────────────────────────────────
# Sorted by filename, which for a fixed-width number is numeric order. A file
# that is not NNNN-<slug>.sh is not a migration and is reported rather than
# skipped in silence: a migration nobody runs is the failure this guards.
migration_files() {
    local f base
    [[ -d "${MIG_DIR}" ]] || return 0
    for f in "${MIG_DIR}"/*.sh; do
        [[ -f "${f}" ]] || continue
        base="$(basename "${f}")"
        if [[ "${base}" =~ ^[0-9]{4}- ]]; then
            printf '%s\n' "${f}"
        else
            fail "WARNING: ${base} is not named NNNN-<slug>.sh and will never run"
        fi
    done | sort
}
id_of()      { local b; b="$(basename "$1")"; printf '%s' "${b:0:4}"; }
summary_of() {
    # Line 2 of the header, after the "name — " lead if it has one.
    local s; s="$(sed -n '2p' "$1" | sed 's/^# \{0,1\}//')"
    case "${s}" in *' — '*) s="${s#*' — '}" ;; esac
    printf '%s' "${s}"
}
# ── the ledger ───────────────────────────────────────────────────────
# Read ONCE, at startup, and never guessed at. A ledger that cannot be read or
# that does not parse stops the run: concluding "nothing has been applied" from
# an unreadable file would re-run every migration a site ever received, and
# idempotence is a contract each migration keeps, not a licence to re-run the
# whole history on the strength of a permissions error.
#
# Loaded at top level rather than inside a command substitution, because an
# `exit` in a subshell would only end the subshell.
LEDGER_IDS=""
load_ledger() {
    [[ -e "${LEDGER}" ]] || return 0          # fresh site: no ledger yet, not an error
    [[ -r "${LEDGER}" && -f "${LEDGER}" ]] \
        || { fail "FATAL: ${LEDGER} exists but cannot be read — refusing to guess which migrations have run"; exit 1; }
    local line n=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        n=$((n + 1))
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line}" == \#* ]] && continue
        if [[ ! "${line}" =~ ^[0-9]{4}[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+ ]]; then
            fail "FATAL: ${LEDGER} line ${n} is not 'NNNN  <date>  <commit>  <reason>': ${line}"
            fail "  refusing to guess which migrations have run — repair it from ${BACKUP_DIR}/ or the site backup (#545)"
            exit 1
        fi
        LEDGER_IDS+="${line:0:4}"$'\n'
    done < "${LEDGER}"
}
is_applied() { grep -qx "$1" <<< "${LEDGER_IDS}"; }

site_commit() { git -C "${MIG_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown; }
# `date -Is` is GNU; a host without it printed nothing and the ledger line came
# out with an empty field, which the reader above then refuses to start from.
# Every field is therefore filled or defaulted before it is written — a ledger
# this script cannot parse is a site that cannot update.
now_iso() { date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
record() {
    local when commit line
    mkdir -p "${STATE_DIR}" \
        || { fail "FATAL: cannot create ${STATE_DIR} to record migration $1"; exit 1; }
    when="$(now_iso)"; [[ -n "${when}" ]] || when="unknown-time"
    commit="$(site_commit)"; [[ -n "${commit}" ]] || commit="unknown"
    line="$(printf '%s  %s  %s  %s' "$1" "${when}" "${commit}" "$2")"
    # The line this run will not be able to read next time is caught now, while
    # there is still someone to tell.
    [[ "${line}" =~ ^[0-9]{4}[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+ ]] \
        || { fail "FATAL: refusing to write an unparseable ledger line: ${line}"; exit 1; }
    # A migration that ran and was not recorded would run again next sweep. That
    # is safe by D3, but it is not something to discover later: stop here.
    printf '%s\n' "${line}" >> "${LEDGER}" \
        || { fail "FATAL: migration $1 succeeded but could not be recorded in ${LEDGER}"; exit 1; }
    LEDGER_IDS+="$1"$'\n'
}

# Every mode below asks "has this run?", so the ledger is read before any of
# them — and a bad one stops us here, before a single migration is considered.
load_ledger

pending() {
    local f id
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        id="$(id_of "${f}")"
        is_applied "${id}" || printf '%s\n' "${f}"
    done < <(migration_files)
}

# ── the whole-config snapshot, and the prune that keeps it bounded ───
snapshot_config() {
    # A unique suffix, not just the timestamp: two runs in the same second would
    # otherwise share a directory and the second would overwrite the first's
    # pre-image — which is the one thing a snapshot may not do.
    local run dest
    mkdir -p "${BACKUP_DIR}" || { fail "cannot create ${BACKUP_DIR}"; return 1; }
    run="$(mktemp -d "${BACKUP_DIR}/run-$(date +%Y%m%d-%H%M%S).XXXX")" \
        || { fail "cannot create a backup set under ${BACKUP_DIR}"; return 1; }
    dest="${run}/config"
    mkdir -p "${dest}" || { fail "cannot create ${dest}"; return 1; }
    # The state dir holds the backups themselves — copying it into one would
    # nest every previous run inside this one.
    local entry missed=0
    for entry in "${CONFIG_DIR}"/* "${CONFIG_DIR}"/.[!.]*; do
        [[ -e "${entry}" ]] || continue
        [[ "${entry}" == "${STATE_DIR}" ]] && continue
        cp -a "${entry}" "${dest}/" 2>/dev/null || { missed=$((missed + 1)); fail "  cannot snapshot ${entry}"; }
    done
    # A snapshot with holes in it is worse than none: step 6's fallback is
    # written on the assumption this directory is the whole of config/, and a
    # partial copy still LOOKS like a backup to whoever reaches for it. Remove
    # it and stop, rather than leave that lying around.
    if (( missed > 0 )); then
        fail "could not snapshot ${missed} item(s) — a partial snapshot is not a safety net"
        rm -rf -- "${run}"
        return 1
    fi
    log "config snapshotted to ${dest}"
}
prune_runs() {
    local old
    # Run snapshots only: a migration's own NNNN/ pre-image is one per migration
    # and is what D8's rollback restores.
    # `head -n -N` is GNU-only; this reads the same on any awk.
    old="$(ls -1d "${BACKUP_DIR}"/run-* 2>/dev/null | sort \
        | awk -v keep="${KEEP_RUNS}" '{a[NR]=$0} END{for (i = 1; i <= NR - keep; i++) print a[i]}')"
    [[ -n "${old}" ]] || return 0
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        rm -rf -- "${d}" && log "pruned old backup set $(basename "${d}")"
    done <<< "${old}"
}

# ── modes that write nothing ─────────────────────────────────────────
if [[ "${MODE}" == "list" || "${MODE}" == "check" ]]; then
    n=0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        n=$((n + 1))
        printf '  %s  %s\n' "$(id_of "${f}")" "$(summary_of "${f}")"
        if [[ "${MODE}" == "check" ]]; then
            CONFIG_DIR="${CONFIG_DIR}" TAPPAAS_CONFIG_DIR="${CONFIG_DIR}" \
                bash "${f}" --check 2>&1 | sed 's/^/      /'
            rc="${PIPESTATUS[0]}"
            if [[ "${rc}" != "0" ]]; then
                fail "migration $(id_of "${f}") --check could not tell what it would do (rc ${rc})"
                exit 1
            fi
        fi
    done < <(pending)
    [[ "${n}" -gt 0 ]] || log "no pending migrations"
    exit 0
fi

# ── baseline: a fresh site is stamped, not migrated (D4) ─────────────
if [[ "${MODE}" == "baseline" ]]; then
    n=0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        id="$(id_of "${f}")"
        is_applied "${id}" && continue
        record "${id}" baseline
        n=$((n + 1))
    done < <(migration_files)
    log "stamped ${n} migration(s) as baseline — a fresh config already has these shapes"
    exit 0
fi

# ── rerun: one migration, applied or not (D13) ───────────────────────
if [[ "${MODE}" == "rerun" ]]; then
    target=""
    while IFS= read -r f; do
        [[ "$(id_of "${f}")" == "${RERUN_ID}" ]] && target="${f}"
    done < <(migration_files)
    [[ -n "${target}" ]] || { fail "no migration ${RERUN_ID} in ${MIG_DIR}"; exit 1; }
    snapshot_config || exit 1
    log "re-running ${RERUN_ID}: $(summary_of "${target}")"
    if CONFIG_DIR="${CONFIG_DIR}" TAPPAAS_CONFIG_DIR="${CONFIG_DIR}" \
            TAPPAAS_MIGRATION_BACKUP_DIR="${BACKUP_DIR}/${RERUN_ID}" bash "${target}"; then
        record "${RERUN_ID}" rerun
        prune_runs
        log "migration ${RERUN_ID} re-applied"
        exit 0
    fi
    fail "migration ${RERUN_ID} failed — config is restorable from ${BACKUP_DIR}"
    exit 1
fi

# ── apply ────────────────────────────────────────────────────────────
mapfile -t TODO < <(pending)
if [[ "${#TODO[@]}" -eq 0 ]]; then
    log "no pending migrations"
    exit 0
fi

log "${#TODO[@]} pending migration(s):"
for f in "${TODO[@]}"; do log "  $(id_of "${f}")  $(summary_of "${f}")"; done

# One snapshot for the run, before the first migration writes anything. A
# missing or stale site backup never blocks this: a site without one is usually
# a deliberate choice (a test machine), and refusing to update it would punish
# exactly the site that most wants the new code (D13).
snapshot_config || exit 1

for f in "${TODO[@]}"; do
    id="$(id_of "${f}")"
    log "applying ${id}: $(summary_of "${f}")"
    if CONFIG_DIR="${CONFIG_DIR}" TAPPAAS_CONFIG_DIR="${CONFIG_DIR}" \
            TAPPAAS_MIGRATION_BACKUP_DIR="${BACKUP_DIR}/${id}" bash "${f}"; then
        record "${id}" applied
    else
        rc=$?
        fail "FATAL: migration ${id} failed (rc ${rc}) — no rebuild, no sweep, no module updated"
        fail "  config/ is unchanged or restorable: ${BACKUP_DIR}/${id}/ (this migration) or ${BACKUP_DIR}/run-*/config/ (the whole run)"
        exit 1
    fi
done

prune_runs
log "${#TODO[@]} migration(s) applied"
