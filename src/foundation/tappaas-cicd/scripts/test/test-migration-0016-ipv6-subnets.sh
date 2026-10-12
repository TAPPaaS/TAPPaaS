#!/usr/bin/env bash
# test-migration-0016-ipv6-subnets.sh — the fixture test for migration 0016 (ADR-030 D4).
#
# before → after, the VLAN-as-hex rule and its fallback, the zone types it skips,
# --check writes nothing, applying twice is a no-op, the backup holds the
# pre-image, and a shape it does not trust stops it with zones.json untouched.
# Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0016-zones-get-ipv6-subnets.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0016.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# A site's zones: the template ones, an operator's zone off the ten-step grid,
# a zone that already has a number, and the types that never carry IPv6.
zones() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    jq "${1:-.}" <<'J' > "${CFG}/zones.json"
{
  "_README": {"note": "text"},
  "mgmt":    {"type": "Management", "state": "Manual",  "vlantag": 0},
  "admin":   {"type": "Overlay",    "state": "Manual",  "vlantag": 0},
  "wan":     {"type": "WAN",        "state": "Manual",  "vlantag": 100},
  "rossen":  {"type": "Service",    "state": "Active",  "vlantag": 200},
  "home":    {"type": "Client",     "state": "Active",  "vlantag": 310},
  "test":    {"type": "Service",    "state": "Active",  "vlantag": 299},
  "work":    {"type": "Client",     "state": "Active",  "vlantag": 320, "ipv6Subnet": 7},
  "guest":   {"type": "Guest",      "state": "Inactive","vlantag": 510}
}
J
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0016" bash "${M}" "$@" 2>&1; }
num() { jq -r --arg z "$1" '.[$z].ipv6Subnet // "none"' "${CFG}/zones.json"; }

zones
before="$(cat "${CFG}/zones.json")"
out="$(run)"; rc=$?
ck "the run succeeds"                               0 "${rc}"
ck "VLAN 200 → 0x20"                                32 "$(num rossen)"
ck "VLAN 310 → 0x31"                                49 "$(num home)"
ck "VLAN 510 → 0x51 (an Inactive zone is stamped too)" 81 "$(num guest)"
ck "VLAN 299, off the grid → the lowest free number" 1 "$(num test)"
ck "an existing number is kept"                     7 "$(num work)"
ck "Management gets none"                           none "$(num mgmt)"
ck "Overlay gets none"                              none "$(num admin)"
ck "WAN gets none"                                  none "$(num wan)"
ck "…each stamp is reported with how to opt out"    yes "$(has "${out}" "network-manager modify home --unset ipv6Subnet")"
ck "…nothing else changes"                          "$(jq -c 'walk(if type == "object" then del(.ipv6Subnet) else . end)' <<<"${before}")" \
                                                    "$(jq -c 'walk(if type == "object" then del(.ipv6Subnet) else . end) | .work.ipv6Subnet = null | del(.work.ipv6Subnet)' "${CFG}/zones.json")"
ck "…the pre-image is backed up"                    "${before}" "$(cat "${CFG}/.migrations/backup/0016/zones.json")"
after="$(cat "${CFG}/zones.json")"; out="$(run)"
ck "a second run changes nothing"                   "${after}" "$(cat "${CFG}/zones.json")"
ck "…and says so"                                   yes "$(has "${out}" "nothing to migrate")"

# A readable number already taken falls back to the lowest free one.
zones '.work.ipv6Subnet = 49'
run >/dev/null
# Taken in VLAN order: test (299) takes 1 first, so home (310) gets 2.
ck "0x31 taken by another zone → home gets the lowest free" 2 "$(num home)"

zones
out="$(run --check)"
ck "--check writes nothing"                         none "$(num home)"
ck "…and says what it would do"                     yes "$(has "${out}" "would give zone home ipv6Subnet 49 (0x31)")"
ck "…no backup is made"                             no "$([[ -e "${CFG}/.migrations" ]] && echo yes || echo no)"

zones '.home.ipv6Subnet = "x"'
out="$(run)"; rc=$?
ck "a non-integer ipv6Subnet stops it"              1 "${rc}"
ck "…naming the zone"                               yes "$(has "${out}" "home")"
ck "…zones.json untouched"                          none "$(num rossen)"

zones '.home.ipv6Subnet = 7'
out="$(run)"; rc=$?
ck "a number shared by two zones stops it"          1 "${rc}"

echo "── 0016: ${pass} passed, ${fail} failed ──"
[[ "${fail}" -eq 0 ]]
