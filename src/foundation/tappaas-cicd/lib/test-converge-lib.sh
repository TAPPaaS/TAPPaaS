#!/usr/bin/env bash
#
# test-converge-lib.sh — unit tests for the drift-record runner (converge-lib.sh).
#
# Runs entirely against stubs: the provider callbacks and the hook scripts are
# throwaway shells that append to a command log, so what is asserted is the
# RUNNER'S decisions — what it batches, what it dispatches, in what order, and
# what verdict it returns — with no cluster anywhere near it.
#
# The guarantees under test are the ones ADR-020 P3 had to carry over from the
# imperative drift loop it replaced. Each was load-bearing before the refactor:
#
#   - ONE batched set call, never one per field (a single Proxmox round-trip);
#   - a relocation runs LAST, because `qm set` is node-local and a migrate moves
#     the ground out from under every other unit;
#   - side effects run ONCE across the whole record and in reboot→wait-ip→dns
#     order, not once per changed NIC;
#   - side effects do NOT run when nothing applied;
#   - `manual` drift warns and keeps going while `immutable`/`recreate` fails —
#     exactly the split cluster:vm's storage-vs-bios handling has always had;
#   - a hook's 10/20 exit codes mean deferred (still rc 0) and refused (rc 1),
#     because a deferral is not a failure (ADR-020 D8);
#   - --check applies nothing at all.
#
# Usage: test-converge-lib.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The lib logs through common-install-routines' helpers; stub them so the suite
# is quiet and so warn/error output can be captured per-case.
LOG=""
info()  { LOG+="INFO:$*"$'\n'; }
debug() { LOG+="DEBUG:$*"$'\n'; }
warn()  { LOG+="WARN:$*"$'\n'; }
error() { LOG+="ERROR:$*"$'\n'; }
GN=""; CL=""
# shellcheck disable=SC2034  # read by the sourced lib
BL=""

# shellcheck source=converge-lib.sh
. "${HERE}/converge-lib.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok: $1"; }
no(){ fail=$((fail+1)); echo "  FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
contains(){ if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
lacks(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1 (unexpectedly found '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/converge-lib-test.XXXXXX")"
trap 'rm -rf "${W}"' EXIT
CMDLOG="${W}/cmds"

# ── stub provider ────────────────────────────────────────────────────
converge_apply_set() { echo "SET $*" >> "${CMDLOG}"; return "${SET_RC:-0}"; }
converge_side_effect_reboot()  { echo "FX reboot"  >> "${CMDLOG}"; }
converge_side_effect_wait_ip() { echo "FX wait-ip" >> "${CMDLOG}"; }
converge_side_effect_dns()     { echo "FX dns"     >> "${CMDLOG}"; }

# A stub hook that logs its arguments and exits with a code we choose per test.
mk_hook() {
    local name="$1" rc="$2"
    cat > "${W}/${name}" <<EOF
#!/usr/bin/env bash
echo "HOOK ${name} \$*" >> "${CMDLOG}"
exit ${rc}
EOF
    chmod +x "${W}/${name}"
}

# A drift record. \$1 is the units array, \$2 the unreconciled array.
mk_record() {
    cat > "${W}/drift.json" <<EOF
{ "module": "demo", "service": "cluster:vm",
  "actual": { "vmid": "300", "node": "tappaas1", "status": "running" },
  "units": ${1}, "unreconciled": ${2:-[]}, "inSync": [], "skipped": [] }
EOF
}

unit_set() {  # unit_set <name> <flag> <desired> <actual>
    printf '{"name":"%s","kind":"field","class":"in-place","disruptive":false,"apply":"set",' "$1"
    printf '"liveKey":"%s","setFlag":"%s","sideEffects":[],' "$1" "$2"
    printf '"fields":[{"field":"%s","class":"in-place","liveKey":"%s","desired":"%s","actual":"%s","desiredNorm":"%s","actualNorm":"%s","defaulted":false}]}' \
        "$1" "$1" "$3" "$4" "$3" "$4"
}

unit_hook() {  # unit_hook <name> <hook> <class> <disruptive> <sideEffects-json>
    printf '{"name":"%s","kind":"field","class":"%s","disruptive":%s,"apply":"hook","hook":"%s",' "$1" "$3" "$4" "$2"
    printf '"liveKey":"%s","sideEffects":%s,' "$1" "$5"
    printf '"fields":[{"field":"%s","class":"%s","liveKey":"%s","desired":"b","actual":"a","desiredNorm":"b","actualNorm":"a","defaulted":false}]}' \
        "$1" "$3" "$1"
}

reset() { : > "${CMDLOG}"; LOG=""; }
run() { converge_apply demo "${W}" "${W}/drift.json" "${1:-0}" "${2:-1}" "${3:-0}"; }

# ── 1. batching: many set fields, ONE call ───────────────────────────
{
    reset
    mk_record "[$(unit_set cores --cores 8 4),$(unit_set memory --memory 16384 8192)]"
    run; rc=$?
    check "two in-place fields converge cleanly" "${rc}" "0"
    check "…in exactly ONE batched set call" "$(grep -c '^SET ' "${CMDLOG}")" "1"
    contains "…carrying both flags" "$(cat "${CMDLOG}")" "--cores 8 --memory 16384"
}

# ── 2. hooks, and a relocation last ──────────────────────────────────
{
    reset
    mk_hook update-net.sh 0
    mk_hook update-node.sh 0
    mk_record "[$(unit_hook node update-node.sh migrate true '[]'),$(unit_hook net0 update-net.sh in-place-reboot true '["reboot"]')]"
    run; rc=$?
    check "hook units converge cleanly" "${rc}" "0"
    order="$(grep '^HOOK ' "${CMDLOG}" | sed 's/ .*//;s/HOOK //')"
    check "a migrate runs LAST, after every node-local change" \
        "$(grep -o 'update-net.sh\|update-node.sh' <<< "$(grep '^HOOK ' "${CMDLOG}" | awk '{print $2}')" | paste -sd, -)" \
        "update-net.sh,update-node.sh"
    contains "a hook is handed the module and a unit file" "$(cat "${CMDLOG}")" "demo --unit"
    contains "…plus the single-field trio, so it is runnable by hand" "$(cat "${CMDLOG}")" "--field net0 --desired b --actual a"
}

# ── 3. side effects: once, in order, only after something applied ────
{
    reset
    mk_hook update-net.sh 0
    # BOTH NICs changed and both declare the same three side effects.
    mk_record "[$(unit_hook net0 update-net.sh in-place-reboot true '["reboot","wait-ip","dns"]'),$(unit_hook net1 update-net.sh in-place-reboot true '["reboot","wait-ip","dns"]')]"
    run >/dev/null
    check "two changed NICs still produce exactly ONE reboot" "$(grep -c '^FX reboot$' "${CMDLOG}")" "1"
    check "…one IP wait" "$(grep -c '^FX wait-ip$' "${CMDLOG}")" "1"
    check "…and one DNS pass" "$(grep -c '^FX dns$' "${CMDLOG}")" "1"
    check "…sequenced reboot → wait-ip → dns, never the record's order" \
        "$(grep '^FX ' "${CMDLOG}" | awk '{print $2}' | paste -sd, -)" "reboot,wait-ip,dns"
}

# ── 4. --check applies nothing ───────────────────────────────────────
{
    reset
    mk_hook update-net.sh 0
    mk_record "[$(unit_set cores --cores 8 4),$(unit_hook net0 update-net.sh in-place-reboot true '["reboot"]')]"
    run 1 >/dev/null; rc=$?
    check "--check exits 0" "${rc}" "0"
    check "--check runs NOTHING — no set, no hook, no side effect" "$(wc -l < "${CMDLOG}")" "0"
    contains "…but it does report the drift it found" "${LOG}" "Detected drift"
}

# ── 5. unreconcilable drift: manual warns, immutable fails ───────────
{
    reset
    mk_record "[]" '[{"field":"storage","class":"manual","liveKey":"storage","desired":"tankb1","actual":"tanka1","desiredNorm":"tankb1","actualNorm":"tanka1","defaulted":false}]'
    run; rc=$?
    check "a 'manual' field does not fail the converge" "${rc}" "0"
    contains "…it warns, naming the operator action" "${LOG}" "WARN:  storage drift (tanka1→tankb1) is not auto-applied"

    reset
    mk_record "[]" '[{"field":"bios","class":"recreate","liveKey":"bios","desired":"seabios","actual":"ovmf","desiredNorm":"seabios","actualNorm":"ovmf","defaulted":false}]'
    run; rc=$?
    check "a 'recreate' field FAILS the converge, as the old bios check did" "${rc}" "1"
    contains "…and says a reinstall is what it takes" "${LOG}" "requires delete + reinstall"
}

# ── 6. the hook exit protocol ────────────────────────────────────────
{
    reset
    mk_hook update-disk.sh 20
    mk_record "[$(unit_hook diskSize update-disk.sh grow-only false '[]')]"
    run; rc=$?
    check "a hook exiting 20 (refused) fails the converge" "${rc}" "1"
    contains "…naming the hook that refused" "${LOG}" "refused by update-disk.sh"

    reset
    mk_hook update-net.sh 10
    mk_record "[$(unit_hook net0 update-net.sh in-place-reboot true '["reboot"]')]"
    run; rc=$?
    check "a hook exiting 10 (needs authorization) is DEFERRED, not failed" "${rc}" "0"
    contains "…with a machine-parseable DEFERRED: line for the sweep summary" "${LOG}" "DEFERRED: demo net0"
    check "…and its side effects do not run" "$(grep -c '^FX ' "${CMDLOG}")" "0"

    reset
    mk_hook update-net.sh 3
    mk_record "[$(unit_hook net0 update-net.sh in-place-reboot true '[]')]"
    run; rc=$?
    check "any other non-zero hook exit is an error" "${rc}" "1"
}

# ── 7. the disruption gate (ADR-020 D8) ──────────────────────────────
{
    reset
    mk_hook update-net.sh 0
    # One disruptive unit, one not. Without authorization the safe one must
    # still apply — deferring everything because one change needs a window
    # would leave the guest further from its declared state, not closer.
    mk_record "[$(unit_set cores --cores 8 4),$(unit_hook net0 update-net.sh in-place-reboot true '["reboot"]')]"
    run 0 0; rc=$?
    check "an unauthorized disruptive change exits 0 — a deferral is not a failure" "${rc}" "0"
    contains "…and is reported as DEFERRED" "${LOG}" "DEFERRED: demo net0"
    contains "…naming the command that would authorize it" "${LOG}" "module modify demo --force"
    contains "the NON-disruptive change still applied" "$(cat "${CMDLOG}")" "--cores 8"
    check "…while the disruptive hook did not run" "$(grep -c '^HOOK ' "${CMDLOG}")" "0"
    check "…and neither did its reboot" "$(grep -c '^FX ' "${CMDLOG}")" "0"

    reset
    mk_hook update-net.sh 0
    mk_record "[$(unit_hook net0 update-net.sh in-place-reboot true '["reboot"]')]"
    run 0 1; rc=$?
    check "the same change applies once disruption is authorized" "${rc}" "0"
    check "…and its reboot runs" "$(grep -c '^FX reboot$' "${CMDLOG}")" "1"
}

# ── 8. missing provider pieces are reported, never silently skipped ──
{
    reset
    rm -f "${W}/update-ghost.sh"
    mk_record "[$(unit_hook ghost update-ghost.sh in-place false '[]')]"
    run; rc=$?
    check "a missing hook script fails the converge" "${rc}" "1"
    contains "…naming the path it looked for" "${LOG}" "update-ghost.sh is missing or not executable"

    reset
    mk_hook update-net.sh 0
    mk_record "[$(unit_hook net0 update-net.sh in-place-reboot true '["ha-repoint"]')]"
    run >/dev/null
    contains "a side effect the service does not implement is reported, not skipped in silence" \
        "${LOG}" "this service implements no converge_side_effect_ha_repoint"
}

# ── 9. a malformed record is refused ─────────────────────────────────
{
    reset
    echo "not json" > "${W}/drift.json"
    run; rc=$?
    check "a drift record that is not JSON fails rather than applying nothing quietly" "${rc}" "1"

    reset
    converge_apply demo "${W}" "${W}/nosuchfile.json" 0 1 0; rc=$?
    check "an unreadable drift record fails" "${rc}" "1"
}

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
