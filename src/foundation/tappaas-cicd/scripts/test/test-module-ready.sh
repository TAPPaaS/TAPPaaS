#!/usr/bin/env bash
#
# test-module-ready.sh — verify the post-reboot readiness gate (#468).
#
# Covers the two offline-testable halves:
#   - module_ready_ports():  the declared-ports list, including the port-22
#                            floor that makes this a no-op for modules which
#                            declare nothing (the no-regression property).
#   - wait_for_module_ready(): the ready.sh branch — success, retry-then-succeed
#                            and timeout.
#
# NOT covered here: the port-probe branch of wait_for_module_ready(), which
# needs a reachable VM over ssh. That path is exercised on a real module update.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# module_ready_ports/get_module_dir read CONFIG_DIR at call time.
CONFIG_DIR="${WORK}"

echo "── test-module-ready.sh ──"

# ── module_ready_ports ────────────────────────────────────────────────

# A module declaring nothing: must yield the port-22 floor ONLY, so behaviour is
# identical to the pre-#468 sshd-only gate.
cat > "${WORK}/bare.json" <<'EOF'
{ "vmname": "bare" }
EOF
got="$(module_ready_ports bare | tr '\n' ' ')"
if [[ "${got}" == "22 " ]]; then
    pass "module with no declared ports yields the port-22 floor only (no regression)"
else
    fail "bare module expected '22 ', got '${got}'"
fi

# proxyPort only (the litellm shape) — flat form.
cat > "${WORK}/flatp.json" <<'EOF'
{ "vmname": "flatp", "proxyPort": 4000 }
EOF
got="$(module_ready_ports flatp | tr '\n' ' ')"
if [[ "${got}" == "22 4000 " ]]; then
    pass "proxyPort is appended after the 22 floor"
else
    fail "flatp expected '22 4000 ', got '${got}'"
fi

# Pattern A form must give the same answer as flat — the reader funnel (#207)
# is what makes this format-independent.
cat > "${WORK}/pa.json" <<'EOF'
{
  "vmname": "pa",
  "dependsOn": ["network:proxy"],
  "config": { "network:proxy": { "proxyPort": 4000 } }
}
EOF
if [[ "$(module_ready_ports pa)" == "$(module_ready_ports flatp)" ]]; then
    pass "Pattern A and flat configs yield the same port list"
else
    fail "Pattern A differs: '$(module_ready_ports pa | tr '\n' ' ')'"
fi

# ports[] + proxyPort, with an overlap and a range (the unifi-os shape).
cat > "${WORK}/many.json" <<'EOF'
{
  "vmname": "many",
  "proxyPort": 11443,
  "ports": [
    { "port": 11443, "protocol": "TCP" },
    { "port": 8443,  "protocol": "TCP" },
    { "port": "8000:8010", "protocol": "TCP" },
    { "port": 3478,  "protocol": "UDP" }
  ]
}
EOF
got="$(module_ready_ports many | tr '\n' ' ')"
if [[ "${got}" == "22 11443 8443 " ]]; then
    pass "ports[] merged, duplicate proxyPort collapsed, range and UDP skipped"
else
    fail "many expected '22 11443 8443 ', got '${got}'"
fi

# Only a port a TCP connect can reach counts (#826): UDP and ICMP never accept
# one; TCP/UDP and an unset protocol (TCP is the default) do. Case-insensitive.
cat > "${WORK}/proto.json" <<'EOF'
{
  "vmname": "proto",
  "ports": [
    { "port": 8080 },
    { "port": 1900, "protocol": "UDP" },
    { "port": 3478, "protocol": "TCP/UDP" },
    { "port": 7,    "protocol": "ICMP" },
    { "port": 2100, "protocol": "udp" },
    { "port": 8443, "protocol": "tcp" }
  ]
}
EOF
got="$(module_ready_ports proto | tr '\n' ' ')"
if [[ "${got}" == "22 8080 3478 8443 " ]]; then
    pass "UDP and ICMP ports are not probed; TCP, TCP/UDP and unset are"
else
    fail "proto expected '22 8080 3478 8443 ', got '${got}'"
fi

# A module that declares 22 itself must not produce it twice.
cat > "${WORK}/dup22.json" <<'EOF'
{ "vmname": "dup22", "proxyPort": 22 }
EOF
got="$(module_ready_ports dup22 | tr '\n' ' ')"
if [[ "${got}" == "22 " ]]; then
    pass "a self-declared port 22 is not duplicated"
else
    fail "dup22 expected '22 ', got '${got}'"
fi

# ── wait_for_module_ready: the ready.sh branch ────────────────────────

# get_module_dir resolves the hook via the config's .location.
mkdir -p "${WORK}/moddir"
cat > "${WORK}/hooked.json" <<EOF
{ "vmname": "hooked", "location": "${WORK}/moddir", "proxyPort": 9999 }
EOF

# Immediate success: ready.sh exits 0 on the first poll.
cat > "${WORK}/moddir/ready.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
if wait_for_module_ready hooked 192.0.2.1 10 >/dev/null 2>&1; then
    pass "ready.sh exiting 0 is taken as ready (port probe not consulted)"
else
    fail "ready.sh exit 0 did not report ready"
fi

# Retry: fail twice, then succeed — proves it polls rather than probing once.
cat > "${WORK}/moddir/ready.sh" <<EOF
#!/usr/bin/env bash
n=\$(cat "${WORK}/count" 2>/dev/null || echo 0)
echo \$((n + 1)) > "${WORK}/count"
[[ \${n} -ge 2 ]]
EOF
rm -f "${WORK}/count"
if wait_for_module_ready hooked 192.0.2.1 60 >/dev/null 2>&1; then
    attempts="$(cat "${WORK}/count")"
    if [[ "${attempts}" -ge 3 ]]; then
        pass "ready.sh is polled until it succeeds (${attempts} attempts)"
    else
        fail "expected >=3 attempts, got ${attempts}"
    fi
else
    fail "wait_for_module_ready gave up on a hook that eventually succeeded"
fi

# Timeout: a hook that never succeeds must return 1, not hang or die.
cat > "${WORK}/moddir/ready.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
start=$(date +%s)
if wait_for_module_ready hooked 192.0.2.1 10 >/dev/null 2>&1; then
    fail "a never-ready hook reported ready"
else
    elapsed=$(( $(date +%s) - start ))
    if [[ ${elapsed} -ge 10 && ${elapsed} -lt 30 ]]; then
        pass "a never-ready hook times out and returns 1 (${elapsed}s)"
    else
        fail "timeout took ${elapsed}s, expected ~10s"
    fi
fi

# The hook takes precedence: a module with BOTH a ready.sh and declared ports
# must not fall through to the (unreachable) port probe.
cat > "${WORK}/moddir/ready.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
start=$(date +%s)
wait_for_module_ready hooked 192.0.2.1 10 >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - start ))
if [[ ${elapsed} -lt 5 ]]; then
    pass "ready.sh wins over declared ports (returned in ${elapsed}s, no ssh attempted)"
else
    fail "took ${elapsed}s — looks like the port probe ran despite a ready.sh"
fi

# ── wait_for_guest_settled (#700) ─────────────────────────────────────
# ssh and sleep are stubbed: each call answers the next line of ANSWERS.
# The stub runs inside $(...), so its call count lives in a file.
ANSWERS=()
CALLS=0
ssh() { local n; n=$(cat "${WORK}/calls"); echo $((n + 1)) > "${WORK}/calls"
        local a="${ANSWERS[$n]:-${ANSWERS[-1]}}"; printf '%s\n' "$a"; [[ "$a" == STATE* ]]; }
sleep() { :; }
settled() { local rc=0; ANSWERS=("$@"); echo 0 > "${WORK}/calls"
            wait_for_guest_settled g.mgmt.internal 20 >/dev/null 2>&1 || rc=$?
            CALLS=$(cat "${WORK}/calls"); return "${rc}"; }

settled "STATE running NTP yes" && [[ ${CALLS} -eq 1 ]] && pass "a settled guest with a synchronised clock: one ask, no wait" || fail "settled guest (calls=${CALLS})"
settled "STATE running" && [[ ${CALLS} -eq 1 ]] && pass "a guest that does not report its clock is not waited on" || fail "no NTP field (calls=${CALLS})"
# #716: booted, clock not synchronised yet — wait for it, a bounded time
settled "STATE running NTP no" "STATE running NTP no" "STATE running NTP yes" && [[ ${CALLS} -eq 3 ]] \
    && pass "booted but unsynchronised: waits until the clock is synchronised" || fail "clock wait (calls=${CALLS})"
OUTW="$(ANSWERS=("STATE running NTP no"); echo 0 > "${WORK}/calls"; TAPPAAS_NTP_WAIT=10 wait_for_guest_settled g.mgmt.internal 300 2>&1)"; RCW=$?
[[ ${RCW} -eq 0 && "${OUTW}" == *"clock is NOT synchronised"* ]] \
    && pass "a clock that never synchronises: a warning, not a failure" || fail "unsynced clock (rc=${RCW}): ${OUTW}"
OUTB="$(ANSWERS=("STATE running NTP no"); echo 0 > "${WORK}/calls"; TAPPAAS_NTP_WAIT=600 wait_for_guest_settled g.mgmt.internal 20 2>&1)"; RCB=$?
[[ ${RCB} -eq 0 && "${OUTB}" != *"not finished booting"* ]] \
    && pass "…and a booted guest is never reported as not booted, whichever bound comes first" || fail "bounds (rc=${RCB}): ${OUTB}"
settled "STATE degraded" && pass "degraded counts as booted (a failed unit is the test's to report)" || fail "degraded"
settled "ssh: connect to host g port 22: Connection refused" "STATE starting" "STATE running" && [[ ${CALLS} -eq 3 ]] \
    && pass "not answering, then starting, then running: waits for the end of boot" || fail "boot sequence (calls=${CALLS})"
settled "tappaas@g: Permission denied (publickey)." && [[ ${CALLS} -eq 1 ]] \
    && pass "a guest that refuses the key (OPNsense, a container) is not waited on" || fail "permission denied (calls=${CALLS})"
settled "STATE none" && pass "no systemd: nothing to wait for" || fail "no systemd"
if settled "STATE starting"; then fail "a guest that never finishes booting must time out"
else [[ ${CALLS} -eq 5 ]] && pass "never settles: times out (20s / 5s polls)" || fail "timeout polls (calls=${CALLS})"; fi
unset -f ssh sleep

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
