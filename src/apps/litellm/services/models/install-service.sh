#!/usr/bin/env bash
#
# TAPPaaS LiteLLM Models Service — Install (BL-3)
#
# Provisions a permanent virtual key (VK) in LiteLLM for a consuming module and
# writes the key + base URL to /etc/secrets/litellm-svckey.env on the consumer VM.
# Idempotent: an existing VK for this consumer (by alias) is reused; the generated
# key is persisted on the litellm VM at /etc/secrets/litellm-svc-<consumer>.key so
# it can be recovered on re-runs without regeneration (LiteLLM only returns the
# plaintext key at creation time; subsequent /key/list returns only the token hash).
#
# Called by install-module.sh when a module declares dependsOn: ["litellm:models"].
# Variant-aware: resolves litellm vs litellm-<variant> from the consuming module's
# variant field, mirroring the resolve_provider_module logic in install-module.sh.
#
# Usage: install-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

DRY_RUN=0
CONSUMING_MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        # ADR-020 D8: accepted and ignored. Registering a model with LiteLLM
        # needs no downtime, so there is nothing to authorize — but
        # `module-manager reconcile --force` forwards --force to EVERY provider,
        # so rejecting it failed every module that dependsOn litellm:models
        # under `site-manager update --force`.
        --force) shift ;;
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
CONSUMING_ENV="$(jq -r '.environment // ""' "${CONSUMING_JSON}")"
CONSUMING_HOST="${CONSUMING_VMNAME}.${CONSUMING_ZONE}.internal"

# Resolve the correct litellm provider for this variant (e.g. litellm-a3k).
PROVIDER_MODULE="$(resolve_provider_module "litellm" "${CONSUMING_ENV}")"
PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
[[ -f "${PROVIDER_JSON}" ]] || die "litellm provider config not found: ${PROVIDER_JSON} (is ${PROVIDER_MODULE} installed?)"

LITELLM_VMNAME="$(jq -r '.vmname' "${PROVIDER_JSON}")"
LITELLM_ZONE="$(jq  -r '.zone0'  "${PROVIDER_JSON}")"
LITELLM_HOST="${LITELLM_VMNAME}.${LITELLM_ZONE}.internal"

VK_ALIAS="litellm-svc-${CONSUMING_VMNAME}"
# Key stored on litellm VM — survives re-runs (LiteLLM returns plaintext only at creation)
LITELLM_KEYSTORE="/etc/secrets/litellm-svc-${CONSUMING_VMNAME}.key"
CONSUMER_SECRETS="/etc/secrets/litellm-svckey.env"

info "${BOLD}litellm:models install-service${CL}: wiring ${BL}${CONSUMING_MODULE}${CL}"
info "  provider: ${LITELLM_HOST}  consumer: ${CONSUMING_HOST}"
info "  VK alias: ${VK_ALIAS}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would provision VK '${VK_ALIAS}' on ${LITELLM_HOST}"
    info "  ${YW}[dry-run]${CL} would write ${CONSUMER_SECRETS} on ${CONSUMING_HOST}"
    exit 0
fi

# ── SSH helpers (all remote ops via heredoc to avoid quoting issues) ──────────
ssh-keygen -R "${LITELLM_HOST}" >/dev/null 2>&1 || true
ssh-keygen -R "${CONSUMING_HOST}" >/dev/null 2>&1 || true
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10)

litellm_run() {
    ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" 'bash -s' "$@"
}
consumer_run() {
    ssh "${SSH_OPTS[@]}" "tappaas@${CONSUMING_HOST}" 'bash -s' "$@"
}

# ── Wait for the provider to be able to answer ───────────────────────────────
# A VM restored from a snapshot reports running, and its guest agent answers,
# well before LiteLLM serves its admin API (#690). Every call below then fails
# for a provider that is merely still starting — which is the NORMAL state
# during a sweep, not an exception. ready.sh gates on /health/readiness, so this
# returns as soon as the database behind /key/generate is actually connected.
wait_for_module_ready "${PROVIDER_MODULE}" "${LITELLM_HOST}" 180 hook-only \
    || die "${PROVIDER_MODULE} on ${LITELLM_HOST} was not ready within 180s — not provisioning against a starting provider"

# ── Read master key ───────────────────────────────────────────────────────────
MASTER=$(litellm_run <<'EOSH'
sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-
EOSH
) || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"
[[ -n "${MASTER}" ]] || die "LITELLM_MASTER_KEY is empty on ${LITELLM_HOST}"

# ── Check if VK alias already exists and key is persisted ────────────────────
NEW_KEY=""
FOUND=$(litellm_run <<EOSH
MASTER="${MASTER}"
ALIAS="${VK_ALIAS}"
KEYSTORE="${LITELLM_KEYSTORE}"
# /key/list requires return_full_object=true to get key_alias in the response.
# The status is kept rather than dropped: falling back to an empty JSON object
# made an unreachable provider indistinguishable from one holding no keys (#690).
BODY=\$(mktemp)
CODE=\$(curl -s -o "\${BODY}" -w '%{http_code}' --max-time 15 \
    "http://localhost:4000/key/list?return_full_object=true" \
    -H "Authorization: Bearer \${MASTER}")
if [[ "\${CODE}" != 2* ]]; then
    rm -f "\${BODY}"; echo "UNAVAILABLE:\${CODE}"; exit 0
fi
EXISTING=\$(jq -r --arg a "\${ALIAS}" \
    '.keys[]? | select(.key_alias == \$a) | .token' "\${BODY}" 2>/dev/null | head -1)
rm -f "\${BODY}"
if [[ -n "\${EXISTING}" ]] && sudo test -f "\${KEYSTORE}"; then
    STORED_KEY=\$(sudo cat "\${KEYSTORE}")
    echo "EXISTING:\${STORED_KEY}"
elif [[ -n "\${EXISTING}" ]]; then
    echo "ALIAS_ONLY:\${EXISTING}"
else
    echo "NONE"
fi
EOSH
) || die "failed to query VK list on ${LITELLM_HOST}"

if [[ "${FOUND}" == UNAVAILABLE:* ]]; then
    # Readiness passed and the API still will not answer: that is a fault, and
    # minting a second key for a consumer that may already hold a working one
    # would overwrite the keystore and break it (#690).
    die "litellm did not answer /key/list on ${LITELLM_HOST} (HTTP ${FOUND#UNAVAILABLE:}) — refusing to provision over an unknown key state"
elif [[ "${FOUND}" == EXISTING:* ]]; then
    NEW_KEY="${FOUND#EXISTING:}"
    info "  ${GN}✓${CL} VK '${VK_ALIAS}' exists and key file found — reusing"
elif [[ "${FOUND}" == ALIAS_ONLY:* ]]; then
    # VK alias exists but key file missing — delete and regenerate. The token
    # comes from the listing just made; re-listing to find it again was a second
    # round-trip that could disagree with the first.
    warn "  VK '${VK_ALIAS}' alias found but key file missing — regenerating"
    litellm_run <<EOSH || true
MASTER="${MASTER}"
TOKEN="${FOUND#ALIAS_ONLY:}"
[[ -n "\${TOKEN}" ]] && curl -s -o /dev/null --max-time 15 -X POST http://localhost:4000/key/delete \
    -H "Authorization: Bearer \${MASTER}" \
    -H "Content-Type: application/json" \
    --data-raw "{\"keys\": [\"\${TOKEN}\"]}" || true
EOSH
fi

# ── Provision new VK if needed ────────────────────────────────────────────────
if [[ -z "${NEW_KEY}" ]]; then
    info "  Provisioning new VK '${VK_ALIAS}' on ${LITELLM_HOST} (no expiry)"
    NEW_KEY=$(litellm_run <<EOSH
MASTER="${MASTER}"
ALIAS="${VK_ALIAS}"
KEYSTORE="${LITELLM_KEYSTORE}"
# Retry a refusal that a moment more would fix. -f is NOT used: it discards the
# body, which is the one thing worth keeping when the last attempt fails (#690).
BODY=\$(mktemp)
KEY=""
for ATTEMPT in 1 2 3 4 5; do
    CODE=\$(curl -s -o "\${BODY}" -w '%{http_code}' --max-time 30 \
        -X POST http://localhost:4000/key/generate \
        -H "Authorization: Bearer \${MASTER}" \
        -H "Content-Type: application/json" \
        --data-raw "{\"key_alias\": \"\${ALIAS}\", \"duration\": null}")
    KEY=\$(jq -r '.key // empty' "\${BODY}" 2>/dev/null)
    [[ -n "\${KEY}" ]] && break
    # 000 = nothing answered, 429/5xx = busy or still settling. A 4xx is a
    # refusal that will read the same in ten seconds, so it is not retried.
    if [[ \${ATTEMPT} -lt 5 && ( "\${CODE}" == 000 || "\${CODE}" == 429 || "\${CODE}" == 5* ) ]]; then
        sleep \$(( ATTEMPT * 3 ))
        continue
    fi
    echo "ERROR: /key/generate failed after \${ATTEMPT} attempt(s) — HTTP \${CODE}: \$(cat "\${BODY}")" >&2
    rm -f "\${BODY}"; exit 1
done
rm -f "\${BODY}"
# Persist key on litellm VM for future idempotency checks
sudo install -d -m 700 /etc/secrets
printf '%s' "\${KEY}" | sudo tee "\${KEYSTORE}" > /dev/null
sudo chmod 600 "\${KEYSTORE}"
echo "\${KEY}"
EOSH
    ) || die "VK provisioning failed on ${LITELLM_HOST}"
    [[ -n "${NEW_KEY}" ]] || die "VK generation returned empty key"
    info "  ${GN}✓${CL} VK '${VK_ALIAS}' provisioned and key persisted at ${LITELLM_KEYSTORE}"
fi

# ── Write svckey env file to consuming VM ────────────────────────────────────
info "  Writing ${CONSUMER_SECRETS} on ${CONSUMING_HOST}"
consumer_run <<EOSH || die "failed to write ${CONSUMER_SECRETS} on ${CONSUMING_HOST}"
NEW_KEY="${NEW_KEY}"
LITELLM_HOST="${LITELLM_HOST}"
SECRETS_FILE="${CONSUMER_SECRETS}"
sudo install -d -m 700 /etc/secrets
CONTENT=\$(printf 'LITELLM_API_KEY=%s\nLITELLM_BASE_URL=http://%s:4000/v1\n' "\${NEW_KEY}" "\${LITELLM_HOST}")
T=\$(sudo mktemp /etc/secrets/.litellm-svckey.XXXXXX)
printf '%s' "\${CONTENT}" | sudo tee "\${T}" > /dev/null
sudo chmod 600 "\${T}"
sudo mv -f "\${T}" "\${SECRETS_FILE}"
echo "written"
EOSH
info "  ${GN}✓${CL} wrote ${CONSUMER_SECRETS} on ${CONSUMING_HOST}"

info ""
info "  ${GN}${BOLD}✓ litellm:models wired for ${CONSUMING_MODULE}${CL}"
info "    VK alias  : ${VK_ALIAS}"
info "    Key store : ${LITELLM_KEYSTORE} on ${LITELLM_HOST}"
info "    Key file  : ${CONSUMER_SECRETS} on ${CONSUMING_HOST}"
info "    LiteLLM   : http://${LITELLM_HOST}:4000/v1"
info "    Note      : configure OpenWebUI admin → Settings → Connections with"
info "                Base URL and the key from ${CONSUMER_SECRETS}"
