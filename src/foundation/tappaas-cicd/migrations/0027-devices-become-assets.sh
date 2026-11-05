#!/usr/bin/env bash
# 0027-devices-become-assets.sh — positions.json's devices become assets; every node, switch and AP gets one
#
# Introduced: 2.5.  Required by: #906 (ADR-040 D7-D9, O5).
# Touches: config/positions.json (only; created when the site has nodes, switches
#   or access points and no positions.json yet); reads the pvehost instances
#   (config/<node>.json) and config/switch-configuration-desired.json.
# Reversible: yes — restore config/.migrations/backup/0027/positions.json, or
#   remove config/positions.json when the backup holds positions.json.absent.
#
# WHY. position-manager became asset-manager: a physical thing is an asset with
# a life of its own — ordered, in stock, placed, operational, disposed — and
# the node, switch, access point or device nothing manages is the role it
# plays for a while (ADR-040 D7). Its ports belong to it, each named by its
# connector (D9). The recorded devices were the only boxes known apart from
# their roles; now every box is.
#
# What it writes:
#   - `devices{}` becomes `assets{}`, keyed as before: `kind` as it was, the
#     model, display name, description and location kept; each port name a
#     port {name, kind: rj45, speed: 1g} (nothing more is known); the MAC on
#     the port its recorded cable reaches, else its first port, else a port
#     "1"; `stage` placed when it has a placement, else stock; `role` its own
#     name — the device the topology lists it as — unless a node, switch or
#     access point has that name;
#   - one asset per node (its pvehost instance, in node order: the primary
#     first), per switch and per access point (switch-configuration-desired.json,
#     in its order) that no asset plays yet: named by the next free tag of its
#     kind (srv-NN, sw-NN, ap-NN, ADR-040 O5), `displayName` and `role` the
#     role's name, a switch's or AP's vendor and model, the location its
#     record names, `stage` placed when the role's name has a placement, else
#     stock; no serial until a controller or the installer reports one;
#   - placements and cables are left as they are: they name the roles.
# asset-manager reads devices{} as assets until this has run and refuses to
# change the file before.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - a positions.json that is not a JSON object, or whose devices{} is not one;
#   - devices{} and assets{} both present (a person decides which is the site's);
#   - a device of a kind other than modem, ont, ups, patch-panel or other;
#   - a device with the name of a node, a switch or an access point (the
#     topology never listed it: a person decides what it is);
#   - a switch configuration that is not a JSON object.
#
# Usage: 0027-devices-become-assets.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0027}"
POSITIONS="${CONFIG_DIR}/positions.json"
DESIRED="${CONFIG_DIR}/switch-configuration-desired.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[1;92m[Info]\033[m   0027: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0027: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0027: $*" >&2; exit 1; }

pos='{}'
if [[ -f "${POSITIONS}" ]]; then
    jq empty "${POSITIONS}" 2>/dev/null || stop "${POSITIONS} is not valid JSON — refusing to touch it"
    [[ "$(jq -r 'type' "${POSITIONS}")" == "object" ]] || stop "${POSITIONS} is not a JSON object — a person should look at this"
    pos="$(jq -c . "${POSITIONS}")"
fi

# The nodes: the pvehost instances, not archived, by name with numbers as
# numbers (lib/ts nodes.ts, lib/cluster-nodes.sh) — the primary first.
nodes='[]'
for f in "${CONFIG_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    n="$(basename "${f}" .json)"
    row="$(jq -c --arg n "${n}" '
        select(type == "object"
               and ((.moduleSource // .location // "") | type == "string" and test("(^|/)pvehost/*$"))
               and (.status // "") != "archived")
        | {name: $n, location: (if (.location | type) == "string" and .location != "" and (.location | contains("/") | not) then .location else null end)}' "${f}" 2>/dev/null || true)"
    [[ -n "${row}" ]] && nodes="$(jq -c --argjson r "${row}" '. + [$r]' <<<"${nodes}")"
done
nodes="$(jq -c 'sort_by(.name | [scan("[0-9]+|[^0-9]+") | (tonumber? // .)])' <<<"${nodes}")"

desired='{}'
if [[ -f "${DESIRED}" ]]; then
    jq empty "${DESIRED}" 2>/dev/null || stop "${DESIRED} is not valid JSON — refusing to guess its switches"
    [[ "$(jq -r 'type' "${DESIRED}")" == "object" ]] || stop "${DESIRED} is not a JSON object — a person should look at this"
    desired="$(jq -c . "${DESIRED}")"
fi

# The plan: the new document, what is reported, and every reason to stop.
plan="$(jq -n --argjson d "${pos}" --argjson nodes "${nodes}" --argjson sw "${desired}" '
def str: if type == "string" and . != "" then . else null end;
def loc: if type == "string" and . != "" and (contains("/") | not) then . else null end;
def tagmax($assets; $p): [ $assets | keys[] | capture("^\($p)-(?<n>[0-9]+)$")? | .n | tonumber ] | max // 0;
def tag($p; $n): "\($p)-\(if $n < 10 then "0" else "" end)\($n)";
  ($d.devices // null) as $devices
  | ($d.placements // {}) as $placed
  | ($d.cables // []) as $cables
  | ([$nodes[].name]) as $nodeNames
  | ($sw.switches // {} | if type == "object" then to_entries else [] end) as $switches
  | ($sw.accessPoints // {} | if type == "object" then to_entries else [] end) as $aps
  | ($nodeNames + [$switches[].key] + [$aps[].key]) as $roles
  | [ if $devices != null and ($devices | type) != "object" then "devices is not an object" else empty end,
      if $devices != null and $d.assets != null then "both devices{} and assets{} — a person decides which is the site'"'"'s" else empty end,
      ( $devices // {} | if type == "object" then to_entries[] else empty end
        | if (.value | type) != "object" then "device \(.key) is not an object"
          elif (.value.kind as $k | ["modem", "ont", "ups", "patch-panel", "other"] | any(.[]; . == $k) | not) then "device \(.key): kind \(.value.kind | tojson) is none of modem, ont, ups, patch-panel, other"
          elif (.key as $k | any($roles[]; . == $k)) then "device \(.key) has the name of a node, switch or access point — the topology never listed it: a person decides what it is"
          else empty end )
    ] as $refusals
  | if ($refusals | length) > 0 then {refusals: $refusals} else
    # The recorded devices, as assets.
    ( $devices // {} | with_entries(
        .key as $name | .value as $x
        | ([ $cables[] | (.from, .to) | select(.device == $name) | .port ] | first) as $cabled
        | ([ ($x.ports // [])[] | strings | {name: ., kind: "rj45", speed: "1g"} ]) as $ports0
        | (if ($x.mac | str) == null then $ports0
           else (($cabled // $ports0[0].name // "1") as $at
                 | if any($ports0[]; .name == $at) then $ports0 | map(if .name == $at then . + {mac: ($x.mac | ascii_downcase)} else . end)
                   else $ports0 + [{name: $at, kind: "rj45", speed: "1g", mac: ($x.mac | ascii_downcase)}] end) end) as $ports
        | .value = ({kind: $x.kind}
            + ($x | {model, displayName, description, location} | with_entries(select(.value | str != null)))
            + (if ($ports | length) > 0 then {ports: $ports} else {} end)
            + {stage: (if $placed[$name] != null then "placed" else "stock" end), role: $name}) )
    ) as $fromDevices
    | ($d.assets // {}) + $fromDevices
    | . as $assets0
    # One asset per node, switch and AP no asset plays yet, by the next tag of its kind.
    | ([ $assets0[] | .role // empty ]) as $played
    | ( [ $nodes[] | select(.name as $k | any($played[]; . == $k) | not) | {kind: "server", p: "srv", role: .name, location: .location} ]
      + [ $switches[] | select(.key as $k | any($played[]; . == $k) | not) | {kind: "switch", p: "sw", role: .key, vendor: (.value.vendor | str), model: (.value.model | str), location: (.value.location | loc)} ]
      + [ $aps[] | select(.key as $k | any($played[]; . == $k) | not) | {kind: "access-point", p: "ap", role: .key, vendor: (.value.vendor | str), model: (.value.model | str), location: (.value.location | loc)} ]
      ) as $new
    | reduce $new[] as $r ({assets: $assets0, made: []};
        (tagmax(.assets; $r.p) + 1) as $n
        | tag($r.p; $n) as $key
        | .assets[$key] = ({kind: $r.kind, displayName: $r.role}
            + ($r | {vendor, model, location} | with_entries(select(.value != null)))
            + {stage: (if $placed[$r.role] != null then "placed" else "stock" end), role: $r.role})
        | .made += ["\($key) \($r.role) (\($r.kind))"])
    | . as $out
    | {
        refusals: [],
        changed: ($devices != null or ($out.made | length) > 0),
        doc: (
          { version: 1 }
          + ($d | del(.version, .devices, .assets, .cables, .faceplates))
          + (if ($out.assets | length) > 0 then { assets: $out.assets } else {} end)
          + (if $d.cables != null then { cables: $d.cables } else {} end)
          + (if $d.faceplates != null then { faceplates: $d.faceplates } else {} end)
        ),
        report: (
          (if $devices != null then [ "devices{} → assets{}: \($devices | length) device(s)\(if ($devices | length) > 0 then " (\($devices | keys | join(", ")))" else "" end), each playing itself, its ports rj45 at 1g" ] else [] end)
          + [ $out.made[] | "asset \(.)" ]
        )
      } end
')" || stop "could not read the site's records — nothing was changed"

if [[ "$(jq '.refusals | length' <<<"${plan}")" -gt 0 ]]; then
    jq -r '.refusals[]' <<<"${plan}" | while IFS= read -r l; do echo -e "\033[01;31m[Error]\033[m 0027: ${l}" >&2; done
    stop "nothing was changed — a person should look at ${POSITIONS}"
fi
if [[ "$(jq -r '.changed' <<<"${plan}")" != "true" ]]; then
    say "no devices{} and every node, switch and access point has an asset — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
if [[ -f "${POSITIONS}" ]]; then
    cp -p "${POSITIONS}" "${BACKUP_DIR}/positions.json" || stop "cannot back up ${POSITIONS} — refusing to write"
else
    : > "${BACKUP_DIR}/positions.json.absent" || stop "cannot write ${BACKUP_DIR} — refusing to write"
fi

# Through a temp beside it, checked, then moved into place.
tmp="${POSITIONS}.0027.tmp"
jq '.doc' <<<"${plan}" > "${tmp}" || { rm -f "${tmp}"; stop "writing ${POSITIONS} failed — it is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the new ${POSITIONS} is not valid JSON — it is unchanged"; }
[[ -f "${POSITIONS}" ]] && { chmod --reference="${POSITIONS}" "${tmp}" 2>/dev/null || true; }
mv -f "${tmp}" "${POSITIONS}"

jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
note "backup: ${BACKUP_DIR}"
