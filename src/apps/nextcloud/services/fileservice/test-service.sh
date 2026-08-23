#!/usr/bin/env bash
#
# TAPPaaS Nextcloud Service - Test
#
# Verifies Nextcloud is installed and reachable for a consuming module.
# Called by test-module.sh for any module that depends on nextcloud:fileservice.
#
# Tests:
#   1. Nextcloud HTTP endpoint responds
#   2. OnlyOffice connector configured with a DocumentServerUrl
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

readonly CONFIG_DIR="/home/tappaas/config"

# Resolve Nextcloud config for THIS consumer, environment-aware — the same
# resolution install-service.sh/update-service.sh do (#438).
#
# The previous version scanned nextcloud.json then nextcloud-*.json and took the
# first that provides "nextcloud", ignoring the consuming module entirely. With a
# default nextcloud deployed that always won, so testing a consumer in another
# environment (euro-office-test) checked the DEFAULT Nextcloud — the wrong VM,
# and with it the wrong connector state. It only looked correct while exactly one
# Nextcloud existed.
CONSUMER_ENV=""
[[ -f "${CONFIG_DIR}/${MODULE}.json" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONFIG_DIR}/${MODULE}.json" 2>/dev/null || true)
NEXTCLOUD_MODULE="$(resolve_provider_module nextcloud "${CONSUMER_ENV}")"
readonly NEXTCLOUD_JSON="${CONFIG_DIR}/${NEXTCLOUD_MODULE}.json"

if [[ ! -f "${NEXTCLOUD_JSON}" ]]; then
    error "Nextcloud config not found: ${NEXTCLOUD_JSON}"
    exit 2
fi

VMNAME=$(jq -r '.vmname' "${NEXTCLOUD_JSON}")
ZONE=$(jq -r '.zone0' "${NEXTCLOUD_JSON}")
INTERNAL_URL="http://${VMNAME}.${ZONE}.internal"

PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}nextcloud:fileservice tests for ${BL}${MODULE}${CL}"

# ── Test 1: Nextcloud HTTP endpoint ──────────────────────────────────

info "  Check 1: Nextcloud reachable at ${INTERNAL_URL}"
http_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${INTERNAL_URL}/" 2>/dev/null) || http_code="000"
if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
    pass "Nextcloud responding (HTTP ${http_code})"
else
    fail "Nextcloud not responding at ${INTERNAL_URL} (HTTP ${http_code})"
fi

# ── Test 2: OnlyOffice connector (conditional — only if euro-office is installed) ──

info "  Check 2: OnlyOffice connector (if euro-office installed)"
EURO_INSTALLED=false
for _eo in "${CONFIG_DIR}/euro-office.json" "${CONFIG_DIR}"/euro-office-*.json; do
    [[ -f "${_eo}" ]] && EURO_INSTALLED=true && break
done

if [[ "${EURO_INSTALLED}" == "true" ]]; then
    DOC_URL=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "tappaas@${VMNAME}.${ZONE}.internal" \
        "sudo -u postgres psql -d nextcloud -tAc \
        \"SELECT configvalue FROM oc_appconfig WHERE appid='onlyoffice' AND configkey='DocumentServerUrl'\" \
        2>/dev/null" 2>/dev/null || echo "")
    DOC_URL="${DOC_URL// /}"
    if [[ -n "${DOC_URL}" ]]; then
        pass "OnlyOffice DocumentServerUrl is set (${DOC_URL})"
    else
        fail "OnlyOffice DocumentServerUrl not configured — euro-office installed but connector not set up"
    fi

    # A set DocumentServerUrl proves the wiring ran, NOT that it works. When the
    # document server cannot fetch a document back out of Nextcloud, the
    # connector stores `settings_error` and hides the editor completely — the
    # user sees no "open in Euro-Office" action at all, while this test used to
    # report a clean pass on the URL alone. Read the error rather than re-running
    # the check: test-service.sh is the READ-ONLY verifier the drift report and
    # `module test` call, and `onlyoffice:documentserver --check` would mutate
    # state. The converge (update-service.sh) is what re-runs and clears it.
    OO_ERR=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "tappaas@${VMNAME}.${ZONE}.internal" \
        "sudo -u postgres psql -d nextcloud -tAc \
        \"SELECT configvalue FROM oc_appconfig WHERE appid='onlyoffice' AND configkey='settings_error'\" \
        2>/dev/null" 2>/dev/null | tr -d '[:space:]') || OO_ERR=""
    if [[ -z "${OO_ERR}" ]]; then
        pass "OnlyOffice connector reports no settings_error (editor available)"
    else
        fail "OnlyOffice connector is wired but NOT working: ${OO_ERR} — Nextcloud hides the editor while this is set"
    fi
else
    pass "OnlyOffice check skipped — euro-office not installed"
fi

# ── Summary ──────────────────────────────────────────────────────────

info "  Results: ${PASS} passed, ${FAIL} failed"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
