#!/usr/bin/env bash
# test-zone0-placement.sh — where a module lands when its release names no zone0 (#349).
#
# A released module names zone0 only when it must live in a particular kind of
# zone; otherwise it names none and the site decides. For a foundation module
# that is mgmt, recorded by copy-update-json.sh — the one path every config is
# written through, the bootstrap's included. Asserts that rule on copy-update-json
# (this tree's, never /home/tappaas/bin) and on the released modules themselves.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUND="$(cd "${CICD}/.." && pwd)"
REPO="$(cd "${FOUND}/../.." && pwd)"
LIB="${CICD}/lib/common-install-routines.sh"
CUJ="${CICD}/manager/module-manager/copy-update-json.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zone0.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

S="${TMP}/schema.json"
"${CICD}/scripts/compose-fields.sh" "${CICD}/.." > "${S}" 2>/dev/null || echo '{"fields":{}}' > "${S}"
CFG="${TMP}/config"; mkdir -p "${CFG}"; CFG="$(cd "${CFG}" && pwd -P)"
cuj() {   # <module> <module.json content> [args...] — prints the deployed zone0 ('-' when absent)
    local m="$1" body="$2"; shift 2
    local d="${TMP}/src/${m}"; mkdir -p "${d}"; echo "${body}" > "${d}/${m}.json"
    ( cd "${d}" && CONFIG_DIR="${CFG}" SCHEMA_FILE="${S}" TAPPAAS_SCHEMA_FILE="${S}" bash -c '
        . "$1" >/dev/null 2>&1; shift; cuj="$1"; shift
        set -- "$@"; . "${cuj}" >/dev/null 2>&1' _ "${LIB}" "${CUJ}" "${m}" "$@" )
    jq -r '[.. | objects | .zone0? // empty] | first // "-"' "${CFG}/${m}.json" 2>/dev/null || echo "?"
}

ck "a foundation module naming no zone0 lands in mgmt"   mgmt "$(cuj fmod '{"tier":"foundation","description":"f"}')"
ck "a foundation module naming its own zone keeps it"    edge "$(cuj smod '{"tier":"foundation","zone0":"edge","description":"s"}')"
ck "an explicit --zone0 still wins"                      lab  "$(cuj gmod '{"tier":"foundation","description":"g"}' --zone0 lab)"
ck "an app naming none is left for install to resolve"   -    "$(cuj amod '{"tier":"app","description":"a"}')"

# The rule, on the released modules themselves.
for m in network tappaas-cicd backup identity logging; do
    ck "released ${m} names no zone0" "" "$(jq -r '[.. | objects | .zone0? // empty] | first // empty' "${FOUND}/${m}/${m}.json")"
done
for f in templates/tappaas-nixos.json templates/tappaas-winserver.json; do
    ck "released ${f##*/} names no zone0" "" "$(jq -r '[.. | objects | .zone0? // empty] | first // empty' "${FOUND}/${f}")"
done
for pair in apps/coturn:dmz apps/vaultwarden:dmz apps/deconz:iotCloud apps/netbird-client:home foundation/satellite:edge; do
    p="${pair%%:*}"; z="${pair#*:}"
    ck "${p##*/} keeps the zone it must live in (${z})" "${z}" "$(jq -r '[.. | objects | .zone0? // empty] | first // empty' "${REPO}/src/${p}/${p##*/}.json")"
done

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
