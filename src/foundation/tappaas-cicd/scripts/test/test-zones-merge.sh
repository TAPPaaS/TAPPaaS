#!/usr/bin/env bash
#
# test-zones-merge.sh — tabletop tests for apply-zones-merge.sh (#209).
#
# Each case writes fixture files into a temp dir, invokes apply-zones-merge.sh
# with TAPPAAS_ZONES_SOURCE + a per-case CONFIG_DIR, then asserts on the
# merged zones.json.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_SCRIPT="${SCRIPT_DIR}/../apply-zones-merge.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Run one case.
#   $1 case name
#   $2 current zones.json content
#   $3 orig zones.json content (empty string → no .orig file)
#   $4 source zones.json content
#   $5 jq filter that must succeed on the merged file (assertion)
#   $6 optional: jq filter that must succeed on the stderr report
run_case() {
    local name="$1" cur="$2" orig="$3" src="$4" assert_merged="$5" assert_report="${6:-}"
    echo "  Case: ${name}"
    local case_dir="${WORK}/${name}"
    mkdir -p "${case_dir}/config"
    local cur_file="${case_dir}/config/zones.json"
    local orig_file="${case_dir}/config/zones.json.orig"
    local src_file="${case_dir}/src.json"
    echo "${cur}" > "${cur_file}"
    [[ -n "${orig}" ]] && echo "${orig}" > "${orig_file}"
    echo "${src}" > "${src_file}"

    local report
    if ! report=$(CONFIG_DIR="${case_dir}/config" TAPPAAS_ZONES_SOURCE="${src_file}" \
                    "${MERGE_SCRIPT}" 2>&1); then
        fail "${name}: merge script exited non-zero"
        echo "${report}" | sed 's/^/      /'
        return
    fi

    if ! jq -e "${assert_merged}" "${cur_file}" >/dev/null 2>&1; then
        fail "${name}: merged assertion failed (${assert_merged})"
        echo "    merged: $(jq -c '.' "${cur_file}")"
        return
    fi

    if [[ -n "${assert_report}" ]]; then
        if ! echo "${report}" | grep -qE "${assert_report}"; then
            fail "${name}: report assertion failed (${assert_report})"
            echo "${report}" | sed 's/^/      /'
            return
        fi
    fi

    pass "${name}"
}

echo "── test-zones-merge.sh ──"

# Case 1: no-op when c == o == s.
ZONES='{"home":{"type":"Client","state":"Active","vlantag":300,"description":"d"}}'
run_case "no-op" "${ZONES}" "${ZONES}" "${ZONES}" \
    '.home.state == "Active" and .home.description == "d"'

# Case 2: release bumps description; operator untouched → adopt.
run_case "release-adopt" \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"old"}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"old"}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"new"}}' \
    '.home.description == "new"'

# Case 3: operator pinned state — AUTO_FIELD: never adopt from source.
run_case "auto-field-state-pinned" \
    '{"srv":{"type":"Service","state":"Active","vlantag":200}}' \
    '{"srv":{"type":"Service","state":"Inactive","vlantag":200}}' \
    '{"srv":{"type":"Service","state":"Inactive","vlantag":200}}' \
    '.srv.state == "Active"'

# Case 4: operator pinned ip — non-auto field, but current != orig → pinned.
run_case "operator-pinned-ip" \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"ip":"10.4.0.0/24"}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"ip":"10.3.0.0/24"}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"ip":"10.3.0.0/24"}}' \
    '.home.ip == "10.4.0.0/24"'

# Case 5: split — operator changed state, release changed vlantag.
run_case "split-state-and-vlantag" \
    '{"home":{"type":"Client","state":"Active","vlantag":300}}' \
    '{"home":{"type":"Client","state":"Inactive","vlantag":300}}' \
    '{"home":{"type":"Client","state":"Inactive","vlantag":301}}' \
    '.home.state == "Active" and .home.vlantag == 301'

# Case 6: zone added in source.
run_case "zone-added" \
    '{"home":{"type":"Client","state":"Active","vlantag":300}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300},"srv-cust":{"type":"Service","state":"Inactive","vlantag":230}}' \
    '.["srv-cust"].state == "Inactive" and .home.state == "Active"' \
    'added.*srv-cust'

# Case 7: zone kept (orphan — in current but not source).
run_case "zone-kept-orphan" \
    '{"home":{"type":"Client","state":"Active","vlantag":300},"legacy":{"type":"Client","state":"Active","vlantag":999}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300},"legacy":{"type":"Client","state":"Active","vlantag":999}}' \
    '{"home":{"type":"Client","state":"Active","vlantag":300}}' \
    '.legacy.state == "Active"' \
    'kept.*legacy|legacy'

# Case 8: possible rename — same vlantag, different name.
run_case "possible-rename" \
    '{"test3":{"type":"Test","state":"Inactive","vlantag":830}}' \
    '{"test3":{"type":"Test","state":"Inactive","vlantag":830}}' \
    '{"lab":{"type":"Test","state":"Inactive","vlantag":830}}' \
    '.test3.state == "Inactive" and .lab.state == "Inactive"' \
    'vlantag=830: source=lab vs current=test3'

# Case 9: backfill — .orig missing → cp source → orig, operator customizations preserved.
run_case "backfill-preserves-customizations" \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"custom"}}' \
    '' \
    '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"upstream"}}' \
    '.home.description == "custom"'

# Case 10: idempotent — second run produces no further change.
ZONES='{"home":{"type":"Client","state":"Active","vlantag":300,"description":"d"}}'
echo "  Case: idempotent"
case_dir="${WORK}/idempotent"
mkdir -p "${case_dir}/config"
echo "${ZONES}" > "${case_dir}/config/zones.json"
echo "${ZONES}" > "${case_dir}/src.json"
CONFIG_DIR="${case_dir}/config" TAPPAAS_ZONES_SOURCE="${case_dir}/src.json" \
    "${MERGE_SCRIPT}" >/dev/null 2>&1 || true
md5_first=$(md5sum "${case_dir}/config/zones.json" | awk '{print $1}')
CONFIG_DIR="${case_dir}/config" TAPPAAS_ZONES_SOURCE="${case_dir}/src.json" \
    "${MERGE_SCRIPT}" >/dev/null 2>&1 || true
md5_second=$(md5sum "${case_dir}/config/zones.json" | awk '{print $1}')
if [[ "${md5_first}" == "${md5_second}" ]]; then
    pass "idempotent"
else
    fail "idempotent: md5 changed across runs (${md5_first} → ${md5_second})"
fi

# Case 11: --diff does not mutate the file.
echo "  Case: --diff-does-not-write"
case_dir="${WORK}/diff"
mkdir -p "${case_dir}/config"
echo '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"old"}}' > "${case_dir}/config/zones.json"
echo '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"old"}}' > "${case_dir}/config/zones.json.orig"
echo '{"home":{"type":"Client","state":"Active","vlantag":300,"description":"new"}}' > "${case_dir}/src.json"
md5_before=$(md5sum "${case_dir}/config/zones.json" | awk '{print $1}')
CONFIG_DIR="${case_dir}/config" TAPPAAS_ZONES_SOURCE="${case_dir}/src.json" \
    "${MERGE_SCRIPT}" --diff >/dev/null 2>&1 || true
md5_after=$(md5sum "${case_dir}/config/zones.json" | awk '{print $1}')
if [[ "${md5_before}" == "${md5_after}" ]]; then
    pass "--diff-does-not-write"
else
    fail "--diff-does-not-write: file changed"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
