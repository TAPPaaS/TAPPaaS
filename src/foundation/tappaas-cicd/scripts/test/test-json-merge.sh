#!/usr/bin/env bash
#
# test-json-merge.sh — tabletop tests for apply-json-merge.sh + convert-json-to-config.sh (#207).
#
# Runs entirely in a temp directory; no VMs touched. Each test case sets up a
# trio of (current, orig, source) JSONs, runs the merge, and asserts the
# expected outcome on the merged config.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/test → scripts → tappaas-cicd → foundation
FOUNDATION_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TAPPAAS_ROOT="${FOUNDATION_DIR}"
TAPPAAS_SCHEMA_FILE="$(mktemp)"
# Composed, not schemas/module-fields.json: since #567 that file holds only
# the 19 generic fields, and these cases resolve service-owned ones.
"${FOUNDATION_DIR}/tappaas-cicd/scripts/compose-fields.sh" "${FOUNDATION_DIR}" > "${TAPPAAS_SCHEMA_FILE}"
export TAPPAAS_SCHEMA_FILE

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/apply-json-merge.sh"
# convert-json-to-config.sh moved to manager/site-manager/ in the c2480cc
# manager/controller reorg; this source path was left pointing at
# scripts/convert-json-to-config.sh, so the file aborted here before running a
# single case (#570). Resolved from the REPO, deliberately: a test in the tree
# must exercise the tree's code, not whatever /home/tappaas/bin is symlinked to.
CONVERTER="${SCRIPT_DIR}/../../manager/site-manager/convert-json-to-config.sh"
[[ -f "${CONVERTER}" ]] || {
    echo "test-json-merge.sh: converter not found at ${CONVERTER}" >&2
    echo "  (it moved once already — if it moved again, fix this path; do not" >&2
    echo "   fall back to /home/tappaas/bin, which can be stale or absent)" >&2
    exit 1
}
# shellcheck disable=SC1090
. "${CONVERTER}"

PASS=0
FAIL=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Run a single case.
# Usage: run_case <name> <current_json> <orig_json> <source_json> <module> <module_dir> <expect_jq_filter>
run_case() {
    local name="$1" cur="$2" orig="$3" src="$4" module="$5" mdir="$6" expect_filter="$7"
    echo "  Case: ${name}"
    # Fresh per-case CONFIG_DIR + module dir
    local cd="${WORKDIR}/${name}/config"
    local md="${WORKDIR}/${name}/${mdir}"
    mkdir -p "${cd}" "${md}"
    if [[ -n "${cur}"  ]]; then echo "${cur}"  > "${cd}/${module}.json"; fi
    if [[ -n "${orig}" ]]; then echo "${orig}" > "${cd}/${module}.json.orig"; fi
    if [[ -n "${src}"  ]]; then echo "${src}"  > "${md}/${module##*-}.json"; fi

    # Call the REAL apply_three_way_merge (#581).
    #
    # This used to re-implement the per-leaf jq inline, on the grounds that
    # _MERGE_CONFIG_DIR is readonly and the file "hard-codes
    # /home/tappaas/config". It does not: that readonly reads
    # TAPPAAS_MERGE_CONFIG_DIR, which exists for exactly this. The duplicate was
    # the worse bargain — it drifted out of step with the code it claimed to
    # cover (its AUTO_FIELDS had lost "environment", and it never saw the Rule 2
    # split), so twelve green cases attested to a copy nobody ships. readonly is
    # per-shell, so each case gets its own subshell.
    local out rc
    out=$(
        TAPPAAS_MERGE_CONFIG_DIR="${cd}" TAPPAAS_SCHEMA_FILE="${TAPPAAS_SCHEMA_FILE}" \
        bash -c '
            . "$1/tappaas-cicd/lib/common-install-routines.sh" >/dev/null 2>&1
            . "$1/tappaas-cicd/lib/apply-json-merge.sh"
            apply_three_way_merge "$2" "$3"
        ' _ "${FOUNDATION_DIR}" "${module}" "${md}" 2>&1
    ) && rc=0 || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        fail "${name} — apply_three_way_merge exited ${rc}: ${out}"
        return
    fi

    # Assert against the FLAT view. The merge stores canonical Pattern A, and
    # which service bucket a field lands in depends on the module's dependsOn —
    # not what these cases are about.
    local merged
    merged=$(jq '
        if (.config | type) == "object"
        then reduce (.config | to_entries[]) as $svc (.; . * $svc.value) | del(.config)
        else . end' "${cd}/${module}.json")

    if echo "${merged}" | jq -e "${expect_filter}" >/dev/null 2>&1; then
        pass "${name}"
    else
        fail "${name} — got: $(echo "${merged}" | jq -c '.')"
    fi
}

echo "── test-json-merge.sh ──"

# Case 1: no-op — current==orig==source → result == current
run_case "no-op" \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","cores":2}' \
    "a" "moda" \
    '.cores == 2'

# Case 2: release bump, operator untouched → adopt
run_case "release-update" \
    '{"vmname":"a","cores":4}' \
    '{"vmname":"a","cores":4}' \
    '{"vmname":"a","cores":8}' \
    "a" "moda" \
    '.cores == 8'

# Case 3: operator pinned → keep operator
run_case "user-pinned" \
    '{"vmname":"a","cores":6}' \
    '{"vmname":"a","cores":4}' \
    '{"vmname":"a","cores":8}' \
    "a" "moda" \
    '.cores == 6'

# Case 4: split — A pinned, B follows release
run_case "split" \
    '{"vmname":"a","cores":6,"memory":4}' \
    '{"vmname":"a","cores":4,"memory":4}' \
    '{"vmname":"a","cores":8,"memory":8}' \
    "a" "moda" \
    '.cores == 6 and .memory == 8'

# Case 5: new release field
run_case "new-release-field" \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","cores":2,"gpu":false}' \
    "a" "moda" \
    '.gpu == false'

# Case 6: operator-added field
run_case "user-added-field" \
    '{"vmname":"a","cores":2,"mySetting":"x"}' \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","cores":2}' \
    "a" "moda" \
    '.mySetting == "x"'

# Case 6b: the release REMOVED a field it used to define → prune it (#581).
# orig HAS it (so it was in the release at install time), source no longer does.
# Keeping it is what made a key unremovable: modify merged source over deployed
# forever, so a stale value outlived the field that gave it meaning.
run_case "release-removed-field" \
    '{"vmname":"a","cores":2,"proxyUpstreamTls":"true"}' \
    '{"vmname":"a","cores":2,"proxyUpstreamTls":"true"}' \
    '{"vmname":"a","cores":2}' \
    "a" "moda" \
    '(has("proxyUpstreamTls") | not) and .cores == 2'

# Case 6c: same, but the operator had CUSTOMIZED the value before the release
# dropped the field. Still pruned — the field it applied to is gone — and the
# merge reports the discarded value rather than swallowing it.
run_case "release-removed-customized" \
    '{"vmname":"a","cores":2,"proxyUpstreamTls":"false"}' \
    '{"vmname":"a","cores":2,"proxyUpstreamTls":"true"}' \
    '{"vmname":"a","cores":2}' \
    "a" "moda" \
    '(has("proxyUpstreamTls") | not)'

# Case 7: array pinned (whole-array equality)
run_case "array-pinned" \
    '{"vmname":"a","nics":[1,2]}' \
    '{"vmname":"a","nics":[1]}' \
    '{"vmname":"a","nics":[1,3]}' \
    "a" "moda" \
    '.nics == [1,2]'

# Case 8: array adopted from release when operator untouched
run_case "array-adopted" \
    '{"vmname":"a","nics":[1]}' \
    '{"vmname":"a","nics":[1]}' \
    '{"vmname":"a","nics":[1,2]}' \
    "a" "moda" \
    '.nics == [1,2]'

# Case 9: auto-stamped field always preserved
run_case "auto-stamped" \
    '{"vmname":"a","installTime":"20260101-00:00:00","cores":2}' \
    '{"vmname":"a","installTime":"20250101-00:00:00","cores":2}' \
    '{"vmname":"a","installTime":"20240101-00:00:00","cores":2}' \
    "a" "moda" \
    '.installTime == "20260101-00:00:00"'

# Case 10: Pattern A on source flattens correctly for compare
run_case "patternA-source" \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","cores":2}' \
    '{"vmname":"a","dependsOn":["cluster:vm"],"config":{"cluster:vm":{"cores":8}}}' \
    "a" "moda" \
    '.cores == 8'

# Case 11: Pattern A on orig + flat current (mid-rollout)
run_case "patternA-orig" \
    '{"vmname":"a","cores":4}' \
    '{"vmname":"a","dependsOn":["cluster:vm"],"config":{"cluster:vm":{"cores":4}}}' \
    '{"vmname":"a","dependsOn":["cluster:vm"],"config":{"cluster:vm":{"cores":8}}}' \
    "a" "moda" \
    '.cores == 8'

# ── The converter paths the libraries hard-code must EXIST (#570) ───────
#
# This file aborted at load for releases on end because a source path was left
# behind by a file move. The same move left two more behind, in the FALLBACK
# arms of apply-json-merge.sh and common-install-routines.sh — arms that only
# run when /home/tappaas/bin is absent, so they were broken exactly in the
# situation they exist for, and nothing noticed.
#
# So: every absolute REPO path either lib names for the converter must resolve.
# A /home/tappaas/bin path is a symlink pre-update.sh refreshes and is not this
# test's business; a path under the repo is.
echo "  Case: hard-coded converter paths resolve"
_bad=""
for _lib in "${SCRIPT_DIR}/../../lib/apply-json-merge.sh" \
            "${SCRIPT_DIR}/../../lib/common-install-routines.sh"; do
    while read -r _p; do
        [[ -n "${_p}" ]] || continue
        case "${_p}" in /home/tappaas/bin/*) continue ;; esac
        [[ -f "${_p}" ]] || _bad+=" $(basename "${_lib}"):${_p}"
    done < <(grep -oE '/home/tappaas/[^"'"'"' ]*convert-json-to-config\.sh' "${_lib}" | sort -u)
done
if [[ -z "${_bad}" ]]; then
    pass "every repo path the libs name for the converter exists"
else
    fail "converter path(s) that do not exist:${_bad}"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
