#!/usr/bin/env bash
# test-migration-0025-ssids.sh — the fixture test for migration 0025 (#889).
#
# fixtures/0025-two-aps: two access points declaring rossen-home and rossen-iot
# with the same settings, one (ap-loft) also rossen-guest; zones.json with the
# template placeholders and one hand-set name. And hrossen's switch
# configuration (fixtures/0021-hrossen: one AP, no SSIDs). Before → after,
# --check writes nothing, applying twice is a no-op, the backup holds what it
# rewrote, ap-manager derives the same per-AP SSIDs from the list, and each
# refusal (conflicting settings, a foreign VLAN, two SSIDs on one zone, an
# unknown zone) leaves every file as it was. Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0025-ssids-become-site-wide.sh"
FIX="${HERE}/fixtures/0025-two-aps"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { grep -q -- "$2" <<<"$1" && echo yes || echo no; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
[[ -f "${FIX}/zones.json" ]] || { echo "  ✗ the fixtures are not in ${FIX}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0025.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"
fresh() { rm -rf "${CFG}"; mkdir -p "${CFG}"; cp "${FIX}"/*.json "${CFG}/"; }
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0025" bash "${M}" "$@" 2>&1; }
cfg() { jq -c "$2" "${CFG}/$1"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "${f}" "$(cksum < "${f}")"; done); }
edit() { jq "$2" "${CFG}/$1" > "${CFG}/$1.t" && mv "${CFG}/$1.t" "${CFG}/$1"; }

echo "test-migration-0025:"

# ── hrossen as it is: one AP, no SSIDs ──
rm -rf "${CFG}"; mkdir -p "${CFG}"; cp "${HERE}/fixtures/0021-hrossen/switch-configuration-desired.json" "${CFG}/"
echo '{"home":{"type":"Client","vlantag":310,"state":"Active","SSID":"<HOME_SSID>"}}' > "${CFG}/zones.json"
before="$(snap)"; out="$(run)"; rc=$?
ck "hrossen's config: exit 0"                     0 "${rc}"
ck "…nothing to migrate"                          yes "$(has "${out}" 'no access point declares an SSID')"
ck "…no file touched"                             "${before}" "$(snap)"

# ── two APs, the same SSIDs ──
fresh
before="$(snap)"; out="$(run --check)"; rc=$?
ck "--check: exit 0"                              0 "${rc}"
ck "…says what it would do"                       yes "$(has "${out}" 'would: SSID rossen-home → zone home, wpa2-personal, on every access point')"
ck "…writes nothing"                              "${before}" "$(snap)"
ck "…no backup"                                   no "$([[ -d "${CFG}/.migrations" ]] && echo yes || echo no)"

out="$(run)"; rc=$?
ck "apply: exit 0"                                0 "${rc}"
ck "one entry per SSID"                           '["rossen-guest","rossen-home","rossen-iot"]' "$(cfg switch-configuration-desired.json '.ssids | keys')"
ck "declared on both APs: broadcast on all"       '{"zone":"home","security":"wpa2-personal","broadcastOn":"all"}' "$(cfg switch-configuration-desired.json '.ssids["rossen-home"]')"
ck "declared on one: that AP, captive kept"       '{"zone":"guest","security":"open","captive":true,"broadcastOn":["ap-loft"]}' "$(cfg switch-configuration-desired.json '.ssids["rossen-guest"]')"
ck "each AP's SSIDs as they were"                 "$(jq -c .accessPoints "${FIX}/switch-configuration-desired.json")" "$(cfg switch-configuration-desired.json .accessPoints)"
ck "the zones name their SSIDs"                   '["rossen-home","rossen-iot","rossen-guest","<WORK_SSID>"]' "$(cfg zones.json '[.home.SSID, .iotLocal.SSID, .guest.SSID, .work.SSID]')"
ck "…a placeholder replaced is reported"          yes "$(has "${out}" 'zone home names SSID rossen-home (was the template <HOME_SSID>)')"
ck "…a hand-set name replaced is reported"        yes "$(has "${out}" 'it named OldGuest, which no access point declared')"
ck "…nothing else in zones.json changed"          "$(jq -c 'del(.home.SSID, .iotLocal.SSID, .guest.SSID)' "${FIX}/zones.json")" "$(cfg zones.json 'del(.home.SSID, .iotLocal.SSID, .guest.SSID)')"
ck "the backup holds both files as they were"     "$(jq -c . "${FIX}/switch-configuration-desired.json")|$(jq -c . "${FIX}/zones.json")" \
    "$(jq -c . "${CFG}/.migrations/backup/0025/switch-configuration-desired.json")|$(jq -c . "${CFG}/.migrations/backup/0025/zones.json")"
before="$(snap)"; out="$(run)"; rc=$?
ck "a second run: exit 0, nothing to do"          "0 yes" "${rc} $(has "${out}" 'nothing to migrate')"
ck "…no file touched"                             "${before}" "$(snap)"

# ap-manager derives the same per-AP SSIDs from the list (the derived view).
AM="${CICD}/manager/ap-manager/ap-manager"
if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
    # shellcheck source=../../manager/ap-manager/test-lib.bash
    . "${CICD}/manager/ap-manager/test-lib.bash"
    CONFIG_DIR="${CFG}" AP_NETWORK_MANAGER="$(make_nm_stub "${TMP}")" "${AM}" update-desired >/dev/null 2>&1; rc=$?
    ck "ap-manager update-desired on the result (rc)" 0 "${rc}"
    ck "…derives each AP's SSIDs unchanged"       "$(jq -cS .accessPoints "${FIX}/switch-configuration-desired.json")" "$(jq -cS .accessPoints "${CFG}/switch-configuration-desired.json")"
    out="$(CONFIG_DIR="${CFG}" "${AM}" delta 2>&1)"
    ck "…and delta finds no zone/SSID mismatch"  no "$(has "${out}" 'names SSID\|template SSID <HOME\|template SSID <IOT')"
else
    echo "  - ap-manager derive check skipped (no /home/tappaas/bin/common-install-routines.sh here)"
fi

# ── refusals: each changes nothing and names the cause ──
refuse() {  # <desc> <needle> — run on the current CFG, expect exit 1 and no change
    local before out rc
    before="$(snap)"; out="$(run)"; rc=$?
    ck "$1: exit 1"            1 "${rc}"
    ck "…names it"             yes "$(has "${out}" "$2")"
    ck "…no file touched"      "${before}" "$(snap)"
}
fresh; edit switch-configuration-desired.json '.accessPoints["ap-loft"].ssids["rossen-home"].security = "wpa3-personal"'
refuse "the same SSID with different settings" "SSID 'rossen-home' is declared with different settings: ap-living security wpa2-personal; ap-loft security wpa3-personal"
fresh; edit switch-configuration-desired.json '.accessPoints["ap-loft"].ssids["rossen-home"].zone = "guest" | .accessPoints["ap-loft"].ssids["rossen-home"].vlan = 510'
refuse "…a different zone" "ap-living zone home; ap-loft zone guest"
fresh; edit switch-configuration-desired.json '.accessPoints[].ssids["rossen-iot"].vlan = 999'
refuse "a VLAN that is not the zone's" "SSID 'rossen-iot' on ap-living is on VLAN 999, not its zone 'iotLocal' VLAN 410"
fresh; edit switch-configuration-desired.json '.accessPoints["ap-loft"].ssids["rossen-home2"] = {"vlan":310,"zone":"home","security":"open","enabled":true}'
refuse "two SSIDs on one zone" "zone 'home' carries 'rossen-home' and 'rossen-home2'"
fresh; edit switch-configuration-desired.json '.accessPoints["ap-loft"].ssids["rossen-guest"].zone = "cafe"'
refuse "a zone zones.json lacks" "bridges to zone 'cafe', which zones.json does not have"
fresh; edit switch-configuration-desired.json '.accessPoints["ap-loft"].ssids["rossen-guest"] |= del(.zone)'
refuse "an SSID with no zone" "SSID 'rossen-guest' on ap-loft names no zone"
fresh; echo '[]' > "${CFG}/zones.json"
refuse "a zones.json that is not an object" "is not a JSON object"

# ── a site already on the list: only a zone that does not name its SSID ──
fresh; run >/dev/null; edit zones.json '.home.SSID = "<HOME_SSID>"'
edit switch-configuration-desired.json '.ssids["rossen-home"].passphraseChanged = true'
d_before="$(cfg switch-configuration-desired.json .)"
out="$(CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${TMP}/b2" bash "${M}" 2>&1)"; rc=$?
ck "migrated list, a zone off: exit 0"            0 "${rc}"
ck "…the zone names it again"                     '"rossen-home"' "$(cfg zones.json .home.SSID)"
ck "…the list untouched (its mark kept)"          "${d_before}" "$(cfg switch-configuration-desired.json .)"

echo ""
echo "test-migration-0025: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
