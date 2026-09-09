#!/usr/bin/env bash
#
# Unit tests for PBS-job MEMBERSHIP (ADR-012 §2.7/D18) — who is in the managed
# backup job. Config-only: the pvesh mutations are live-tested, the set logic is
# here.
#
# The contract:
#   dependsOn backup:vm       → in the job (a hard dependency)
#   integratesWith backup:vm  → in the job (#501 — the optional integration the
#                               foundation VMs that bootstrap before the backup
#                               server use, since they cannot depend on it)
#   neither                   → NOT in the job. Backup is opt-in, and hardware /
#                               test / scratch modules take neither relationship.
#   alwaysBackup              → deprecated, still read for one release, and now
#                               robust: an entry with no deployed config warns
#                               instead of silently truncating the whole list.
#
# Usage: ./test-pbs-membership.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; debug() { :; }; error() { echo "ERR: $*" >&2; }
WARNINGS=""
warn() { WARNINGS+="$*"$'\n'; }
BOLD=""; CL=""; BL=""; GN=""; BGN=""
get_node_hostname() { echo "tappaas1"; }
CONFIG_DIR="$(mktemp -d)"

# shellcheck source=pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-job.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

mod() { # mod <name> <vmid> <dependsOn-csv> <integratesWith-csv>
    jq -n --arg n "$1" --arg v "$2" --arg d "$3" --arg i "$4" '{
        vmname: $n, vmid: $v,
        dependsOn:      ($d | if . == "" then [] else split(",") end),
        integratesWith: ($i | if . == "" then [] else split(",") end)
    }' > "${CONFIG_DIR}/$1.json"
}
sorted() { tr ' ' '\n' <<<"$*" | sed '/^$/d' | sort -n | paste -sd',' -; }

printf '%s\n' '{"pbsStorageName":"tappaas_backup"}' > "${CONFIG_DIR}/backup.json"

mod app        340 "backup:vm"          ""             # a normal data-bearing app
mod mothership 130 "cluster:vm"         "backup:vm"    # bootstraps before backup (#501)
mod hardware   811 "cluster:vm"         ""             # wants no backup
mod scratch    999 ""                   "network:proxy" # unrelated integration
mod fsonly     500 "backup:filesystem"  ""             # a different capability

# ── pbs_optin_vmids: the union, and only the union ───────────────────
ck "opt-in: dependsOn + integratesWith, nothing else" \
   "130,340" "$(sorted "$(pbs_optin_vmids)")"

# Adding the relationship to a module adds it; removing it removes it.
mod hardware 811 "cluster:vm" "backup:vm"
ck "opt-in: adding integratesWith opts a module in" \
   "130,340,811" "$(sorted "$(pbs_optin_vmids)")"
mod hardware 811 "cluster:vm" ""
ck "opt-in: removing it opts the module back out" \
   "130,340" "$(sorted "$(pbs_optin_vmids)")"

# A module with the relationship but no vmid contributes nothing (and must not
# break the others).
mod novmid "" "backup:vm" ""
printf '%s\n' '{"vmname":"novmid","dependsOn":["backup:vm"]}' > "${CONFIG_DIR}/novmid.json"
ck "opt-in: a module with no vmid is skipped, the rest survive" \
   "130,340" "$(sorted "$(pbs_optin_vmids)")"
rm -f "${CONFIG_DIR}/novmid.json"

# ── the deprecated alwaysBackup list ─────────────────────────────────
# The regression that made this test exist: a stale entry with no deployed
# config used to abort the loop (`[[ -n $vmid ]] && printf` returns 1 under
# `set -e`, inside a process substitution — so the failure was invisible), and
# every LATER entry silently lost its backup. Live-confirmed 2026-09-09:
# `firewall` truncated the list before `tappaas-cicd`, the mothership.
printf '%s\n' '{"pbsStorageName":"tappaas_backup","alwaysBackup":["app","ghost","mothership"]}' \
    > "${CONFIG_DIR}/backup.json"
WARNINGS=""
ck "alwaysBackup: a stale entry does NOT truncate the list" \
   "130,340" "$(sorted "$(pbs_always_vmids 2>/dev/null)")"
pbs_always_vmids >/dev/null 2>&1
ck "alwaysBackup: the stale entry is warned about, not silently dropped" \
   "yes" "$(grep -q "ghost" <<<"${WARNINGS}" && echo yes || echo no)"

# Under `set -e` — exactly how install.sh/update.sh run it — the list is still
# complete. This is the assertion that would have caught the live bug.
ck "alwaysBackup: complete under set -e (the live-bug regression)" \
   "130,340" "$(sorted "$(bash -c "
        set -euo pipefail
        info() { :; }; debug() { :; }; warn() { :; }; error() { :; }
        get_node_hostname() { echo tappaas1; }
        CONFIG_DIR='${CONFIG_DIR}'
        . '${SCRIPT_DIR}/pbs-job.sh'
        pbs_always_vmids" 2>/dev/null)")"

# ── pbs_declared_vmids: opt-ins ∪ alwaysBackup, sorted and unique ────
ck "declared: union of both sources, deduplicated" \
   "130,340" "$(pbs_declared_vmids)"

printf '%s\n' '{"pbsStorageName":"tappaas_backup","alwaysBackup":["hardware"]}' \
    > "${CONFIG_DIR}/backup.json"
ck "declared: a legacy alwaysBackup entry still contributes during the window" \
   "130,340,811" "$(pbs_declared_vmids)"

printf '%s\n' '{"pbsStorageName":"tappaas_backup"}' > "${CONFIG_DIR}/backup.json"
ck "declared: with no alwaysBackup at all, membership is purely opt-in" \
   "130,340" "$(pbs_declared_vmids)"

rm -f "${CONFIG_DIR}"/*.json
ck "declared: nothing deployed → empty, not an error" "" "$(pbs_declared_vmids)"

rm -rf "${CONFIG_DIR}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
