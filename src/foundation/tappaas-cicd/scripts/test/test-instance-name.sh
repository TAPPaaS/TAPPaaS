#!/usr/bin/env bash
# test-instance-name.sh — an instance name is not a module name (ADR-026 D6.3/D6.4).
#
# The rule for what an instance may be called; `copy-update-json.sh --instance`
# writing config/<instance>.json with .moduleSource on the module; module_of naming
# the module from that .moduleSource; and the default (no --instance) unchanged.
# Uses THIS tree's lib and scripts, never /home/tappaas/bin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
LIB="${CICD}/lib/common-install-routines.sh"
CUJ="${CICD}/manager/module-manager/copy-update-json.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/instname.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# ── instance_name_ok ────────────────────────────────────────────────────────
ok_name() { bash -c '. "$1" >/dev/null 2>&1; instance_name_ok "$2"' _ "${LIB}" "$1" && echo yes || echo no; }
for n in tappaas2 backup nextcloud-lab1 a1; do ck "name '${n}' is accepted" yes "$(ok_name "${n}")"; done
for n in Tappaas2 -x x- a_b "a.b" "" site zones module-fields pull-buddy remote-x receive-nas \
         "$(printf 'a%.0s' {1..64})"; do
    ck "name '${n:0:20}' is refused" no "$(ok_name "${n}")"
done

# ── copy-update-json.sh --instance ──────────────────────────────────────────
MOD="${TMP}/src/foundation/demo"; CFG="${TMP}/config"
mkdir -p "${MOD}" "${CFG}"
MOD="$(cd "${MOD}" && pwd -P)"; CFG="$(cd "${CFG}" && pwd -P)"   # the path the script records
# Generic fields only: a service-owned one (cores → cluster:vm) on a module that
# does not depend on that service cannot be rendered to Pattern A, and the
# mothership's renderer rightly refuses it.
echo '{"description":"demo machine module","version":"0.1.0"}' > "${MOD}/demo.json"
S="${TMP}/schema.json"
"${CICD}/scripts/compose-fields.sh" "${CICD}/.." > "${S}" 2>/dev/null || echo '{"fields":{}}' > "${S}"
cuj() {   # <args...> — source the script as install-module.sh does; print EFFECTIVE_MODULE
    # TAPPAAS_SCHEMA_FILE as well: on a mothership the Pattern A converter runs,
    # and it reads the schema from there or from config/module-fields.json — the
    # cache a real site has and an empty test config/ does not.
    ( cd "${MOD}" && CONFIG_DIR="${CFG}" SCHEMA_FILE="${S}" TAPPAAS_SCHEMA_FILE="${S}" bash -c '
        . "$1" >/dev/null 2>&1; shift; cuj="$1"; shift
        set -- "$@"; . "${cuj}" >/dev/null 2>&1; echo "${EFFECTIVE_MODULE:-}"' _ "${LIB}" "${CUJ}" "$@" )
}
out="$(cuj demo --instance tappaas2)"; rc=$?
ck "--instance: succeeds"                         0 "${rc}"
ck "--instance: EFFECTIVE_MODULE is the instance" tappaas2 "${out}"
[[ -f "${CFG}/tappaas2.json" ]] && ck "--instance: config/tappaas2.json written" ok ok || ck "--instance: config/tappaas2.json written" ok missing
[[ ! -f "${CFG}/demo.json" ]] && ck "--instance: no config/demo.json beside it" ok ok || ck "--instance: no config/demo.json beside it" ok present
ck "--instance: .moduleSource is the MODULE's directory" "${MOD}" "$(jq -r .moduleSource "${CFG}/tappaas2.json" 2>/dev/null)"
ck "--instance: no legacy .location is written (#609)" false "$(jq 'has("location")' "${CFG}/tappaas2.json" 2>/dev/null)"
ck "--instance: the module's fields came across"    0.1.0 "$(jq -r '[.. | objects | select(has("version")) | .version][0]' "${CFG}/tappaas2.json" 2>/dev/null)"

# module_of names the module from .moduleSource, not from the instance name
mo="$(CONFIG_DIR="${CFG}" TAPPAAS_RESOLVE_MODULE_BIN=/nonexistent bash -c '. "$1" >/dev/null 2>&1; module_of "$2"' _ "${LIB}" tappaas2)"
ck "module_of tappaas2 → demo"                    demo "${mo}"

# a bad name is refused before anything is written
rm -f "${CFG}"/*.json
cuj demo --instance Bad_Name >/dev/null; rc=$?
ck "--instance with a bad name: refused"          1 "$(( rc != 0 ))"
ck "…and nothing written"                         0 "$(find "${CFG}" -name '*.json' | wc -l | tr -d ' ')"

# the default is unchanged: no --instance → config/<module>.json
out="$(cuj demo)"
ck "default: EFFECTIVE_MODULE is the module"      demo "${out}"
[[ -f "${CFG}/demo.json" ]] && ck "default: config/demo.json written" ok ok || ck "default: config/demo.json written" ok missing

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
