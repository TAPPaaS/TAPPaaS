#!/usr/bin/env bash
#
# test-dependson-delta-e2e.sh — LIVE end-to-end test for the dependsOn-delta
# lifecycle-verb fix (issue #511).
#
# Runs on the tappaas-cicd mothership against the real cluster. It stands up a
# disposable VM (the existing cluster/test-vmdrift fixture) and a no-VM provider
# (fixtures/test-depprov, offering a harmless 'probe' service), then drives the
# REAL update-module.sh through two release changes:
#
#   1. ADD    test-depprov:probe to the consumer's shipped dependsOn  → expects
#      Step 0 to WARN "Changed the released value of dependsOn" and Step 3.5 to
#      run the provider's install-service.sh (create verb).
#   2. REMOVE test-depprov:probe from the shipped dependsOn           → expects
#      Step 3.5 to run the provider's delete-service.sh (teardown verb).
#
# Each verb-script appends a marker line; the test asserts the RIGHT verb fired
# for each transition, and that the merged config tracked the released list.
#
# DESTRUCTIVE: creates and deletes VM 920 (test-vmdrift). Opt-in only — it is not
# part of the fast tier. Cleans up on every exit path.
#
# Usage:  ./test-dependson-delta-e2e.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# test → module-manager → manager → tappaas-cicd → foundation
FOUNDATION_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

readonly BIN="/home/tappaas/bin"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER="test-vmdrift"
readonly CONSUMER_DIR="${FOUNDATION_DIR}/cluster/test-vmdrift"
readonly CONSUMER_JSON="${CONSUMER_DIR}/${CONSUMER}.json"
readonly PROVIDER="test-depprov"
readonly PROVIDER_DIR="${SCRIPT_DIR}/fixtures/test-depprov"
readonly DEP="test-depprov:probe"

PASS=0
FAIL=0
ok()  { echo "  ok:   $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
say() { echo ""; echo "== $* =="; }

# Preconditions — must run on the cicd with the toolbox present.
for t in update-module.sh install-module.sh delete-module.sh; do
    [[ -x "${BIN}/${t}" ]] || { echo "ABORT: ${BIN}/${t} not found — run this on the tappaas-cicd mothership"; exit 2; }
done
[[ -f "${CONSUMER_JSON}" ]]  || { echo "ABORT: consumer fixture missing: ${CONSUMER_JSON}"; exit 2; }
[[ -d "${PROVIDER_DIR}" ]]   || { echo "ABORT: provider fixture missing: ${PROVIDER_DIR}"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/depdelta-e2e.XXXXXX")"
MARKER="${WORK}/probe.log"
export TAPPAAS_PROBE_MARKER="${MARKER}"
: > "${MARKER}"

# Preserve the consumer's shipped JSON — the test mutates it to simulate release
# changes, and must restore it verbatim regardless of how it exits.
CONSUMER_JSON_BAK="${WORK}/${CONSUMER}.json.orig-fixture"
cp "${CONSUMER_JSON}" "${CONSUMER_JSON_BAK}"

cleanup() {
    say "Cleanup"
    cp "${CONSUMER_JSON_BAK}" "${CONSUMER_JSON}" 2>/dev/null && echo "  restored ${CONSUMER}.json fixture"
    if [[ -f "${CONFIG_DIR}/${CONSUMER}.json" ]]; then
        echo "  delete-module ${CONSUMER} (removes VM 920)..."
        "${BIN}/delete-module.sh" "${CONSUMER}" --force >/dev/null 2>&1 || echo "  (consumer delete returned non-zero)"
    fi
    if [[ -f "${CONFIG_DIR}/${PROVIDER}.json" ]]; then
        echo "  delete-module ${PROVIDER}..."
        "${BIN}/delete-module.sh" "${PROVIDER}" --force >/dev/null 2>&1 || echo "  (provider delete returned non-zero)"
    fi
    # Best-effort DNS scrub (mirrors cluster/test.sh) in case cluster:vm registered records.
    if [[ -x "${BIN}/dns-manager" ]]; then
        "${BIN}/dns-manager" --no-ssl-verify delete "${CONSUMER}" mgmt.internal >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

# Run update-module.sh, tee-ing output to a file so we can both stream and grep.
# Truncates the marker first so each transition's markers are isolated.
run_update() {
    local logfile="$1"
    : > "${MARKER}"
    ( cd "${CONSUMER_DIR}" && "${BIN}/update-module.sh" "${CONSUMER}" ) >"${logfile}" 2>&1
    return $?
}

installed_depends_on() {
    "${BIN}/module-manager" show "${CONSUMER}" 2>/dev/null | jq -r '.dependsOn // [] | .[]' 2>/dev/null \
        || jq -r '.dependsOn // (.config|.[]?|.dependsOn) // [] | .[]?' "${CONFIG_DIR}/${CONSUMER}.json" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────
say "Step A: install provider fixture ${PROVIDER} (no VM)"
if ( cd "${PROVIDER_DIR}" && "${BIN}/install-module.sh" "${PROVIDER}" ) >"${WORK}/install-prov.log" 2>&1; then
    ok "installed ${PROVIDER}"
else
    bad "install ${PROVIDER} failed — see ${WORK}/install-prov.log"; sed -n '$p' "${WORK}/install-prov.log"; exit 1
fi
[[ -f "${CONFIG_DIR}/${PROVIDER}.json" ]] && ok "${PROVIDER} config registered" || bad "${PROVIDER} config not registered"

say "Step B: install consumer ${CONSUMER} (creates VM 920)"
if ( cd "${CONSUMER_DIR}" && "${BIN}/install-module.sh" "${CONSUMER}" ) >"${WORK}/install-cons.log" 2>&1; then
    ok "installed ${CONSUMER}"
else
    bad "install ${CONSUMER} failed — see ${WORK}/install-cons.log"; tail -n 20 "${WORK}/install-cons.log"; exit 1
fi
if installed_depends_on | grep -qx "${DEP}"; then
    bad "consumer already depends on ${DEP} before the test (unexpected)"
else
    ok "consumer starts WITHOUT ${DEP}"
fi

# ─────────────────────────────────────────────────────────────────────────
say "Step C: release ADDS ${DEP} → expect install-service.sh (create)"
# Simulate the module author extending the shipped dependsOn.
tmp="$(mktemp)"; jq --arg d "${DEP}" '.dependsOn += [$d]' "${CONSUMER_JSON}" > "${tmp}" && mv "${tmp}" "${CONSUMER_JSON}"
grep -q "${DEP}" "${CONSUMER_JSON}" && ok "injected ${DEP} into shipped ${CONSUMER}.json" || bad "failed to inject dep"

run_update "${WORK}/update-add.log"; add_rc=$?
[[ "${add_rc}" -eq 0 ]] && ok "update-module.sh (add) exited 0" \
                       || bad "update-module.sh (add) exited ${add_rc} — see ${WORK}/update-add.log"

grep -q "Changed the released value of dependsOn" "${WORK}/update-add.log" \
    && ok "Step 0 WARNED about the changed released dependsOn (#511 reporting)" \
    || bad "no 'Changed the released value of dependsOn' warning in output"

grep -qx "install ${CONSUMER}" "${MARKER}" \
    && ok "Step 3.5 ran install-service.sh (create) for the added dep" \
    || bad "install-service marker missing; markers=[$(tr '\n' ';' < "${MARKER}")]"

grep -qx "delete ${CONSUMER}" "${MARKER}" \
    && bad "delete-service.sh unexpectedly ran on an ADD" \
    || ok "delete-service.sh did NOT run on an add"

if installed_depends_on | grep -qx "${DEP}"; then
    ok "merged config now carries ${DEP} (released list adopted — default behaviour intact)"
else
    bad "merged config did not adopt ${DEP}"
fi

# ─────────────────────────────────────────────────────────────────────────
say "Step D: release REMOVES ${DEP} → expect delete-service.sh (teardown)"
cp "${CONSUMER_JSON_BAK}" "${CONSUMER_JSON}"   # restore shipped list to [cluster:vm]
grep -q "${DEP}" "${CONSUMER_JSON}" && bad "dep still present after restore" || ok "restored shipped ${CONSUMER}.json (dep removed)"

run_update "${WORK}/update-del.log"; del_rc=$?
[[ "${del_rc}" -eq 0 ]] && ok "update-module.sh (remove) exited 0" \
                       || bad "update-module.sh (remove) exited ${del_rc} — see ${WORK}/update-del.log"

grep -qx "delete ${CONSUMER}" "${MARKER}" \
    && ok "Step 3.5 ran delete-service.sh (teardown) for the removed dep" \
    || bad "delete-service marker missing; markers=[$(tr '\n' ';' < "${MARKER}")]"

grep -qx "install ${CONSUMER}" "${MARKER}" \
    && bad "install-service.sh unexpectedly ran on a REMOVE" \
    || ok "install-service.sh did NOT run on a remove"

if installed_depends_on | grep -qx "${DEP}"; then
    bad "merged config still carries ${DEP} after removal"
else
    ok "merged config dropped ${DEP} (released removal adopted)"
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
