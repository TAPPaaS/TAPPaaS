#!/usr/bin/env bash
# test-migration-0023-shared-zones.sh — the fixture test for migration 0023 (#876).
#
# Erik's site after the first 0018: gridtefy's own zone `gridtefy` and the
# shared zone `srvWork` both name "gridtefy" as a string. With 0018's pre-image
# the zone the environment named before keeps it; without it the zone named
# like the environment does; with neither the migration refuses. --check writes
# nothing, applying twice is a no-op, the backup holds the pre-image, and a site
# with no contested environment (hrossen's shape) is left as it is.
# Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0023-shared-service-zones-repaired.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0023.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# Erik's post-0018 shape. $1 edits zones.json; $2 (optional) is the zone
# gridtefy named as its network.zone in 0018's pre-image.
erik() {
    rm -rf "${CFG}"; mkdir -p "${CFG}/environments"
    jq "${1:-.}" <<'J' > "${CFG}/zones.json"
{
  "_README":  {"note": "text"},
  "mgmt":     {"type": "Management", "state": "Manual", "environment": "mgmt"},
  "erik":     {"type": "Service",    "state": "Active", "environment": "erik"},
  "gridtefy": {"type": "Service",    "state": "Active", "environment": "gridtefy"},
  "acmeco":   {"type": "Service",    "state": "Active", "environment": "acmeco"},
  "srvWork":  {"type": "Service",    "state": "Active", "environment": "gridtefy"},
  "work":     {"type": "Client",     "state": "Active", "environment": ["gridtefy", "acmeco"]},
  "home":     {"type": "Client",     "state": "Active", "environment": "erik"}
}
J
    for e in mgmt erik gridtefy acmeco; do
        jq -n --arg e "${e}" '{name: $e, displayName: $e, ownerOrg: "o"}' > "${CFG}/environments/${e}.json"
    done
    if [[ -n "${2:-}" ]]; then
        mkdir -p "${CFG}/.migrations/backup/0018/environments"
        jq -n --arg z "$2" '{name: "gridtefy", displayName: "gridtefy", ownerOrg: "o", network: {zone: $z}}' \
            > "${CFG}/.migrations/backup/0018/environments/gridtefy.json"
    fi
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0023" bash "${M}" "$@" 2>&1; }
env_of() { jq -c --arg z "$1" '.[$z].environment' "${CFG}/zones.json"; }

# With 0018's pre-image naming gridtefy: gridtefy keeps it, srvWork is shared.
erik '.' gridtefy
zbefore="$(cat "${CFG}/zones.json")"
out="$(run)"; rc=$?
ck "the run succeeds"                                  0 "${rc}"
ck "gridtefy stays gridtefy's own zone"                '"gridtefy"' "$(env_of gridtefy)"
ck "srvWork becomes a shared service zone"             '["gridtefy"]' "$(env_of srvWork)"
ck "…nothing else changes"                             "$(jq -c 'del(.srvWork.environment)' <<<"${zbefore}")" "$(jq -c 'del(.srvWork.environment)' "${CFG}/zones.json")"
ck "…said with its reason"                             yes "$(has "${out}" "gridtefy keeps zone gridtefy (it was its zone before 0018); srvWork becomes a shared service zone")"
ck "the pre-image is backed up"                        "${zbefore}" "$(cat "${CFG}/.migrations/backup/0023/zones.json")"
after="$(cat "${CFG}/zones.json")"; out="$(run)"
ck "a second run changes nothing"                      "${after}" "$(cat "${CFG}/zones.json")"
ck "…and says so"                                      yes "$(has "${out}" "nothing to migrate")"

# The pre-image decides even against the name: gridtefy named srvWork before 0018.
erik '.' srvWork
run >/dev/null; rc=$?
ck "the pre-image wins over the name"                  0 "${rc}"
ck "…srvWork stays gridtefy's own zone"                '"gridtefy"' "$(env_of srvWork)"
ck "…and the zone named gridtefy becomes shared"       '["gridtefy"]' "$(env_of gridtefy)"

# A pre-image naming a zone that is not among the competitors falls back to the name.
erik '.' nosuch
run >/dev/null
ck "a pre-image naming neither falls back to the name" '"gridtefy"' "$(env_of gridtefy)"

# Without the pre-image: the zone named like the environment keeps it.
erik
run >/dev/null; rc=$?
ck "without the pre-image the run succeeds"            0 "${rc}"
ck "…the zone named gridtefy keeps it"                 '"gridtefy"' "$(env_of gridtefy)"
ck "…srvWork becomes shared"                           '["gridtefy"]' "$(env_of srvWork)"
ck "…an existing shared list is left alone"            '["gridtefy","acmeco"]' "$(env_of work)"

erik
before="$(cat "${CFG}/zones.json")"; out="$(run --check)"
ck "--check writes nothing"                            "${before}" "$(cat "${CFG}/zones.json")"
ck "…and says what it would do"                        yes "$(has "${out}" "would repair: gridtefy keeps zone gridtefy (it is named like the environment); srvWork becomes a shared service zone")"
ck "…no backup is made"                                no "$([[ -e "${CFG}/.migrations/backup/0023" ]] && echo yes || echo no)"

# Refusals: nothing changes.
refuse() {  # <label> <expected fragment> <zones edit> [pre-image zone]
    erik "$3" "${4:-}"
    local b; b="$(cat "${CFG}/zones.json")"
    local o; o="$(run)"; local r=$?
    ck "$1 stops it"                                   1 "${r}"
    ck "…naming why"                                   yes "$(has "${o}" "$2")"
    ck "…with nothing changed"                         "${b}" "$(cat "${CFG}/zones.json")"
}
refuse "competitors neither rule decides" \
       "environment gridtefy is named as its own by 2 zones (srvWork, srvTeam)" \
       '.srvTeam = .gridtefy | del(.gridtefy)'
refuse "a Management zone that would be shared" \
       "would make the Management zone mgmt shared" \
       '.mgmt.environment = "erik"'

# hrossen's shape: one own zone per environment — nothing to do.
rm -rf "${CFG}"; mkdir -p "${CFG}"
jq -n '{mgmt: {type: "Management", environment: "mgmt"}, rossen: {type: "Service", environment: "rossen"},
        test: {type: "Service", environment: "test"}, home: {type: "Client", environment: "rossen"},
        iotLocal: {type: "IoT", environment: "rossen"}, dmz: {type: "DMZ"}}' > "${CFG}/zones.json"
before="$(cat "${CFG}/zones.json")"; out="$(run)"; rc=$?
ck "a site with no contested environment is a no-op"  0 "${rc}"
ck "…zones.json is untouched"                          "${before}" "$(cat "${CFG}/zones.json")"
ck "…and it says so"                                   yes "$(has "${out}" "nothing to migrate")"

# No zones.json: nothing to do.
rm -rf "${CFG}"; mkdir -p "${CFG}"
run >/dev/null; rc=$?
ck "no zones.json is nothing to migrate"               0 "${rc}"

echo "  test-migration-0023: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
