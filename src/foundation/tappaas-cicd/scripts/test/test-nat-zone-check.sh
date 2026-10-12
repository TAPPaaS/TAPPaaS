#!/usr/bin/env bash
#
# test-nat-zone-check.sh — a port forward reaches only a zone that accepts the
# internet (its pinhole-allowed-from lists `internet`: the dmz), the control
# plane excepted. nat_zone_check decides before anything is created or removed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC="$(readlink -f "${HERE}/../../../network/services/nat/nat-common.sh")"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${NC}" ]] || { echo "nat-common.sh not found — cannot run here."; exit 77; }
command -v jq >/dev/null || { echo "jq not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/natzone.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
cat > "${TMP}/zones.json" <<'Z'
{ "dmz":   { "pinhole-allowed-from": ["internet"] },
  "srv":   { "pinhole-allowed-from": ["home"] },
  "mgmt":  { "pinhole-allowed-from": [] } }
Z

# check <module> <zone0> [effective-zones-json] — prints "allowed", or "refused" plus the error text
check() {
    local eff="${3:-}"
    rm -f "${TMP}/zones.effective.json"
    [[ -n "${eff}" ]] && printf '%s' "${eff}" > "${TMP}/zones.effective.json"
    CONFIG_DIR="${TMP}" JSON="{\"zone0\":\"$2\",\"natRules\":[{\"externalPort\":22}]}" bash -c '
        error() { echo "$*"; }
        die() { echo "DIE: $*"; exit 1; }
        . "'"${NC}"'"
        nat_zone_check "'"$1"'" && echo __PASSED_CHECK__
    ' 2>&1 | { out="$(cat)"; if [[ "${out}" == *__PASSED_CHECK__* ]]; then echo allowed; else echo "refused ${out}"; fi; }
}

ck "a forward into the dmz is allowed"            "allowed" "$(check coturn dmz)"
r="$(check forgejo srv)"
ck "a forward into a service zone is refused"     "refused" "${r%% *}"
ck "…naming the zone"                             "yes" "$([[ "${r}" == *"zone 'srv'"* ]] && echo yes || echo no)"
ck "…and the command that would allow it"         "yes" "$([[ "${r}" == *"network-manager modify srv"* ]] && echo yes || echo no)"
ck "the control plane may expose SSH from mgmt"   "allowed" "$(check tappaas-cicd mgmt)"
ck "another module in mgmt may not"               "refused" "$(r="$(check backup mgmt)"; echo "${r%% *}")"
ck "the effective zones decide when present"      "allowed" \
   "$(check forgejo srv '{"srv":{"pinhole-allowed-from":["home","internet"]}}')"

echo "── nat zone check: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
