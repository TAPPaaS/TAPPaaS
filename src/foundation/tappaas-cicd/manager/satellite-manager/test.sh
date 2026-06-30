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

# 6. install/remove still report not-implemented (exit 2) — P3.
#    (|| rc=$? keeps the failing exit code without tripping `set -e`.)
rc=0
TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install t >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok "install reports not-implemented (exit 2)"; else no "install exit code ${rc}"; fi

# --- P2 tunnel: mock the satellite over SSH ($TAPPAAS_SSH_RUNNER) ---
cat > "${tmp}/mockssh" << 'SH'
#!/usr/bin/env bash
# args: <target> <remote-command-string>
case "$2" in
  *latest-handshakes*) printf 'FAKEPEERKEY\t1700000000\n' ;;
  "date +%s")          echo 1700000100 ;;
  *public-key*)        echo "FAKEPUBKEY=" ;;
  *)                   exit 1 ;;
esac
SH
chmod +x "${tmp}/mockssh"
printf '#!/usr/bin/env bash\nexit 1\n' > "${tmp}/mockdown"; chmod +x "${tmp}/mockdown"

# 7. status: reachable (mocked) host -> reports handshake age, exit 0
rc=0
out="$(TAPPAAS_CONFIG_DIR="${tmp}" TAPPAAS_SSH_RUNNER="${tmp}/mockssh" "${mgr}" status t 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "last handshake 100s ago" <<< "${out}"; then ok "status reports handshake (mocked)"; else no "status mocked: rc=${rc}"; fi

# 8. status: unreachable host -> exit 1 with a clear message
rc=0
TAPPAAS_CONFIG_DIR="${tmp}" TAPPAAS_SSH_RUNNER="${tmp}/mockdown" "${mgr}" status t >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then ok "status reports unreachable (exit 1)"; else no "status down: rc=${rc}"; fi

# 9. tunnel_satellite_pubkey reads the public key (mocked)
if ( . "${here}/lib/tunnel.sh"; export TAPPAAS_SSH_RUNNER="${tmp}/mockssh"; [[ "$(tunnel_satellite_pubkey root@x)" == "FAKEPUBKEY=" ]] ); then
    ok "tunnel_satellite_pubkey reads pubkey (mocked)"
else
    no "tunnel_satellite_pubkey"
fi

echo ""
echo "satellite-manager fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
