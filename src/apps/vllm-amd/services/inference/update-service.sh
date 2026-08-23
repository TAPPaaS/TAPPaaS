#!/usr/bin/env bash
#
# TAPPaaS vLLM-AMD Inference Service - Update (the converge)
#
# Hands a consuming module everything it needs to reach this vLLM instance, and
# is the same entry point install-service.sh execs (#495).
#
# Before #503 this was a no-op placeholder: the cross-zone pinhole was
# synthesised by rules-manager, but nothing ever told the consumer WHERE vLLM is
# or WHICH model it serves. For LiteLLM that meant an empty model list — the
# dependency was declared, the firewall was open, and the wiring was still a
# manual step through the LiteLLM UI.
#
# Writes /etc/secrets/vllm-inference.env on the consumer:
#   VLLM_BASE_URL   OpenAI-compatible endpoint
#   VLLM_MODEL_ID   the model id vLLM actually serves (read live, not guessed)
#   VLLM_API_KEY    bearer token, or the literal "none" — see below
#
# AUTH: this vLLM is served WITHOUT an API key; it is protected by zone policy
# plus the services/inference/pinhole.json ingress rule, not by a bearer token.
# VLLM_API_KEY is therefore "none" unless vllm.apiKey is set in the module JSON.
# Consumers must still send SOME key (OpenAI clients require one) — LiteLLM is
# configured with this literal value. If you later start vLLM with --api-key,
# set vllm.apiKey and re-converge; nothing else changes.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: $0 <module-name>"

readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${CONSUMER_JSON}" ]] || die "Consumer config not found: ${CONSUMER_JSON}"

# Resolve the vllm-amd provider for THIS consumer's environment (#438).
CONSUMER_ENV="$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)"
PROVIDER_MODULE="$(resolve_provider_module vllm-amd "${CONSUMER_ENV}")"
readonly PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
[[ -f "${PROVIDER_JSON}" ]] || die "vllm-amd config not found: ${PROVIDER_JSON}"

VLLM_VMNAME="$(jq -r '.vmname' "${PROVIDER_JSON}")"
VLLM_ZONE="$(jq -r '.zone0' "${PROVIDER_JSON}")"
VLLM_PORT="$(jq -r '.vllm.port // 8000' "${PROVIDER_JSON}")"
VLLM_KEY="$(jq -r '.vllm.apiKey // "none"' "${PROVIDER_JSON}")"
VLLM_HOST="${VLLM_VMNAME}.${VLLM_ZONE}.internal"
VLLM_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}/v1"

CONSUMER_VMNAME="$(jq -r '.vmname' "${CONSUMER_JSON}")"
CONSUMER_ZONE="$(jq -r '.zone0' "${CONSUMER_JSON}")"
CONSUMER_HOST="${CONSUMER_VMNAME}.${CONSUMER_ZONE}.internal"

info "vllm-amd:inference update-service for ${BL}${MODULE}${CL}"
info "  provider: ${VLLM_HOST}:${VLLM_PORT}  consumer: ${CONSUMER_HOST}"

# ── Read the served model id LIVE ────────────────────────────────────────────
# vLLM serves whatever model it was started with; the id is not recorded in the
# module JSON, and guessing it produces a model entry that resolves nothing.
AUTH_HDR=()
[[ "${VLLM_KEY}" != "none" ]] && AUTH_HDR=(-H "Authorization: Bearer ${VLLM_KEY}")

MODELS_JSON="$(curl -sS --max-time 20 "${AUTH_HDR[@]}" "${VLLM_BASE_URL}/models" 2>/dev/null || true)"
MODEL_ID="$(jq -r '(.data // [])[0].id // empty' <<<"${MODELS_JSON}" 2>/dev/null || true)"

if [[ -z "${MODEL_ID}" ]]; then
    warn "  vLLM at ${VLLM_BASE_URL} served no model list — is the container up?"
    warn "  Writing endpoint anyway; re-converge once vLLM is serving to pick up the model id."
    MODEL_ID=""
else
    info "  ${GN}✓${CL} vLLM serves model ${BL}${MODEL_ID}${CL}"
fi

# ── Publish to the consumer ──────────────────────────────────────────────────
CONTENT="$(printf 'VLLM_BASE_URL=%s\nVLLM_MODEL_ID=%s\nVLLM_API_KEY=%s\n' \
    "${VLLM_BASE_URL}" "${MODEL_ID}" "${VLLM_KEY}")"

if printf '%s\n' "${CONTENT}" | ssh -o BatchMode=yes -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new "tappaas@${CONSUMER_HOST}" \
        "sudo install -d -m 700 /etc/secrets && \
         sudo install -m600 -o root -g root /dev/stdin /etc/secrets/vllm-inference.env"
then
    info "  ${GN}✓${CL} wrote /etc/secrets/vllm-inference.env on ${CONSUMER_HOST}"
else
    die "failed to write /etc/secrets/vllm-inference.env on ${CONSUMER_HOST} (is the VM up?)"
fi

# Let the consumer re-apply immediately when it ships a hook for it (LiteLLM
# registers the model from this file). Absent or failing hook is not fatal here:
# the consumer's own converge runs it too.
ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    "tappaas@${CONSUMER_HOST}" \
    "systemctl list-unit-files litellm-integrations.service >/dev/null 2>&1 && \
     sudo systemctl restart litellm-integrations.service" >/dev/null 2>&1 || true

info "  ${GN}✓${CL} vllm-amd:inference wired for ${MODULE}"
