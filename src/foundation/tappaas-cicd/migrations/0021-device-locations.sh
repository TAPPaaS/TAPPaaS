#!/usr/bin/env bash
# 0021-device-locations.sh — machines, switches and access points name their location
#
# Introduced: 2.3.  Required by: #871 (ADR-036 D2).
# Touches: config/site.json, config/<instance>.json of kind machine, and
#          config/switch-configuration-{desired,actual}.json (only).
# Reversible: yes — restore config/.migrations/backup/0021/.
#
# WHY. Where a device is was written three ways: a machine module's
# `physicalLocation {country, city, building}`, a switch's or access point's
# free-text `location`, and (since 0019) a name of the site's locations. Now
# every device names one of the site's locations with `location`; absent, it is
# at the primary location.
#
# What it writes:
#   - each machine (`kind: machine`) with a `physicalLocation`: the location at
#     the same place — the same country, city and building/address, case and
#     spaces ignored, absent equal only to absent, as 0019 matched the peers, so
#     no off-site verdict changes — or a new one (`kind: remote`) named after its
#     building, else its city, else the instance, with -2, -3, … when that name
#     is another place's. The machine gets `location: <name>`;
#     `physicalLocation` goes. An empty or null `physicalLocation` just goes.
#   - each switch and access point in the switch configuration (desired and
#     actual): a `location` that names one of the site's locations stays; an
#     empty or null one goes; any other text is kept as its `description` (after
#     the description it has, unless that already says it) and `location` goes.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - a site.json with no `locations` (migration 0019 first) or not an object;
#   - a machine whose `physicalLocation` is not an object or has no country; a
#     machine with both a `location` and a `physicalLocation`; a machine whose
#     `location` is a path (migration 0006 first);
#   - a switch or access point whose `location` is not a string.
#
# Usage: 0021-device-locations.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0021}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0021: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0021: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0021: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${SITE}")" == "object" ]] || stop "${SITE} is not a JSON object — a person should look at this"
jq -e '(.locations | type) == "object"' "${SITE}" >/dev/null \
    || stop "site.json has no locations — migration 0019 makes them first; nothing changed"

# The machines: {"<file>": <document>} of every config of kind machine.
machines='{}'
mfiles=()
for f in "${CONFIG_DIR}"/*.json; do
    [[ -e "${f}" ]] || continue
    case "$(basename "${f}")" in site.json|switch-configuration-*.json|positions.json|racks.json|zones*.json) continue ;; esac
    jq -e 'type == "object" and .kind == "machine"' "${f}" >/dev/null 2>&1 || continue
    mfiles+=("${f}")
done
if [[ ${#mfiles[@]} -gt 0 ]]; then
    machines="$(for f in "${mfiles[@]}"; do jq -c --arg f "$(basename "${f}")" '{($f): .}' "${f}"; done | jq -s 'add')"
fi
# The switch configuration files that exist: {"<file>": <document>}.
switchcfg='{}'
for f in "${CONFIG_DIR}/switch-configuration-desired.json" "${CONFIG_DIR}/switch-configuration-actual.json"; do
    [[ -e "${f}" ]] || continue
    jq empty "${f}" 2>/dev/null || stop "${f} is not valid JSON — refusing to guess"
    switchcfg="$(jq -c --arg f "$(basename "${f}")" --slurpfile d "${f}" '. + {($f): $d[0]}' <<<"${switchcfg}")"
done

# One program: the new site.json, machines and switch configuration, what it
# did, and what it refuses. lname is lib/ts locations.ts locationName and the
# same as 0019's: every place is named the same way.
plan="$(jq -n --slurpfile site "${SITE}" --argjson machines "${machines}" --argjson sw "${switchcfg}" '
def lname:
  if type != "string" then "" else
    ascii_downcase
    | gsub("[æÆ]"; "ae") | gsub("[øØ]"; "oe") | gsub("[åÅ]"; "aa") | gsub("[äÄ]"; "ae")
    | gsub("[öÖ]"; "oe") | gsub("[üÜ]"; "ue") | gsub("ß"; "ss")
    | gsub("[áàâãÁÀÂÃ]"; "a") | gsub("[éèêëÉÈÊË]"; "e") | gsub("[íìîïÍÌÎÏ]"; "i")
    | gsub("[óòôõÓÒÔÕ]"; "o") | gsub("[úùûÚÙÛ]"; "u") | gsub("[ýÝ]"; "y") | gsub("[çÇčČ]"; "c")
    | gsub("[ñÑ]"; "n") | gsub("[łŁ]"; "l") | gsub("[šŠ]"; "s") | gsub("[žŽ]"; "z")
    | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")
    | if . == "" then "" elif test("^[a-z]") then . else "loc-" + . end
    | .[0:63] | sub("-+$"; "")
  end;
def str: if type == "string" and (gsub("\\s"; "") != "") then gsub("^\\s+|\\s+$"; "") else null end;
def norm: if type == "string" then (gsub("^\\s+|\\s+$"; "") | ascii_downcase) else "" end;
def free($taken; $base):
  if ($taken | has($base)) | not then $base
  else first(range(2; 10000) | "\($base[0:60])-\(.)" | . as $n | select(($taken | has($n)) | not)) end;
def nonnull: with_entries(select(.value != null));
def place($o): {country: ($o.country | str | if . then ascii_upcase else null end), city: ($o.city | str), address: ($o.building | str)};
def same($a; $b): ($a.country | norm) == ($b.country | norm) and ($a.city | norm) == ($b.city | norm) and ($a.address | norm) == ($b.address | norm);
def empty_place: . == null or . == {} or (type == "object" and ([.[] | select(. != null and . != "")] | length) == 0);

  $site[0] as $s
  # ── the machines, in file order ──
  | reduce ($machines | to_entries | sort_by(.key) | .[]) as $e ({locs: $s.locations, machines: {}, report: [], errors: []};
      $e.key as $f | $e.value as $m
      | ($f | sub("\\.json$"; "")) as $inst
      | if ($m | has("physicalLocation")) | not then .
        elif ($m.location | type) == "string" and ($m.location | test("/")) then .errors += ["\($f) still records its module directory as location — migration 0006 first"]
        elif ($m.physicalLocation | empty_place) then
          .machines[$f] = ($m | del(.physicalLocation))
          | .report += ["\($f): an empty physicalLocation goes"]
        elif ($m.location | str) != null then .errors += ["\($f) has both location and physicalLocation — a person decides which is right"]
        elif ($m.physicalLocation | type) != "object" or (($m.physicalLocation.country | str) == null) then .errors += ["\($f) physicalLocation records no country"]
        else
          place($m.physicalLocation) as $pl
          | ([.locs | to_entries[] | select(same(.value; $pl)) | .key] | first) as $hit
          | if $hit != null then
              .machines[$f] = ($m | del(.physicalLocation) + {location: $hit})
              | .report += ["\($f): at location \($hit), which site.json has"]
            else
              ([($pl.address | lname), ($pl.city | lname), ($inst | lname), "remote"] | map(select(. != "")) | first) as $base
              | free(.locs; $base) as $n
              | .locs[$n] = ({displayName: ($pl.address // $pl.city), kind: "remote", country: $pl.country, city: $pl.city, address: $pl.address} | nonnull)
              | .machines[$f] = ($m | del(.physicalLocation) + {location: $n})
              | .report += ["\($f): physicalLocation → a new location \($n), kind remote (\([$pl.address, $pl.city, $pl.country] | map(select(. != null)) | join(", ")))"]
            end
        end)
  # ── the switches and access points: a name stays, text becomes the description ──
  | .locs as $locs
  | reduce ($sw | to_entries | sort_by(.key) | .[]) as $file (.;
      $file.key as $f
      | reduce (["switches", "switch"], ["accessPoints", "access point"]) as $part (.;
          reduce ((($file.value[$part[0]] // {}) | to_entries | sort_by(.key)) | .[]) as $d (.;
            ($d.value.location) as $l
            | if ($d.value | type) != "object" or ($d.value | has("location") | not) then .
              elif $l != null and ($l | type) != "string" then .errors += ["\($f) \($part[1]) \($d.key): location is not text"]
              elif $l != null and ($locs | has($l)) then .
              elif ($l | str) == null then
                .sw[$f][$part[0]][$d.key] = ($d.value | del(.location))
                | .changed[$f] = true
              else
                ($l | str) as $text | ($d.value.description | str) as $desc
                | .sw[$f][$part[0]][$d.key] = ($d.value | del(.location)
                    + {description: (if $desc == null then $text elif ($desc | ascii_downcase | contains($text | ascii_downcase)) then $desc else "\($desc) · \($text)" end)})
                | .changed[$f] = true
                | if $f == "switch-configuration-desired.json" or ($sw | has("switch-configuration-desired.json") | not) then
                    .report += ["\($part[1]) \($d.key): location \"\($text)\" names no location — kept as its description"]
                  else . end
              end)))
  | . as $acc
  | {site: ($s + {locations: $acc.locs}),
     siteChanged: ($acc.locs != $s.locations),
     machines: $acc.machines,
     switchcfg: [($acc.changed // {}) | keys[] as $f | {file: $f, doc: ($sw[$f] | reduce ((($acc.sw // {})[$f] // {}) | to_entries[]) as $p (.; reduce ($p.value | to_entries[]) as $d (.; .[$p.key][$d.key] = $d.value)))}],
     report: $acc.report, errors: $acc.errors}
')" || stop "could not read the site, its machines and its switch configuration — refusing to guess"

errors="$(jq -r '.errors[]' <<<"${plan}")"
if [[ -n "${errors}" ]]; then
    while IFS= read -r e; do echo -e "\033[01;31m[Error]\033[m 0021: ${e}" >&2; done <<<"${errors}"
    stop "nothing changed — fix the above by hand, then the next run migrates the rest"
fi

site_changed="$(jq -r '.siteChanged' <<<"${plan}")"
machine_count="$(jq -r '.machines | length' <<<"${plan}")"
switch_count="$(jq -r '.switchcfg | length' <<<"${plan}")"
if [[ "${site_changed}" != "true" && "${machine_count}" -eq 0 && "${switch_count}" -eq 0 ]]; then
    say "no machine records a physicalLocation and every switch and access point names a location or none — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    [[ "${switch_count}" -gt 0 ]] && jq -r '.switchcfg[].file' <<<"${plan}" | while IFS= read -r f; do say "would rewrite ${f}"; done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    cp -p "${CONFIG_DIR}/${f}" "${BACKUP_DIR}/${f}" || stop "cannot back up ${f} — refusing to write"
done < <(jq -r '(.machines | keys[]), (.switchcfg[].file)' <<<"${plan}")

# Each file through a temp beside it, checked, then moved over: a failure
# leaves that file as it was. The site first — a machine naming a location the
# site lacks would be the worse half-state.
write() {  # <target> <jq path into the plan>
    local target="$1" path="$2" tmp="$1.0021.tmp"
    jq "${path}" <<<"${plan}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite of ${target} failed — it is unchanged"; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten ${target} is not valid JSON — it is unchanged"; }
    chmod --reference="${target}" "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${target}"
}
[[ "${site_changed}" == "true" ]] && write "${SITE}" '.site'
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    write "${CONFIG_DIR}/${f}" ".machines[\"${f}\"]"
done < <(jq -r '.machines | keys[]' <<<"${plan}")
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    write "${CONFIG_DIR}/${f}" ".switchcfg[] | select(.file == \"${f}\") | .doc"
done < <(jq -r '.switchcfg[].file' <<<"${plan}")

jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
[[ "${switch_count}" -gt 0 ]] && jq -r '.switchcfg[].file' <<<"${plan}" | while IFS= read -r f; do say "${f}: every switch and access point names a location or none (empty ones dropped, text kept as the description)"; done
note "backup: ${BACKUP_DIR}"
exit 0
