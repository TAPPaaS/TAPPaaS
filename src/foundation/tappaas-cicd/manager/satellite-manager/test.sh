#!/usr/bin/env bash
# test.sh — satellite-manager fast tests (schema/CLI/validation; no live host).
# Deep/live tests (real provisioning) gate behind TAPPAAS_TEST_DEEP=1 (P2-P6).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mgr="${here}/satellite-manager.sh"
pass=0; fail=0
ok()  { echo "  ok   - $*"; pass=$((pass+1)); }
no()  { echo "  FAIL - $*"; fail=$((fail+1)); }

# 1. parses
if bash -n "${mgr}"; then ok "satellite-manager.sh parses"; else no "syntax error"; fi

# 2. --help exits 0 and prints usage
if "${mgr}" --help | grep -q "TAPPaaS VPS satellite manager"; then ok "--help prints usage"; else no "--help"; fi

# 3. validate accepts a good fixture
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
cat > "${tmp}/satellite-t.json" << 'JSON'
{ "kind": "external-host", "tier": "foundation", "name": "t",
  "roles": ["reverse-proxy"], "host": { "publicIp": "203.0.113.10" } }
JSON
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate t >/dev/null; then ok "validate accepts a good config"; else no "validate good"; fi

# 4. validate rejects missing roles
echo '{ "kind":"external-host","tier":"foundation","name":"b","host":{"publicIp":"203.0.113.10"} }' > "${tmp}/satellite-b.json"
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate b >/dev/null 2>&1; then no "validate should reject missing roles"; else ok "validate rejects missing roles"; fi

# 5. validate rejects missing publicIp
echo '{ "kind":"external-host","tier":"foundation","name":"c","roles":["backup"] }' > "${tmp}/satellite-c.json"
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate c >/dev/null 2>&1; then no "validate should reject missing publicIp"; else ok "validate rejects missing publicIp"; fi

# 6. install/update/status/remove are wired but report not-implemented (exit 2).
#    (|| rc=$? keeps the failing exit code without tripping `set -e`.)
rc=0
TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" status t >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok "status reports not-implemented (exit 2)"; else no "status exit code ${rc}"; fi

echo ""
echo "satellite-manager fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
