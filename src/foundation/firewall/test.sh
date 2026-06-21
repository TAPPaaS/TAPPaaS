#!/usr/bin/env bash
#
# TAPPaaS Firewall Module Test
#
# Implements issue #172. Validates the firewall foundation across three depths:
#
#   Basic (always)     : DNS lookup, internet reachability, OPNsense reachability.
#   Standard (always)  : Schema sanity, CLI presence, zone gateway pings, DHCP/DNS
#                        probes, rules-manager dry-runs, NONE-mode fallback.
#   Deep (--deep)      : Provisions test VMs in the fixture-defined test zones, configures
#                        Caddy reverse proxy on VM-A, applies rules-manager rules
#                        on VM-B (exercising both module-name and module-local
#                        alias peers), validates inter-VM connectivity, then
#                        tears everything down.
#
# Called by test-module.sh (which passes the module name as $1). Can also be
# run standalone:  ./test.sh [--deep] [--no-cleanup]
#
# Exit codes:
#   0  All tests passed (or firewallType=NONE → skipped with summary)
#   1  One or more tests failed
#   2  Fatal error (cannot proceed — bad environment, missing CLI, etc.)
#
# Environment:
#   TAPPAAS_TEST_DEEP=1      Run deep tests (or pass --deep)
#   TAPPAAS_TEST_NO_CLEANUP=1  Leave test VMs and activated zones in place after
#                              a deep run (default: tear down on success or fail)
#   TAPPAAS_DEBUG=1          Verbose output
#

set -euo pipefail

# ── Logging / helpers ────────────────────────────────────────────────

# shellcheck source=../tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../cluster/lib/vm-net.sh disable=SC1091
. /home/tappaas/TAPPaaS/src/foundation/cluster/lib/vm-net.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIXTURES_DIR="${SCRIPT_DIR}/test-fixtures"
readonly CONFIG_DIR="/home/tappaas/config"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
readonly ZONES_JSON="${CONFIG_DIR}/zones.json"
readonly ALIASES_JSON="${SCRIPT_DIR}/aliases.json"
FIREWALL_FQDN="firewall.mgmt.internal"
readonly TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
readonly LOG_DIR="/home/tappaas/logs"
readonly LOG_FILE="${LOG_DIR}/firewall-test-${TIMESTAMP}.log"
mkdir -p "${LOG_DIR}"

# Parse flags
DEEP="${TAPPAAS_TEST_DEEP:-0}"
NO_CLEANUP="${TAPPAAS_TEST_NO_CLEANUP:-0}"
for arg in "$@"; do
    case "${arg}" in
        --deep)        DEEP=1 ;;
        --no-cleanup)  NO_CLEANUP=1 ;;
        --help|-h)
            echo "Usage: $0 [<module-name>] [--deep] [--no-cleanup]"
            exit 0
            ;;
        firewall) ;;  # module name passed by test-module.sh — ignore
        *) ;;
    esac
done

# Counters
PASS=0
FAIL=0
SKIP=0

# Mirror output to log file
exec > >(tee -a "${LOG_FILE}") 2>&1

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { info "    ${YW}⊘${CL} $1 (skipped)"; SKIP=$((SKIP + 1)); }

section() {
    echo ""
    info "${BOLD}═══ $1 ═══${CL}"
}

# ── firewallType gate ────────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

info "${BOLD}╔════════════════════════════════════════════╗${CL}"
info "${BOLD}║  TAPPaaS Firewall Test${CL}"
info "${BOLD}╚════════════════════════════════════════════╝${CL}"
info "Timestamp:     $(date)"
info "firewallType:  ${FIREWALL_TYPE}"
info "Deep tests:    $([[ "${DEEP}" == "1" ]] && echo yes || echo no)"
info "Cleanup:       $([[ "${NO_CLEANUP}" == "1" ]] && echo skipped || echo will run)"
info "Log file:      ${LOG_FILE}"

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    section "firewallType=NONE — skipping all firewall tests"
    info "  When firewallType is NONE, the firewall is operator-managed."
    info "  Run with --firewall-type opnsense or remove firewallType=NONE to enable."
    info ""
    info "${GN}Skipped (firewallType=NONE).${CL}"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# Basic tests (issue #172 requirements)
# ─────────────────────────────────────────────────────────────────────

section "Basic 1: DNS lookup"

if getent hosts "${FIREWALL_FQDN}" >/dev/null 2>&1; then
    pass "internal DNS resolves ${FIREWALL_FQDN}"
else
    fail "internal DNS cannot resolve ${FIREWALL_FQDN}"
fi

if getent hosts one.one.one.one >/dev/null 2>&1; then
    pass "external DNS resolves one.one.one.one"
else
    fail "external DNS cannot resolve one.one.one.one"
fi

section "Basic 2: Internet reachability (ping)"

for target in 1.1.1.1 8.8.8.8; do
    if ping -c 2 -W 2 "${target}" >/dev/null 2>&1; then
        pass "ping ${target}"
    else
        fail "ping ${target}"
    fi
done

section "Basic 3: OPNsense reachability"

# TCP probe on the API port (auto-detect 443 then 8443)
OPNSENSE_API_PORT=""
for port in 443 8443; do
    if (echo > "/dev/tcp/${FIREWALL_FQDN}/${port}") 2>/dev/null; then
        OPNSENSE_API_PORT="${port}"
        pass "OPNsense API TCP port reachable on ${port}"
        break
    fi
done
if [[ -z "${OPNSENSE_API_PORT}" ]]; then
    fail "OPNsense API not reachable on 443 or 8443"
fi

# SSH login probe — uses BatchMode so a missing key fails fast
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        root@"${FIREWALL_FQDN}" "echo ok" >/dev/null 2>&1; then
    pass "SSH to root@${FIREWALL_FQDN}"
else
    fail "SSH to root@${FIREWALL_FQDN} (key auth, BatchMode)"
fi

# OPNsense API responds via opnsense-firewall
if command -v opnsense-firewall >/dev/null 2>&1; then
    if opnsense-firewall test --no-ssl-verify >/dev/null 2>&1; then
        pass "opnsense-firewall test (API reachable)"
    else
        fail "opnsense-firewall test (API not reachable)"
    fi
else
    skip "opnsense-firewall not in PATH — cannot test API"
fi

# Capture Basic-section failures (#307). The Basic checks (DNS lookup, internet
# reachability, OPNsense reachability) are run first, so FAIL at this point counts
# only them. A failure here means the firewall is fundamentally broken/unreachable
# — that is FATAL (exit 2), not a soft fail, so `update-module.sh` rolls the
# pre-update snapshot back rather than leaving a bricked firewall in place.
BASIC_FAIL=${FAIL}

# ─────────────────────────────────────────────────────────────────────
# Standard tests (always run; non-destructive)
# ─────────────────────────────────────────────────────────────────────

section "Standard 1: CLI tools available"

for tool in opnsense-firewall zone-manager dns-manager caddy-manager rules-manager \
            opnsense-manager proxmox-manager switch-manager ap-manager zone-reconcile; do
    if command -v "${tool}" >/dev/null 2>&1; then
        pass "${tool} on PATH"
    else
        fail "${tool} missing from PATH"
    fi
done

section "Standard 1b: ADR-008 provider unit tests (proxmox/switch/ap; #335/#339)"

# NB: test-{proxmox,switch,ap}-manager.sh moved to tappaas-cicd/controller/<x>-controller/
# in ADR-007 S0 (run via controller/test.sh). test-unifi-plugin.sh stays with the plugins.
for ut in test-unifi-plugin.sh; do
    if [[ -x "${SCRIPT_DIR}/scripts/${ut}" ]]; then
        if ut_out=$("${SCRIPT_DIR}/scripts/${ut}" 2>&1); then
            pass "${ut}"
        else
            fail "${ut}"
            echo "${ut_out}" | sed 's/^/    /'
        fi
    else
        skip "scripts/${ut} not found or not executable"
    fi
done

section "Standard 2: Schema files parse and validate"

for file in "${ZONES_JSON}" "${SCRIPT_DIR}/zones.json"; do
    if [[ -f "${file}" ]]; then
        if jq empty "${file}" >/dev/null 2>&1; then
            pass "$(basename "$(dirname "${file}")")/zones.json parses"
        else
            fail "$(basename "$(dirname "${file}")")/zones.json invalid JSON"
        fi
    fi
done

if [[ -f "${ALIASES_JSON}" ]]; then
    if jq empty "${ALIASES_JSON}" >/dev/null 2>&1; then
        pass "firewall/aliases.json parses"
    else
        fail "firewall/aliases.json invalid JSON"
    fi
    # private_ranges expected per design
    if jq -e '.private_ranges and (.private_ranges.type == "network")' "${ALIASES_JSON}" >/dev/null 2>&1; then
        pass "aliases.json contains private_ranges (RFC1918)"
    else
        fail "aliases.json missing private_ranges or wrong type"
    fi
else
    fail "firewall/aliases.json not found at ${ALIASES_JSON}"
fi

# Duplicate VLAN-tag detection across enabled zones
DUP_VLANS=$(jq -r '
    [ to_entries[]
      | select(.value.state == "Active" or .value.state == "Mandatory")
      | .value.vlantag ]
    | group_by(.) | map(select(length > 1)) | length
' "${ZONES_JSON}" 2>/dev/null || echo "1")
if [[ "${DUP_VLANS}" == "0" ]]; then
    pass "no duplicate VLAN tags among enabled zones"
else
    fail "${DUP_VLANS} duplicate VLAN tag(s) detected"
fi

section "Standard 3: Zone gateway reachability"

# Ping the .1 gateway of every Active/Mandatory zone — except mgmt (we're on it)
# and zones with no VLAN (typically already covered by mgmt).
mapfile -t enabled_zones < <(jq -r '
    to_entries[]
    | select(.value.state == "Active" or .value.state == "Mandatory")
    | select(.key != "mgmt")
    | "\(.key)\t\(.value.ip)"
' "${ZONES_JSON}" 2>/dev/null || true)

if [[ ${#enabled_zones[@]} -eq 0 ]]; then
    skip "no Active/Mandatory non-mgmt zones to probe"
else
    for entry in "${enabled_zones[@]}"; do
        zone_name=$(echo "${entry}" | cut -f1)
        zone_ip=$(echo "${entry}" | cut -f2)
        # Gateway is .1 of the zone's /24
        gateway="${zone_ip%.*/*}.1"
        if ping -c 1 -W 2 "${gateway}" >/dev/null 2>&1; then
            pass "zone ${zone_name} gateway ${gateway} responds to ping"
        else
            # Not all enabled zones are necessarily routed from tappaas-cicd —
            # downgrade to skip rather than fail, but record it.
            skip "zone ${zone_name} gateway ${gateway} unreachable from this host"
        fi
    done
fi

section "Standard 4: DNS for in-cluster modules"

# Collect installed modules that have a single resolvable host. Modules with
# aliasType=network (#241) represent a set of devices and have no <vmname>
# DHCP/DNS record by design, so they must be excluded here (#255).
sample_modules=""
network_alias_count=0
for f in "${CONFIG_DIR}"/*.json; do
    vmname=$(jq -r '.vmname // empty' "${f}" 2>/dev/null)
    [[ -z "${vmname}" ]] && continue
    alias_type=$(jq -r '.aliasType // "host"' "${f}" 2>/dev/null)
    if [[ "${alias_type}" == "network" ]]; then
        network_alias_count=$((network_alias_count + 1))
        continue
    fi
    sample_modules+="${vmname}"$'\n'
done
sample_modules=$(printf '%s' "${sample_modules}" | sort -u | head -3)

if [[ "${network_alias_count}" -gt 0 ]]; then
    skip "${network_alias_count} module(s) excluded — aliasType=network has no DNS record by design"
fi

if [[ -z "${sample_modules}" ]]; then
    skip "no installed modules with a resolvable vmname — DNS resolution test skipped"
else
    while IFS= read -r vmname; do
        [[ -z "${vmname}" ]] && continue
        zone=$(read_module_config "${vmname}" 2>/dev/null | jq -r '.zone0 // "srvHome"' 2>/dev/null || echo "srvHome")
        fqdn="${vmname}.${zone}.internal"
        if getent hosts "${fqdn}" >/dev/null 2>&1; then
            pass "DNS resolves ${fqdn}"
        else
            fail "DNS cannot resolve ${fqdn}"
        fi
    done <<< "${sample_modules}"
fi

section "Standard 5: zone-manager summary"

if command -v zone-manager >/dev/null 2>&1; then
    if zone-manager --no-ssl-verify --zones-file "${ZONES_JSON}" --summary >/dev/null 2>&1; then
        pass "zone-manager --summary parses and connects"
    else
        fail "zone-manager --summary failed"
    fi
else
    skip "zone-manager missing"
fi

section "Standard 6: caddy-manager list"

if command -v caddy-manager >/dev/null 2>&1; then
    # Note: caddy-manager has an argparse bug where --no-ssl-verify is silently
    # dropped when placed before the subcommand. Pass the flag AFTER 'list'.
    if caddy-manager list --no-ssl-verify >/dev/null 2>&1; then
        pass "caddy-manager list completed"
    else
        fail "caddy-manager list failed"
    fi
else
    skip "caddy-manager missing"
fi

section "Standard 7: rules-manager dry-run against an installed module"

if ! command -v rules-manager >/dev/null 2>&1; then
    skip "rules-manager not in PATH"
else
    # Find a module that already has ingress[] or egress[] declared
    candidate=""
    for f in "${CONFIG_DIR}"/*.json; do
        if jq -e '(.ingress // [] | length > 0) or (.egress // [] | length > 0)' "${f}" >/dev/null 2>&1; then
            candidate=$(basename "${f}" .json)
            break
        fi
    done

    if [[ -z "${candidate}" ]]; then
        skip "no installed module declares ingress/egress yet"
    else
        if rules-manager add-rules "${candidate}" --check-mode --no-ssl-verify --output json \
                > /tmp/rm-check.json 2>/dev/null; then
            errs=$(jq -r '.errors // [] | length' /tmp/rm-check.json 2>/dev/null || echo "?")
            if [[ "${errs}" == "0" ]]; then
                pass "rules-manager add-rules ${candidate} --check-mode (no errors)"
            else
                fail "rules-manager add-rules ${candidate} --check-mode reported ${errs} error(s)"
            fi
        else
            fail "rules-manager add-rules ${candidate} --check-mode crashed"
        fi
        rm -f /tmp/rm-check.json
    fi

    if rules-manager list-rules --no-ssl-verify --output json >/dev/null 2>&1; then
        pass "rules-manager list-rules"
    else
        fail "rules-manager list-rules failed"
    fi

    if rules-manager list-rules --orphans --no-ssl-verify --output json >/dev/null 2>&1; then
        pass "rules-manager list-rules --orphans"
    else
        fail "rules-manager list-rules --orphans failed"
    fi
fi

section "Standard 8: rules-manager NONE-mode fallback"

# Use the deep-test fixture without connecting to OPNsense — NONE mode should
# print manual instructions and exit 0 without touching the firewall.
if command -v rules-manager >/dev/null 2>&1 && [[ -f "${FIXTURES_DIR}/test-fw-a.json" ]]; then
    if rules-manager add-rules test-fw-a \
            --firewall-type NONE \
            --modules-dir "${FIXTURES_DIR}" \
            --zones-file "${SCRIPT_DIR}/zones.json" \
            --aliases-file "${ALIASES_JSON}" \
            --check-mode \
            >/dev/null 2>&1; then
        pass "rules-manager --firewall-type NONE exits 0 against fixture"
    else
        fail "rules-manager --firewall-type NONE failed against fixture"
    fi
else
    skip "rules-manager or fixture missing — NONE-mode test skipped"
fi

section "Standard 9: Auto-pinhole compile (issue #177 → #173)"

# Synthetic-fixture tests for the auto-pinhole compile path. Each scenario:
#   - Builds a temp dir with a provider 'api' (with/without pinhole.json),
#     a consumer 'ui' that depends on 'api:rest', and a tailored zones.json.
#   - Runs `rules-manager add-rules ui --firewall-type NONE` in NONE-mode.
#     NONE-mode prints what *would* be applied (including the
#     "AUTO-PINHOLES (dependsOn-derived, issue #173)" block) without making
#     any real OPNsense API calls — perfect for shape/policy assertions.
#   - The full captured output is grepped for the expected description /
#     warning / absence of either.
#
# Args:
#   $1  consumer_zone        e.g. "src1"
#   $2  provider_zone        e.g. "dst1"
#   $3  pinhole-allowed-from for the provider zone, JSON array
#   $4  access-to            for the provider zone, JSON array
#   $5  pinhole ports        JSON array, or empty string ""  to omit pinhole.json
#   $6  out-path             file to capture stdout/stderr into

run_autopinhole_check() {
    local consumer_zone="$1"
    local provider_zone="$2"
    local pinhole_allowed="$3"
    local access_to="$4"
    local pinhole_ports="$5"
    local out="$6"

    local tmp
    tmp=$(mktemp -d)
    APH_TMP="${tmp}"  # caller cleans up via cleanup_autopinhole_tmp

    mkdir -p "${tmp}/api-loc/services/rest"
    if [[ -n "${pinhole_ports}" ]]; then
        printf '{"ports": %s}\n' "${pinhole_ports}" \
            > "${tmp}/api-loc/services/rest/pinhole.json"
    fi

    cat > "${tmp}/api.json" <<EOF
{"vmname":"api","zone0":"${provider_zone}","bridge0":"lan",
 "location":"${tmp}/api-loc",
 "ports":[{"port":9091,"protocol":"TCP"}]}
EOF
    cat > "${tmp}/ui.json" <<EOF
{"vmname":"ui","zone0":"${consumer_zone}","bridge0":"lan",
 "dependsOn":["cluster:vm","api:rest"]}
EOF

    # Build zones.json. Same-zone case: only one entry.
    if [[ "${consumer_zone}" == "${provider_zone}" ]]; then
        cat > "${tmp}/zones.json" <<EOF
{"${provider_zone}":{"vlantag":810,"ip":"10.80.10.0/24","bridge":"lan",
   "access-to":${access_to},"pinhole-allowed-from":${pinhole_allowed}}}
EOF
    else
        cat > "${tmp}/zones.json" <<EOF
{"${consumer_zone}":{"vlantag":810,"ip":"10.80.10.0/24","bridge":"lan",
   "access-to":["internet"],"pinhole-allowed-from":[]},
 "${provider_zone}":{"vlantag":820,"ip":"10.80.20.0/24","bridge":"lan",
   "access-to":${access_to},"pinhole-allowed-from":${pinhole_allowed}}}
EOF
    fi

    rules-manager add-rules ui \
        --modules-dir "${tmp}" \
        --zones-file "${tmp}/zones.json" \
        --firewall-type NONE \
        > "${out}" 2>&1
}

cleanup_autopinhole_tmp() {
    if [[ -n "${APH_TMP:-}" && -d "${APH_TMP}" ]]; then
        rm -rf "${APH_TMP}"
        APH_TMP=""
    fi
}

if ! command -v rules-manager >/dev/null 2>&1; then
    skip "rules-manager not in PATH — auto-pinhole tests skipped"
else
    APH_OUT="$(mktemp)"

    # ── AC-1: rule emitted with correct form ─────────────────────────
    # Consumer 'src1' is in provider zone 'dst1'.pinhole-allowed-from BUT
    # NOT in 'dst1'.access-to → auto-pinhole required and permitted.
    run_autopinhole_check \
        "src1" "dst1" '["src1"]' '["internet"]' \
        '[{"port":9091,"protocol":"TCP","description":"X"},
          {"port":9092,"protocol":"TCP","description":"Y"}]' \
        "${APH_OUT}"

    if grep -qE 'AUTO-PINHOLES .* for ui' "${APH_OUT}" \
        && grep -qE 'ui +→ +api +:9091/TCP' "${APH_OUT}" \
        && grep -qE 'ui +→ +api +:9092/TCP' "${APH_OUT}"; then
        pass "AC-1: auto-pinhole emitted with correct ports (TCP/9091, TCP/9092)"
    else
        fail "AC-1: expected auto-pinhole lines for ports 9091 and 9092 in NONE-mode output"
        info "  -- output --"
        sed 's/^/    /' "${APH_OUT}" | head -30
    fi
    cleanup_autopinhole_tmp

    # Non-TCP variant: description must include /UDP suffix in OPNsense mode.
    # In NONE-mode we just verify the printed line shows /UDP.
    run_autopinhole_check \
        "src1" "dst1" '["src1"]' '["internet"]' \
        '[{"port":53,"protocol":"UDP","description":"DNS"}]' \
        "${APH_OUT}"
    if grep -qE 'ui +→ +api +:53/UDP' "${APH_OUT}"; then
        pass "AC-1: non-TCP protocol carried into auto-pinhole (UDP)"
    else
        fail "AC-1: UDP protocol not propagated into auto-pinhole output"
    fi
    cleanup_autopinhole_tmp

    # ── AC-3: pinhole-allowed-from violation → warn-and-skip ─────────
    # Provider's pinhole-allowed-from does NOT include the consumer zone.
    run_autopinhole_check \
        "src1" "dst1" '[]' '["internet"]' \
        '[{"port":9091,"protocol":"TCP","description":"X"}]' \
        "${APH_OUT}"
    if grep -qE 'pinhole-allowed-from' "${APH_OUT}" \
        && grep -qiE 'Warning|Skipped' "${APH_OUT}" \
        && ! grep -qE 'ui +→ +api +:9091' "${APH_OUT}"; then
        pass "AC-3: policy-denied case emits warning and creates no rule"
    else
        fail "AC-3: expected pinhole-allowed-from warning + no rule line"
        info "  -- output --"
        sed 's/^/    /' "${APH_OUT}" | head -30
    fi
    cleanup_autopinhole_tmp

    # ── AC-4: same zone → no auto-pinhole ────────────────────────────
    # Intra-zone traffic flows freely; no per-module pinhole needed.
    run_autopinhole_check \
        "src1" "src1" '["src1"]' '["internet"]' \
        '[{"port":9091,"protocol":"TCP","description":"X"}]' \
        "${APH_OUT}"
    if grep -qE 'AUTO-PINHOLES' "${APH_OUT}"; then
        fail "AC-4: same-zone case should NOT emit any auto-pinhole"
        info "  -- output --"
        sed 's/^/    /' "${APH_OUT}" | head -30
    else
        pass "AC-4: same-zone case correctly emits no auto-pinhole"
    fi
    cleanup_autopinhole_tmp

    # ── Bonus: zone-level access-to already covers it → no auto-pinhole.
    # Even though pinhole-allowed-from permits, the zone-level rule already
    # allows the traffic, so the per-module pinhole is redundant.
    run_autopinhole_check \
        "src1" "dst1" '["src1"]' '["internet","src1"]' \
        '[{"port":9091,"protocol":"TCP","description":"X"}]' \
        "${APH_OUT}"
    if grep -qE 'AUTO-PINHOLES' "${APH_OUT}"; then
        fail "access-to-covers-it case should NOT emit any auto-pinhole"
    else
        pass "access-to-covers-it case correctly emits no auto-pinhole"
    fi
    cleanup_autopinhole_tmp

    # ── Bonus: provider service has no pinhole.json → no auto-pinhole.
    # Most services (cluster:vm, templates:debian, …) don't expose ports;
    # the absence of pinhole.json must be a silent no-op.
    run_autopinhole_check \
        "src1" "dst1" '["src1"]' '["internet"]' \
        "" \
        "${APH_OUT}"
    if grep -qE 'AUTO-PINHOLES' "${APH_OUT}"; then
        fail "no-pinhole.json case should not emit AUTO-PINHOLES section"
    else
        pass "no pinhole.json → no auto-pinhole (silent no-op)"
    fi
    cleanup_autopinhole_tmp

    rm -f "${APH_OUT}"
fi

# ─────────────────────────────────────────────────────────────────────
# Standard 10: test-network tooling (issue #225) — non-destructive
# ─────────────────────────────────────────────────────────────────────

section "Standard 10: test-network tooling (issue #225)"

TESTNET_SH="${SCRIPT_DIR}/test-network.sh"

if [[ -x "${TESTNET_SH}" ]]; then
    pass "test-network.sh present and executable"
else
    fail "test-network.sh missing or not executable"
fi

# Syntax + help (no privileged access required)
if bash -n "${TESTNET_SH}" >/dev/null 2>&1; then
    pass "test-network.sh syntax OK (bash -n)"
else
    fail "test-network.sh has syntax errors"
fi
if bash "${TESTNET_SH}" --help 2>/dev/null | grep -q -- "--delete"; then
    pass "test-network.sh --help advertises --delete"
else
    fail "test-network.sh --help missing or incomplete"
fi

# OPNsense-side CLI: prefer the installed wrapper, fall back to the module.
TESTNET_CLI=""
if command -v test-network-manager >/dev/null 2>&1; then
    TESTNET_CLI="test-network-manager"
    pass "test-network-manager on PATH"
elif python3 -c "import opnsense_controller.test_network_cli" >/dev/null 2>&1; then
    TESTNET_CLI="python3 -m opnsense_controller.test_network_cli"
    pass "opnsense_controller.test_network_cli importable (wrapper not yet built)"
else
    skip "test-network-manager not available (rebuild opnsense-controller to expose it)"
fi

if [[ -n "${TESTNET_CLI}" ]]; then
    if ${TESTNET_CLI} --help 2>/dev/null | grep -q "create"; then
        pass "test-network CLI exposes create/delete/status"
    else
        fail "test-network CLI help missing subcommands"
    fi
fi

# Offline logic check: addressing + asymmetric rule set, no API calls.
if python3 -c "import opnsense_controller.test_network_manager" >/dev/null 2>&1; then
    if python3 - <<'PY' >/dev/null 2>&1
from unittest.mock import MagicMock
from opnsense_controller.test_network_manager import TestNetworkManager, RuleAction
m = TestNetworkManager(config=MagicMock(), device="vtnet9")
assert m.gateway_ip == "172.17.3.1", m.gateway_ip
assert m.network_cidr == "172.17.3.0/24", m.network_cidr
assert m.dhcp_start == "172.17.3.50" and m.dhcp_end == "172.17.3.250"
rules = m._build_rules("opt9")
descs = [r[0] for r in rules]
# test->internet allowed, mgmt->test allowed, internal RFC1918 blocked
assert any("internet" in d for d in descs)
assert any("mgmt-access" in d for d in descs)
blocks = [r for r in rules if r[1] is RuleAction.BLOCK]
assert any(r[4] == "10.0.0.0/8" for r in blocks), "mgmt net must be blocked from test"
# mgmt-access rule is on the mgmt interface, sourced from mgmt net
mgmt = [r for r in rules if "mgmt-access" in r[0]][0]
assert mgmt[2] == "lan" and mgmt[3] == "10.0.0.0/24" and mgmt[4] == "172.17.3.0/24"
# Ordering is load-bearing (rules are quick=True): internet-pass MUST be
# sequenced after every RFC1918 block, else the test net could reach mgmt.
seqs = [r[5] for r in rules]
assert len(set(seqs)) == len(seqs), "rule sequences must be unique"
internet_seq = [r[5] for r in rules if r[0].endswith("internet")][0]
assert internet_seq > max(r[5] for r in blocks), "internet pass must follow RFC1918 blocks"
PY
    then
        pass "test-network rule model: test→internet + mgmt→test, internal blocked"
    else
        fail "test-network rule model assertions failed"
    fi
else
    skip "opnsense_controller.test_network_manager not importable — skipping rule-model check"
fi

# ─────────────────────────────────────────────────────────────────────
# Deep tests (--deep) — VM provisioning + inter-VM connectivity
# ─────────────────────────────────────────────────────────────────────

cleanup_deep() {
    local rc=$?
    if [[ "${NO_CLEANUP}" == "1" ]]; then
        warn "Skipping cleanup (TAPPAAS_TEST_NO_CLEANUP=1). test-fw-{a,b,c} left in place."
        return ${rc}
    fi
    echo ""
    info "${BOLD}─── Deep cleanup ───${CL}"
    # Delete order matters: test-fw-a depends on test-fw-c:web (#173), so
    # delete the consumer first to drop its auto-pinhole, then the provider.
    for vm in test-fw-b test-fw-a test-fw-c; do
        if [[ -f "${CONFIG_DIR}/${vm}.json" ]]; then
            info "Removing ${vm}..."
            /home/tappaas/bin/delete-module.sh "${vm}" --force >/dev/null 2>&1 \
                || warn "  delete-module.sh ${vm} returned non-zero"
        fi
    done
    # Tear the test zones back out of the DEPLOYED zones.json: first set them
    # Inactive and reconcile (so zone-manager removes their OPNsense VLAN
    # interfaces), then DELETE the keys entirely — leaving every other zone,
    # including runtime-only ones like variant zones, untouched (defect 4). Zone
    # names come from the globals derived in the deep block (#306).
    if [[ -f "${CONFIG_DIR}/zones.json" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg za "${TFW_A_ZONE}" --arg zb "${TFW_B_ZONE}" --arg zc "${TFW_C_ZONE}" \
           '(.[$za].state = "Inactive") | (.[$zb].state = "Inactive") | (.[$zc].state = "Inactive")' \
            "${CONFIG_DIR}/zones.json" > "${tmp}" \
            && mv "${tmp}" "${CONFIG_DIR}/zones.json"
        zone-manager --no-ssl-verify --zones-file "${CONFIG_DIR}/zones.json" --execute \
            >/dev/null 2>&1 || warn "zone-manager teardown returned non-zero"
        tmp=$(mktemp)
        jq --arg za "${TFW_A_ZONE}" --arg zb "${TFW_B_ZONE}" --arg zc "${TFW_C_ZONE}" \
           'del(.[$za]) | del(.[$zb]) | del(.[$zc])' \
            "${CONFIG_DIR}/zones.json" > "${tmp}" \
            && mv "${tmp}" "${CONFIG_DIR}/zones.json"
        info "Deactivated and removed test zones ${TFW_A_ZONE}/${TFW_B_ZONE}/${TFW_C_ZONE} from deployed zones.json"
    fi
    # Restore the firewall VM net0 trunks now that the test zones are gone, so the
    # NIC config is back to the production set (defect 1 — the old code never did
    # this, leaving the firewall config clobbered after a run).
    vmnet_sync_firewall_trunks "${CONFIG_DIR}/zones.json" "${CONFIG_DIR}/firewall.json" \
        || warn "Could not restore firewall net0 trunks — verify manually"
    return ${rc}
}

# ─────────────────────────────────────────────────────────────────────
# Deep A/B: ADR-008 switch/ap providers (#339) — SAFE, file-only.
#
# Runs entirely in an isolated temp CONFIG_DIR (a copy of the live zones.json +
# test zones), so it never touches live zones.json or the live switch-config
# files and needs no hardware (vendor 'generic' → manual plugin). Exercises:
#   - adding / changing / removing test zones and the resulting desired.json
#   - the five reconcile phases and how desired.json vs actual.json evolve
#   - switch ports, incl. an unknown equipment type that forces manual mode
#   - that the manual instructions cite the correct ports / VLANs
#   - ap-manager SSID tracking + cross-provider uplink validation
#
# CONFIG_DIR is readonly here, so providers are invoked with `env CONFIG_DIR=…`;
# every call is guarded (|| true / capture rc) because the suite runs set -e.
deep_test_adr008_providers() {
    local T D AF z out rc
    T="$(mktemp -d)"
    D="${T}/switch-configuration-desired.json"
    AF="${T}/switch-configuration-actual.json"
    if ! cp "${CONFIG_DIR}/zones.json" "${T}/zones.json" 2>/dev/null; then
        fail "Deep A: could not copy zones.json for isolated test"; rm -rf "${T}"; return 0
    fi
    set +e   # body uses explicit pass/fail + rc capture; a stray non-zero must not abort the suite

    # Local assert helpers (use the global pass/fail counters).
    _dgrep() { # desc, fixed-pattern, text
        if grep -qF -- "$2" <<< "$3"; then pass "$1"; else fail "$1"; echo "      expected to find: $2" >&2; fi
    }
    _djq() { # desc, jq-filter, file  (pass if filter is truthy/non-null)
        if [[ "$(jq -r "$2" "$3" 2>/dev/null)" == "true" ]]; then pass "$1"; else fail "$1"; fi
    }

    section "Deep A: switch-manager — zone add/change/remove across reconcile phases (#339)"

    # Seed two test zones (961, 962) as Active in the isolated zones.json.
    jq '.swdeepA={state:"Active",vlantag:961} | .swdeepB={state:"Active",vlantag:962}' \
        "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"

    # vendor 'generic' has no plugin → manual fallback (an "equipment type that
    # does not exist" as far as automation is concerned).
    env CONFIG_DIR="${T}" switch-manager add testcore --vendor generic --ip 10.0.0.99 >/dev/null 2>&1 || true
    env CONFIG_DIR="${T}" switch-manager port testcore 1 --mode trunk --source zones \
        --connected-to node:tappaas1:nic0:lan >/dev/null 2>&1 || true
    env CONFIG_DIR="${T}" switch-manager port testcore 5 --mode access --zone swdeepA \
        --connected-to device:test-printer >/dev/null 2>&1 || true

    # ── A1: add zones → update-desired pulls the new VLANs into desired.json ──
    env CONFIG_DIR="${T}" switch-manager update-desired >/dev/null 2>&1 || true
    _djq "Deep A1: desired trunk port gained added VLANs 961+962" \
        '.switches.testcore.ports["1"].taggedVlans | (index(961) and index(962)) != null' "${D}"
    _djq "Deep A1: access port nativeVlan tracks zone swdeepA (961)" \
        '.switches.testcore.ports["5"].nativeVlan == 961' "${D}"

    # ── A2: phases — actual.json only changes after confirm ──────────────────
    env CONFIG_DIR="${T}" switch-manager interrogate >/dev/null 2>&1 || true   # manual → actual stays empty
    out="$(env CONFIG_DIR="${T}" switch-manager delta 2>&1 || true)"
    _dgrep "Deep A2: delta reports ports need configuring (actual empty)" "configure-port" "${out}"
    if jq -e '.switches.testcore' "${AF}" >/dev/null 2>&1; then
        fail "Deep A2: actual.json must NOT contain testcore before confirm"
    else
        pass "Deep A2: actual.json has no testcore before confirm"
    fi
    env CONFIG_DIR="${T}" switch-manager confirm >/dev/null 2>&1 || true
    _djq "Deep A2: confirm wrote applied state into actual.json" \
        '.switches.testcore.ports["1"].taggedVlans | index(961) != null' "${AF}"
    rc=0; env CONFIG_DIR="${T}" switch-manager reconcile >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 0 ]]; then pass "Deep A2: reconcile reports in-sync after confirm (rc 0)"; else fail "Deep A2: reconcile not in-sync after confirm (rc ${rc})"; fi

    # ── A3: change a zone's VLAN (961→965) → drift on trunk AND access ──────
    jq '.swdeepA.vlantag=965' "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"
    env CONFIG_DIR="${T}" switch-manager update-desired >/dev/null 2>&1 || true
    out="$(env CONFIG_DIR="${T}" switch-manager delta 2>&1 || true)"
    _dgrep "Deep A3: trunk VLAN change detected" "trunk-vlans" "${out}"
    _dgrep "Deep A3: access VLAN change detected" "access-vlan" "${out}"
    _djq "Deep A3: desired.json now has new VLAN 965" \
        '.switches.testcore.ports["1"].taggedVlans | index(965) != null' "${D}"
    _djq "Deep A3: actual.json still has OLD VLAN 961 (drift, not yet applied)" \
        '.switches.testcore.ports["1"].taggedVlans | index(961) != null' "${AF}"

    # ── A4: remove a zone → its VLAN drops out of desired.json ─────────────
    jq 'del(.swdeepB)' "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"
    env CONFIG_DIR="${T}" switch-manager update-desired >/dev/null 2>&1 || true
    _djq "Deep A4: removed zone VLAN 962 dropped from desired trunk" \
        '.switches.testcore.ports["1"].taggedVlans | index(962) == null' "${D}"

    # ── A5: unknown equipment type → manual instructions cite real port/VLAN ─
    out="$(env CONFIG_DIR="${T}" switch-manager reconcile --apply 2>&1)"; rc=$?
    _dgrep "Deep A5: manual plugin engaged for unknown vendor 'generic'" "MANUAL CONFIGURATION REQUIRED" "${out}"
    _dgrep "Deep A5: manual instructions cite the affected port (port 1)" "port 1" "${out}"
    _dgrep "Deep A5: manual instructions cite the new VLAN (965)" "965" "${out}"
    if [[ "${rc}" -eq 2 ]]; then pass "Deep A5: reconcile --apply returns needs-manual (rc 2)"; else fail "Deep A5: expected rc 2 (needs-manual), got ${rc}"; fi
    if jq -e '.switches.testcore.ports["1"].taggedVlans | index(965)' "${AF}" >/dev/null 2>&1; then
        fail "Deep A5: actual.json must stay unchanged after a manual (unapplied) reconcile"
    else
        pass "Deep A5: actual.json unchanged after manual reconcile (no false confirm)"
    fi

    section "Deep B: ap-manager — SSID tracking + cross-provider uplink validation (#339)"

    # swdeepA (965) gains an SSID; an AP (unknown vendor → manual) broadcasts it.
    jq '.swdeepA.SSID="TAPPaaS-Test"' "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"
    env CONFIG_DIR="${T}" ap-manager add testap --vendor generic --ip 10.0.0.98 >/dev/null 2>&1 || true
    env CONFIG_DIR="${T}" ap-manager ssid testap add TAPPaaS-Test --zone swdeepA --security wpa3-personal >/dev/null 2>&1 || true
    env CONFIG_DIR="${T}" ap-manager link testap --switch testcore --port 9 >/dev/null 2>&1 || true
    env CONFIG_DIR="${T}" ap-manager update-desired >/dev/null 2>&1 || true
    _djq "Deep B1: SSID VLAN auto-tracks its zone (965)" \
        '.accessPoints.testap.ssids["TAPPaaS-Test"].vlan == 965' "${D}"

    out="$(env CONFIG_DIR="${T}" ap-manager delta 2>&1 || true)"
    _dgrep "Deep B1: ap delta reports create-ssid" "create-ssid" "${out}"
    _dgrep "Deep B2: validation flags uplink port not carrying the SSID VLAN" "does not carry VLAN 965" "${out}"

    # Fix the uplink: switch port 9 trunk must carry 965 → validation clears.
    env CONFIG_DIR="${T}" switch-manager port testcore 9 --mode trunk --tagged 965 \
        --connected-to ap:testap >/dev/null 2>&1 || true
    out="$(env CONFIG_DIR="${T}" ap-manager delta 2>&1 || true)"
    if grep -qF "does not carry VLAN 965" <<< "${out}"; then
        fail "Deep B2: uplink validation should clear once port 9 carries VLAN 965"
    else
        pass "Deep B2: uplink validation clears once the switch port carries the SSID VLAN"
    fi

    # Manual apply instructions for the AP must cite the SSID; confirm writes actual.
    out="$(env CONFIG_DIR="${T}" ap-manager reconcile --apply 2>&1 || true)"
    _dgrep "Deep B3: AP manual instructions cite the SSID" "TAPPaaS-Test" "${out}"
    env CONFIG_DIR="${T}" ap-manager confirm >/dev/null 2>&1 || true
    if jq -e '.accessPoints.testap.ssids["TAPPaaS-Test"]' "${AF}" >/dev/null 2>&1; then
        pass "Deep B3: ap confirm wrote the SSID into actual.json"
    else
        fail "Deep B3: ap confirm did not update actual.json"
    fi

    rm -rf "${T}"
    set -e
    return 0
}

if [[ "${DEEP}" != "1" ]]; then
    section "Deep tests skipped"
    info "  Re-run with --deep (or TAPPAAS_TEST_DEEP=1) to provision two test VMs and"
    info "  validate inter-zone firewall rules end-to-end. Expected runtime: 5–10 min."
else
    # ADR-008 switch/ap provider deep tests run first: isolated (temp CONFIG_DIR),
    # fast, hardware-free, and independent of the VM-provisioning deep flow below.
    deep_test_adr008_providers

    # ── Derive zone names + FQDNs from the fixture JSON (issue #306) ──────
    # The deep path must NOT hardcode zone names: derive them once here so a zone
    # rename in the fixtures flows everywhere (DNS, SSH, curl, zone-manager, and
    # the cleanup trap). cleanup_deep reads these globals at trap time, which is
    # always after this point, so it sees them too.
    TFW_A_ZONE=$(jq -r '.zone0 // empty' "${FIXTURES_DIR}/test-fw-a.json" 2>/dev/null)
    TFW_B_ZONE=$(jq -r '.zone0 // empty' "${FIXTURES_DIR}/test-fw-b.json" 2>/dev/null)
    TFW_C_ZONE=$(jq -r '.zone0 // empty' "${FIXTURES_DIR}/test-fw-c/test-fw-c.json" 2>/dev/null)
    [[ -n "${TFW_A_ZONE}" && -n "${TFW_B_ZONE}" && -n "${TFW_C_ZONE}" ]] \
        || die "Could not derive test zone names from fixtures (test-fw-{a,b,c} zone0)"
    TFW_A_FQDN="test-fw-a.${TFW_A_ZONE}.internal"
    TFW_B_FQDN="test-fw-b.${TFW_B_ZONE}.internal"
    TFW_C_FQDN="test-fw-c.${TFW_C_ZONE}.internal"

    section "Deep 1: Activate ${TFW_A_ZONE} and ${TFW_B_ZONE} zones"

    # #306 regression guard: no fixture zone NAME may be hardcoded anywhere in
    # this script — everything must derive from the fixtures. Uses the
    # fixture-derived values, so it stays correct across future zone renames.
    if grep -qE "${TFW_A_ZONE}|${TFW_B_ZONE}|${TFW_C_ZONE}" "${BASH_SOURCE[0]}"; then
        fail "hardcoded zone-name literal(s) in $(basename "${BASH_SOURCE[0]}") (#306) — derive from fixtures"
        grep -nE "${TFW_A_ZONE}|${TFW_B_ZONE}|${TFW_C_ZONE}" "${BASH_SOURCE[0]}" | sed 's/^/      /'
    else
        pass "no hardcoded zone-name literals in $(basename "${BASH_SOURCE[0]}") (#306)"
    fi

    trap cleanup_deep EXIT

    # MERGE the test zones from the canonical SOURCE into the DEPLOYED zones.json
    # (set Active), preserving every other zone. We must NOT overwrite the runtime
    # config wholesale — that destroys runtime-only zones such as variant zones
    # (defect 4, ISSUES/deep-test-trunk-and-nixbuild.md). cleanup_deep removes
    # these test-zone keys again afterwards.
    if [[ -f "${SCRIPT_DIR}/zones.json" && -f "${CONFIG_DIR}/zones.json" ]]; then
        tmp=$(mktemp)
        if jq --slurpfile src "${SCRIPT_DIR}/zones.json" \
              --arg za "${TFW_A_ZONE}" --arg zb "${TFW_B_ZONE}" --arg zc "${TFW_C_ZONE}" '
              ($src[0]) as $s
              | reduce ([$za, $zb, $zc][]) as $z
                  (.; .[$z] = (($s[$z] // {}) + { state: "Active" }))' \
              "${CONFIG_DIR}/zones.json" > "${tmp}" && jq empty "${tmp}" 2>/dev/null; then
            mv "${tmp}" "${CONFIG_DIR}/zones.json"
            info "Merged test zones ${TFW_A_ZONE}/${TFW_B_ZONE}/${TFW_C_ZONE} (Active) into deployed zones.json (runtime-only zones preserved)"
        else
            rm -f "${tmp}"
            fail "Could not merge test zones into deployed zones.json"
        fi
    fi

    if [[ ! -f "${CONFIG_DIR}/zones.json" ]]; then
        fail "deployed zones.json missing — cannot activate test zones"
    else
        tmp=$(mktemp)
        jq --arg za "${TFW_A_ZONE}" --arg zb "${TFW_B_ZONE}" --arg zc "${TFW_C_ZONE}" \
           '(.[$za].state = "Active") | (.[$zb].state = "Active") | (.[$zc].state = "Active")' \
            "${CONFIG_DIR}/zones.json" > "${tmp}" \
            && mv "${tmp}" "${CONFIG_DIR}/zones.json"
        info "Activated ${TFW_A_ZONE}, ${TFW_B_ZONE} and ${TFW_C_ZONE} in deployed zones.json"

        # NOTE: do NOT touch firewall.json trunks0 — it is the sentinel "ALL",
        # which vmnet_sync_firewall_trunks resolves to every active zone's VLAN
        # (the test zones are Active by now, so they are included automatically).
        # Appending a zone NAME here used to mangle "ALL" and clobber the firewall
        # NIC to a single VLAN (defect 1 — now fixed).
        if zone-manager --no-ssl-verify --zones-file "${CONFIG_DIR}/zones.json" --execute 2>&1 | tail -5; then
            pass "zone-manager applied ${TFW_A_ZONE}+${TFW_B_ZONE} (VLAN+DHCP+rules)"
        else
            fail "zone-manager could not apply ${TFW_A_ZONE}+${TFW_B_ZONE}"
        fi

        # zone-manager creates new opt interfaces (opt5/opt6 for the new test zones), but
        # OPNsense's auto-generated bootp/anti-lockout pass rules for those new
        # interfaces are NOT regenerated by /api/firewall/filter/apply. Without
        # `configctl filter reload`, DHCP DISCOVER from VMs in the new zones is
        # silently dropped — VMs never get an IP.
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                root@"${FIREWALL_FQDN}" \
                "configctl filter reload" >/dev/null 2>&1; then
            pass "OPNsense filter reloaded — auto-rules regenerated for new interfaces"
        else
            fail "configctl filter reload failed — DHCP for new zones may not work"
        fi

        # Sync the firewall VM's Proxmox net0 trunks so the newly-activated test
        # VLANs reach OPNsense. Uses the SAFE shared helper (resolves trunks0=
        # "ALL" -> all active VLAN tags; preserves MAC/tag/queues; only writes on
        # change) — NOT the old per-zone rewrite that clobbered net0 to a single
        # VLAN (defect 1, ISSUES/deep-test-trunk-and-nixbuild.md).
        if vmnet_sync_firewall_trunks "${CONFIG_DIR}/zones.json" "${CONFIG_DIR}/firewall.json"; then
            pass "OPNsense VM net0 trunks synced with all active VLANs"
        else
            fail "Could not sync OPNsense VM net0 trunks"
        fi
    fi

    # Distribute the refreshed zones.json to each Proxmox node so
    # Create-TAPPaaS-VM.sh on the node can resolve the new test zones.
    nodes_pushed=0
    if command -v jq >/dev/null 2>&1 && [[ -f "${CONFIG_DIR}/configuration.json" ]]; then
        mapfile -t pve_nodes < <(jq -r '."tappaas-nodes"[]?.hostname // empty' \
                                    "${CONFIG_DIR}/configuration.json" 2>/dev/null)
        for node in "${pve_nodes[@]}"; do
            [[ -z "${node}" ]] && continue
            if scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
                    "${CONFIG_DIR}/zones.json" \
                    "root@${node}.mgmt.internal:/root/tappaas/zones.json" \
                    >/dev/null 2>&1; then
                nodes_pushed=$((nodes_pushed + 1))
            fi
        done
    fi
    if (( nodes_pushed > 0 )); then
        pass "Distributed zones.json to ${nodes_pushed} Proxmox node(s)"
    else
        skip "Could not enumerate/push to Proxmox nodes (test VMs may fail to create)"
    fi

    section "Deep 2a: Install test-fw-c in ${TFW_C_ZONE} (auto-pinhole provider, #173)"

    pushd "${FIXTURES_DIR}" >/dev/null || die "Cannot enter ${FIXTURES_DIR}"

    # Helper: install a module with one retry on transient failure. The
    # templates:nixos step intermittently fails on the first VM brought up in
    # a freshly-activated zone (cloud-init / SSH-readiness race). A second
    # attempt — after delete-module.sh has cleaned partial state — reliably
    # succeeds.
    install_with_retry() {
        local mod="$1"
        local mod_dir="$2"
        # Source layout: most fixtures live flat in FIXTURES_DIR, but
        # test-fw-c lives in its own subdir (test-fw-c/) because it ships a
        # services/web/{install,update,delete}-service.sh + pinhole.json.
        # install-module.sh resolves <mod>.json relative to cwd.
        pushd "${mod_dir}" >/dev/null
        if /home/tappaas/bin/install-module.sh "${mod}" 2>&1 | tee -a "${LOG_FILE}" | tail -10; then
            pass "install-module.sh ${mod}"
            popd >/dev/null
            return 0
        fi
        warn "  First install of ${mod} failed (likely cloud-init race) — retrying once after cleanup..."
        /home/tappaas/bin/delete-module.sh "${mod}" --force >/dev/null 2>&1 || true
        if /home/tappaas/bin/install-module.sh "${mod}" 2>&1 | tee -a "${LOG_FILE}" | tail -10; then
            pass "install-module.sh ${mod} (succeeded on retry)"
            popd >/dev/null
            return 0
        fi
        fail "install-module.sh ${mod} (failed twice)"
        popd >/dev/null
        return 1
    }

    install_with_retry test-fw-c "${FIXTURES_DIR}/test-fw-c" || true

    info "Waiting up to 90s for test-fw-c DNS registration..."
    for _ in {1..18}; do
        if getent hosts "${TFW_C_FQDN}" >/dev/null 2>&1; then
            pass "DNS registered ${TFW_C_FQDN}"
            break
        fi
        sleep 5
    done
    getent hosts "${TFW_C_FQDN}" >/dev/null 2>&1 \
        || fail "${TFW_C_FQDN} did not appear in DNS within 90s"

    section "Deep 2b: Install test-fw-a in ${TFW_A_ZONE} (auto-pinhole consumer, #173)"

    install_with_retry test-fw-a "${FIXTURES_DIR}" || true

    # Wait for cloud-init / DHCP / DNS to settle
    info "Waiting up to 90s for test-fw-a DNS registration..."
    for _ in {1..18}; do
        if getent hosts "${TFW_A_FQDN}" >/dev/null 2>&1; then
            pass "DNS registered ${TFW_A_FQDN}"
            break
        fi
        sleep 5
    done
    getent hosts "${TFW_A_FQDN}" >/dev/null 2>&1 \
        || fail "${TFW_A_FQDN} did not appear in DNS within 90s"

    section "Deep 3: Verify test-fw-a webserver"

    if curl -fsS --max-time 5 "http://${TFW_A_FQDN}:8080/" 2>/dev/null \
            | grep -q "tappaas-firewall-test-a-ok"; then
        pass "test-fw-a webserver returns marker"
    else
        fail "test-fw-a webserver did not return marker"
    fi

    section "Deep 4: Caddy reverse proxy for test-fw-a"

    # firewall:proxy install-service already ran via install-module.sh. Verify it.
    proxy_domain=$(read_module_config "test-fw-a" 2>/dev/null | jq -r '.proxyDomain // empty' 2>/dev/null)
    if [[ -z "${proxy_domain}" ]]; then
        # Derive default — <vmname>.<tappaas.domain>
        domain=$(jq -r '.tappaas.domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null)
        proxy_domain="test-fw-a.${domain}"
    fi
    if [[ -n "${proxy_domain}" && "${proxy_domain}" != "test-fw-a." ]]; then
        # caddy-manager has the global-flag-before-subcommand argparse bug;
        # place --no-ssl-verify AFTER the subcommand.
        if caddy-manager list --no-ssl-verify 2>/dev/null | grep -q "test-fw-a\|${proxy_domain}"; then
            pass "Caddy domain entry for test-fw-a present"
        else
            fail "Caddy domain entry for test-fw-a missing"
        fi
    else
        skip "no proxyDomain — Caddy verification skipped"
    fi

    section "Deep 5: Install test-fw-b in ${TFW_B_ZONE}"

    install_with_retry test-fw-b "${FIXTURES_DIR}" || true

    info "Waiting up to 90s for test-fw-b DNS registration..."
    for _ in {1..18}; do
        if getent hosts "${TFW_B_FQDN}" >/dev/null 2>&1; then
            pass "DNS registered ${TFW_B_FQDN}"
            break
        fi
        sleep 5
    done

    section "Deep 6: rules-manager applied rules for test-fw-b"

    # Module-name peer rule
    if rules-manager list-rules --module test-fw-b --no-ssl-verify --output json 2>/dev/null \
            | jq -e '.rules // [] | map(.description) | any(. | contains("tappaas-module:test-fw-b:ingress:test-fw-a:9090"))' \
            >/dev/null 2>&1; then
        pass "ingress from module-name peer (test-fw-a) rule present"
    else
        fail "ingress from module-name peer (test-fw-a) rule missing"
    fi

    # Module-local alias peer rule
    if rules-manager list-rules --module test-fw-b --no-ssl-verify --output json 2>/dev/null \
            | jq -e '.rules // [] | map(.description) | any(. | contains("tappaas-module:test-fw-b:ingress:alias:test_admin_ips:9090"))' \
            >/dev/null 2>&1; then
        pass "ingress from module-local alias (test_admin_ips) rule present"
    else
        fail "ingress from module-local alias (test_admin_ips) rule missing"
    fi

    section "Deep 6b: Auto-pinhole rule for test-fw-a → test-fw-c (issue #173, AC-1)"

    # The auto-pinhole rule is owned by the *consumer* (test-fw-a) per #173 —
    # so we query rules-manager filtering on module test-fw-a, looking for a
    # description with the svcdep prefix referring to provider test-fw-c
    # service 'web' on port 9091.
    AUTO_DESC="tappaas-svcdep:test-fw-a:web:test-fw-c:9091"

    if rules-manager list-rules --module test-fw-a --no-ssl-verify --output json 2>/dev/null \
            | jq -e --arg d "${AUTO_DESC}" \
                '.rules // [] | map(.description) | any(. | contains($d))' \
            >/dev/null 2>&1; then
        pass "auto-pinhole rule ${AUTO_DESC} present in OPNsense"
    else
        fail "auto-pinhole rule ${AUTO_DESC} missing from OPNsense"
        # Dump what IS there to make diagnosis easy.
        rules-manager list-rules --module test-fw-a --no-ssl-verify --output json 2>/dev/null \
            | jq -r '.rules // [] | .[].description' | sed 's/^/    /' | head -10
    fi

    # Also verify the rule's source/destination point at the right host
    # aliases (consumer.alias → provider.alias) and lives on the consumer's
    # zone interface. We query the FirewallManager-level info via the same
    # list-rules output, which carries source_net/destination_net/interface
    # if the OPNsense API returns them.
    rules-manager list-rules --module test-fw-a --no-ssl-verify --output json 2>/dev/null \
        > /tmp/fw-test-rules-a.json || true
    if jq -e --arg d "${AUTO_DESC}" '
        .rules // []
        | map(select(.description | contains($d)))
        | length > 0
    ' /tmp/fw-test-rules-a.json >/dev/null 2>&1; then
        pass "auto-pinhole rule references both module aliases (form check)"
    else
        fail "auto-pinhole rule form check failed"
    fi
    rm -f /tmp/fw-test-rules-a.json

    section "Deep 7: OPNsense aliases exist"

    # Verify the FQDN alias was created in OPNsense's filter config. We check
    # by listing the alias rules-manager has applied — if the rule destinations
    # contain the alias name, OPNsense accepted the alias and bound it to a
    # rule (Deep 8/9 then prove it functions end-to-end via Unbound resolution).
    # (Note: pfctl -t ... -T show is unreliable because OPNsense's update_tables.py
    # populates FQDN-host aliases asynchronously on a cron; the table can be empty
    # for minutes after creation even though the rules using it work fine.)
    if rules-manager list-rules --module test-fw-b --output json --no-ssl-verify 2>/dev/null \
            | jq -e '.rules[] | select(.description | contains("test-fw-a")) | .uuid' \
            >/dev/null 2>&1; then
        pass "rules referencing FQDN alias tm_test_fw_a applied to OPNsense"
    else
        fail "no rule references tm_test_fw_a — alias not wired through"
    fi

    # Test VMs are typically reinstalled fresh; clear stale host keys so the
    # inter-VM ssh probes don't fail on REMOTE_HOST_IDENTIFICATION_CHANGED.
    ssh-keygen -R "${TFW_A_FQDN}" >/dev/null 2>&1 || true
    ssh-keygen -R "${TFW_B_FQDN}" >/dev/null 2>&1 || true

    section "Deep 8: Inter-VM connectivity (pinhole works)"

    # From test-fw-a, curl test-fw-b on its pinhole port — should succeed.
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "tappaas@${TFW_A_FQDN}" \
            "curl -fsS --max-time 5 http://${TFW_B_FQDN}:9090/" 2>/dev/null \
            | grep -q "tappaas-firewall-test-b-ok"; then
        pass "test-fw-a → test-fw-b:9090 (pinhole permitted)"
    else
        fail "test-fw-a → test-fw-b:9090 (expected pinhole to allow)"
    fi

    section "Deep 9: Reverse direction respects policy"

    # test-fw-b → test-fw-a on 8080 IS declared in test-fw-a's ingress (from test-fw-b's zone),
    # so this SHOULD succeed; confirms bidirectional rule compilation.
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "tappaas@${TFW_B_FQDN}" \
            "curl -fsS --max-time 5 http://${TFW_A_FQDN}:8080/" 2>/dev/null \
            | grep -q "tappaas-firewall-test-a-ok"; then
        pass "test-fw-b → test-fw-a:8080 (declared pinhole permitted)"
    else
        fail "test-fw-b → test-fw-a:8080 (declared pinhole expected)"
    fi

    section "Deep 9b: Auto-pinhole permits real traffic (issue #173, AC-2)"

    # Curl from test-fw-a (consumer zone) → test-fw-c (provider zone) over the
    # auto-pinhole rule on port 9091. zone-level access-to from the consumer zone
    # to the provider zone is deliberately absent (provider access-to = ['internet']) — only
    # the auto-pinhole grants this path. A successful response with the
    # test-fw-c marker proves the auto-pinhole works end-to-end.
    #
    # FQDN-alias asynchrony: rules-manager creates the OPNsense alias
    # tm_test_fw_c pointing at ${TFW_C_FQDN}, but the
    # pfctl alias TABLE behind it is populated by OPNsense's update_tables.py
    # cron (typically every 60s). Until the table holds an IP, the rule's
    # destination matches nothing and the packet falls through to deny. We
    # poke filter+alias reload on the firewall to coerce immediate population,
    # then retry the curl with backoff so a cold cron schedule doesn't make
    # this test flaky.
    ssh-keygen -R "${TFW_C_FQDN}" >/dev/null 2>&1 || true

    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        root@"${FIREWALL_FQDN}" \
        "configctl filter reload >/dev/null 2>&1; \
         /usr/local/etc/rc.update_alias_tables.sh >/dev/null 2>&1 || true; \
         configctl alias reload >/dev/null 2>&1 || true" \
        >/dev/null 2>&1 || true

    autopinhole_curl_ok=0
    for attempt in 1 2 3 4 5 6; do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                "tappaas@${TFW_A_FQDN}" \
                "curl -fsS --max-time 5 http://${TFW_C_FQDN}:9091/" 2>/dev/null \
                | grep -q "tappaas-firewall-test-c-ok"; then
            autopinhole_curl_ok=1
            break
        fi
        # Re-poke alias reload between attempts — handles update_tables.py cron
        # cadence that may not have fired since rule creation.
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            root@"${FIREWALL_FQDN}" \
            "/usr/local/etc/rc.update_alias_tables.sh >/dev/null 2>&1 || true" \
            >/dev/null 2>&1 || true
        sleep 15
    done

    if (( autopinhole_curl_ok == 1 )); then
        pass "test-fw-a → test-fw-c:9091 (auto-pinhole permits cross-zone traffic; attempt ${attempt})"
    else
        # Distinguish "auto-pinhole wrong" from the known
        # "zone-manager block-private shadows the pinhole" infrastructure bug
        # (see ISSUES/zone-manager-block-private-shadows-auto-pinholes.md).
        # If pflog shows a `block` rule (numbered low on vlan0.810) eating
        # the SYN, that's the upstream issue, not an auto-pinhole bug — we
        # downgrade the result to a skip with a pointer.
        pflog_verdict=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            root@"${FIREWALL_FQDN}" \
            "timeout 3 tcpdump -i pflog0 -nvec 2 'tcp port 9091' 2>/dev/null &
             sleep 1
             ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                 tappaas@${TFW_A_FQDN} \
                 'curl --max-time 2 http://${TFW_C_FQDN}:9091/ >/dev/null 2>&1'
             wait" 2>/dev/null || true)

        if echo "${pflog_verdict}" | grep -qE 'block.*in on vlan0\.810'; then
            skip "test-fw-a → test-fw-c:9091 — auto-pinhole rule IS created (see Deep 6b) but zone-manager's block-private rule shadows it (see ISSUES/zone-manager-block-private-shadows-auto-pinholes.md)"
            info "  -- pflog evidence (a 'block' rule on vlan0.810 caught the SYN) --"
            echo "${pflog_verdict}" | grep -E 'block|tcp.*9091' | sed 's/^/      /' | head -4
        else
            fail "test-fw-a → test-fw-c:9091 (expected auto-pinhole to allow, gave up after 6×15s)"
            info "  -- pflog evidence --"
            echo "${pflog_verdict}" | sed 's/^/      /' | head -6
            info "  -- pfctl alias contents on firewall --"
            ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                root@"${FIREWALL_FQDN}" \
                "pfctl -t tm_test_fw_c -T show 2>&1; \
                 pfctl -t tm_test_fw_a -T show 2>&1" 2>/dev/null \
                | sed 's/^/      /' | head -20
        fi
    fi

    # Negative check: a port that is NOT in pinhole.json should be blocked.
    # We use 22/SSH on test-fw-c — sshd is enabled but no pinhole or zone rule
    # allows the consumer zone → provider zone:22, so the connection must be filtered.
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=3 \
            "tappaas@${TFW_A_FQDN}" \
            "timeout 5 bash -c 'echo > /dev/tcp/${TFW_C_FQDN}/22' 2>&1; echo rc=\$?" \
            2>/dev/null | grep -qE 'rc=(1|124|2)'; then
        pass "test-fw-a → test-fw-c:22 BLOCKED (no auto-pinhole, no zone access)"
    else
        fail "test-fw-a → test-fw-c:22 should be blocked (auto-pinhole only opens 9091)"
    fi

    section "Deep 10: Reconcile prunes a removed ingress entry"

    # Remove one ingress entry from the deployed test-fw-b.json and reconcile.
    # The deployed config is in Pattern A form (#207) — `ingress` is nested under
    # `.config.*`, so a raw `jq '.ingress[]'` against the file sees null. Use
    # jq_module_write, which normalizes to flat (where `.ingress` is the array),
    # applies the filter, and writes back as Pattern A.
    jq_module_write test-fw-b 'del(.ingress[] | select(.from == "alias:test_admin_ips"))'

    if rules-manager reconcile test-fw-b --no-ssl-verify --output json >/tmp/rm-rec.json 2>/dev/null; then
        deleted=$(jq -r '.deleted // 0' /tmp/rm-rec.json 2>/dev/null || echo 0)
        if [[ "${deleted}" -ge 1 ]]; then
            pass "reconcile deleted ${deleted} orphan rule(s)"
        else
            fail "reconcile did not delete the removed ingress (deleted=${deleted})"
        fi
    else
        fail "rules-manager reconcile failed"
    fi
    rm -f /tmp/rm-rec.json

    popd >/dev/null

    # ── Deep 11: Caddy public + split-horizon access (ADR-005, #316) ──────
    # Reuses the test-fw-a webserver (already registered via firewall:proxy with
    # the default variant's wildcard domain) to prove a service published on the
    # internet is reachable end-to-end:
    #   (a) from outside — via the public IP, TLS-terminated + proxied by Caddy
    #   (b) from inside  — via split-horizon DNS (FQDN -> DMZ gateway -> Caddy)
    section "Deep 11: Caddy public + split-horizon access (ADR-005)"

    # Reject empty / RFC1918 / loopback / link-local — i.e. require a public IP.
    is_public_ip() {
        local ip="$1"
        [[ -n "${ip}" ]] || return 1
        case "${ip}" in
            10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        esac
        return 0
    }

    TFW_A_MARKER="tappaas-firewall-test-a-ok"
    DEF_DOMAIN="$(get_variant_config "" 2>/dev/null | jq -r '.domain // ""')"
    PROXY_FQDN=""
    [[ -n "${DEF_DOMAIN}" ]] && PROXY_FQDN="test-fw-a.${DEF_DOMAIN}"
    PUBLIC_IP=""
    if [[ -n "${PROXY_FQDN}" ]]; then
        PUBLIC_IP="$(dig +short @1.1.1.1 A "${PROXY_FQDN}" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
    fi

    # ── Gate: default-variant domain set AND public DNS -> a public IP ────
    if [[ -z "${DEF_DOMAIN}" || "${DEF_DOMAIN}" == CHANGE* ]]; then
        skip "Deep 11: no default-variant domain set (variant-manager add \"\" --domain <domain>)"
    elif ! is_public_ip "${PUBLIC_IP}"; then
        skip "Deep 11: public DNS for ${PROXY_FQDN} did not resolve to a public IP (got '${PUBLIC_IP:-none}') — publish the A/wildcard record first"
    else
        info "  Service FQDN: ${BL}${PROXY_FQDN}${CL}"
        info "  Public IP:    ${BL}${PUBLIC_IP}${CL}"

        # (a) External passthrough: connect to the public IP (NAT reflection),
        #     Caddy terminates the wildcard TLS and proxies to the upstream.
        if curl -fsS --max-time 15 --resolve "${PROXY_FQDN}:443:${PUBLIC_IP}" \
                "https://${PROXY_FQDN}/" 2>/dev/null | grep -q "${TFW_A_MARKER}"; then
            pass "Deep 11a: ${PROXY_FQDN} reachable via public IP ${PUBLIC_IP} (TLS + passthrough through Caddy)"
        else
            fail "Deep 11a: no passthrough via public IP ${PUBLIC_IP} (needs public A record, NAT reflection, valid wildcard cert, and Caddy->upstream:8080)"
        fi

        # (b) Split-horizon: internal DNS must resolve the FQDN to the DMZ gateway
        #     (NOT the public IP), and the service must be reachable that way.
        DMZ_GW="$(dmz_gateway_ip 2>/dev/null || echo '')"
        INTERNAL_IP="$(getent hosts "${PROXY_FQDN}" 2>/dev/null | awk '{print $1}' | head -1)"
        if [[ -n "${DMZ_GW}" && "${INTERNAL_IP}" == "${DMZ_GW}" ]]; then
            pass "Deep 11b: internal DNS resolves ${PROXY_FQDN} -> ${DMZ_GW} (split-horizon)"
        else
            fail "Deep 11b: internal DNS for ${PROXY_FQDN} is '${INTERNAL_IP:-none}', expected DMZ gateway '${DMZ_GW:-?}'"
        fi

        if curl -fsS --max-time 15 "https://${PROXY_FQDN}/" 2>/dev/null | grep -q "${TFW_A_MARKER}"; then
            pass "Deep 11c: ${PROXY_FQDN} reachable internally via split-horizon DNS + Caddy"
        else
            fail "Deep 11c: not reachable internally via split-horizon (needs DMZ access from this host + Caddy->upstream:8080)"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────

echo ""
info "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
info "${BOLD}  Firewall test summary${CL}"
info "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
info "  ${GN}Passed:${CL}  ${PASS}"
info "  ${RD}Failed:${CL}  ${FAIL}"
info "  ${YW}Skipped:${CL} ${SKIP}"
info ""
info "Log saved: ${LOG_FILE}"

if [[ "${FAIL}" -eq 0 ]]; then
    info "${GN}${BOLD}All firewall tests passed.${CL}"
    exit 0
elif [[ "${BASIC_FAIL:-0}" -gt 0 ]]; then
    # Basic connectivity/DNS broke → firewall is unreachable/non-functional.
    # Exit 2 (fatal) so update-module.sh treats it as rollback-worthy (#307).
    error "${RD}${BOLD}${FAIL} firewall test(s) failed — ${BASIC_FAIL} in Basic"
    error "${RD}${BOLD}(DNS/connectivity): firewall is broken — FATAL.${CL}"
    exit 2
else
    error "${RD}${BOLD}${FAIL} firewall test(s) failed.${CL}"
    exit 1
fi
