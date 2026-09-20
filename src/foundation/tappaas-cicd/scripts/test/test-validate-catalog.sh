#!/usr/bin/env bash
# test-validate-catalog.sh — the catalog check (#463), on fixture repositories.
#
# A catalog answers where a module is and which VMID it takes; the check asserts
# those answers hold against the repository. Fixtures are throwaway trees, so
# this runs anywhere — and it pins the shift bug that an entry with no vmid
# caused (tab is IFS whitespace; the separator is \001).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VC="$(cd "${HERE}/../.." && pwd)/manager/site-manager/validate-catalog.sh"
pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

# A repository: two modules, one of them with no guest (no vmid).
mkrepo() {  # <dir> <catalog-json>
    local d="$1"; rm -rf "${d}"; mkdir -p "${d}/src/apps/hass" "${d}/src/foundation/backup"
    echo '{"stack":"home-automation","vmid":210}' > "${d}/src/apps/hass/hass.json"
    echo '{"stack":"foundation","kind":"application"}' > "${d}/src/foundation/backup/backup.json"
    printf '%s\n' "$2" > "${d}/src/module-catalog.json"
}
run()   { "${VC}" "$@" >"${T}/out" 2>&1; echo $?; }
finds() { local n; n="$(grep -c '\[Warning\]' "${T}/out" 2>/dev/null)" || true; echo "${n:-0}"; }
said()  { grep -q "$1" "${T}/out" && echo yes || echo no; }

CLEAN='{"modules":[{"moduleName":"hass","moduleJson":"src/apps/hass/hass.json","vmid":210,"stack":"home-automation"},
                   {"moduleName":"backup","moduleJson":"src/foundation/backup/backup.json","stack":"foundation"}]}'
mkrepo "${T}/r" "${CLEAN}"
ck "a catalog that says true things passes"     "0 0" "$(run "${T}/r") $(finds)"
ck "…and an entry with no vmid does not shift"  "no"  "$(said 'vmid')"
ck "--strict on a clean catalog still exits 0"  0     "$(run "${T}/r" --strict)"

mkrepo "${T}/r" "${CLEAN/src\/apps\/hass\/hass.json/src/apps/hass/gone.json}"
ck "a moduleJson that does not exist is a finding" "yes" "$(run "${T}/r" >/dev/null; said 'does not exist')"
ck "…and --strict makes it fatal"                1 "$(run "${T}/r" --strict)"

mkrepo "${T}/r" '{"modules":[{"moduleName":"hass","moduleJson":"src/apps/hass/hass.json","vmid":210,"stack":"ai"},
                             {"moduleName":"backup","moduleJson":"src/foundation/backup/backup.json","stack":"foundation"}]}'
run "${T}/r" >/dev/null; ck "a stack the module disagrees with is a finding" "yes" "$(said "catalog stack 'ai'")"

mkrepo "${T}/r" "${CLEAN/\"vmid\":210/\"vmid\":999}"
run "${T}/r" >/dev/null; ck "a vmid the module disagrees with is a finding" "yes" "$(said 'catalog vmid 999')"

mkrepo "${T}/r" '{"modules":[{"moduleName":"hass","moduleJson":"src/apps/hass/hass.json","vmid":210,"stack":"home-automation"},
                             {"moduleName":"hass","moduleJson":"src/foundation/backup/backup.json","vmid":210,"stack":"foundation"}]}'
run "${T}/r" >/dev/null
ck "one name, twice, is a finding"  "yes" "$(said "appears 2 times")"
ck "one VMID, twice, is a finding"  "yes" "$(said 'claimed by 2')"

mkrepo "${T}/r" '{"modules":[{"moduleName":"hass","moduleJson":"src/apps/hass/hass.json","vmid":210,"stack":"home-automation"}]}'
run "${T}/r" >/dev/null; ck "a module the catalog does not list is a finding" "yes" "$(said 'catalog does not list')"

mkrepo "${T}/r" '{"modules":[{"moduleName":"hass","moduleJson":"src/apps/hass/hass.json","vmid":210,"stack":"home-automation","status":"beta"},
                             {"moduleName":"backup","moduleJson":"src/foundation/backup/backup.json","stack":"foundation"}]}'
run "${T}/r" >/dev/null; ck "a field the schema dropped is a finding" "yes" "$(said 'does not define: status')"

mkrepo "${T}/r" '{"foundationModules":[{"moduleName":"backup","moduleJson":"src/foundation/backup/backup.json","tier":"foundation","source":"official","stack":"foundation"}],
                  "applicationModules":[{"moduleName":"hass","moduleJson":"src/apps/hass/hass.json","vmid":210,"tier":"app","stack":"home-automation","category":"automation","status":"beta"}]}'
ck "the pre-#463 shape is read, and said to be old" "0 yes" "$(run "${T}/r") $(said 'pre-#463 lists')"
ck "…its tier/source/category are not findings"     1 "$(finds)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
