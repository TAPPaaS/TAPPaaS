#!/usr/bin/env bash
#
# TAPPaaS LiteLLM Models Service — Test
#
# Verifies the litellm:models service wiring for a consuming module:
#   1. VK for this consumer exists and is not blocked
#   2. svckey env file is present on consuming VM
#   3. VK can reach at least one model via /model/info
#   4. No DB models are missing an explicit api_key (Pattern 5)
#
# Usage: test-service.sh <consuming-module-name>
# Exit: 0 = all checks pass; 1 = one or more checks failed

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONSUMING_MODULE="${1:-}"
[[ -n "${CONSUMING_MODULE}" ]] || die "Usage: $0 <consuming-module-name>"

CONSUMING_JSON="${CONFIG_DIR}/${CONSUMING_MODULE}.json"
[[ -f "${CONSUMING_JSON}" ]] || die "consuming module config not found: ${CONSUMING_JSON}"

CONSUMING_VMNAME="$(jq -r '.vmname'  "${CONSUMING_JSON}")"
CONSUMING_ZONE="$(jq  -r '.zone0'    "${CONSUMING_JSON}")"
CONSUMING_VARIANT="$(jq -r '.variant // ""' "${CONSUMING_JSON}")"
CONSUMING_HOST="${CONSUMING_VMNAME}.${CONSUMING_ZONE}.internal"

PROVIDER_MODULE="$(resolve_provider_module "litellm" "${CONSUMING_VARIANT}")"
PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
[[ -f "${PROVIDER_JSON}" ]] || die "litellm provider config not found: ${PROVIDER_JSON}"

LITELLM_VMNAME="$(jq -r '.vmname' "${PROVIDER_JSON}")"
LITELLM_ZONE="$(jq  -r '.zone0'  "${PROVIDER_JSON}")"
LITELLM_HOST="${LITELLM_VMNAME}.${LITELLM_ZONE}.internal"

VK_ALIAS="litellm-svc-${CONSUMING_VMNAME}"
SECRETS_FILE="/etc/secrets/litellm-svckey.env"

PASS=0; FAIL=0

_pass() { info "  ${GN}✓${CL} $*"; PASS=$((PASS + 1)); }
_fail() { error "  ✗ $*"; FAIL=$((FAIL + 1)); }

info "${BOLD}litellm:models test-service${CL}: ${BL}${CONSUMING_MODULE}${CL}"

# ── SSH setup ────────────────────────────────────────────────────────────────
ssh-keygen -R "${LITELLM_HOST}" >/dev/null 2>&1 || true
ssh-keygen -R "${CONSUMING_HOST}" >/dev/null 2>&1 || true
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# ── Read master key ───────────────────────────────────────────────────────────
MASTER=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<'EOSH' 2>/dev/null
sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-
EOSH
) || true
if [[ -z "${MASTER}" ]]; then
    _fail "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"
    exit 1
fi

LITELLM_KEYSTORE="/etc/secrets/litellm-svc-${CONSUMING_VMNAME}.key"

# ── Test 1: VK alias exists and key file is present ──────────────────────────
VK_STATUS=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH 2>/dev/null
MASTER="${MASTER}"
ALIAS="${VK_ALIAS}"
KEYSTORE="${LITELLM_KEYSTORE}"
LIST=\$(curl -sf "http://localhost:4000/key/list?return_full_object=true" \
    -H "Authorization: Bearer \${MASTER}" 2>/dev/null || echo '{}')
FOUND=\$(echo "\${LIST}" | jq -r --arg a "\${ALIAS}" \
    '.keys[]? | select(.key_alias == \$a) | .token' 2>/dev/null | head -1)
if [[ -n "\${FOUND}" && -f "\${KEYSTORE}" ]]; then echo "ok:\${FOUND}"
elif [[ -n "\${FOUND}" ]]; then echo "alias_no_file"
else echo "missing"; fi
EOSH
) || VK_STATUS="error"

EXISTING_KEY=""
if [[ "${VK_STATUS}" == ok:* ]]; then
    EXISTING_KEY="${VK_STATUS#ok:}"
    _pass "VK '${VK_ALIAS}' exists with key file on ${LITELLM_HOST}"
elif [[ "${VK_STATUS}" == "alias_no_file" ]]; then
    _fail "VK '${VK_ALIAS}' alias found but key file missing — run install-service.sh"
else
    _fail "VK '${VK_ALIAS}' not found on ${LITELLM_HOST} — run install-service.sh"
fi

# ── Test 2: svckey env file present on consuming VM ──────────────────────────
FILE_STATUS=$(ssh "${SSH_OPTS[@]}" "tappaas@${CONSUMING_HOST}" 'bash -s' <<EOSH 2>/dev/null
SECRETS_FILE="${SECRETS_FILE}"
sudo test -f "\${SECRETS_FILE}" && echo "present" || echo "missing"
EOSH
) || FILE_STATUS="error"
if [[ "${FILE_STATUS}" == "present" ]]; then
    _pass "${SECRETS_FILE} present on ${CONSUMING_HOST}"
else
    _fail "${SECRETS_FILE} missing on ${CONSUMING_HOST} — run install-service.sh"
fi

# ── Test 3: stored key can see at least one model ────────────────────────────
if [[ -n "${EXISTING_KEY}" ]]; then
    STORED_KEY=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH 2>/dev/null
KEYSTORE="${LITELLM_KEYSTORE}"
sudo cat "\${KEYSTORE}" 2>/dev/null || true
EOSH
) || STORED_KEY=""
    if [[ -n "${STORED_KEY}" ]]; then
        MODEL_COUNT=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH 2>/dev/null
KEY="${STORED_KEY}"
curl -sf "http://localhost:4000/model/info" \
    -H "Authorization: Bearer \${KEY}" 2>/dev/null | jq '.data | length' 2>/dev/null || echo 0
EOSH
) || MODEL_COUNT=0
        if [[ "${MODEL_COUNT}" -gt 0 ]]; then
            _pass "VK key resolves ${MODEL_COUNT} model(s)"
        else
            _fail "VK key resolves 0 models — check model list and VK allowed_models"
        fi
    fi
fi

# ── Test 4: DB-model api_key coverage ────────────────────────────────────────
MODEL_CHECK=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH 2>/dev/null
MASTER="${MASTER}"
curl -sf "http://localhost:4000/model/info" \
    -H "Authorization: Bearer \${MASTER}" 2>/dev/null \
| jq '[.data[] | {name: .model_name, id: .model_info.id, has_key: (.litellm_params.api_key != null)}]' \
2>/dev/null || echo "[]"
EOSH
) || MODEL_CHECK="[]"
NO_KEY_COUNT=$(echo "${MODEL_CHECK}" | jq '[.[] | select(.has_key == false)] | length' 2>/dev/null || echo "0")
if [[ "${NO_KEY_COUNT}" -gt 0 ]]; then
    _fail "${NO_KEY_COUNT} DB model(s) without explicit api_key (will 401 after rotation):"
    echo "${MODEL_CHECK}" | jq -r '.[] | select(.has_key == false) | "      - \(.name) (\(.id))"' || true
else
    _pass "all DB models have explicit api_key"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "  Tests: ${GN}${PASS} passed${CL}  ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
