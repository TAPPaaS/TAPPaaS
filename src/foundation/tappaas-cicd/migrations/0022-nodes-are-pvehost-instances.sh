#!/usr/bin/env bash
# 0022-nodes-are-pvehost-instances.sh — a node's storagePools move onto its pvehost instance
#
# Introduced: 2.3.  Required by: #872 (ADR-036 D6).
# Touches: config/site.json and the pvehost instances config/<node>.json (only).
# Reversible: yes — restore config/.migrations/backup/0022/.
#
# WHY. The cluster's nodes were listed twice: as site.json `hardware.nodes[]`
# ({name, storagePools}) and as their pvehost module instances, which hold
# everything else about a node (address, uplinks, zone0, location). Now the
# instance is the node: it carries `storagePools`, and site.json lists no
# hardware.
#
# What it writes:
#   - each `hardware.nodes[]` entry's `storagePools` onto `config/<name>.json`,
#     when that instance has no `storagePools` of its own. An instance that
#     already has a list keeps it — it is the record, written since the pull —
#     and a difference from site.json's is reported;
#   - `hardware` removed from site.json.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - a node in `hardware.nodes[]` with no pvehost instance (`config/<name>.json`
#     missing, archived, or another module's): the node would vanish from the
#     site. Each is named with what to do — `module-manager module adopt
#     <name>.mgmt.internal` for a node in the cluster; for a node that is gone,
#     remove its entry from site.json by hand;
#   - a `hardware` that is not an object, `nodes` that is not a list, an entry
#     with no name, or `storagePools` that is not a list of names.
#
# Usage: 0022-nodes-are-pvehost-instances.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0022}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0022: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0022: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0022: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${SITE}")" == "object" ]] || stop "${SITE} is not a JSON object — a person should look at this"
if ! jq -e 'has("hardware")' "${SITE}" >/dev/null; then
    say "site.json lists no hardware — nothing to migrate"
    exit 0
fi

# The instances the entries name: {"<name>": <document> | null}. null when
# config/<name>.json does not exist or is no JSON object.
names="$(jq -r '(.hardware.nodes? // [])[]? | .name? // empty | strings' "${SITE}" 2>/dev/null || true)"
instances='{}'
while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    [[ "${n}" =~ ^[A-Za-z0-9_-]+$ ]] || continue   # refused below
    f="${CONFIG_DIR}/${n}.json"
    doc=null
    [[ -f "${f}" ]] && doc="$(jq -c 'if type == "object" then . else null end' "${f}" 2>/dev/null || echo null)"
    instances="$(jq -c --arg n "${n}" --argjson d "${doc:-null}" '. + {($n): $d}' <<<"${instances}")"
done <<<"${names}"

# One program: the new site.json, the instances it writes, what it did, and
# what it refuses. A pvehost instance is the rule of lib/ts nodes.ts: its
# moduleSource names the pvehost module, and it is not archived.
plan="$(jq -n --slurpfile site "${SITE}" --argjson inst "${instances}" '
def is_node: type == "object" and ((.moduleSource // .location // "") | type == "string" and test("(^|/)pvehost/*$")) and (.status // "") != "archived";
def pools_ok: type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_-]+$"));

  $site[0] as $s
  | $s.hardware as $hw
  | if ($hw | type) != "object" and $hw != null then {errors: ["site.json hardware is not an object — a person should look at this"]}
    elif ($hw.nodes // [] | type) != "array" then {errors: ["site.json hardware.nodes is not a list — a person should look at this"]}
    else
      reduce ($hw.nodes // [] | to_entries[]) as $e ({nodes: {}, report: [], errors: []};
        $e.value as $n
        | if ($n | type) != "object" or (($n.name | type) != "string") or ($n.name == "") then
            .errors += ["hardware.nodes[\($e.key)] has no name — a person decides what it is"]
          elif ($n.name | test("^[A-Za-z0-9_-]+$") | not) then
            .errors += ["hardware.nodes[\($e.key)] is named \($n.name | tojson), which is no node name"]
          elif ($n | has("storagePools")) and ($n.storagePools | pools_ok | not) then
            .errors += ["\($n.name): storagePools is not a list of pool names"]
          elif ($inst[$n.name] | is_node | not) then
            .errors += ["\($n.name) has no pvehost instance (config/\($n.name).json\(if $inst[$n.name] == null then " is missing" elif ($inst[$n.name].status // "") == "archived" then " is archived" else " is another module'"'"'s" end)): register it with module-manager module adopt \($n.name).mgmt.internal (a node in the cluster), or remove its entry from site.json hardware.nodes by hand (a node that is gone)"]
          else
            ($n.storagePools // []) as $p
            | $inst[$n.name] as $i
            | if ($i | has("storagePools")) then
                if ($i.storagePools | sort) == ($p | sort) then .report += ["\($n.name): already records its storagePools \($p | tojson)"]
                else .report += ["\($n.name): keeps the storagePools its record has, \($i.storagePools | tojson); site.json said \($p | tojson)"] end
              else
                .nodes[$n.name] = ($i + {storagePools: ($p | unique)})
                | .report += ["\($n.name): storagePools \($p | unique | tojson) onto config/\($n.name).json"]
              end
          end)
      | . + {site: ($s | del(.hardware))}
    end')"

errors="$(jq -r '.errors[]?' <<<"${plan}")"
if [[ -n "${errors}" ]]; then
    while IFS= read -r e; do echo -e "\033[01;31m[Error]\033[m 0022: ${e}" >&2; done <<<"${errors}"
    stop "nothing changed — fix the above, then the next run migrates the rest"
fi

node_count="$(jq -r '.nodes | length' <<<"${plan}")"
if [[ "${CHECK}" -eq 1 ]]; then
    jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    say "would: remove hardware from site.json"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"
while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    cp -p "${CONFIG_DIR}/${n}.json" "${BACKUP_DIR}/${n}.json" || stop "cannot back up ${n}.json — refusing to write"
done < <(jq -r '.nodes | keys[]' <<<"${plan}")

# Each file through a temp beside it, checked, then moved over: a failure
# leaves that file as it was. The instances first — site.json without its
# hardware and an instance without its pools would lose them.
write() {  # <target> <jq path into the plan>
    local target="$1" path="$2" tmp="$1.0022.tmp"
    jq "${path}" <<<"${plan}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite of ${target} failed — it is unchanged"; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten ${target} is not valid JSON — it is unchanged"; }
    chmod --reference="${target}" "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${target}"
}
while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    write "${CONFIG_DIR}/${n}.json" ".nodes[\"${n}\"]"
done < <(jq -r '.nodes | keys[]' <<<"${plan}")
write "${SITE}" '.site'

jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
say "site.json lists no hardware: the nodes are their pvehost instances (${node_count} given their storagePools)"
note "backup: ${BACKUP_DIR}"
exit 0
