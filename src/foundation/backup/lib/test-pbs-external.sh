#!/usr/bin/env bash
#
# Unit tests for the pure helpers behind consuming an externally-managed PBS
# (ADR-012 §1.3, #456) — pbs-external.sh and the shared pbs-storage.sh URL
# parsing. No cluster access: the pvesm registration itself runs over ssh and is
# covered live.
#
# Usage: ./test-pbs-external.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
BOLD=""; CL=""; BL=""; GN=""; BGN=""
# shellcheck disable=SC2034
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }

# shellcheck source=pbs-storage.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-storage.sh"
# shellcheck source=pbs-external.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-external.sh"

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# ── URL parsing (the one thing that differs between peer flavours) ───
ck "url host: bare"            "pbs.lan"          "$(_pbs_url_host 'pbs.lan')"
ck "url host: with port"       "pbs.lan"          "$(_pbs_url_host 'pbs.lan:8007')"
ck "url host: with scheme"     "pbs.example.org"  "$(_pbs_url_host 'https://pbs.example.org')"
ck "url host: scheme+port+path" "pbs.example.org" "$(_pbs_url_host 'https://pbs.example.org:8007/')"
ck "url host: tunnel address"  "10.9.0.2"         "$(_pbs_url_host '10.9.0.2:8007')"
ck "url host: empty"           ""                 "$(_pbs_url_host '')"

ck "url port: none → empty"    ""      "$(_pbs_url_port 'pbs.lan')"
ck "url port: explicit"        "8007"  "$(_pbs_url_port 'pbs.lan:8007')"
ck "url port: scheme+port"     "8007"  "$(_pbs_url_port 'https://pbs.example.org:8007/')"
ck "url port: scheme, no port" ""      "$(_pbs_url_port 'https://pbs.example.org')"

# ── the permanence guard ─────────────────────────────────────────────
# Allowed where nothing local is orphaned...
for s in "" shim external remote-only; do
    pbs_external_allowed "${s}" && r=0 || r=1
    ck_rc "guard: allowed from '${s:-<empty>}'" 0 "$r"
done
# ...and refused where a live datastore would be abandoned.
pbs_external_allowed "node:tappaas3" && r=0 || r=1
ck_rc "guard: refused from node:tappaas3" 1 "$r"
pbs_external_allowed "local" && r=0 || r=1
ck_rc "guard: refused from the legacy 'local'" 1 "$r"

# ── datastore name choice ────────────────────────────────────────────
ck "datastore: explicit wins"  "their_store"    "$(pbs_external_datastore their_store tappaas_backup)"
ck "datastore: falls back to pbsStorageName" "tappaas_backup" "$(pbs_external_datastore '' tappaas_backup)"
ck "datastore: default of the fallback"      "tappaas_backup" "$(pbs_external_datastore '' '')"

# ── register refuses an unparseable URL rather than half-wiring ──────
pbs_external_register '' sname store '' user pw && r=0 || r=1
ck_rc "register: empty URL is refused" 1 "$r"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
