#!/usr/bin/env bash
# 0019-site-location-becomes-locations.sh — site.location and the peers' places become locations
#
# Introduced: 2.3.  Required by: #869 (ADR-036 D1, D5).
# Touches: config/site.json and config/{remote,pull,receive}-*.json (only).
# Reversible: yes — restore config/.migrations/backup/0019/ (site.json and the peer files).
#
# WHY. A place was recorded in two shapes: site.json `location` (the site's own,
# with its time and locale) and each backup peer's `physicalLocation`. Now the
# site keeps every place it cares about in `locations{}`, by name, with
# `primaryLocation` naming its own; a peer names its location by `location`.
#
# What it writes:
#   - site.json: `location` becomes `locations{<name>}` — country, city, the
#     building as `address`, timezone, latitude, longitude; displayName the
#     building or city as written — and `primaryLocation: <name>`. The name is
#     the building's, else the city's, else the site code's, lower-case (ø → oe,
#     spaces → '-'). `locale` and `keyboard` move to the top level; a value
#     already there wins, and the difference is reported. `location` goes.
#   - each peer with a `physicalLocation`: the location at the same place — the
#     same country, city and building/address, case and spaces ignored, absent
#     equal only to absent, so no peer's off-site verdict changes — or a new one
#     (`kind: remote`) named after its building, else its city, else the peer,
#     with -2, -3, … when that name is another place's. The peer gets
#     `location: <name>`; `physicalLocation` goes.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - a site.json that is not a JSON object; a `location` that is not an object,
#     or has no country; `location` beside `locations`; a `primaryLocation`
#     naming no location;
#   - a peer whose `physicalLocation` is not an object or has no country; a peer
#     with both `location` and `physicalLocation`; a peer naming a location the
#     site does not have.
#
# Usage: 0019-site-location-becomes-locations.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0019}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0019: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0019: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0019: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${SITE}")" == "object" ]] || stop "${SITE} is not a JSON object — a person should look at this"

# The peers: {"<file>": <document>}, in file-name order.
peer_files=()
for f in "${CONFIG_DIR}"/remote-*.json "${CONFIG_DIR}"/pull-*.json "${CONFIG_DIR}"/receive-*.json; do
    [[ -e "${f}" ]] || continue
    jq empty "${f}" 2>/dev/null || stop "${f} is not valid JSON — refusing to guess"
    peer_files+=("${f}")
done
peers='{}'
if [[ ${#peer_files[@]} -gt 0 ]]; then
    peers="$(for f in "${peer_files[@]}"; do jq -c --arg f "$(basename "${f}")" '{($f): .}' "${f}"; done | jq -s 'add')"
fi

# One program: the new site.json, the new peers, what it did, and what it refuses.
# lname is lib/ts locations.ts locationName: both must name a place the same way.
plan="$(jq -n --argjson site "$(cat "${SITE}")" --argjson peers "${peers}" '
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

  $site as $s
  | [] as $errors | [] as $report
  # ── refusals on the site ──
  | (if ($s | has("location")) and ($s | has("locations")) then $errors + ["site.json has both location and locations — a person decides which is right"]
     elif ($s | has("location")) and (($s.location | type) != "object") then $errors + ["site.json location is not an object"]
     elif ($s | has("location")) and (($s.location.country | str) == null) then $errors + ["site.json location records no country"]
     elif ($s | has("location") | not) and ($s.primaryLocation | str) != null and (($s.locations // {}) | has($s.primaryLocation) | not) then $errors + ["primaryLocation \($s.primaryLocation) names no location"]
     else $errors end) as $errors
  # ── the site: location → locations{name}, primaryLocation, locale, keyboard ──
  | (if ($s | has("location")) and ($errors | length) == 0 then
       $s.location as $l
       | ([($l.building | lname), ($l.city | lname), ($s.name | lname), "site"] | map(select(. != "")) | first) as $n
       | ({displayName: (($l.building | str) // ($l.city | str)), country: ($l.country | ascii_upcase), city: ($l.city | str),
           address: ($l.building | str), timezone: ($l.timezone | str),
           latitude: (if ($l.latitude | type) == "number" then $l.latitude else null end),
           longitude: (if ($l.longitude | type) == "number" then $l.longitude else null end)} | nonnull) as $loc
       | {site: ($s | del(.location) + {locations: {($n): $loc}, primaryLocation: $n}
                   + (if ($s.locale | str) == null and ($l.locale | str) != null then {locale: $l.locale} else {} end)
                   + (if ($s.keyboard | str) == null and ($l.keyboard | str) != null then {keyboard: $l.keyboard} else {} end)),
         report: ($report + ["site.json location → locations.\($n), the primary location (\([$loc.address, $loc.city, $loc.country] | map(select(. != null)) | join(", ")))"]
                  + (if ($s.locale | str) != null and ($l.locale | str) != null and $s.locale != $l.locale then ["locale: site.json already says \($s.locale); location.locale \($l.locale) is dropped"] else [] end)
                  + (if ($s.keyboard | str) != null and ($l.keyboard | str) != null and $s.keyboard != $l.keyboard then ["keyboard: site.json already says \($s.keyboard); location.keyboard \($l.keyboard) is dropped"] else [] end))}
     else {site: $s, report: $report} end) as $r
  | $r.site as $new | $r.report as $report
  # ── the peers, in file order ──
  | reduce ($peers | to_entries | sort_by(.key) | .[]) as $e ({locs: ($new.locations // {}), peers: {}, report: $report, errors: $errors};
      $e.key as $f | $e.value as $p
      | ($f | sub("^(remote|pull|receive)-"; "") | sub("\\.json$"; "")) as $peer
      | if ($p | type) != "object" then .errors += ["\($f) is not a JSON object"]
        elif ($p | has("physicalLocation")) and ($p | has("location")) then .errors += ["\($f) has both location and physicalLocation"]
        elif ($p | has("physicalLocation")) | not then
          (if ($p.location | str) != null and (.locs | has($p.location) | not) and (($p.location | test("/")) | not)
           then .errors += ["\($f) names location \($p.location), which site.json does not have"] else . end)
        elif ($p.physicalLocation | type) != "object" or (($p.physicalLocation.country | str) == null) then .errors += ["\($f) physicalLocation records no country"]
        else
          place($p.physicalLocation) as $pl
          | ([.locs | to_entries[] | select(same(.value; $pl)) | .key] | first) as $hit
          | if $hit != null then
              .peers[$f] = ($p | del(.physicalLocation) + {location: $hit})
              | .report += ["\($f): at location \($hit), which site.json has"]
            else
              ([($pl.address | lname), ($pl.city | lname), ($peer | lname), "remote"] | map(select(. != "")) | first) as $base
              | free(.locs; $base) as $n
              | .locs[$n] = ({displayName: ($pl.address // $pl.city), kind: "remote", country: $pl.country, city: $pl.city, address: $pl.address} | nonnull)
              | .peers[$f] = ($p | del(.physicalLocation) + {location: $n})
              | .report += ["\($f): physicalLocation → a new location \($n), kind remote (\([$pl.address, $pl.city, $pl.country] | map(select(. != null)) | join(", ")))"]
            end
        end)
  | . as $acc
  | {site: (if ($acc.locs | length) > 0 or ($new | has("locations")) then $new + {locations: $acc.locs} else $new end),
     siteChanged: ((if ($acc.locs | length) > 0 or ($new | has("locations")) then $new + {locations: $acc.locs} else $new end) != $s),
     peers: $acc.peers, report: $acc.report, errors: $acc.errors}
')" || stop "could not read the site and its peers — refusing to guess"

errors="$(jq -r '.errors[]' <<<"${plan}")"
if [[ -n "${errors}" ]]; then
    while IFS= read -r e; do echo -e "\033[01;31m[Error]\033[m 0019: ${e}" >&2; done <<<"${errors}"
    stop "nothing changed — fix the above by hand, then the next run migrates the rest"
fi

site_changed="$(jq -r '.siteChanged' <<<"${plan}")"
peer_count="$(jq -r '.peers | length' <<<"${plan}")"
if [[ "${site_changed}" != "true" && "${peer_count}" -eq 0 ]]; then
    say "site.json has its locations and no peer records a physicalLocation — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    cp -p "${CONFIG_DIR}/${f}" "${BACKUP_DIR}/${f}" || stop "cannot back up ${f} — refusing to write"
done < <(jq -r '.peers | keys[]' <<<"${plan}")

# Each file through a temp beside it, checked, then moved over: a failure
# leaves that file as it was. The site first — a peer naming a location the
# site lacks would be the worse half-state.
write() {  # <target> <jq path into the plan>
    local target="$1" path="$2" tmp="$1.0019.tmp"
    jq "${path}" <<<"${plan}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite of ${target} failed — it is unchanged"; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten ${target} is not valid JSON — it is unchanged"; }
    chmod --reference="${target}" "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${target}"
}
[[ "${site_changed}" == "true" ]] && write "${SITE}" '.site'
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    write "${CONFIG_DIR}/${f}" ".peers[\"${f}\"]"
done < <(jq -r '.peers | keys[]' <<<"${plan}")

jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
note "backup: ${BACKUP_DIR}"
