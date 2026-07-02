#!/usr/bin/env bash
#
# TAPPaaS LiteLLM — Rotate Provider API Key
#
# Orchestrates the 2-step rotation SOP for the OPENROUTER_API_KEY (or any
# provider key stored in /etc/secrets/litellm.env):
#
#   Step 1: Update OPENROUTER_API_KEY in /etc/secrets/litellm.env; restart service
#   Step 2: Rotate the matching LiteLLM DB credential (delegates to
#           litellm-credentials.sh rotate) — every model referencing that
#           credential by name picks up the new value automatically, no
#           per-model action needed.
#
# Formerly had a Step 3 that deleted+recreated every DB model with the literal
# key embedded — that only existed because models didn't reference named
# credentials yet. Now that they do (litellm-credentials.sh assign-model),
# Step 3 is structurally obsolete and has been removed (2026-07-02).
#
# If --new-key is omitted, the key is read interactively (not stored in history).
# If --new-key is provided (e.g. piped from openrouter-manager), the value is used
# directly; prefer piping via a process substitution rather than passing plaintext
# on the command line when called from automation.
#
# Usage:
#   rotate-provider-key.sh --vmname <vmname> [--new-key <key>] \
#       [--credential-name <name>] [--owui-service <systemd-unit>] [--dry-run]
#
# Examples:
#   rotate-provider-key.sh --vmname litellm-a3k
#   rotate-provider-key.sh --vmname litellm --owui-service podman-openwebui.service
#   NEW_KEY=$(openrouter-manager create-key --name litellm-a3k --print-key)
#   rotate-provider-key.sh --vmname litellm-a3k --new-key "${NEW_KEY}"

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME=""
NEW_KEY=""
CREDENTIAL_NAME=""
OWUI_SERVICE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmname)          VMNAME="$2";          shift 2 ;;
        --new-key)         NEW_KEY="$2";         shift 2 ;;
        --credential-name) CREDENTIAL_NAME="$2";  shift 2 ;;
        --owui-service)    OWUI_SERVICE="$2";     shift 2 ;;
        --dry-run)         DRY_RUN=1;             shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "${VMNAME}" ]] || die "--vmname is required"

# Resolve module config from CONFIG_DIR
MODULE_JSON="${CONFIG_DIR}/${VMNAME}.json"
[[ -f "${MODULE_JSON}" ]] || die "module config not found: ${MODULE_JSON}"

LITELLM_ZONE="$(jq -r '.zone0' "${MODULE_JSON}")"
LITELLM_HOST="${VMNAME}.${LITELLM_ZONE}.internal"
SECRETS_FILE="/etc/secrets/litellm.env"
START_TIME=$(date +%s)

info "${BOLD}rotate-provider-key${CL}: ${BL}${VMNAME}${CL} (${LITELLM_HOST})"

# ── Get new key ───────────────────────────────────────────────────────────────
if [[ -z "${NEW_KEY}" ]]; then
    printf 'New OPENROUTER_API_KEY for %s (hidden): ' "${VMNAME}" >&2
    read -rs NEW_KEY; echo >&2
fi
[[ -n "${NEW_KEY}" ]] || die "new key cannot be empty"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} Step 1: would update OPENROUTER_API_KEY in ${SECRETS_FILE} on ${LITELLM_HOST}"
    info "  ${YW}[dry-run]${CL} Step 2: would rotate DB credential${CREDENTIAL_NAME:+ '${CREDENTIAL_NAME}'} via litellm-credentials.sh"
    [[ -n "${OWUI_SERVICE}" ]] && \
        info "  ${YW}[dry-run]${CL} Post:   would restart ${OWUI_SERVICE} on ${LITELLM_HOST} zone"
    exit 0
fi

# ── Step 1: Update env file + restart LiteLLM ────────────────────────────────
info "  ${BOLD}Step 1${CL}: updating OPENROUTER_API_KEY in ${SECRETS_FILE}"

ssh-keygen -R "${LITELLM_HOST}" >/dev/null 2>&1 || true

# Write a helper script on the remote VM via stdin to avoid quoting issues
STEP1_SCRIPT=$(cat <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
SECRETS_FILE="/etc/secrets/litellm.env"
NEW_KEY="$1"
[[ -f "${SECRETS_FILE}" ]] || { echo "ERROR: ${SECRETS_FILE} not found"; exit 1; }
cp "${SECRETS_FILE}" "${SECRETS_FILE}.bak"
if grep -q '^OPENROUTER_API_KEY=' "${SECRETS_FILE}"; then
    sed -i "s|^OPENROUTER_API_KEY=.*|OPENROUTER_API_KEY=${NEW_KEY}|" "${SECRETS_FILE}"
else
    echo "OPENROUTER_API_KEY=${NEW_KEY}" >> "${SECRETS_FILE}"
fi
chmod 600 "${SECRETS_FILE}"
echo "env_updated"
EOSH
)

RESULT=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${LITELLM_HOST}" \
    "sudo bash -s -- '${NEW_KEY}'" <<< "${STEP1_SCRIPT}") \
    || die "Step 1 failed: could not update ${SECRETS_FILE} on ${LITELLM_HOST}"
echo "${RESULT}" | grep -q "env_updated" || die "Step 1 failed: sed did not confirm update"

ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${LITELLM_HOST}" \
    "sudo systemctl restart podman-litellm.service && sleep 5 && \
     sudo systemctl is-active podman-litellm.service" \
    || die "Step 1 failed: podman-litellm did not come back up after restart"
info "  ${GN}✓${CL} Step 1 complete — env updated, service restarted"

# ── Read master key (must happen AFTER service restart) ──────────────────────
MASTER=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "tappaas@${LITELLM_HOST}" \
    "sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-") \
    || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"
[[ -n "${MASTER}" ]] || die "LITELLM_MASTER_KEY is empty on ${LITELLM_HOST}"

# ── Step 2: rotate DB credential (delegates to litellm-credentials.sh) ───────
info "  ${BOLD}Step 2${CL}: rotating DB credential on ${LITELLM_HOST}"

if [[ -z "${CREDENTIAL_NAME}" ]]; then
    CRED_LIST=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        "tappaas@${LITELLM_HOST}" \
        "curl -sf http://localhost:4000/credentials \
            -H 'Authorization: Bearer ${MASTER}'" 2>/dev/null) \
        || die "Step 2 failed: could not list credentials"
    # Default to the first credential with an openrouter-related name; pass
    # --credential-name explicitly for any other provider.
    CREDENTIAL_NAME=$(echo "${CRED_LIST}" | \
        jq -r '.credentials[]? | select(.credential_name | test("openrouter|or-key"; "i")) | .credential_name' \
        2>/dev/null | head -1 || true)
fi

if [[ -z "${CREDENTIAL_NAME}" ]]; then
    warn "Step 2: no matching DB credential found — skipping DB credential update"
    warn "  (only the env var was updated; pass --credential-name or create one with"
    warn "   litellm-credentials.sh add if this is a new provider)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "${SCRIPT_DIR}/litellm-credentials.sh" rotate \
        --vmname "${VMNAME}" --name "${CREDENTIAL_NAME}" --key "${NEW_KEY}" --yes \
        || die "Step 2 failed: litellm-credentials.sh rotate failed for '${CREDENTIAL_NAME}'"
    info "  ${GN}✓${CL} Step 2 complete — every model referencing '${CREDENTIAL_NAME}' picked up the new value automatically"
fi

# ── Post: restart OpenWebUI (optional) ───────────────────────────────────────
if [[ -n "${OWUI_SERVICE}" ]]; then
    info "  Post: restarting ${OWUI_SERVICE} (10s after LiteLLM)"
    sleep 10
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${LITELLM_HOST}" \
        "sudo systemctl restart '${OWUI_SERVICE}' 2>/dev/null && echo ok" | grep -q ok; then
        info "  ${GN}✓${CL} ${OWUI_SERVICE} restarted"
    else
        warn "  ${OWUI_SERVICE} not found on ${LITELLM_HOST} — restart it manually on its VM"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TIME ))
info ""
info "  ${GN}${BOLD}✓ Rotation complete for ${VMNAME}${CL} (${ELAPSED}s)"
info "    Step 1 ✓  env var + service restart"
info "    Step 2 ${CREDENTIAL_NAME:+✓  credential '${CREDENTIAL_NAME}' rotated — all referencing models updated}${CREDENTIAL_NAME:-⚠  no DB credential found}"
info ""
info "  Verify: check OpenRouter dashboard for activity with new key"
info "  Revoke: old key in OpenRouter org dashboard (manual)"
