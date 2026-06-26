#!/usr/bin/env bash
#
# test-migrate-to-adr007.sh — tests for the ADR-007 migration orchestrator
# (ADR-007 P1). All cases use --dry-run against synthetic --config-dir fixtures,
# so they make NO changes to the live system and need no cluster/OPNsense access.
#
# Asserts the orchestrator's decision logic: idempotent no-op on an already-
# migrated layout, the full plan on a mainline layout, half-migrated detection,
# and the correct exit codes (0 clean / 2 action-required).
#
# Usage: ./test-migrate-to-adr007.sh
# Exit: 0 all passed, 1 otherwise.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${SCRIPT_DIR}/migrate-to-adr007.sh"

PASS=0
FAIL=0
ck() {  # ck <desc> <expected> <got>
    if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS + 1))
    else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi
}
ck_contains() {  # ck_contains <desc> <needle> <haystack>
    if grep -qF -- "$2" <<<"$3"; then echo "  ok: $1"; PASS=$((PASS + 1))
    else echo "  FAIL: $1 (missing '$2')"; FAIL=$((FAIL + 1)); fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# ── Case 1: already-migrated layout → no-op, exit 0, "fully converged" ──
C1="${TMPROOT}/migrated"; mkdir -p "${C1}/environments"
echo '{ "name": "acme", "version": "1.0" }' > "${C1}/site.json"
echo '{ "name": "mgmt" }'                   > "${C1}/environments/mgmt.json"
echo '{ "name": "acme" }'                   > "${C1}/environments/acme.json"
echo '{ "vmname": "network", "vmid": 110 }' > "${C1}/network.json"
echo '{ "mgmt": {"state":"Manual","vlantag":0} }' > "${C1}/zones.json"
out1="$(bash "${ORCH}" --dry-run --config-dir "${C1}" 2>&1)"; rc1=$?
ck "migrated layout exits 0" "0" "${rc1}"
ck_contains "migrated layout reports converged" "fully converged" "${out1}"
ck_contains "migrated layout skips step 1" "site.json already present" "${out1}"

# ── Case 2: mainline layout → plans all steps, flags firewall, exit 2 ──
C2="${TMPROOT}/mainline"; mkdir -p "${C2}"
echo '{ "tappaas": { "name": "acme", "domain": "acme.example.com" } }' > "${C2}/configuration.json"
echo '{ "vmname": "firewall", "vmid": 110 }' > "${C2}/firewall.json"
echo '{ "mgmt": {"state":"Manual","vlantag":0} }' > "${C2}/zones.json"
out2="$(bash "${ORCH}" --dry-run --config-dir "${C2}" 2>&1)"; rc2=$?
ck "mainline layout exits 2 (action required)" "2" "${rc2}"
ck_contains "plans config->site"          "would run: /home/tappaas/bin/migrate-configuration.sh" "${out2}"
ck_contains "derives name from domain"    "zones-init --name acme"                                "${out2}"
ck_contains "plans create-environments"   "create-minimal-environments.sh --name acme"            "${out2}"
ck_contains "carries the domain through"  "--domain acme.example.com"                             "${out2}"
ck_contains "flags firewall action"       "ACTION REQUIRED"                                        "${out2}"
ck_contains "validation lists pending"    "site.json missing"                                      "${out2}"

# ── Case 3: half-migrated (both firewall.json AND network.json) → flagged ──
C3="${TMPROOT}/half"; mkdir -p "${C3}/environments"
echo '{ "name": "acme" }'                   > "${C3}/site.json"
echo '{ "name": "mgmt" }'                   > "${C3}/environments/mgmt.json"
echo '{ "name": "acme" }'                   > "${C3}/environments/acme.json"
echo '{ "vmname": "network", "vmid": 110 }' > "${C3}/network.json"
echo '{ "vmname": "firewall", "vmid": 110 }'> "${C3}/firewall.json"
out3="$(bash "${ORCH}" --dry-run --config-dir "${C3}" 2>&1)"; rc3=$?
ck "half-migrated layout exits 2" "2" "${rc3}"
ck_contains "half-migrated is detected" "HALF-MIGRATED" "${out3}"

# ── Case 4: missing config dir → hard error (exit 1) ──
bash "${ORCH}" --dry-run --config-dir "${TMPROOT}/does-not-exist" >/dev/null 2>&1; rc4=$?
ck "missing config dir exits 1" "1" "${rc4}"

# ── Case 5: --include-firewall without --node → hard error ──
bash "${ORCH}" --config-dir "${C2}" --include-firewall --yes >/dev/null 2>&1; rc5=$?
ck "include-firewall without --node exits 1" "1" "${rc5}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
