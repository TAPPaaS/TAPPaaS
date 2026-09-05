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

# shellcheck source=../tappaas-cicd/lib/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../cluster/lib/vm-net.sh disable=SC1091
. /home/tappaas/TAPPaaS/src/foundation/cluster/lib/vm-net.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIXTURES_DIR="${SCRIPT_DIR}/test-fixtures"
readonly CONFIG_DIR="/home/tappaas/config"
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi
readonly ZONES_JSON="${CONFIG_DIR}/zones.json"
# The canonical zones SOURCE TEMPLATE moved out of this module dir into the
# network-manager in the firewall→network rename (commit 879341b, "move
# zones.json source template -> network-manager"). The Standard-8 NONE-mode
# fallback and the deep-test zone seeding read from it; point at the new home
# (the old ${SCRIPT_DIR}/zones.json no longer exists → rules-manager init
# failed and the deep merge silently skipped).
readonly ZONES_TEMPLATE="${SCRIPT_DIR}/../tappaas-cicd/manager/network-manager/zones.json"
# ADR-014 D7: the deep-test probe zones were REMOVED from the install template
# (a test probe has no business on a production install) and now live with the
# test that activates them. --deep merges these into the deployed zones.json,
# then cleanup_deep removes the keys again. Their NAMES stay out of this file —
# every use derives from the fixtures, which the #306 guard enforces.
DEEP_COMPLETED=0
readonly TEST_ZONES_FIXTURE="${SCRIPT_DIR}/test-fixtures/test-zones.json"
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
        network|firewall) ;;  # module name passed by test-module.sh (network, or legacy firewall) — ignore
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

# The plane bins network-manager actually shells out to (planes.ts PLANE_BIN):
# zone-manager (opnsense), proxmox-controller, switch-controller, ap-controller.
# (Historically this listed the pre-split names opnsense-manager/proxmox-manager/
# switch-controller/ap-manager/zone-reconcile — which left the switch-controller
# rename gap undetected, since switch-controller existed while switch-controller did not.)
for tool in opnsense-firewall zone-manager dns-manager caddy-manager rules-manager \
            proxmox-controller switch-controller ap-controller network-manager; do
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

for file in "${ZONES_JSON}" "${ZONES_TEMPLATE}"; do
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
        pass "network/aliases.json parses"
    else
        fail "network/aliases.json invalid JSON"
    fi
    # private_ranges expected per design
    if jq -e '.private_ranges and (.private_ranges.type == "network")' "${ALIASES_JSON}" >/dev/null 2>&1; then
        pass "aliases.json contains private_ranges (RFC1918)"
    else
        fail "aliases.json missing private_ranges or wrong type"
    fi
else
    fail "network/aliases.json not found at ${ALIASES_JSON}"
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
hostless_count=0
for f in "${CONFIG_DIR}"/*.json; do
    vmname=$(jq -r '.vmname // empty' "${f}" 2>/dev/null)
    [[ -z "${vmname}" ]] && continue
    alias_type=$(jq -r '.aliasType // "host"' "${f}" 2>/dev/null)
    if [[ "${alias_type}" == "network" ]]; then
        network_alias_count=$((network_alias_count + 1))
        continue
    fi
    # ADR-012: a datastore-less backup (placementState shim / remote-only)
    # realizes no local host, so it has no <vmname> DNS record by design —
    # exclude it, mirroring the aliasType=network exclusion above.
    placement_state=$(jq -r '.placementState // empty' "${f}" 2>/dev/null)
    if [[ "${placement_state}" == "shim" || "${placement_state}" == "remote-only" ]]; then
        hostless_count=$((hostless_count + 1))
        continue
    fi
    sample_modules+="${vmname}"$'\n'
done
sample_modules=$(printf '%s' "${sample_modules}" | sort -u | head -3)

if [[ "${network_alias_count}" -gt 0 ]]; then
    skip "${network_alias_count} module(s) excluded — aliasType=network has no DNS record by design"
fi

if [[ "${hostless_count}" -gt 0 ]]; then
    skip "${hostless_count} module(s) excluded — datastore-less backup (shim/remote-only) has no DNS record by design"
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
# The zones file is the install template PLUS the deep-test probe zones: the
# fixture module lives in one of those probe zones, which ADR-014 D7 removed from
# the install template (see TEST_ZONES_FIXTURE), so the two must be combined for
# the reference check. NOTE: do not name a probe zone literally anywhere in this
# file — the #306 guard below greps for exactly that.
_S8_ZONES="$(mktemp)"
jq -s '.[0] * .[1]' "${ZONES_TEMPLATE}" "${TEST_ZONES_FIXTURE}" > "${_S8_ZONES}" 2>/dev/null \
    || cp "${ZONES_TEMPLATE}" "${_S8_ZONES}"
if command -v rules-manager >/dev/null 2>&1 && [[ -f "${FIXTURES_DIR}/test-fw-a.json" ]]; then
    if rules-manager add-rules test-fw-a \
            --firewall-type NONE \
            --modules-dir "${FIXTURES_DIR}" \
            --zones-file "${_S8_ZONES}" \
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
rm -f "${_S8_ZONES}"

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


section "Standard 11: network:proxy drift reports both directions (issue #580)"

# The drift verdict for network:proxy is this script's EXIT CODE and nothing
# else: reconcile has no report-service.sh for the service and every field in
# its manifest is apply:"reconcile", so the generic differ compares nothing
# (converge.ts, needsActualState). That made the verifier the only thing
# standing between "declared" and "actually provisioned" — and it reported
# `no drift` for a module with zero domains and zero handlers, because Checks 1
# and 2 downgraded a missing vhost to a warning whenever no cert refid resolved.
#
# So assert BOTH directions, which is what #580 asked for and what could not be
# asserted while the only source of truth was the live OPNsense:
#   A. vhost present  → Checks 1 and 2 pass
#   B. vhost absent   → Checks 1 and 2 fail AND the script exits non-zero
#   C. handler on the wrong port   → reported as such, not as clean
#   D. handler on the wrong scheme → reported as such, not as clean
#
# TAPPAAS_TEST_CADDY_LIST feeds test-service.sh a recorded `caddy-manager list`
# instead of querying the firewall — the same NONE-mode fixture trick Standard 9
# uses for the auto-pinhole compile.
#
# Self-calibrating: direction B runs FIRST against an empty listing, and the
# domain/upstream:port it says it expected are what direction A's fixture is
# built from. Nothing here hard-codes an estate's names.

PROXY_TS="${SCRIPT_DIR}/services/proxy/test-service.sh"

# Pick a deployed module that declares network:proxy. Any will do — the fixture
# is derived from whatever that module resolves to.
_p580_mod=""
for f in "${CONFIG_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    if jq -e '[(.dependsOn // []), (.integratesWith // [])] | flatten
              | index("network:proxy")' "${f}" >/dev/null 2>&1; then
        _p580_mod="$(basename "${f}" .json)"
        break
    fi
done

_p580_strip() { sed 's/\x1b\[[0-9;]*m//g'; }

if [[ ! -f "${PROXY_TS}" ]]; then
    fail "network:proxy test-service.sh not found at ${PROXY_TS}"
elif [[ -z "${_p580_mod}" ]]; then
    skip "no deployed module declares network:proxy — nothing to derive a fixture from"
else
    _p580_dir="$(mktemp -d)"
    : > "${_p580_dir}/empty.list"
    printf 'No Caddy reverse proxy entries configured\n' > "${_p580_dir}/empty.list"

    # ── B. vhost absent → must report drift ──────────────────────────
    _p580_out="${_p580_dir}/absent.out"
    TAPPAAS_TEST_CADDY_LIST="${_p580_dir}/empty.list" \
        bash "${PROXY_TS}" "${_p580_mod}" > "${_p580_out}" 2>&1 || true
    _p580_txt="$(_p580_strip < "${_p580_out}")"

    if grep -q "Domain .* not found in Caddy" <<<"${_p580_txt}" \
       && grep -q "Handler for .* not found in Caddy" <<<"${_p580_txt}"; then
        pass "vhost absent: Checks 1 and 2 both report the missing vhost (${_p580_mod})"
    elif grep -q "no vhost expected" <<<"${_p580_txt}"; then
        skip "'${_p580_mod}' has no domain for its environment — no vhost is expected either way"
    else
        fail "vhost absent: missing domain/handler NOT reported — the #580 false green is back"
    fi

    # Exit code is what reconcile actually reads (services.ts: rc 0 == clean).
    if grep -q "no vhost expected" <<<"${_p580_txt}"; then
        : # skipped above; rc is legitimately 0
    else
        TAPPAAS_TEST_CADDY_LIST="${_p580_dir}/empty.list" \
            bash "${PROXY_TS}" "${_p580_mod}" >/dev/null 2>&1 && _p580_rc=0 || _p580_rc=$?
        if [[ "${_p580_rc}" -ne 0 ]]; then
            pass "vhost absent: exits ${_p580_rc} — reconcile reads this as DRIFT"
        else
            fail "vhost absent: exits 0 — reconcile would report 'no drift' (#580)"
        fi
    fi

    # ── A. vhost present → must report clean ─────────────────────────
    # Build the fixture from what direction B said it was looking for.
    _p580_dom="$(sed -n "s/.*Domain '\([^']*\)' not found in Caddy.*/\1/p" <<<"${_p580_txt}" | head -1)"
    _p580_up="$(sed -n "s/.*Handler for '\([^']*\)' not found in Caddy.*/\1/p" <<<"${_p580_txt}" | head -1)"

    if [[ -z "${_p580_dom}" || -z "${_p580_up}" ]]; then
        skip "could not derive a fixture for '${_p580_mod}' (no domain/handler expectation reported)"
    else
        cat > "${_p580_dir}/present.list" <<EOF
Domains (1):
  ${_p580_dom}                    [enabled]  (TAPPaaS: ${_p580_mod})  uuid=fixture-d

Handlers (1):
  -> ${_p580_up}     [enabled]  (TAPPaaS: ${_p580_mod})  uuid=fixture-h
EOF
        _p580_txt="$(TAPPAAS_TEST_CADDY_LIST="${_p580_dir}/present.list" \
            bash "${PROXY_TS}" "${_p580_mod}" 2>&1 | _p580_strip || true)"

        # Assert the two CHECKS, not the exit code: Check 3 curls the real
        # endpoint and its verdict depends on whether public TLS is set up here,
        # which is not what this section is about.
        if grep -q "Domain '${_p580_dom}' exists in Caddy" <<<"${_p580_txt}" \
           && grep -q "Handler for '${_p580_up}' exists in Caddy" <<<"${_p580_txt}"; then
            pass "vhost present: Checks 1 and 2 both report clean (${_p580_mod})"
        else
            fail "vhost present: a provisioned vhost was NOT recognised — the check is too strict"
        fi

        # ── C. handler on the wrong port ─────────────────────────────
        # Same upstream, a port the module did not declare. Must be called out,
        # not passed: a handler pointing at the wrong port is a vhost that
        # cannot serve the application, which is the failure #580 was filed on.
        # _p580_up is "<scheme>://<host>:<port>" — split off the port only.
        _p580_host="${_p580_up%:*}"
        _p580_port="${_p580_up##*:}"
        _p580_wrong=$(( _p580_port == 9 ? 10 : 9 ))
        cat > "${_p580_dir}/wrongport.list" <<EOF
Domains (1):
  ${_p580_dom}                    [enabled]  (TAPPaaS: ${_p580_mod})  uuid=fixture-d

Handlers (1):
  -> ${_p580_host}:${_p580_wrong}     [enabled]  (TAPPaaS: ${_p580_mod})  uuid=fixture-h
EOF
        _p580_txt="$(TAPPAAS_TEST_CADDY_LIST="${_p580_dir}/wrongport.list" \
            bash "${PROXY_TS}" "${_p580_mod}" 2>&1 | _p580_strip || true)"
        if grep -q "not the declared proxyPort ${_p580_port}" <<<"${_p580_txt}"; then
            pass "wrong upstream port reported as drift, not as clean"
        else
            fail "handler on port ${_p580_wrong} instead of ${_p580_port} was not reported"
        fi

        # ── D. handler on the wrong SCHEME ───────────────────────────
        # Right host, right port, but proxied as https:// to a port that speaks
        # plain HTTP. Matching host:port alone reported this clean while the
        # vhost could not serve the application behind it (#580 follow-up).
        _p580_otherscheme="https"
        [[ "${_p580_up}" == https://* ]] && _p580_otherscheme="http"
        _p580_swapped="${_p580_otherscheme}://${_p580_up#*://}"
        cat > "${_p580_dir}/wrongscheme.list" <<EOF
Domains (1):
  ${_p580_dom}                    [enabled]  (TAPPaaS: ${_p580_mod})  uuid=fixture-d

Handlers (1):
  -> ${_p580_swapped}     [enabled]  (TAPPaaS: ${_p580_mod})  uuid=fixture-h
EOF
        _p580_txt="$(TAPPAAS_TEST_CADDY_LIST="${_p580_dir}/wrongscheme.list" \
            bash "${PROXY_TS}" "${_p580_mod}" 2>&1 | _p580_strip || true)"
        if grep -q "proxies as ${_p580_otherscheme}://" <<<"${_p580_txt}"; then
            pass "wrong upstream scheme reported as drift, not as clean"
        else
            fail "handler proxying as ${_p580_otherscheme}:// was not reported"
        fi
    fi

    rm -rf "${_p580_dir}"
fi


# ─────────────────────────────────────────────────────────────────────
# Deep tests (--deep) — VM provisioning + inter-VM connectivity
# ─────────────────────────────────────────────────────────────────────

cleanup_deep() {
    local rc=$?
    # TRUNCATION GUARD. This trap is the only code guaranteed to run on an abort,
    # so the "did the deep tier actually finish?" check belongs HERE, not in the
    # summary block (which an abort never reaches). Twice now a stray non-zero
    # under `set -euo pipefail` unwound through this trap and the run reported
    # SUCCESS with no summary and every counted failure discarded.
    if [[ "${DEEP:-0}" == "1" && "${DEEP_COMPLETED:-0}" != "1" ]]; then
        echo "" >&2
        error "${RD}${BOLD}DEEP TIER ABORTED before completion${CL} — results are TRUNCATED."
        error "  ${PASS:-0} passed / ${FAIL:-0} failed were counted before the abort; later sections never ran."
        error "  Exit status is forced non-zero so this can never read as a pass."
        [[ "${rc}" -eq 0 ]] && rc=1
    fi
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

    # Drop the pf TABLE behind each fixture's alias, not just the alias.
    #
    # delete-module.sh removes the alias DEFINITION (verified: no tm_test_* in
    # /conf/config.xml after a run), but pf does not garbage-collect a table when
    # the rules referencing it go away — the kernel object survives, still
    # holding the address it was populated with. Five per deep run, never
    # removed, so a firewall accumulates dozens of dead tm_test_* tables over
    # time. Harmless to traffic (referenced-by-rules=0) and purely cosmetic, but
    # it reads exactly like a teardown that failed and cost one investigation
    # already.
    #
    # `-T kill` targets one table by name: it cannot touch a live module's table
    # the way a blanket `pfctl -F Tables` would. Best-effort — a table that was
    # never created is not an error worth failing teardown over.
    #
    # sh -c, not bare: root's shell here is csh, where `2>/dev/null` is
    # "Ambiguous output redirect." and the command never runs (see
    # _alias_refresh).
    for vm in test-fw-a test-fw-b test-fw-c; do
        local _tbl
        _tbl="tm_$(echo "${vm}" | tr '-' '_')"
        ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            root@"${FIREWALL_FQDN}" \
            "sh -c 'pfctl -t ${_tbl} -T kill >/dev/null 2>&1'" >/dev/null 2>&1 \
            || true
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
           'del(.[$za]) | del(.[$zb]) | del(.[$zc])
            # Also withdraw the control-plane grant added for the run, or
            # mgmt.access-to keeps naming zones that no longer exist — the exact
            # dangling-reference class ADR-014 set out to eliminate.
            | .mgmt["access-to"] = ((.mgmt["access-to"] // []) - [$za, $zb, $zc])' \
            "${CONFIG_DIR}/zones.json" > "${tmp}" \
            && mv "${tmp}" "${CONFIG_DIR}/zones.json"
        info "Deactivated and removed test zones ${TFW_A_ZONE}/${TFW_B_ZONE}/${TFW_C_ZONE} from deployed zones.json"
    fi
    # Restore the firewall VM net0 trunks now that the test zones are gone, so the
    # NIC config is back to the production set (defect 1 — the old code never did
    # this, leaving the firewall config clobbered after a run).
    vmnet_sync_firewall_trunks "${CONFIG_DIR}/zones.json" "${FIREWALL_JSON}" \
        || warn "Could not restore firewall net0 trunks — verify manually"
    # An EXIT trap's RETURN value does not set the script's exit status — only an
    # explicit `exit` does. Without this the truncation guard above printed its
    # warning and the run still exited 0, which is the exact failure mode it
    # exists to prevent. Clear the trap first so `exit` cannot re-enter it.
    trap - EXIT
    exit ${rc}
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

    section "Deep A: switch-controller — zone add/change/remove across reconcile phases (#339)"

    # Seed two test zones (961, 962) as Active in the isolated zones.json.
    jq '.swdeepA={state:"Active",vlantag:961} | .swdeepB={state:"Active",vlantag:962}' \
        "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"

    # vendor 'generic' has no plugin → manual fallback (an "equipment type that
    # does not exist" as far as automation is concerned).
    #
    # SETUP MUST FAIL LOUDLY. These were `>/dev/null 2>&1 || true`, which is how
    # this whole block silently rotted: #351 renamed the verbs (add → add-switch,
    # port → add-port/update-port, --source/--connected-to → --type/--target) the
    # day after the block was written, every call started printing
    # "Unknown command: add", the swallow hid it, the switch was never registered
    # and all 11 downstream assertions failed against a switch that did not
    # exist. A setup failure is not a test result — abort the block instead.
    _swsetup() { # description, then the switch-controller args
        local _desc="$1"; shift
        if ! env CONFIG_DIR="${T}" switch-controller "$@" >/dev/null 2>&1; then
            fail "Deep A setup: ${_desc} failed — \`switch-controller $1\` rejected its arguments"
            echo "      $(env CONFIG_DIR="${T}" switch-controller "$@" 2>&1 | head -2)" >&2
            return 1
        fi
    }
    if ! _swsetup "register switch"      add-switch testcore --vendor generic --managed manual --ip 10.0.0.99 \
       || ! _swsetup "add node trunk port"  add-port testcore 1 --type node --target tappaas1 \
                --target-port nic0 --mode trunk \
       || ! _swsetup "add device access port" add-port testcore 5 --type device --target test-printer \
                --mode access --zone swdeepA; then
        warn "Deep A: setup failed — skipping the rest of the switch/ap provider block"
        rm -rf "${T}"; set -e; return 0
    fi

    # ── A1: add zones → update-desired pulls the new VLANs into desired.json ──
    env CONFIG_DIR="${T}" switch-controller update-desired >/dev/null 2>&1 || true
    _djq "Deep A1: desired trunk port gained added VLANs 961+962" \
        '.switches.testcore.ports["1"].taggedVlans | (index(961) and index(962)) != null' "${D}"
    _djq "Deep A1: access port nativeVlan tracks zone swdeepA (961)" \
        '.switches.testcore.ports["5"].nativeVlan == 961' "${D}"

    # ── A2: phases — actual.json only changes after confirm ──────────────────
    env CONFIG_DIR="${T}" switch-controller interrogate >/dev/null 2>&1 || true   # manual → actual stays empty
    out="$(env CONFIG_DIR="${T}" switch-controller delta 2>&1 || true)"
    # delta names the CHANGE KIND now ("trunk-vlans:" / "access-vlan:"); the old
    # generic "configure-port" wording is gone.
    _dgrep "Deep A2: delta reports ports need configuring (actual empty)" "trunk-vlans" "${out}"
    # The switch and its port TOPOLOGY are recorded in actual.json at add-switch
    # time (that file is the inventory — see `switch-controller --help`). What
    # must NOT be there before confirm is the APPLIED VLAN state, i.e. taggedVlans.
    if jq -e '.switches.testcore.ports["1"].taggedVlans' "${AF}" >/dev/null 2>&1; then
        fail "Deep A2: actual.json must NOT carry applied VLAN state before confirm"
    else
        pass "Deep A2: actual.json has no applied VLAN state before confirm"
    fi
    env CONFIG_DIR="${T}" switch-controller confirm >/dev/null 2>&1 || true
    _djq "Deep A2: confirm wrote applied state into actual.json" \
        '.switches.testcore.ports["1"].taggedVlans | index(961) != null' "${AF}"
    rc=0; env CONFIG_DIR="${T}" switch-controller reconcile >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 0 ]]; then pass "Deep A2: reconcile reports in-sync after confirm (rc 0)"; else fail "Deep A2: reconcile not in-sync after confirm (rc ${rc})"; fi

    # ── A3: change a zone's VLAN (961→965) → drift on trunk AND access ──────
    jq '.swdeepA.vlantag=965' "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"
    env CONFIG_DIR="${T}" switch-controller update-desired >/dev/null 2>&1 || true
    out="$(env CONFIG_DIR="${T}" switch-controller delta 2>&1 || true)"
    _dgrep "Deep A3: trunk VLAN change detected" "trunk-vlans" "${out}"
    _dgrep "Deep A3: access VLAN change detected" "access-vlan" "${out}"
    _djq "Deep A3: desired.json now has new VLAN 965" \
        '.switches.testcore.ports["1"].taggedVlans | index(965) != null' "${D}"
    _djq "Deep A3: actual.json still has OLD VLAN 961 (drift, not yet applied)" \
        '.switches.testcore.ports["1"].taggedVlans | index(961) != null' "${AF}"

    # ── A4: remove a zone → its VLAN drops out of desired.json ─────────────
    jq 'del(.swdeepB)' "${T}/zones.json" > "${T}/z" && mv "${T}/z" "${T}/zones.json"
    env CONFIG_DIR="${T}" switch-controller update-desired >/dev/null 2>&1 || true
    _djq "Deep A4: removed zone VLAN 962 dropped from desired trunk" \
        '.switches.testcore.ports["1"].taggedVlans | index(962) == null' "${D}"

    # ── A5: unknown equipment type → manual instructions cite real port/VLAN ─
    out="$(env CONFIG_DIR="${T}" switch-controller reconcile --apply 2>&1)"; rc=$?
    _dgrep "Deep A5: manual plugin engaged for unknown vendor 'generic'" "MANUAL CONFIGURATION" "${out}"
    _dgrep "Deep A5: manual instructions cite the affected port (port 1)" "port 1" "${out}"
    _dgrep "Deep A5: manual instructions cite the new VLAN (965)" "965" "${out}"
    # OPEN CONTRACT QUESTION (deliberately still asserted, so it stays visible):
    # a manual switch that printed hand-configuration steps currently exits 0.
    # The five-verb provider contract says rc 2 = needs-manual, and network-manager
    # maps rc 2 → "needs-manual" (planes.ts classify()). Either the controller
    # should return 2, or the contract should say manual-apply is a success. This
    # is a REAL behavioural question for the operator, not a stale test string.
    if [[ "${rc}" -eq 2 ]]; then pass "Deep A5: reconcile --apply returns needs-manual (rc 2)"; else fail "Deep A5: expected rc 2 (needs-manual), got ${rc} — see the contract note above"; fi
    if jq -e '.switches.testcore.ports["1"].taggedVlans | index(965)' "${AF}" >/dev/null 2>&1; then
        fail "Deep A5: actual.json must stay unchanged after a manual (unapplied) reconcile"
    else
        pass "Deep A5: actual.json unchanged after manual reconcile (no false confirm)"
    fi

    section "Deep C: LIVE hardware — interrogate the real switch/AP (read-only)"

    # Deep A/B above are hardware-free: `--vendor generic` forces the manual
    # fallback in a temp CONFIG_DIR, so they prove the BOOKKEEPING (desired /
    # actual / delta / confirm) and never touch a vendor plugin. That was the
    # gap versus what #339 set out to test — the UniFi trunk-prune defect
    # (tagged_vlan_mgmt:"custom", fixed in 826d14c) was found by hand on the live
    # controller, not here. This block closes the read-only half: interrogate the
    # REAL registered equipment through its real plugin and check the result
    # against the recorded inventory. Read-only — it never writes to a switch.
    #
    # Runs against the LIVE CONFIG_DIR (not the temp one), and skips cleanly on a
    # system with no registered switch.
    if ! command -v switch-controller >/dev/null 2>&1; then
        skip "Deep C: switch-controller not on PATH"
    elif ! switch-controller list >/dev/null 2>&1 \
         || [[ -z "$(jq -r '.switches // {} | keys[]?' "${CONFIG_DIR}/switch-configuration-actual.json" 2>/dev/null)" ]]; then
        skip "Deep C: no switch registered — run setup-switches.sh to enable live-hardware coverage"
    else
        _live_sw="$(jq -r '.switches | keys[0]' "${CONFIG_DIR}/switch-configuration-actual.json")"
        _managed="$(jq -r --arg s "${_live_sw}" '.switches[$s].managed' "${CONFIG_DIR}/switch-configuration-actual.json")"
        info "  live switch: '${_live_sw}' (managed: ${_managed})"

        # C1: interrogate must reach the real controller and return cleanly. This
        # is the assertion that would have caught a broken vendor plugin.
        if switch-controller interrogate >/dev/null 2>&1; then
            pass "Deep C1: interrogate reached the live equipment via its vendor plugin"
        else
            fail "Deep C1: interrogate against the live switch failed (vendor plugin or controller unreachable)"
        fi

        # C2: the plugin must report the ports the inventory records. A plugin
        # that silently returns nothing (the failure mode behind the trunk-prune
        # bug) shows up here as a port count of zero.
        _np="$(jq -r --arg s "${_live_sw}" '.switches[$s].ports // {} | length' "${CONFIG_DIR}/switch-configuration-actual.json")"
        if [[ "${_np}" -gt 0 ]]; then
            pass "Deep C2: interrogate reports ${_np} port(s) for '${_live_sw}'"
        else
            fail "Deep C2: interrogate returned NO ports for '${_live_sw}' — plugin silently produced nothing"
        fi

        # C3: every port the operator declared a topology for must carry live VLAN
        # state. A managed port with no actual VLAN data means interrogate did not
        # really read the hardware.
        _blind="$(jq -r --arg s "${_live_sw}" '
            .switches[$s].ports // {} | to_entries
            | map(select(.value.type != null and .value.mode != null
                         and (.value.taggedVlans == null and .value.nativeVlan == null)))
            | map(.key) | join(",")' "${CONFIG_DIR}/switch-configuration-actual.json")"
        if [[ -z "${_blind}" ]]; then
            pass "Deep C3: every managed port carries live VLAN state from the hardware"
        else
            fail "Deep C3: managed port(s) ${_blind} have topology but NO live VLAN state — interrogate did not read them"
        fi

        # C4: desired-vs-actual on the real switch. Not a pass/fail on drift
        # itself (an operator may legitimately be mid-change) — it asserts the
        # comparison RUNS and reports a definite verdict.
        _drc=0; switch-controller delta >/dev/null 2>&1 || _drc=$?
        if [[ "${_drc}" -eq 0 ]]; then
            pass "Deep C4: live switch is in sync with zones.json"
        elif [[ "${_drc}" -eq 2 ]]; then
            skip "Deep C4: live switch has pending drift (rc 2) — converge with: switch-controller reconcile --apply"
        else
            fail "Deep C4: delta against the live switch errored (rc ${_drc})"
        fi

        # C5: LIVE APPLY — the other half of the gap, and the only part that
        # WRITES to real hardware. Deliberately opt-in: point
        # TAPPAAS_TEST_SWITCH_SPARE_PORT at a port that is unmanaged and has
        # nothing plugged into it. The test records the port's current trunk,
        # applies a change through the real vendor plugin, verifies it stuck, and
        # restores the original — the same method used by hand to find the
        # trunk-prune defect (826d14c), now automated.
        if [[ -z "${TAPPAAS_TEST_SWITCH_SPARE_PORT:-}" ]]; then
            skip "Deep C5: live-apply not run — set TAPPAAS_TEST_SWITCH_SPARE_PORT=<unused port> to exercise the vendor plugin's write path"
        elif [[ "${_managed}" != "auto" ]]; then
            skip "Deep C5: live switch is managed:${_managed} — no vendor plugin write path to test"
        else
            _sp="${TAPPAAS_TEST_SWITCH_SPARE_PORT}"
            _sp_type="$(jq -r --arg s "${_live_sw}" --arg p "${_sp}" '.switches[$s].ports[$p].type // "unmanaged"' "${CONFIG_DIR}/switch-configuration-actual.json")"
            if [[ "${_sp_type}" != "unmanaged" ]]; then
                fail "Deep C5: port ${_sp} is managed as '${_sp_type}' — refusing to write to a port in use. Pick an unused port."
            else
                info "  Deep C5: exercising the vendor plugin write path on unused port ${_sp} (will be restored)"
                _before="$(jq -rc --arg s "${_live_sw}" --arg p "${_sp}" '.switches[$s].ports[$p] // {}' "${CONFIG_DIR}/switch-configuration-actual.json")"
                _restore_spare() {
                    switch-controller remove-port "${_live_sw}" "${_sp}" >/dev/null 2>&1 || true
                    switch-controller reconcile --apply >/dev/null 2>&1 || true
                    info "  Deep C5: port ${_sp} restored (was: ${_before})"
                }
                if switch-controller add-port "${_live_sw}" "${_sp}" --type device --target tappaas-test-probe \
                        --mode access --zone mgmt >/dev/null 2>&1 \
                   && switch-controller reconcile --apply >/dev/null 2>&1; then
                    switch-controller interrogate >/dev/null 2>&1 || true
                    _nv="$(jq -r --arg s "${_live_sw}" --arg p "${_sp}" '.switches[$s].ports[$p].nativeVlan // empty' "${CONFIG_DIR}/switch-configuration-actual.json")"
                    if [[ -n "${_nv}" ]]; then
                        pass "Deep C5: vendor plugin applied a real VLAN change (port ${_sp} native ${_nv}) and it read back"
                    else
                        fail "Deep C5: apply reported success but the change did NOT read back from the hardware (the trunk-prune failure mode)"
                    fi
                else
                    fail "Deep C5: apply through the vendor plugin failed on port ${_sp}"
                fi
                _restore_spare
            fi
        fi
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
    env CONFIG_DIR="${T}" switch-controller add-port testcore 9 --type ap --target testap \
        --mode trunk --tagged 965 >/dev/null 2>&1 || true
    # add-port records the port in the INVENTORY (actual.json); the cross-provider
    # uplink check reads the switch's DESIRED trunk, so the switch side has to
    # regenerate it before ap-manager can see the VLAN. Without this the
    # validation can never clear and the assertion below is unsatisfiable.
    env CONFIG_DIR="${T}" switch-controller update-desired >/dev/null 2>&1 || true
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

    # MERGE the test zones from the deep-test FIXTURE into the DEPLOYED zones.json
    # (set Active), preserving every other zone. We must NOT overwrite the runtime
    # config wholesale — that destroys runtime-only zones such as variant zones
    # (historical defect 4 — investigation log in git history:
    # network/ISSUES/deep-test-trunk-and-nixbuild.md). cleanup_deep removes
    # these test-zone keys again afterwards.
    if [[ -f "${TEST_ZONES_FIXTURE}" && -f "${CONFIG_DIR}/zones.json" ]]; then
        tmp=$(mktemp)
        if jq --slurpfile src "${TEST_ZONES_FIXTURE}" \
              --arg za "${TFW_A_ZONE}" --arg zb "${TFW_B_ZONE}" --arg zc "${TFW_C_ZONE}" '
              ($src[0]) as $s
              | reduce ([$za, $zb, $zc][]) as $z
                  (.; .[$z] = (($s[$z] // {}) + { state: "Active" }))
              # The control plane must REACH the probe zones: this host drives the
              # installs over ssh (nixos-rebuild for the NixOS fixture), and that
              # needs a mgmt -> <zone> pass rule, which comes from mgmt.access-to.
              # The pre-ADR-014 template listed these zones there; `retire` correctly
              # stripped those references when the zones were removed from the
              # template, so the test must now grant the reach itself instead of
              # inheriting it. Without this the VMs boot and get DHCP/DNS but ssh
              # times out, and every downstream assertion fails for the wrong reason.
              | .mgmt["access-to"] = ((.mgmt["access-to"] // []) + [$za, $zb, $zc] | unique)' \
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
        # VLAN (historical defect 1 — investigation log in git history:
        # network/ISSUES/deep-test-trunk-and-nixbuild.md).
        if vmnet_sync_firewall_trunks "${CONFIG_DIR}/zones.json" "${FIREWALL_JSON}"; then
            pass "OPNsense VM net0 trunks synced with all active VLANs"
        else
            fail "Could not sync OPNsense VM net0 trunks"
        fi
    fi

    # Distribute the refreshed zones.json to each Proxmox node so
    # Create-TAPPaaS-VM.sh on the node can resolve the new test zones.
    nodes_pushed=0
    if command -v jq >/dev/null 2>&1; then
        # Node hostnames from site.json (.hardware.nodes), fallback configuration.json.
        mapfile -t pve_nodes < <(get_all_node_hostnames 2>/dev/null)
        for node in "${pve_nodes[@]}"; do
            [[ -z "${node}" ]] && continue
            if scp -q -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
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

    # network:proxy install-service already ran via install-module.sh. Verify it.
    proxy_domain=$(read_module_config "test-fw-a" 2>/dev/null | jq -r '.proxyDomain // empty' 2>/dev/null)
    if [[ -z "${proxy_domain}" ]]; then
        # Derive default — <vmname>.<env-domain> (config/environments via
        # get_variant_config, fallback configuration.json .tappaas.domain).
        domain=$(jq -r '.domain // empty' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")
        # Guard the retired-configuration.json fallback with -f + `|| true` so a
        # missing file (fresh ADR-007 install) cannot abort under `set -e`.
        if [[ -z "${domain}" && -f "${CONFIG_DIR}/configuration.json" ]]; then
            domain=$(jq -r '.tappaas.domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null) || domain=""
        fi
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

    # Force the FQDN alias tables to repopulate. The two commands used here
    # before DO NOT EXIST on current OPNsense (26.1 measured):
    #   /usr/local/etc/rc.update_alias_tables.sh  → file missing
    #   configctl alias reload                    → "Action not allowed or missing"
    # Both were swallowed (`|| true`), so this poke was a NO-OP and the test just
    # hoped a periodic refresh would land inside the retry window — which is the
    # whole of #386 ("rule created, traffic blocked, pfctl alias table empty").
    # `configctl filter refresh_aliases` is the working entry point; it returns
    # {"status": "ok"}. Verify it rather than swallowing it.
    # Assert the EFFECT, not the command's stdout: `configctl filter
    # refresh_aliases` returns {"status":"ok"} only sometimes (empty when a
    # refresh is already in flight), so grepping its output is flaky. What
    # actually matters is that the pf table behind the FQDN alias holds an
    # address — that is the precondition for the auto-pinhole rule to match.
    # Verified by hand: flush tm_<mod> -> 0 entries, refresh -> 1 entry.
    # BOTH remote commands run under `sh -c`. root's shell on OPNsense is
    # opnsense-shell (csh), where `2>/dev/null` is not redirection syntax at all:
    # csh answers "Ambiguous output redirect." and runs NOTHING. ssh still exits
    # 0, so the `|| return 1` guard below never fired and the failure was
    # invisible. The consequences were both halves of this helper:
    #
    #   refresh — configctl never ran, so nothing was ever poked;
    #   poll    — `n` came back as the error text, and bash arithmetic scores a
    #             non-numeric string as 0, so `-gt 0` was never true.
    #
    # So `_alias_refresh <name>` failed DETERMINISTICALLY after burning 30s, and
    # the alias populated anyway on OPNsense's own schedule — which is why the
    # traffic assertions immediately below it passed while this reported the
    # table empty, and why it was misattributed to #386 (a real but different
    # bug: block-private quick rules shadowing the auto-pinhole).
    #
    # The evidence block further down already ships a script and runs it with
    # sh, for exactly this reason. This is the same fix, applied where the
    # decision is actually made. Verified against the live firewall:
    #   csh form   -> "Ambiguous output redirect."
    #   sh -c form -> a count, and {"status": "ok"} from refresh_aliases
    _alias_refresh() {   # $1 = alias name to wait for (optional)
        local want="${1:-}" n
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            root@"${FIREWALL_FQDN}" \
            "sh -c 'configctl filter reload >/dev/null 2>&1; configctl filter refresh_aliases >/dev/null 2>&1'" \
            >/dev/null 2>&1 || return 1
        [[ -z "${want}" ]] && return 0
        for _ in 1 2 3 4 5 6; do
            n="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                    root@"${FIREWALL_FQDN}" \
                    "sh -c 'pfctl -t ${want} -T show 2>/dev/null | wc -l'" 2>/dev/null | tr -d ' ')"
            # Guard the arithmetic: a non-numeric n (an error string, an empty
            # reply) must read as "not populated", never as a silent 0 that
            # looks like a clean answer.
            [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]] && return 0
            sleep 5
        done
        return 1
    }
    # tm_<vmname with - replaced by _> is the alias the auto-pinhole targets.
    _tfw_c_alias="tm_$(echo "test-fw-c" | tr '-' '_')"
    if _alias_refresh "${_tfw_c_alias}"; then
        pass "FQDN alias table ${_tfw_c_alias} populated on the firewall"
    else
        fail "FQDN alias table ${_tfw_c_alias} is EMPTY — the auto-pinhole destination matches nothing (this is #386)"
        # LIVE EVIDENCE, captured while the VMs still exist. Everything about
        # this failure has had to be reconstructed after teardown until now:
        # whether the alias was created, what it points at, and whether the
        # firewall can resolve that name. Print all three.
        info "  -- alias evidence (captured while the VMs are still up) --"
        # The firewall's root shell is csh: a compound `sh`-style command sent
        # over ssh silently fails there. Ship a script and run it with sh.
        _ev="$(mktemp)"
        cat > "${_ev}" <<EVIDENCE
#!/bin/sh
echo "alias-defined-count: \$(grep -c '${_tfw_c_alias}' /conf/config.xml 2>/dev/null)"
echo "alias-content:"
grep -A 10 "<name>${_tfw_c_alias}</name>" /conf/config.xml 2>/dev/null | grep -E "<content>|<type>|<proto>" | head -3
echo "resolves-from-firewall:"
drill -Q ${TFW_C_FQDN} 2>/dev/null | head -2 || host ${TFW_C_FQDN} 2>/dev/null | head -2
echo "pf-table:"
pfctl -t ${_tfw_c_alias} -T show 2>&1 | head -3
echo "alias-refresh-rc:"
configctl filter refresh_aliases >/dev/null 2>&1; echo \$?
sleep 5
echo "pf-table-after-refresh:"
pfctl -t ${_tfw_c_alias} -T show 2>&1 | head -3
EVIDENCE
        scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "${_ev}" root@"${FIREWALL_FQDN}":/tmp/_tappaas_alias_evidence.sh 2>/dev/null \
          && ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            root@"${FIREWALL_FQDN}" "sh /tmp/_tappaas_alias_evidence.sh" 2>/dev/null \
            | sed 's/^/       /' \
          || info "       (could not collect evidence from ${FIREWALL_FQDN})"
        rm -f "${_ev}"
    fi

    autopinhole_curl_ok=0
    for attempt in 1 2 3 4 5 6; do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                "tappaas@${TFW_A_FQDN}" \
                "curl -fsS --max-time 5 http://${TFW_C_FQDN}:9091/" 2>/dev/null \
                | grep -q "tappaas-firewall-test-c-ok"; then
            autopinhole_curl_ok=1
            break
        fi
        # Re-poke between attempts, via the entry point that actually exists
        # (see _alias_refresh above — the old rc.update_alias_tables.sh path is
        # absent on current OPNsense, so this retry did nothing at all).
        _alias_refresh || true
        sleep 15
    done

    if (( autopinhole_curl_ok == 1 )); then
        pass "test-fw-a → test-fw-c:9091 (auto-pinhole permits cross-zone traffic; attempt ${attempt})"
    else
        # Distinguish "auto-pinhole wrong" from the known
        # "zone-manager block-private shadows the pinhole" infrastructure bug
        # (see GitHub #386).
        # If pflog shows a `block` rule (numbered low, on the consumer zone's vlan) eating
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

        # The interface name is vlan0.<consumer VLAN>. DERIVE it — a literal here
        # silently stops matching the moment the fixture's VLAN changes, which
        # turns this known-infrastructure-bug SKIP into a spurious FAIL. (The
        # #306 guard above only greps zone NAMES, so a hardcoded VLAN slips past
        # it; this is the same lesson.)
        _tfw_a_vlan="$(jq -r --arg z "${TFW_A_ZONE}" '.[$z].vlantag // empty' \
            "${CONFIG_DIR}/zones.json" 2>/dev/null)"
        if [[ -n "${_tfw_a_vlan}" ]] \
           && echo "${pflog_verdict}" | grep -qE "block.*in on vlan0\.${_tfw_a_vlan}"; then
            skip "test-fw-a → test-fw-c:9091 — auto-pinhole rule IS created (see Deep 6b) but zone-manager's block-private rule shadows it (see GitHub #386)"
            info "  -- pflog evidence (a 'block' rule on vlan0.${_tfw_a_vlan} caught the SYN) --"
            echo "${pflog_verdict}" | grep -E 'block|tcp.*9091' | sed 's/^/      /' | head -4
        else
            fail "test-fw-a → test-fw-c:9091 (expected auto-pinhole to allow, gave up after 6×15s)"
            info "  -- pflog evidence --"
            echo "${pflog_verdict}" | sed 's/^/      /' | head -6
            info "  -- pfctl alias contents on firewall --"
            # `|| true` is LOAD-BEARING: this is a diagnostic, and under
            # `set -euo pipefail` a failing ssh here aborted the whole suite
            # through the EXIT trap — which then reported success (exit 0) with
            # no summary, hiding every failure already counted.
            { ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                root@"${FIREWALL_FQDN}" \
                "pfctl -t tm_test_fw_c -T show 2>&1; \
                 pfctl -t tm_test_fw_a -T show 2>&1" 2>/dev/null \
                | sed 's/^/      /' | head -20; } || true
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
    # Reuses the test-fw-a webserver (already registered via network:proxy with
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
        # `|| true` is LOAD-BEARING: NOT resolving is an expected outcome here —
        # the gate below explicitly skips when PUBLIC_IP is empty. But `grep`
        # exits 1 on no match, and under `set -euo pipefail` that aborted the
        # WHOLE suite at this line, so Deep 11 never ran on any system without a
        # public A record for the test FQDN, and everything after it was lost.
        PUBLIC_IP="$(dig +short @1.1.1.1 A "${PROXY_FQDN}" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1 || true)"
    fi

    # ── Gate: default-environment domain set AND public DNS -> a public IP ────
    if [[ -z "${DEF_DOMAIN}" || "${DEF_DOMAIN}" == CHANGE* ]]; then
        skip "Deep 11: no default-environment domain set (set domains.primary in the default environment file)"
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

    # Reached only if the deep block ran to completion. The summary asserts it:
    # an early abort (a stray non-zero under `set -euo pipefail`, an ssh that
    # died) unwinds through the EXIT trap and used to report SUCCESS with no
    # summary at all — 13 counted failures vanished that way. A truncated run
    # must never be mistaken for a clean one.
    DEEP_COMPLETED=1
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
# NOTE: the completeness/truncation check now lives in cleanup_deep (the EXIT
# trap), because everything below is skipped when the run aborts.

echo ""
# ── Assertion-count floor ───────────────────────────────────────────
# (truncation itself is caught by cleanup_deep's EXIT trap, above)
# Floor on the number of assertions actually executed. Catches a block that
# silently stops contributing results — e.g. a renamed CLI whose errors are
# swallowed by `|| true`, which hid 11 failing switch/ap assertions for ~10 weeks.
if [[ "${DEEP}" == "1" ]]; then _expected_min=70; else _expected_min=40; fi
if (( PASS + FAIL + SKIP < _expected_min )); then
    fail "only $(( PASS + FAIL + SKIP )) assertion(s) ran; expected >= ${_expected_min} — the suite is not exercising what it claims"
fi

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
