#!/usr/bin/env bash
# test-migration-0026-zone-consent.sh — the fixture test for migration 0026 (#816).
#
# The shape of the 2026-10-26 site: fleets in iotCloud egress to a module in
# srvHome, a NAS in srvHome egresses to mgmt, a module in srvHome depends on an
# iotCloud provider with a pinhole.json. Each gets its zone consent; a rule
# access-to already allows, one inside a zone, an archived module, internet
# ingress and a service without ports get none; --check writes nothing; a second
# run is a no-op; the backup holds the pre-image; a broken zone stops it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0026-zones-consent-to-existing-rules.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0026.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"; SRC="${TMP}/src"

run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0026" bash "${M}" "$@" 2>&1; }
paf() { jq -c --arg z "$1" '.[$z]["pinhole-allowed-from"] // []' "${CFG}/zones.json"; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }
mod() { printf '%s\n' "$2" > "${CFG}/$1.json"; }

site() {
    rm -rf "${CFG}" "${SRC}"; mkdir -p "${CFG}" "${SRC}/sonos/services/audio" "${SRC}/sonos/services/discovery"
    cat > "${CFG}/zones.json" <<'EOF'
{"_README": "x",
 "mgmt":     {"type": "Management", "access-to": ["internet", "all"], "pinhole-allowed-from": []},
 "srvHome":  {"type": "Service", "access-to": ["internet"], "pinhole-allowed-from": ["home"]},
 "iotCloud": {"type": "IoT", "access-to": ["internet"]},
 "home":     {"type": "Client", "access-to": ["internet", "srvHome"], "pinhole-allowed-from": []}}
EOF
    echo '{"ports":[{"port":1400,"protocol":"tcp"}]}' > "${SRC}/sonos/services/audio/pinhole.json"
    echo '{"ports":[]}' > "${SRC}/sonos/services/discovery/pinhole.json"
    mod site '{"name":"s","zone0":"mgmt"}'
    mod hassanova '{"vmname":"hassanova","zone0":"srvHome","dependsOn":["sonos:audio","sonos:discovery","network:rules"]}'
    mod sonos "{\"vmname\":\"sonos\",\"zone0\":\"iotCloud\",\"moduleSource\":\"${SRC}/sonos\",\"egress\":[{\"to\":\"hassanova\",\"ports\":[8123],\"description\":\"d\"}]}"
    mod deconz '{"vmname":"deconz","zone0":"iotCloud","egress":[{"to":"hassanova","ports":[8123],"description":"d"},{"to":"hassanova","ports":[1883],"description":"d"},{"to":"internet","ports":[443],"description":"d"}]}'
    mod synology '{"vmname":"synology","zone0":"srvHome","egress":[{"to":"mgmt","ports":[514],"description":"d"},{"to":"srvHome","ports":[1],"description":"d"}]}'
    mod laptop '{"vmname":"laptop","zone0":"home","egress":[{"to":"hassanova","ports":[8123],"description":"d"}]}'
    mod web '{"vmname":"web","zone0":"srvHome","ingress":[{"from":"internet","ports":[443],"description":"d"}]}'
    mod network '{"vmname":"network","zone0":"mgmt","ingress":[{"from":"internet","ports":[443],"description":"d"}]}'
    mod oldcam '{"vmname":"oldcam","zone0":"iotCloud","status":"archived","egress":[{"to":"mgmt","ports":[1],"description":"d"}]}'
}

site
before="$(cat "${CFG}/zones.json")"
out="$(run --check)"; rc=$?
ck "--check succeeds"                                   0 "${rc}"
ck "--check writes nothing"                             "${before}" "$(cat "${CFG}/zones.json")"
ck "…and names each grant with who needs it"            yes "$(has "${out}" "would add iotCloud to srvHome.pinhole-allowed-from — for deconz (egress to hassanova), sonos (egress to hassanova)")"
ck "…a module with two rules for one grant is named once" 1 "$(grep -o 'deconz (egress to hassanova)' <<<"${out}" | wc -l | tr -d ' ')"

out="$(run)"; rc=$?
ck "the run succeeds"                                   0 "${rc}"
ck "egress iotCloud → srvHome: srvHome accepts iotCloud (kept 'home')" '["home","iotCloud"]' "$(paf srvHome)"
ck "egress srvHome → mgmt: mgmt accepts srvHome"        '["srvHome"]' "$(paf mgmt)"
ck "an auto-pinhole srvHome → iotCloud: iotCloud accepts srvHome" '["srvHome"]' "$(paf iotCloud)"
ck "…named after the dependency"                        yes "$(has "${out}" "for hassanova (sonos:audio)")"
ck "a service whose pinhole.json has no ports needs no consent" no "$(has "${out}" "sonos:discovery")"
ck "a rule access-to already allows gets none (home)"   '[]' "$(paf home)"
ck "an archived module gets none"                       no "$(has "${out}" "oldcam")"
ck "internet ingress is not granted…"                   no "$(jq -r '.srvHome["pinhole-allowed-from"] | index("internet") != null' "${CFG}/zones.json" | sed 's/false/no/;s/true/yes/')"
ck "…but said, with the command"                        yes "$(has "${out}" "web: ingress from the internet into srvHome — not granted")"
ck "the firewall's own internet ingress is no finding" no "$(has "${out}" "network: ingress")"
ck "other zone fields are kept"                         '"x"' "$(jq -c ._README "${CFG}/zones.json")"
ck "the pre-image is backed up"                         "${before}" "$(cat "${CFG}/.migrations/backup/0026/zones.json")"
after="$(cat "${CFG}/zones.json")"; out="$(run)"
ck "a second run changes nothing"                       "${after}" "$(cat "${CFG}/zones.json")"
ck "…and says so"                                       yes "$(has "${out}" "nothing to migrate")"

site
jq '.mgmt["pinhole-allowed-from"] = "srvHome"' "${CFG}/zones.json" > "${CFG}/z" && mv "${CFG}/z" "${CFG}/zones.json"
before="$(cat "${CFG}/zones.json")"
out="$(run)"; rc=$?
ck "a pinhole-allowed-from that is not a list stops it" 1 "${rc}"
ck "…with the file untouched"                           "${before}" "$(cat "${CFG}/zones.json")"

rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "no zones.json: nothing to do"                       0 "${rc}"

echo
echo "── ${pass} passed, ${fail} failed ──"
[[ "${fail}" -eq 0 ]]
