#!/usr/bin/env bash
#
# TAPPaaS LiteLLM Models Service — Update
#
# Verifies the consuming module's VK is still valid and re-provisions if not.
# Also runs DB-model api_key verification (Pattern 5 from retro-2026-06-23-s6):
# any DB-stored model without an explicit api_key in litellm_params is flagged.
#
# Usage: update-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
CONSUMING_MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -*) die "unknown option: $1" ;;
        *) if [[ -z "${CONSUMING_MODULE}" ]]; then CONSUMING_MODULE="$1"; shift
           else die "unexpected argument: $1"; fi ;;
    esac
done
[[ -n "${CONSUMING_MODULE}" ]] || die "Usage: $0 <consuming-module-name> [--dry-run]"

CONSUMING_JSON="${CONFIG_DIR}/${CONSUMING_MODULE}.json"
[[ -f "${CONSUMING_JSON}" ]] || die "consuming module config not found: ${CONSUMING_JSON}"

CONSUMING_VMNAME="$(jq -r '.vmname'  "${CONSUMING_JSON}")"
CONSUMING_VARIANT="$(jq -r '.variant // ""' "${CONSUMING_JSON}")"

PROVIDER_MODULE="$(resolve_provider_module "litellm" "${CONSUMING_VARIANT}")"
PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
[[ -f "${PROVIDER_JSON}" ]] || die "litellm provider config not found: ${PROVIDER_JSON}"

LITELLM_VMNAME="$(jq -r '.vmname' "${PROVIDER_JSON}")"
LITELLM_ZONE="$(jq  -r '.zone0'  "${PROVIDER_JSON}")"
LITELLM_HOST="${LITELLM_VMNAME}.${LITELLM_ZONE}.internal"

VK_ALIAS="litellm-svc-${CONSUMING_VMNAME}"

info "${BOLD}litellm:models update-service${CL}: checking ${BL}${CONSUMING_MODULE}${CL}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would verify VK '${VK_ALIAS}' on ${LITELLM_HOST}"
    info "  ${YW}[dry-run]${CL} would check DB-model api_key coverage on ${LITELLM_HOST}"
    exit 0
fi

# ── Read master key ───────────────────────────────────────────────────────────
ssh-keygen -R "${LITELLM_HOST}" >/dev/null 2>&1 || true
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

MASTER=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<'EOSH'
sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-
EOSH
) || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

# ── Verify VK alias exists and key file is present ───────────────────────────
LITELLM_KEYSTORE="/etc/secrets/litellm-svc-${CONSUMING_VMNAME}.key"
VK_OK=0
VK_STATUS=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH
MASTER="${MASTER}"
ALIAS="${VK_ALIAS}"
KEYSTORE="${LITELLM_KEYSTORE}"
LIST=\$(curl -sf "http://localhost:4000/key/list?return_full_object=true" \
    -H "Authorization: Bearer \${MASTER}" 2>/dev/null || echo '{}')
FOUND=\$(echo "\${LIST}" | jq -r --arg a "\${ALIAS}" \
    '.keys[]? | select(.key_alias == \$a) | .token' 2>/dev/null | head -1)
if [[ -n "\${FOUND}" && -f "\${KEYSTORE}" ]]; then echo "ok"
elif [[ -n "\${FOUND}" ]]; then echo "alias_no_file"
else echo "missing"; fi
EOSH
) || VK_STATUS="error"

if [[ "${VK_STATUS}" == "ok" ]]; then
    VK_OK=1
    info "  ${GN}✓${CL} VK '${VK_ALIAS}' exists with key file"
elif [[ "${VK_STATUS}" == "alias_no_file" ]]; then
    warn "  VK alias found but key file missing on ${LITELLM_HOST}"
elif [[ "${VK_STATUS}" == "missing" ]]; then
    warn "  VK '${VK_ALIAS}' not found"
else
    warn "  VK check failed (${VK_STATUS})"
fi

if [[ "${VK_OK}" -eq 0 ]]; then
    warn "VK '${VK_ALIAS}' is missing or invalid — re-provisioning"
    "${_SCRIPT_DIR}/install-service.sh" "${CONSUMING_MODULE}" \
        || die "install-service.sh re-provisioning failed"
fi

# ── DB-model api_key coverage check (Pattern 5) ──────────────────────────────
info "  Checking DB-model api_key coverage on ${LITELLM_HOST}"
MODEL_CHECK=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH
MASTER="${MASTER}"
curl -sf "http://localhost:4000/model/info" \
    -H "Authorization: Bearer \${MASTER}" 2>/dev/null \
| jq '[.data[] | {name: .model_name, id: .model_info.id, has_key: (.litellm_params.api_key != null)}]' \
2>/dev/null || echo "[]"
EOSH
) || MODEL_CHECK="[]"

NO_KEY_COUNT=$(echo "${MODEL_CHECK}" | jq '[.[] | select(.has_key == false)] | length' 2>/dev/null || echo "0")
if [[ "${NO_KEY_COUNT}" -gt 0 ]]; then
    warn "${NO_KEY_COUNT} DB model(s) have no explicit api_key — will 401 after key rotation:"
    echo "${MODEL_CHECK}" | jq -r '.[] | select(.has_key == false) | "  - \(.name) (id: \(.id))"' || true
    warn "Run scripts/rotate-provider-key.sh to fix (Step 3 of rotation SOP)"
else
    info "  ${GN}✓${CL} all DB models have explicit api_key"
fi

info "  ${GN}✓${CL} update-service complete for ${CONSUMING_MODULE}"
