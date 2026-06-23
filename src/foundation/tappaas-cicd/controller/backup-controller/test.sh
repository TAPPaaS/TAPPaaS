#!/usr/bin/env bash
# test.sh — backup-controller offline test suite (ADR-007 P9).
#
# FAST + non-disruptive: the CLI parses, --help/help work, pure functions
# (retention args, namespace paths, CSV helpers reused from pbs-namespace.sh /
# pbs-job.sh) pass --selftest, and a live command degrades gracefully (exit 0)
# when PBS is unreachable. NEVER contacts a real PBS. Deep/live ops are not run
# here (they require a reachable cluster).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BC="${HERE}/backup-controller"
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

# Syntax
for f in "${HERE}"/*.sh "${BC}"; do
    b="$(basename "$f")"
    if bash -n "$f"; then ok "${b} parses"; else bad "${b} syntax"; fi
done

# CLI loads + help
if "${BC}" help >/dev/null 2>&1; then ok "CLI help works"; else bad "help failed"; fi
if "${BC}" --selftest 2>&1 | grep -q "pure-function checks passed"; then
    ok "pure-function selftest passes (reuses pbs-job/pbs-namespace helpers)"
else
    bad "selftest failed"
fi

# Unknown command -> non-zero, usage
"${BC}" bogus >/dev/null 2>&1 && bad "unknown command should fail" || ok "unknown command rejected"

# Graceful degradation: against a fixture config with an unreachable PBS host,
# job-status / namespaces must exit 0 (skip), not error. Force unreachable by
# pointing get_node_hostname's resolution at a config dir whose nodes don't
# exist; the ssh probe times out fast (ConnectTimeout=5). To keep the test fast
# and hermetic we stub pbs_reachable via PBS_LIB_DIR pointing at a fake lib.
FAKELIB="$(mktemp -d "${TMPDIR:-/tmp}/bc-lib.XXXXXX")"
trap 'rm -rf "${FAKELIB}"' EXIT
# Minimal fake pbs-job.sh: defines the queried functions but pbs_reachable is
# provided by the controller; we instead make the node probe fail by overriding
# get_node_hostname to print an unroutable name (probe fails quickly).
cat > "${FAKELIB}/pbs-job.sh" <<'EOF'
# shellcheck shell=bash
pbs_managed_job_id() { echo ""; }
pbs_job_vmids() { echo ""; }
pbs_storage_name() { echo "tappaas_backup"; }
pbs_node() { echo "nonexistent-node-xyz"; }
EOF
cat > "${FAKELIB}/pbs-namespace.sh" <<'EOF'
# shellcheck shell=bash
pbs_ns_list() { echo ""; }
EOF
# Provide common routines stub so get_node_hostname returns an unroutable host.
FAKECOMMON="${FAKELIB}/common.sh"
cat > "${FAKECOMMON}" <<'EOF'
# shellcheck shell=bash
info()  { echo "[Info] $*"; }
warn()  { echo "[Warning] $*" >&2; }
error() { echo "[Error] $*" >&2; }
get_node_hostname() { echo "nonexistent-node-xyz"; }
EOF

run_offline() { PBS_LIB_DIR="${FAKELIB}" COMMON_ROUTINES="${FAKECOMMON}" "${BC}" "$@"; }

if run_offline job-status >/dev/null 2>&1; then
    ok "job-status degrades gracefully when PBS unreachable (exit 0)"
else
    bad "job-status did not degrade gracefully"
fi
if run_offline namespaces >/dev/null 2>&1; then
    ok "namespaces degrades gracefully when PBS unreachable (exit 0)"
else
    bad "namespaces did not degrade gracefully"
fi

# list/verify with a fixture module resolve the vmid then skip offline (exit 0).
FIX="$(mktemp -d "${TMPDIR:-/tmp}/bc-fix.XXXXXX")"
echo '{"vmname":"foo","vmid":321}' > "${FIX}/foo.json"
if CONFIG_DIR="${FIX}" run_offline list foo >/dev/null 2>&1; then
    ok "list <module> resolves vmid + degrades gracefully"
else
    bad "list <module> failed"
fi
# list for a missing module -> non-zero (real error, not a skip)
if CONFIG_DIR="${FIX}" run_offline list nope >/dev/null 2>&1; then
    bad "list of missing module should fail"
else
    ok "list of missing module reports error"
fi
rm -rf "${FIX}"

echo ""
echo "backup-controller test: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
