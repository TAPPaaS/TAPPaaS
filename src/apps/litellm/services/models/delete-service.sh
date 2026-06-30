#!/usr/bin/env bash
#
# TAPPaaS LiteLLM Models Service — Delete
#
# Revokes the VK provisioned for a consuming module and removes the svckey env
# file from the consuming VM.
#
# Usage: delete-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

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

info "${BOLD}litellm:models delete-service${CL}: removing ${BL}${CONSUMING_MODULE}${CL}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would revoke VK '${VK_ALIAS}' on ${LITELLM_HOST}"
    info "  ${YW}[dry-run]${CL} would remove ${SECRETS_FILE} on ${CONSUMING_HOST}"
    exit 0
fi

# ── Read master key ───────────────────────────────────────────────────────────
ssh-keygen -R "${LITELLM_HOST}" >/dev/null 2>&1 || true
ssh-keygen -R "${CONSUMING_HOST}" >/dev/null 2>&1 || true
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

MASTER=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<'EOSH'
sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-
EOSH
) || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

# ── Find and revoke VK ────────────────────────────────────────────────────────
LITELLM_KEYSTORE="/etc/secrets/litellm-svc-${CONSUMING_VMNAME}.key"
REVOKE_RESULT=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' <<EOSH
MASTER="${MASTER}"
ALIAS="${VK_ALIAS}"
KEYSTORE="${LITELLM_KEYSTORE}"
LIST=\$(curl -sf "http://localhost:4000/key/list?return_full_object=true" \
    -H "Authorization: Bearer \${MASTER}" 2>/dev/null || echo '{}')
TOKEN=\$(echo "\${LIST}" | jq -r --arg a "\${ALIAS}" \
    '.keys[]? | select(.key_alias == \$a) | .token' 2>/dev/null | head -1)
if [[ -n "\${TOKEN}" ]]; then
    curl -sf -X POST http://localhost:4000/key/delete \
        -H "Authorization: Bearer \${MASTER}" \
        -H "Content-Type: application/json" \
        --data-raw "{\"keys\": [\"\${TOKEN}\"]}" >/dev/null 2>&1 || true
    sudo rm -f "\${KEYSTORE}" 2>/dev/null || true
    echo "revoked"
else
    echo "not_found"
fi
EOSH
) || REVOKE_RESULT="error"

if [[ "${REVOKE_RESULT}" == "revoked" ]]; then
    info "  ${GN}✓${CL} VK '${VK_ALIAS}' revoked and key file removed from ${LITELLM_HOST}"
elif [[ "${REVOKE_RESULT}" == "not_found" ]]; then
    info "  VK '${VK_ALIAS}' not found on ${LITELLM_HOST} — nothing to revoke"
else
    warn "  VK revocation failed (${REVOKE_RESULT}) — verify manually in LiteLLM admin UI"
fi

# ── Remove svckey env file from consuming VM ─────────────────────────────────
REMOVE_RESULT=$(ssh "${SSH_OPTS[@]}" "tappaas@${CONSUMING_HOST}" 'bash -s' <<EOSH
SECRETS_FILE="${SECRETS_FILE}"
if sudo test -f "\${SECRETS_FILE}" 2>/dev/null; then
    sudo rm -f "\${SECRETS_FILE}" && echo "removed"
else
    echo "absent"
fi
EOSH
) || REMOVE_RESULT="error"

if [[ "${REMOVE_RESULT}" == "removed" ]]; then
    info "  ${GN}✓${CL} removed ${SECRETS_FILE} from ${CONSUMING_HOST}"
elif [[ "${REMOVE_RESULT}" == "absent" ]]; then
    info "  ${SECRETS_FILE} not present on ${CONSUMING_HOST} — nothing to remove"
else
    warn "  Could not remove ${SECRETS_FILE} from ${CONSUMING_HOST}: ${REMOVE_RESULT}"
fi

info "  ${GN}✓${CL} delete-service complete for ${CONSUMING_MODULE}"
