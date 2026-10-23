#!/usr/bin/env bash
# test-migration-0018-zone-environment.sh — the fixture test for migration 0018 (#865).
#
# before → after on a site shaped like the reference system (an environment per
# Service zone, mgmt on the Management zone, client and IoT zones serving one),
# --check writes nothing, applying twice is a no-op, the backup holds the
# pre-image, and every shape it does not trust stops it with nothing changed.
# Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0018-zone-names-its-environment.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0018.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# The reference system's shape. $1 edits zones.json, $2 is run in environments/.
site() {
    rm -rf "${CFG}"; mkdir -p "${CFG}/environments"
    jq "${1:-.}" <<'J' > "${CFG}/zones.json"
{
  "_README": {"note": "text"},
  "mgmt":     {"type": "Management", "state": "Manual"},
  "admin":    {"type": "Overlay",    "state": "Manual"},
  "rossen":   {"type": "Service",    "state": "Active"},
  "test":     {"type": "Service",    "state": "Active"},
  "work":     {"type": "Client",     "state": "Inactive"},
  "home":     {"type": "Client",     "state": "Active", "serves": "rossen"},
  "iotLocal": {"type": "IoT",        "state": "Active", "serves": "rossen"},
  "iotCams":  {"type": "IoT",        "state": "Active", "serves": ["rossen"]},
  "dmz":      {"type": "DMZ",        "state": "Mandatory"},
  "guest":    {"type": "Guest",      "state": "Active"}
}
J
    for e in mgmt rossen test; do
        jq -n --arg e "${e}" '{name: $e, displayName: $e, ownerOrg: "o", network: {zone: $e}}' > "${CFG}/environments/${e}.json"
    done
    if [[ -n "${2:-}" ]]; then ( cd "${CFG}/environments" && eval "$2" ); fi
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0018" bash "${M}" "$@" 2>&1; }
env_of() { jq -r --arg z "$1" '.[$z].environment // "none"' "${CFG}/zones.json"; }
snapshot() { (cd "${CFG}" && cat zones.json environments/*.json); }

site
zbefore="$(cat "${CFG}/zones.json")"; rbefore="$(cat "${CFG}/environments/rossen.json")"
out="$(run)"; rc=$?
ck "the run succeeds"                                  0 "${rc}"
ck "mgmt names mgmt (its zone)"                        mgmt "$(env_of mgmt)"
ck "rossen names rossen (its zone)"                    rossen "$(env_of rossen)"
ck "test names test (its zone)"                        test "$(env_of test)"
ck "home serves rossen"                                rossen "$(env_of home)"
ck "an IoT zone serves rossen"                         rossen "$(env_of iotLocal)"
ck "a one-element serves list becomes its name"        rossen "$(env_of iotCams)"
ck "a zone with neither names none"                    none "$(env_of work)"
ck "no zone keeps serves"                              0 "$(jq '[.[] | objects | select(has("serves"))] | length' "${CFG}/zones.json")"
ck "no environment keeps network"                      0 "$(jq -s '[.[] | select(has("network"))] | length' "${CFG}"/environments/*.json)"
ck "…the rest of an environment is kept"               '{"name":"rossen","displayName":"rossen","ownerOrg":"o"}' "$(jq -c . "${CFG}/environments/rossen.json")"
ck "…nothing else in zones.json changes"               "$(jq -c 'walk(if type == "object" then del(.serves) else . end)' <<<"${zbefore}")" \
                                                       "$(jq -c 'walk(if type == "object" then del(.environment) else . end)' "${CFG}/zones.json")"
ck "…each link is reported"                            yes "$(has "${out}" "gave zone home environment rossen (it serves rossen)")"
ck "…and its own zone said as such"                    yes "$(has "${out}" "gave zone rossen environment rossen (its zone)")"
ck "the zones.json pre-image is backed up"             "${zbefore}" "$(cat "${CFG}/.migrations/backup/0018/zones.json")"
ck "an environment's pre-image is backed up"           "${rbefore}" "$(cat "${CFG}/.migrations/backup/0018/environments/rossen.json")"
after="$(snapshot)"; out="$(run)"
ck "a second run changes nothing"                      "${after}" "$(snapshot)"
ck "…and says so"                                      yes "$(has "${out}" "nothing to migrate")"

# A half-done run (zones written, an environment file still naming its zone)
# converges rather than stopping.
site '.rossen.environment = "rossen"'
run >/dev/null; rc=$?
ck "an already-written link that agrees converges"     0 "${rc}"
ck "…and the environment loses network"                false "$(jq 'has("network")' "${CFG}/environments/rossen.json")"

site
before="$(snapshot)"; out="$(run --check)"
ck "--check writes nothing"                            "${before}" "$(snapshot)"
ck "…and says what it would do"                        yes "$(has "${out}" "would give zone iotCams environment rossen (it serves rossen)")"
ck "…and which fields go"                              yes "$(has "${out}" "would remove network from: mgmt.json, rossen.json, test.json")"
ck "…no backup is made"                                no "$([[ -e "${CFG}/.migrations" ]] && echo yes || echo no)"

# Refusals: each leaves zones.json and every environment file as they were.
refuse() {  # <label> <expected fragment> <zones edit> [env edit]
    site "$3" "${4:-}"
    local b; b="$(snapshot)"
    local o; o="$(run)"; local r=$?
    ck "$1 stops it"                                   1 "${r}"
    ck "…naming why"                                   yes "$(has "${o}" "$2")"
    ck "…with nothing changed"                         "${b}" "$(snapshot)"
}
refuse "a zone serving two environments"        "zone home would name 2 environments (rossen, test)" '.home.serves = ["rossen", "test"]'
refuse "serves disagreeing with the zone's own"  "zone test would name 2 environments (rossen, test)" '.test.serves = "rossen" | .test.type = "Client"'
refuse "two environments naming one zone"        "zone rossen would name 2 environments (rossen, test)" '.' \
       'jq ".network.zone = \"rossen\"" test.json > t && mv t test.json'
refuse "an environment naming a missing zone"    "names zone ghost, which is not in zones.json" '.' \
       'jq ".network.zone = \"ghost\"" test.json > t && mv t test.json'
refuse "an environment naming a Client zone"     "names zone work as its zone, but that is a Client zone" '.' \
       'jq ".network.zone = \"work\"" test.json > t && mv t test.json'
refuse "serves on a Service zone"                "zone test is a Service zone and carries serves" '.test.serves = "test"'
refuse "serves that is not a name"               "zone home: serves is not an environment name" '.home.serves = 7'
refuse "a file whose name disagrees"             "says name \"other\"" '.' \
       'jq ".name = \"other\"" test.json > t && mv t test.json'
refuse "an existing link that disagrees"         "zone rossen would name 2 environments" '.rossen.environment = "test"'

# No zones.json: nothing to do.
rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "no zones.json is nothing to migrate"               0 "${rc}"

echo "  test-migration-0018: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
