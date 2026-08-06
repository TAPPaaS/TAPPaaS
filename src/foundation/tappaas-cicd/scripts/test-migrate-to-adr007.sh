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
echo '{ "name": "acme", "defaultEnvironment": "acme", "version": "1.0" }' > "${C1}/site.json"
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
ck_contains "derives name from domain"    "init --name acme"                                      "${out2}"
ck_contains "plans create-environments"   "environment-manager add --name acme"                   "${out2}"
ck_contains "carries the domain through"  "--domain acme.example.com"                             "${out2}"
ck_contains "flags firewall action"       "ACTION REQUIRED"                                        "${out2}"
ck_contains "validation lists pending"    "site.json missing"                                      "${out2}"

# ── Case 3: half-migrated (both firewall.json AND network.json) → flagged ──
C3="${TMPROOT}/half"; mkdir -p "${C3}/environments"
echo '{ "name": "acme", "defaultEnvironment": "acme" }' > "${C3}/site.json"
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

# ── Case 6: legacy client zones + --dry-run → planned, nothing written (#425) ──
# A system migrated with the OLD code carries <name>-private/<name>-guest. The
# cleanup step plans the rename-back under --dry-run but must not touch the file.
C6="${TMPROOT}/legacy-dry"; mkdir -p "${C6}/environments"
echo '{ "name": "acme", "version": "1.0" }' > "${C6}/site.json"
echo '{ "name": "mgmt" }'                   > "${C6}/environments/mgmt.json"
echo '{ "name": "acme" }'                   > "${C6}/environments/acme.json"
echo '{ "vmname": "network", "vmid": 110 }' > "${C6}/network.json"
cat > "${C6}/zones.json" <<'JSON'
{
  "_README": "doc block",
  "acme":         { "type": "Service", "state": "Active", "vlantag": 200, "access-to": ["internet"] },
  "acme-private": { "type": "Client",  "state": "Active", "vlantag": 310, "access-to": ["internet", "acme"] },
  "acme-guest":   { "type": "Guest",   "state": "Active", "vlantag": 510, "access-to": ["internet"] },
  "mgmt":         { "state": "Manual", "vlantag": 0, "access-to": ["acme", "acme-private", "acme-guest", "srvHome"] }
}
JSON
before6="$(cat "${C6}/zones.json")"
out6="$(bash "${ORCH}" --dry-run --config-dir "${C6}" 2>&1)"
ck_contains "dry-run plans the client-zone cleanup" "would rename acme-private→home" "${out6}"
ck "dry-run leaves zones.json unchanged" "${before6}" "$(cat "${C6}/zones.json")"

# ── Case 7: legacy client zones, real run → renamed back to home/guest (#425) ──
# Non-dry run: init/env steps skip (environments already exist), people skip (org
# present), firewall skips (network.json present) — so zones.json only changes via
# the cleanup step. We assert on file content + idempotence, not the exit code
# (other steps may still flag a follow-up on a bare checkout without ~/bin tools).
C7="${TMPROOT}/legacy-live"; mkdir -p "${C7}/environments" "${C7}/people/organizations"
echo '{ "name": "acme", "version": "1.0", "email": "admin@acme.example" }' > "${C7}/site.json"
echo '{ "name": "mgmt" }'                   > "${C7}/environments/mgmt.json"
echo '{ "name": "acme" }'                   > "${C7}/environments/acme.json"
echo '{ "vmname": "network", "vmid": 110 }' > "${C7}/network.json"
echo '{ "name": "acme" }'                   > "${C7}/people/organizations/acme.json"
cat > "${C7}/zones.json" <<'JSON'
{
  "_README": "doc block",
  "acme":         { "type": "Service", "state": "Active", "vlantag": 200, "access-to": ["internet"] },
  "acme-private": { "type": "Client",  "state": "Active", "vlantag": 310, "access-to": ["internet", "acme"] },
  "acme-guest":   { "type": "Guest",   "state": "Active", "vlantag": 510, "access-to": ["internet"] },
  "mgmt":         { "state": "Manual", "vlantag": 0, "access-to": ["acme", "acme-private", "acme-guest", "srvHome"] }
}
JSON
cp "${C7}/zones.json" "${C7}/zones.json.orig"
bash "${ORCH}" --config-dir "${C7}" --yes >/dev/null 2>&1 || true
z7="${C7}/zones.json"
ck "cleanup: home + guest now present"     "true"  "$(jq 'has("home") and has("guest")' "${z7}" 2>/dev/null)"
ck "cleanup: legacy acme-private/-guest gone" "false" "$(jq 'has("acme-private") or has("acme-guest")' "${z7}" 2>/dev/null)"
ck "cleanup: mgmt refs rewritten to home"  "true"  "$(jq '(.mgmt["access-to"]|index("home"))!=null and (.mgmt["access-to"]|index("acme-private"))==null' "${z7}" 2>/dev/null)"
ck "cleanup: default zone acme untouched"  "true"  "$(jq 'has("acme")' "${z7}" 2>/dev/null)"
ck "cleanup: _README doc block preserved"  "true"  "$(jq 'has("_README")' "${z7}" 2>/dev/null)"
ck "cleanup: baseline zones.json.orig converged too" "true" "$(jq 'has("home") and (has("acme-private")|not)' "${C7}/zones.json.orig" 2>/dev/null)"
# #426: the run backfills site.json .defaultEnvironment (was absent → derived from .name).
ck "backfill: site.json .defaultEnvironment set" "acme" "$(jq -r '.defaultEnvironment // ""' "${C7}/site.json" 2>/dev/null)"
a7="$(cat "${z7}")"
bash "${ORCH}" --config-dir "${C7}" --yes >/dev/null 2>&1 || true
ck "cleanup is idempotent (second run no-op)" "${a7}" "$(cat "${z7}")"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
