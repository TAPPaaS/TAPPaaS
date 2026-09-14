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

# ADR-012 P7: backup-manager's CliClient puts `--pbs <host>` BEFORE the verb.
# Each call shape it emits must parse (it used to fail "Unknown command: --pbs").
for _args in "job-status --json" "list foo --json" "add-to-job 321 --bucket weekly" "apply-schedule daily" "key list"; do
    # shellcheck disable=SC2086  # word-split on purpose
    _out="$(TAPPAAS_KEY_ESCROW="${FIX}" CONFIG_DIR="${FIX}" run_offline --pbs sat1 ${_args} 2>&1)" && _rc=0 || _rc=$?
    if [[ ${_rc} -eq 0 ]] && ! grep -q 'Unknown command' <<<"${_out}"; then
        ok "--pbs <host> ${_args} parses (client call shape)"
    else
        bad "--pbs <host> ${_args} failed (rc ${_rc}): ${_out##*$'\n'}"
    fi
done
if run_offline --pbs sat1 job-status --json 2>/dev/null | jq -e '.reachable == false' >/dev/null; then
    ok "--pbs before the verb keeps --json structured output"
else
    bad "--pbs before the verb lost the JSON offline marker"
fi
if run_offline --pbs >/dev/null 2>&1; then bad "--pbs without a host accepted"; else ok "--pbs without a host is refused"; fi
rm -rf "${FIX}"


# ── ADR-012 §2.5.1: encryption-key escrow export / import ─────────────
# The escrow lives inside the system a full-site DR is rebuilding, so it cannot
# be the only copy of a key. These verbs are the out-of-band copy and its way
# back in — tested end to end against a throwaway escrow, never the real one.
echo ""
echo "== key escrow: export -> media -> import onto a fresh escrow =="
_ke_src="$(mktemp -d)"; _ke_media="$(mktemp -d)"; _ke_dst="$(mktemp -d)/escrow"
printf 'FAKE-KEY-CONTENT\n' > "${_ke_src}/demo.key"
chmod 600 "${_ke_src}/demo.key"

_ke_out="$(TAPPAAS_KEY_ESCROW="${_ke_src}" "${BC}" key list 2>&1)"
if grep -q "demo" <<<"${_ke_out}"; then
    ok "key list names the escrowed key"
else
    bad "key list did not report the escrowed key [got: ${_ke_out}]"
fi

if TAPPAAS_KEY_ESCROW="${_ke_src}" "${BC}" key export "${_ke_media}" >/dev/null 2>&1 \
   && [[ -s "${_ke_media}/tappaas-backup-keys/demo.key" ]]; then
    ok "key export copies the key to the media"
else
    bad "key export did not produce ${_ke_media}/tappaas-backup-keys/demo.key"
fi

# The media must carry instructions: whoever needs them is rebuilding a site and
# will not have the repository to hand.
if grep -q "key import" "${_ke_media}/tappaas-backup-keys/README.txt" 2>/dev/null; then
    ok "the media carries restore instructions"
else
    bad "the exported media has no README naming the import step"
fi

if [[ "$(stat -c %a "${_ke_media}/tappaas-backup-keys/demo.key" 2>/dev/null)" == "600" ]]; then
    ok "the exported key is mode 600"
else
    bad "the exported key is not mode 600"
fi

if TAPPAAS_KEY_ESCROW="${_ke_dst}" "${BC}" key import "${_ke_media}" >/dev/null 2>&1 \
   && sudo cmp -s "${_ke_dst}/demo.key" "${_ke_src}/demo.key"; then
    ok "key import restores the key byte-identically onto a fresh escrow"
else
    bad "key import did not restore the key"
fi

# Re-importing must never silently replace an escrowed key: anywhere but a fresh
# mothership, that could strand every backup made with the key it replaced.
printf 'DIFFERENT\n' > "${_ke_media}/tappaas-backup-keys/demo.key"
TAPPAAS_KEY_ESCROW="${_ke_dst}" "${BC}" key import "${_ke_media}" >/dev/null 2>&1
if sudo cmp -s "${_ke_dst}/demo.key" "${_ke_src}/demo.key"; then
    ok "re-import leaves an already-escrowed key untouched"
else
    bad "re-import OVERWROTE an escrowed key — backups made with the old one would be unreadable"
fi

if "${BC}" key bogus >/dev/null 2>&1; then
    bad "an unknown key subcommand is accepted"
else
    ok "an unknown key subcommand is rejected"
fi

# #644: --help in any position runs nothing (`key export <dest> --help` used to
# write the keys to <dest>); an option the verb does not take is refused.
_ke_help="$(mktemp -d "${TMPDIR:-/tmp}/bc-help.XXXXXX")"
_rc=0; TAPPAAS_KEY_ESCROW="${_ke_src}" "${BC}" key export "${_ke_help}" --help >/dev/null 2>&1 || _rc=$?
if [[ ${_rc} -eq 0 && ! -e "${_ke_help}/tappaas-backup-keys" ]]; then
    ok "key export <dest> --help prints help and writes nothing"
else
    bad "key export <dest> --help wrote to <dest> or failed (rc ${_rc})"
fi
_rc=0; TAPPAAS_KEY_ESCROW="${_ke_src}" "${BC}" key export "${_ke_help}" --force >/dev/null 2>&1 || _rc=$?
if [[ ${_rc} -ne 0 && ! -e "${_ke_help}/tappaas-backup-keys" ]]; then
    ok "key export <dest> --force is refused before anything is written"
else
    bad "key export <dest> --force was not refused (rc ${_rc})"
fi
for _args in "apply-schedule daily --help" "add-to-job 100 --bucket weekly -h"; do
    # shellcheck disable=SC2086  # word-split on purpose
    if "${BC}" ${_args} >/dev/null 2>&1; then ok "'${_args}': help, rc 0"; else bad "'${_args}' did not print help"; fi
done
if "${BC}" add-to-job --help | grep -q -- '--retention'; then
    ok "add-to-job --help prints add-to-job's usage"
else
    bad "add-to-job --help does not show its options"
fi
if "${BC}" job-status --jsn >/dev/null 2>&1; then bad "job-status --jsn accepted"; else ok "job-status --jsn is refused"; fi
rm -rf "${_ke_help}"
sudo rm -rf "${_ke_src}" "${_ke_media}" "${_ke_dst}"

echo ""
echo "backup-controller test: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
