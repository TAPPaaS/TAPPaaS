#!/usr/bin/env bash
#
# TAPPaaS logging Health & Regression Test
#
# Validates that the logging stack is running: SSH, Loki ready, Grafana
# responding, Alloy metrics endpoint, and the syslog ingest port open.
#
# Usage: ./test.sh <vmname>
# Example: ./test.sh logging
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

# get_config_value reads the module config out of the global $JSON, which
# install-module.sh sets before sourcing install/update.sh. A STANDALONE test.sh
# has no such caller, so it must load the config itself — without this, $JSON is
# unbound and every lookup falls through to its default. That is silent for the
# keys that have one, but `vmid` has none, so the suite aborted on line 1 with
# "Missing required key 'vmid'" and never ran a single assertion.
MODULE_NAME="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
# A positional module name is optional — this IS the ${MODULE_NAME} module's test,
# so it defaults to itself. A leading FLAG (e.g. --deep, which the sweep passes)
# is never a module name.
ARG_MODULE=""
[[ -n "${1:-}" && "${1:-}" != -* ]] && ARG_MODULE="$1"
JSON="$(read_module_config "${ARG_MODULE:-${MODULE_NAME}}" 2>/dev/null || echo '{}')"
export JSON

VMNAME="$(get_config_value 'vmname' "${ARG_MODULE:-${MODULE_NAME}}")"
# vmid/zone0 may be overridden to test a non-default instance (issue #196).
VMID="${TAPPAAS_VMID_OVERRIDE:-$(get_config_value 'vmid')}"
ZONE0NAME="${TAPPAAS_ZONE0_OVERRIDE:-$(get_config_value 'zone0' 'mgmt')}"
readonly VMNAME VMID ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

# SSH options: accept changed host keys after reboot, hard timeout, no interactive prompts
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS_COUNT=0
FAIL_COUNT=0

# ── Helpers ───────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Run health and regression checks for the logging module.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} logging
EOF
}

check_pass() {
    info "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    error "  ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ── Test functions ────────────────────────────────────────────────────

check_ssh() {
    info "Check 1: SSH connectivity to ${VM_HOST}"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; then
        check_pass "SSH connection successful"
    else
        check_fail "SSH connection failed to tappaas@${VM_HOST}"
    fi
}

check_loki_ready() {
    info "Check 2: Loki /ready endpoint"
    local body
    # shellcheck disable=SC2086
    body=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s --max-time 10 http://127.0.0.1:3102/ready" 2>/dev/null) || true
    if [[ "${body}" == *"ready"* ]]; then
        check_pass "Loki reports ready"
    else
        check_fail "Loki /ready did not return 'ready' (got: ${body:-no response})"
    fi
}

check_loki_metrics() {
    info "Check 3: Loki /metrics endpoint"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3102/metrics" 2>/dev/null) || true
    if [[ "${http_code}" == "200" ]]; then
        check_pass "Loki metrics responding"
    else
        check_fail "Loki metrics not responding (status: ${http_code:-timeout})"
    fi
}

check_grafana_http() {
    info "Check 4: Grafana login page"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3000/login" 2>/dev/null) || true
    # With SSO, Grafana's auto-login answers /login with a 307 to its OIDC login.
    if [[ "${http_code}" =~ ^(200|302|307)$ ]]; then
        check_pass "Grafana login responding (status ${http_code})"
    else
        check_fail "Grafana login not responding (status: ${http_code:-timeout})"
    fi
}

check_grafana_health() {
    info "Check 5: Grafana /api/health"
    local body
    # shellcheck disable=SC2086
    body=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s --max-time 10 http://127.0.0.1:3000/api/health" 2>/dev/null) || true
    if [[ "${body}" == *"\"database\":"*"\"ok\""* ]]; then
        check_pass "Grafana health: database ok"
    else
        check_fail "Grafana health unexpected (got: ${body:-no response})"
    fi
}

check_alloy_metrics() {
    info "Check 6: Alloy metrics endpoint"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9080/metrics" 2>/dev/null) || true
    if [[ "${http_code}" == "200" ]]; then
        check_pass "Alloy metrics responding"
    else
        check_fail "Alloy metrics not responding (status: ${http_code:-timeout})"
    fi
}

check_syslog_port() {
    info "Check 7: Syslog receiver listening on tcp/1514"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "ss -lnt 'sport = :1514' | grep -c LISTEN >/dev/null" &>/dev/null; then
        check_pass "Syslog ingest port 1514/tcp is listening"
    else
        check_fail "Syslog ingest port 1514/tcp is NOT listening"
    fi
}

check_push_receiver() {
    info "Check 7b: Push and query need a credential; a VM writes only as itself (#770, #165)"
    # From here (mgmt), with the mothership's own push credential — the path
    # every VM's journal client takes. Lines carry job="tappaas-test".
    # shellcheck source=../tappaas-cicd/lib/log-shipping.sh
    . "${LOG_SHIPPING_LIB:-/home/tappaas/bin/log-shipping.sh}"
    local now mark pw code body n
    now="$(date +%s%N)"; mark="push-check-${now}"
    pw="$(cat "${LOG_SHIPPING_CRED_DIR}/tappaas-cicd" 2>/dev/null)"
    # The line claims to be another host; Loki must store it as tappaas-cicd.
    body="{\"streams\":[{\"stream\":{\"job\":\"tappaas-test\",\"host\":\"spoofed\"},\"values\":[[\"${now}\",\"${mark}\"]]}]}"
    push() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' \
                -X POST "http://${VM_HOST}:3101/loki/api/v1/push" --data "${body}" "$@" 2>/dev/null || true; }

    code="$(push)"
    if [[ "${code}" == "401" ]]; then check_pass "Push without a credential refused (401)"
    else check_fail "Push without a credential got ${code:-no answer}, not 401"; fi

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${VM_HOST}:3100/loki/api/v1/labels" 2>/dev/null || true)"
    if [[ "${code}" == "401" ]]; then check_pass "Query without a credential refused (401)"
    else check_fail "Query without a credential got ${code:-no answer}, not 401"; fi

    if [[ -z "${pw}" ]]; then
        check_fail "No push credential for tappaas-cicd in ${LOG_SHIPPING_CRED_DIR} — re-run update-module.sh logging"
        return
    fi
    code="$(push -u "tappaas-cicd:${pw}")"
    if [[ "${code}" == "204" || "${code}" == "200" ]]; then check_pass "Authenticated push accepted (HTTP ${code})"
    else check_fail "Authenticated push got ${code:-no answer}"; return; fi

    sleep 2
    n="$(log_shipping_curl_admin -s --max-time 10 -G "http://${VM_HOST}:3100/loki/api/v1/query_range" \
            --data-urlencode "query={job=\"tappaas-test\",host=\"tappaas-cicd\"} |= \"${mark}\"" \
            --data-urlencode "start=$(( now - 60000000000 ))" 2>/dev/null \
         | jq -r '[.data.result[].values[]] | length' 2>/dev/null || echo "")"
    if [[ "${n}" == "1" ]]; then check_pass "The line is stored as host=tappaas-cicd, not the host it claimed"
    else check_fail "The test line was not found as host=tappaas-cicd (found: ${n:-query failed})"; fi
}

check_loki_query() {
    info "Check 8: Loki has received at least one log line from the local journal"
    local count
    # The Alloy journal scrape ships local journal entries. After a fresh boot
    # there should be at least one stream with job="systemd-journal".
    # shellcheck disable=SC2086
    count=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s --max-time 10 --get 'http://127.0.0.1:3102/loki/api/v1/label/job/values' | jq -r '.data | length'" 2>/dev/null) || true
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= 1 )); then
        check_pass "Loki has ${count} job label value(s)"
    else
        check_fail "Loki has no log streams yet (got: ${count:-no response})"
    fi
}

# Check 0 (offline): the DiskErrors line filter against real lines — the ones it
# must catch, and the ones it must not. A smartd attribute moving at boot
# ("SMART Prefailure Attribute: … changed from 100 to 64") once fired it.
check_disk_filter() {
    info "Check 0: the DiskErrors filter matches disk errors, not smartd's routine lines"
    local f re line bad=""
    f="$(dirname "${BASH_SOURCE[0]}")/logging.nix"
    re="$(sed -n 's/^  diskErrorFilter = "\(.*\)";$/\1/p' "${f}")"
    [[ -n "${re}" ]] || { check_fail "no diskErrorFilter in ${f}"; return; }
    while IFS= read -r line; do
        grep -qP -- "${re}" <<<"${line}" || bad+=" [missed: ${line}]"
    done <<'EOF'
eid=412 class=checksum pool='tankc1' vdev=wwn-0x5000c500a1b2c3d4-part1
eid=413 class=statechange pool='tankc1' vdev_state=FAULTED
Device: /dev/sdb [SAT], 8 Currently unreadable (pending) sectors
Device: /dev/sdb [SAT], 8 Offline uncorrectable sectors
Device: /dev/sdb [SAT], FAILED SMART self-check. BACK UP DATA NOW!
Device: /dev/sdb [SAT], Failed SMART usage Attribute: 5 Reallocated_Sector_Ct.
Device: /dev/sdb [SAT], SMART Failure: DATA CHANNEL IMPENDING FAILURE
blk_update_request: I/O error, dev sdb, sector 123456 op 0x0:(READ)
EOF
    while IFS= read -r line; do
        grep -qP -- "${re}" <<<"${line}" && bad+=" [false alarm: ${line}]"
    done <<'EOF'
Device: /dev/sda [SAT], SMART Prefailure Attribute: 1 Raw_Read_Error_Rate changed from 100 to 64
Device: /dev/sda [SAT], SMART Usage Attribute: 194 Temperature_Celsius changed from 64 to 62
eid=7 class=config_sync pool='tanka1'
eid=8 class=pool_import pool='tankb1'
Device: /dev/sda [SAT], opened
EOF
    if [[ -z "${bad}" ]]; then
        check_pass "DiskErrors filter: 8 error lines caught, 5 routine lines ignored"
    else
        check_fail "DiskErrors filter:${bad}"
    fi
}

check_alert_rules() {
    info "Check 9: Grafana has the TAPPaaS alert rules and the webhook contact point (#126)"
    local out want
    # As many as logging.nix defines (each one is an `alertRule {` call), so a
    # new rule does not fail this check until the count here is edited too.
    want="$(grep -c 'alertRule {' "$(dirname "${BASH_SOURCE[0]}")/logging.nix") 1"
    # Asked on the VM itself, with the admin password read there: it never
    # crosses the wire or lands in a log.
    # shellcheck disable=SC2086,SC2016
    out=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" '
        pw=$(sudo cat /etc/secrets/grafana-admin-password 2>/dev/null)
        r=$(curl -s --max-time 10 -u "admin:${pw}" http://127.0.0.1:3000/api/v1/provisioning/alert-rules \
            | jq -r "[.[] | select(.uid | startswith(\"tappaas-\"))] | length")
        c=$(curl -s --max-time 10 -u "admin:${pw}" http://127.0.0.1:3000/api/v1/provisioning/contact-points \
            | jq -r "[.[] | select(.uid == \"tappaas-site-notify\" and .type == \"webhook\")] | length")
        echo "${r:-?} ${c:-?}"' 2>/dev/null) || true
    if [[ "${out}" == "${want}" ]]; then
        check_pass "${want% *} alert rules (heartbeat included) and the tappaas-site-notify webhook are provisioned"
    else
        check_fail "alert provisioning incomplete (rules, contact points: ${out:-no answer}; want ${want})"
    fi
}

check_alert_delivery() {
    info "Check 10: Grafana's token opens the mothership's alert receiver (#126)"
    local code
    # An empty alert list with Grafana's own token: 200 proves the path, the
    # receiver and the token at once, and sends no mail ("nothing to send").
    # shellcheck disable=SC2086,SC2016
    code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" '
        tok=$(sudo cat /etc/secrets/grafana-alert-webhook-token 2>/dev/null)
        curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
            -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" \
            --data "{\"status\":\"firing\",\"alerts\":[]}" \
            http://tappaas-cicd.mgmt.internal:9095/alert' 2>/dev/null) || true
    case "${code}" in
        200) check_pass "the receiver accepts Grafana's token" ;;
        401) check_fail "the receiver refuses Grafana's token — re-run this module's update to deliver it" ;;
        *)   check_fail "the alert receiver is not reachable from ${VMNAME} (HTTP ${code:-none})" ;;
    esac
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # No positional module name needed: it defaults to this module (see above).
    # Only a name that was GIVEN but has no config on disk is an error.
    if [[ -n "${ARG_MODULE}" && ! -f "${CONFIG_DIR}/${ARG_MODULE}.json" ]]; then
        error "Module '${ARG_MODULE}' has no config at ${CONFIG_DIR}/${ARG_MODULE}.json"
        usage
        exit 1
    fi

    info "=== logging Health Check ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    check_disk_filter
    check_ssh
    check_loki_ready
    check_loki_metrics
    check_grafana_http
    check_grafana_health
    check_alloy_metrics
    check_syslog_port
    check_push_receiver
    check_loki_query
    check_alert_rules
    check_alert_delivery

    echo ""
    info "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        error "Health check FAILED — ${FAIL_COUNT} check(s) did not pass"
        exit 1
    fi

    info "${GN}All health checks passed${CL}"
    exit 0
}

main "$@"
