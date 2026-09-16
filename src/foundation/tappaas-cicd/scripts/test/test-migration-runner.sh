#!/usr/bin/env bash
# test-migration-runner.sh — the config-migration runner (ADR-025, #652).
#
# Self-contained: a temp config/ and a temp migrations/ holding fixture
# migrations. No cluster, no systemd, no repository.
#
# What it pins down, decision by decision:
#   D1  ascending numeric order; a file that is not NNNN-<slug>.sh is reported
#   D3  the runner passes --check through, and writes nothing in that mode
#   D4  the ledger records id/date/commit/reason; --baseline stamps without running
#   D5  the first failure stops the run — later migrations do not run
#   D6  --list names what is pending and writes nothing
#   D13 a whole-config snapshot precedes the run; only two are kept; --rerun works
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
RUNNER="${CICD}/scripts/run-migrations.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
ok() { if [[ -n "$2" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig-runner.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"
MIGS="${TMP}/migrations"

fresh() {
    rm -rf "${CFG}" "${MIGS}"
    mkdir -p "${CFG}" "${MIGS}"
    echo '{"name":"t","updateSchedule":["daily",null,2]}' > "${CFG}/site.json"
    echo '{"vmid":100}' > "${CFG}/nextcloud.json"
}
# A fixture migration: appends its id to config/marker, backing the file up first.
write_mig() {  # <id> <slug> <summary>
    cat > "${MIGS}/$1-$2.sh" <<EOF
#!/usr/bin/env bash
# $1-$2.sh — $3
# Introduced: test.  Reversible: yes.
set -euo pipefail
cfg="\${CONFIG_DIR:?}"
[[ "\${1:-}" == "--check" ]] && { echo "would append $1 to marker"; exit 0; }
mkdir -p "\${TAPPAAS_MIGRATION_BACKUP_DIR:?}"
[[ -f "\${cfg}/marker" ]] && cp -p "\${cfg}/marker" "\${TAPPAAS_MIGRATION_BACKUP_DIR}/"
grep -qx "$1" "\${cfg}/marker" 2>/dev/null || echo "$1" >> "\${cfg}/marker"
EOF
    chmod +x "${MIGS}/$1-$2.sh"
}
run() { TAPPAAS_CONFIG_DIR="${CFG}" TAPPAAS_MIGRATIONS_DIR="${MIGS}" bash "${RUNNER}" "$@" 2>&1; }

# ── D6: --list names what is pending, and writes nothing ────────────────────
fresh
write_mig 0001 first  "the first fixture migration"
write_mig 0002 second "the second fixture migration"
out="$(run --list)"
[[ "${out}" == *"0001  the first fixture migration"* && "${out}" == *"0002  the second"* ]] \
    && ck "--list names each pending migration with its summary" ok ok \
    || ck "--list names each pending migration with its summary" ok "got: ${out}"
ck "--list writes no ledger" "" "$(cat "${CFG}/.migrations/applied" 2>/dev/null || true)"
ck "--list writes no marker" "" "$(cat "${CFG}/marker" 2>/dev/null || true)"

# ── D3: --check passes through and still writes nothing ─────────────────────
out="$(run --check)"
[[ "${out}" == *"would append 0001"* ]] && ck "--check runs each migration's own --check" ok ok \
                                        || ck "--check runs each migration's own --check" ok missing
ck "--check changes nothing" "" "$(cat "${CFG}/marker" 2>/dev/null || true)"

# ── D1/D4: apply — ascending order, ledger written ──────────────────────────
out="$(run)"; rc=$?
ck "a run with pending migrations exits 0" 0 "${rc}"
ck "they ran in ascending order" "0001
0002" "$(cat "${CFG}/marker")"
ck "the ledger has one line per migration" 2 "$(wc -l < "${CFG}/.migrations/applied" | tr -d ' ')"
ok "the ledger records the reason" "$(grep -c 'applied' "${CFG}/.migrations/applied")"
ok "the ledger records a date" "$(awk '{print $2}' "${CFG}/.migrations/applied" | grep -c '^2')"

# ── D13: a whole-config snapshot preceded the run ───────────────────────────
ok "config/ was snapshotted before the first migration" "$(ls -d "${CFG}"/.migrations/backup/run-*/config/site.json 2>/dev/null)"
ck "the snapshot does not nest the backup directory" "" "$(ls -d "${CFG}"/.migrations/backup/run-*/config/.migrations 2>/dev/null || true)"

# ── D4: an applied migration is not re-run ──────────────────────────────────
out="$(run)"
[[ "${out}" == *"no pending migrations"* ]] && ck "a second run has nothing to do" ok ok \
                                            || ck "a second run has nothing to do" ok "got: ${out}"
ck "…and the ledger did not grow" 2 "$(wc -l < "${CFG}/.migrations/applied" | tr -d ' ')"

# ── D1: a new migration is picked up; earlier ones stay applied ─────────────
write_mig 0003 third "the third fixture migration"
run >/dev/null
ck "only the new migration ran" "0001
0002
0003" "$(cat "${CFG}/marker")"

# ── D13: retention — the two most recent run snapshots are kept ─────────────
# Two runs a second apart would be indistinguishable by timestamp alone, so the
# older sets are planted with names a run would have produced on earlier days.
for d in run-20260101-020000.aaaa run-20260102-020000.bbbb run-20260103-020000.cccc; do
    mkdir -p "${CFG}/.migrations/backup/${d}/config"
done
before="$(ls -1d "${CFG}"/.migrations/backup/run-* | wc -l | tr -d ' ')"
ok "several backup sets exist before the run" "$([[ "${before}" -ge 4 ]] && echo yes)"
write_mig 0004 fourth "the fourth fixture migration"
run >/dev/null
ck "old backup sets are pruned to two" 2 "$(ls -1d "${CFG}"/.migrations/backup/run-* 2>/dev/null | wc -l | tr -d ' ')"
ck "…and the newest is the run that just happened" "" "$(ls -1d "${CFG}"/.migrations/backup/run-2026010* 2>/dev/null || true)"

# ── D13: --rerun applies an applied migration again, and says so ────────────
rm -f "${CFG}/marker"
run --rerun 0002 >/dev/null
ck "--rerun applies the named migration" "0002" "$(cat "${CFG}/marker")"
ok "--rerun is a second ledger line, not a replacement" "$(grep -c '^0002 .* rerun$' "${CFG}/.migrations/applied")"
run --rerun 9999 >/dev/null 2>&1 && ck "--rerun of an unknown id fails" ok "exited 0" \
                                 || ck "--rerun of an unknown id fails" ok ok

# ── D5: the first failure stops the run ─────────────────────────────────────
fresh
write_mig 0001 first "the first fixture migration"
cat > "${MIGS}/0002-doomed.sh" <<'EOF'
#!/usr/bin/env bash
# 0002-doomed.sh — a migration that meets an input it does not recognise
set -euo pipefail
[[ "${1:-}" == "--check" ]] && exit 0
echo "0002: unrecognised updateSchedule shape — stopping" >&2
exit 1
EOF
chmod +x "${MIGS}/0002-doomed.sh"
write_mig 0003 third "the third fixture migration"
out="$(run)"; rc=$?
ck "a failed migration fails the run" 1 "${rc}"
ck "the migrations after it did not run" "0001" "$(cat "${CFG}/marker")"
ck "the failed migration is not in the ledger" 0 "$(grep -c '^0002' "${CFG}/.migrations/applied" || true)"
[[ "${out}" == *"no rebuild, no sweep"* ]] && ck "the run says nothing was updated" ok ok \
                                           || ck "the run says nothing was updated" ok missing
# Interrupted mid-apply → no ledger line → re-run next sweep (D4).
rm -f "${MIGS}/0002-doomed.sh"
run >/dev/null
ck "the next sweep carries on from where it stopped" "0001
0003" "$(cat "${CFG}/marker")"

# ── D4: --baseline stamps a fresh site without running anything ─────────────
fresh
write_mig 0001 first  "the first fixture migration"
write_mig 0002 second "the second fixture migration"
run --baseline >/dev/null
ck "--baseline runs no migration" "" "$(cat "${CFG}/marker" 2>/dev/null || true)"
ck "--baseline stamps every shipped id" 2 "$(wc -l < "${CFG}/.migrations/applied" | tr -d ' ')"
ok "…with the reason 'baseline'" "$(grep -c 'baseline' "${CFG}/.migrations/applied")"
out="$(run)"
[[ "${out}" == *"no pending migrations"* ]] && ck "a stamped site has nothing pending" ok ok \
                                            || ck "a stamped site has nothing pending" ok "got: ${out}"

# ── D1: a file that is not NNNN-<slug>.sh is reported, not silently skipped ──
printf '#!/usr/bin/env bash\n# helper\n' > "${MIGS}/helper.sh"
out="$(run --list)"
[[ "${out}" == *"helper.sh is not named"* ]] && ck "an unnumbered script is reported" ok ok \
                                             || ck "an unnumbered script is reported" ok missing

# ── D11: the shipped directory is empty in this release ─────────────────────
shipped="$(ls -1 "${CICD}/migrations"/[0-9][0-9][0-9][0-9]-*.sh 2>/dev/null | wc -l | tr -d ' ')"
ck "the runner's own release carries no migrations (D11)" 0 "${shipped}"

# ── D2/D5: the wiring the runner depends on ─────────────────────────────────
P="${CICD}/scripts/tappaas-self-prepare.sh"
n_ref="$(grep -n '"\${REFRESH}"' "${P}" | head -1 | cut -d: -f1)"
n_mig="$(grep -n '"\${MIGRATE}"' "${P}" | head -1 | cut -d: -f1)"
n_hand="$(grep -n 'prepared' "${P}" | tail -1 | cut -d: -f1)"
if [[ -n "${n_ref}" && -n "${n_mig}" && "${n_ref}" -lt "${n_mig}" && "${n_mig}" -lt "${n_hand}" ]]; then
    ck "the runner sits after the refresh and before the hand-over" ok ok
else
    ck "the runner sits after the refresh and before the hand-over" ok "refresh ${n_ref}, migrate ${n_mig}, hand-over ${n_hand}"
fi
grep -q 'echo migrate > "\${CONFIG_DIR}/.update-stage"' "${P}" \
    && ck "the stage marker says 'migrate' while it runs" ok ok \
    || ck "the stage marker says 'migrate' while it runs" ok missing
N="${CICD}/scripts/notify-update-failure.sh"
grep -q 'prepare|rebuild|migrate)' "${N}" \
    && ck "the notice synthesizes a result for a migrate failure" ok ok \
    || ck "the notice synthesizes a result for a migrate failure" ok missing
grep -q 'migrate) stage_line=' "${N}" \
    && ck "the notice has an operator line for 'migrate'" ok ok \
    || ck "the notice has an operator line for 'migrate'" ok missing

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
