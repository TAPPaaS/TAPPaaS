#!/usr/bin/env bash
# 0025-ssids-become-site-wide.sh — each access point's SSIDs become one site-wide list
#
# Introduced: 2.4.  Required by: #889.
# Touches: config/switch-configuration-desired.json and config/zones.json (only).
# Reversible: yes — restore config/.migrations/backup/0025/.
#
# WHY. A WiFi network was declared once per access point
# (`accessPoints{<ap>}.ssids{<ssid>}`, from `ap-manager ssid <ap> add`), so the
# same network was written down once for every AP that broadcast it, and the
# zone's `SSID` field was a separate, hand-set name. Now an SSID is one site-wide
# entry in `ssids{}` — its zone, how clients join, and which access points
# broadcast it — and the zone's `SSID` names it. ap-manager writes each AP's
# `ssids{}` from that list; it is the same content the AP had.
#
# What it writes:
#   - `ssids{<name>}`: for every SSID any access point declares, `zone`,
#     `security`, `radius` (from `radiusServer`), `captive` (from
#     `captivePortal`), `disabled` (from `enabled: false`), and `broadcastOn`:
#     "all" when every access point declared it, else the list of those that did;
#   - the zone's `SSID` in zones.json: the SSID that bridges to it, replacing a
#     template placeholder (<HOME_SSID>), nothing, or another name (reported).
#   Each AP's `ssids{}` stays as it is: it is the derived view, unchanged.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - two access points declaring the same SSID with different settings (zone,
#     security, RADIUS server, captive portal, enabled) — named, with the fields;
#   - an SSID with no zone, a zone zones.json does not have, or a VLAN that is not
#     its zone's (the VLAN is the zone's now);
#   - two SSIDs on one zone (a zone carries one SSID);
#   - a switch configuration or zones.json that is not a JSON object.
# A site-wide `ssids` already there is the migrated shape: then only a zone that
# does not name its SSID is written.
#
# Usage: 0025-ssids-become-site-wide.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0025}"
DESIRED="${CONFIG_DIR}/switch-configuration-desired.json"
ZONES="${CONFIG_DIR}/zones.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0025: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0025: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0025: $*" >&2; exit 1; }

[[ -f "${DESIRED}" ]] || { say "no ${DESIRED} — nothing to migrate"; exit 0; }
jq empty "${DESIRED}" 2>/dev/null || stop "${DESIRED} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${DESIRED}")" == "object" ]] || stop "${DESIRED} is not a JSON object — a person should look at this"
if ! jq -e '[.accessPoints // {} | .[] | .ssids // {} | length] | add // 0 | . > 0' "${DESIRED}" >/dev/null; then
    say "no access point declares an SSID — nothing to migrate"
    exit 0
fi
[[ -f "${ZONES}" ]] || stop "access points declare SSIDs but there is no ${ZONES} to bridge them to — refusing to guess"
jq empty "${ZONES}" 2>/dev/null || stop "${ZONES} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${ZONES}")" == "object" ]] || stop "${ZONES} is not a JSON object — a person should look at this"

# One program: the site-wide list, the zones' SSIDs, what it did, and what it
# refuses. `settings` is what two declarations of one SSID must agree on.
plan="$(jq -n --slurpfile d "${DESIRED}" --slurpfile z "${ZONES}" '
  $d[0] as $des | $z[0] as $zones
  | ($des.accessPoints // {}) as $aps
  | ($aps | keys) as $all
  | def settings: {zone: (.zone // null), security: (.security // null), radius: (.radiusServer // null),
                   captive: (.captivePortal == true), disabled: (.enabled == false)};
    def placeholder: type == "string" and test("^<.*>$");
  # every declaration: {ssid, ap, value}
  [ $aps | to_entries[] | .key as $ap | (.value.ssids // {}) | to_entries[] | {ssid: .key, ap: $ap, value: .value} ] as $decl
  | ($decl | group_by(.ssid)) as $groups
  | [ $groups[] | . as $g | ($g[0].ssid) as $s
      | ([$g[] | .value | settings] | unique) as $variants
      | if ($variants | length) > 1 then
          (([$variants[0] | keys[]] | map(. as $k | select(($variants | map(.[$k]) | unique | length) > 1))) as $diff
           | "SSID \u0027\($s)\u0027 is declared with different settings: "
             + ([$g[] | (.value | settings) as $st | "\(.ap) \($diff | map("\(.) \($st[.] // "none")") | join(", "))"] | join("; "))
             + " — make them agree (ap-manager ssid <ap> add \u0027\($s)\u0027 … on each), then update again")
        else
          ($variants[0]) as $v
          | if ($v.zone // "") == "" then "SSID \u0027\($s)\u0027 on \([$g[].ap] | join(", ")) names no zone"
            elif ($zones | has($v.zone) | not) then "SSID \u0027\($s)\u0027 bridges to zone \u0027\($v.zone)\u0027, which zones.json does not have"
            elif (($v.security // "") as $sec | ["open","wpa2-personal","wpa3-personal","wpa2-enterprise","wpa3-enterprise"] | any(. == $sec) | not) then
              "SSID \u0027\($s)\u0027 has security \u0027\($v.security)\u0027, which is none of open, wpa2-personal, wpa3-personal, wpa2-enterprise, wpa3-enterprise"
            else
              ($zones[$v.zone].vlantag) as $zv
              | [ $g[] | select(.value.vlan != null and .value.vlan != $zv) | "SSID \u0027\($s)\u0027 on \(.ap) is on VLAN \(.value.vlan), not its zone \u0027\($v.zone)\u0027 VLAN \($zv) — an SSID is on its zone VLAN now; point it at the zone of that VLAN" ][]
            end
        end ] as $errs1
  | ( [ $groups[] | {s: .[0].ssid, z: (.[0].value.zone // "")} ] | group_by(.z) | map(select(length > 1 and .[0].z != ""))
      | map("zone \u0027\(.[0].z)\u0027 carries \(map("\u0027\(.s)\u0027") | join(" and ")) — a zone carries one SSID now: remove all but one (ap-manager ssid <ap> remove <ssid>), or move one to another zone, then update again") ) as $errs2
  # the site-wide list
  | ( reduce $groups[] as $g ({};
        ($g[0].value | settings) as $v
        | ([$g[].ap] | unique) as $on
        | . + {($g[0].ssid): ({zone: $v.zone, security: $v.security}
                + (if $v.radius != null and $v.radius != "" then {radius: $v.radius} else {} end)
                + (if $v.captive then {captive: true} else {} end)
                + (if $v.disabled then {disabled: true} else {} end)
                + {broadcastOn: (if $on == $all then "all" else $on end)})}) ) as $ssids
  # A list already there is the migrated shape: it stands, and only the zones follow it.
  | ($des | has("ssids")) as $migrated
  | (if $migrated then ($des.ssids // {}) else $ssids end) as $ssids
  | (if $migrated then [] else $errs1 + $errs2 end) as $errors
  # the zones: each names the SSID that bridges to it
  | ( reduce ($ssids | to_entries[]) as $e ({zones: $zones, report: []};
        ($e.value.zone) as $zn
        | if ($zn | type) != "string" or ($zones | has($zn) | not) or (.zones[$zn].SSID == $e.key) then .
          else (.zones[$zn].SSID // null) as $cur | .zones[$zn].SSID = $e.key
            | .report += [ if $cur == null then "zone \($zn) names SSID \($e.key)"
                           elif ($cur | placeholder) then "zone \($zn) names SSID \($e.key) (was the template \($cur))"
                           else "zone \($zn) names SSID \($e.key) — it named \($cur), which no access point declared" end ]
          end) ) as $zp
  | { errors: $errors,
      desiredChanged: ($migrated | not),
      desired: ($des + {ssids: $ssids}),
      zonesChanged: ($zp.report | length > 0),
      zones: $zp.zones,
      report: ( [ $ssids | to_entries[] | "SSID \(.key) → zone \(.value.zone), \(.value.security), on \(.value.broadcastOn | if type == "array" then join(", ") else "every access point" end)" ]
                + $zp.report ) }
')" || stop "could not read the switch configuration and zones.json — refusing to guess"

errors="$(jq -r '.errors[]' <<<"${plan}")"
if [[ -n "${errors}" ]]; then
    while IFS= read -r e; do echo -e "\033[01;31m[Error]\033[m 0025: ${e}" >&2; done <<<"${errors}"
    stop "nothing changed — fix the above with the current ap-manager, then the next update migrates the rest"
fi

desired_changed="$(jq -r '.desiredChanged' <<<"${plan}")"
zones_changed="$(jq -r '.zonesChanged' <<<"${plan}")"
if [[ "${desired_changed}" != "true" && "${zones_changed}" != "true" ]]; then
    say "the SSIDs are already one site-wide list and every zone names its SSID — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    [[ "${desired_changed}" == "true" ]] && jq -r '.report[] | select(startswith("SSID "))' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    jq -r '.report[] | select(startswith("zone "))' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${DESIRED}" "${BACKUP_DIR}/switch-configuration-desired.json" || stop "cannot back up ${DESIRED} — refusing to write"
cp -p "${ZONES}" "${BACKUP_DIR}/zones.json" || stop "cannot back up ${ZONES} — refusing to write"

# Each file through a temp beside it, checked, then moved over: a failure
# leaves that file as it was. The list first — a zone naming an SSID the list
# lacks would be the worse half-state.
write() {  # <target> <jq path into the plan>
    local target="$1" path="$2" tmp="$1.0025.tmp"
    jq "${path}" <<<"${plan}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite of ${target} failed — it is unchanged"; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten ${target} is not valid JSON — it is unchanged"; }
    chmod --reference="${target}" "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${target}"
}
[[ "${desired_changed}" == "true" ]] && write "${DESIRED}" '.desired'
[[ "${zones_changed}" == "true" ]] && write "${ZONES}" '.zones'

if [[ "${desired_changed}" == "true" ]]; then
    jq -r '.report[] | select(startswith("SSID "))' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
fi
jq -r '.report[] | select(startswith("zone "))' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
note "backup: ${BACKUP_DIR}"
exit 0
