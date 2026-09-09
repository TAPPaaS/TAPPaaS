#!/usr/bin/env bash
#
# Unit tests for pbs_migrate_placement_state — the ADR-012 §4.1 legacy backfill
# (D22). Pure jq over a config fixture; no cluster access.
#
# The contract under test:
#   local        → node:<name>, node from the caller's hint (the node the PBS
#                  actually runs on) or the legacy .node. The datastore is NOT
#                  moved — this only records where it already is.
#   remote-only  → external, seeding .pbsUrl from the push target's remoteHost
#                  when that config exists (and never overwriting an explicit one).
#   shim/external/node:<n> → unchanged (idempotent).
#   (empty)      → left empty; install/update derives it.
#   .placement   → always removed (the field no longer exists in v0.3).
#
# Usage: ./test-pbs-migrate.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
BOLD=""; CL=""; BGN=""; BL=""; GN=""
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }
get_all_node_hostnames() { printf 'tappaas1\ntappaas2\n'; }

# shellcheck source=pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-placement.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"
PBS_PLACEMENT_CONFIG_DIR="${TMP}"
F="${TMP}/backup.json"
fixture() { printf '%s\n' "$1" > "${F}"; }
field()   { jq -r "$1 // empty" "${F}"; }

# ── legacy local → node:<name> ───────────────────────────────────────
fixture '{"placement":"auto","placementState":"local","node":"tappaas3","storage":"tankc1"}'
ck "local: returns the new state"   "node:tappaas3" "$(pbs_migrate_placement_state)"
ck "local: state written"           "node:tappaas3" "$(field .placementState)"
ck "local: .placement removed"      ""              "$(field .placement)"
ck "local: .node left alone"        "tappaas3"      "$(field .node)"
ck "local: .storage untouched"      "tankc1"        "$(field .storage)"

# The caller's hint wins over a stale/blanked .node (the 3-way merge may reset
# .node to the release default before update.sh runs — #581 rule 4).
fixture '{"placementState":"local","node":"","storage":"tankc1"}'
ck "local: hint names the node when .node was blanked" \
   "node:tappaas3" "$(pbs_migrate_placement_state "" tappaas3)"
fixture '{"placementState":"local","node":"tappaas9"}'
ck "local: explicit hint overrides .node" \
   "node:tappaas3" "$(pbs_migrate_placement_state "" tappaas3)"

# No node knowable at all → shim rather than a wrong node (never guess where a
# datastore lives; a shim re-derives on the next update).
fixture '{"placementState":"local"}'
ck "local: no node knowable → shim" "shim" "$(pbs_migrate_placement_state)"

# ── legacy remote-only → external ────────────────────────────────────
fixture '{"placement":"remote-only","placementState":"remote-only","pushTarget":"offsite"}'
printf '%s\n' '{"remoteHost":"pbs.offsite.example"}' > "${TMP}/push-offsite.json"
ck "remote-only: → external"          "external"            "$(pbs_migrate_placement_state)"
ck "remote-only: pbsUrl from target"  "pbs.offsite.example" "$(field .pbsUrl)"
ck "remote-only: pushTarget kept (read for one release)" "offsite" "$(field .pushTarget)"

# An explicit pbsUrl is never overwritten by the push target.
fixture '{"placementState":"remote-only","pushTarget":"offsite","pbsUrl":"explicit.example"}'
pbs_migrate_placement_state >/dev/null
ck "remote-only: explicit pbsUrl wins" "explicit.example" "$(field .pbsUrl)"

# No push config on disk → still external, just no URL to seed.
fixture '{"placementState":"remote-only","pushTarget":"missing"}'
ck "remote-only: unknown target → external" "external" "$(pbs_migrate_placement_state)"
ck "remote-only: no pbsUrl invented"        ""         "$(field .pbsUrl)"

# ── already-migrated states are untouched (idempotent) ───────────────
for s in shim external node:tappaas2; do
    fixture "{\"placementState\":\"${s}\"}"
    ck "idempotent: ${s} unchanged" "${s}" "$(pbs_migrate_placement_state)"
    ck "idempotent: ${s} stable on a second run" "${s}" "$(pbs_migrate_placement_state)"
done

# ── empty state is left for install/update to derive ─────────────────
fixture '{"vmname":"backup","placement":"auto"}'
ck "empty: stays empty"        ""  "$(pbs_migrate_placement_state)"
ck "empty: .placement removed" ""  "$(field .placement)"

# ── a missing config file is not an error ────────────────────────────
rm -f "${F}"
pbs_migrate_placement_state >/dev/null && r=0 || r=1
ck "missing config: rc 0" "0" "${r}"

rm -rf "${TMP}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
