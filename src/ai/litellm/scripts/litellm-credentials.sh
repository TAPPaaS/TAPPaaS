#!/usr/bin/env bash
#
# TAPPaaS LiteLLM — Credential & Model-Wiring Management
#
# Functional application management for the LiteLLM proxy's own credential
# registry — distinct from Virtual Keys (per-consumer auth INTO litellm,
# see services/models/install-service.sh) and from provider-level secrets in
# /etc/secrets/litellm.env (the source values that get registered here).
#
# LiteLLM stores provider credentials as named objects (`/credentials`);
# models reference a credential by name (`litellm_params.litellm_credential_name`)
# instead of embedding the literal key. This script is the front door for
# that registry: inspect it, add a new named credential, rotate an existing
# one's value, or wire a model to a credential.
#
# No secret values are ever printed by this script — `inspect` shows only
# what LiteLLM's own API already returns masked (e.g. "sk****a3"); `add`/
# `rotate` read the key via a hidden prompt or --key (prefer piping via
# process substitution over the literal command line when scripted).
#
# Usage:
#   litellm-credentials.sh inspect [--vmname <name>]
#   litellm-credentials.sh add --name <name> --provider <provider> [--key <value>] [--vmname <name>]
#   litellm-credentials.sh rotate --name <name> [--key <value>] [--yes] [--vmname <name>]
#   litellm-credentials.sh assign-model --model <model_name> --credential <credential_name> [--vmname <name>]
#
# Examples:
#   litellm-credentials.sh inspect
#   litellm-credentials.sh add --name "A3K - Openrouter API key" --provider openrouter
#   litellm-credentials.sh rotate --name "Gridtefy - Openrouter API key"
#   litellm-credentials.sh assign-model --model devstral --credential "Gridtefy - Openrouter API key"

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

VMNAME="litellm"
VERB="${1:-}"
shift 2>/dev/null || true

NAME=""; PROVIDER=""; KEY=""; MODEL=""; CREDENTIAL=""; ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmname)     VMNAME="$2";     shift 2 ;;
        --name)       NAME="$2";       shift 2 ;;
        --provider)   PROVIDER="$2";   shift 2 ;;
        --key)        KEY="$2";        shift 2 ;;
        --model)      MODEL="$2";      shift 2 ;;
        --credential) CREDENTIAL="$2"; shift 2 ;;
        --yes)        ASSUME_YES=1;    shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "${VERB}" ]] || die "verb required: inspect | add | rotate | assign-model (use --help)"

MODULE_JSON="${CONFIG_DIR}/${VMNAME}.json"
[[ -f "${MODULE_JSON}" ]] || die "module config not found: ${MODULE_JSON}"
LITELLM_ZONE="$(jq -r '.zone0' "${MODULE_JSON}")"
LITELLM_HOST="${VMNAME}.${LITELLM_ZONE}.internal"
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

_master_key() {
    ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" \
        "sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-" \
        2>/dev/null
}

_remote_curl() {
    # $1 = remote curl args (already quoted for the remote shell)
    # shellcheck disable=SC2029
    ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" "$1"
}

# Credential names contain spaces/parens ("Gridtefy - Openrouter API key") —
# URL-encode before embedding in a path segment (/credentials/by_name/<name>,
# /credentials/<name>). JSON request bodies handle spaces fine and don't need
# this. Found via a live bug: an unencoded name broke the by_name lookup
# (curl returned HTTP 000 — malformed URL) on the very first real test with
# a space-containing name.
_urlencode() {
    jq -rn --arg s "$1" '$s|@uri'
}

# ── inspect ────────────────────────────────────────────────────────────────
# Read-only. Prints only what LiteLLM's own API already masks — no secrets
# leave the proxy host through this script.
cmd_inspect() {
    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"
    [[ -n "${master}" ]] || die "LITELLM_MASTER_KEY is empty on ${LITELLM_HOST}"

    info "${BOLD}LiteLLM inspect${CL}: ${BL}${VMNAME}${CL} (${LITELLM_HOST})"
    echo ""

    info "${BOLD}CREDENTIALS${CL}"
    # Never pass credential_values.api_key through, even masked — LiteLLM's
    # own server-side masking is not something this script should depend on
    # as its only safeguard. Show presence/absence only (SET/MISSING).
    _remote_curl "curl -sf http://localhost:4000/credentials -H 'Authorization: Bearer ${master}'" \
        | jq -r '.credentials[]? | "  \(.credential_name)\t\(if .credential_values.api_key != null then "SET" else "MISSING" end)\tprovider=\(.credential_info.custom_llm_provider // "?")"' \
        | column -t -s $'\t'
    echo ""

    info "${BOLD}MODELS${CL} (grouped by model_name — multiple rows = multiple deployments/providers)"
    _remote_curl "curl -sf http://localhost:4000/model/info -H 'Authorization: Bearer ${master}'" \
        | jq -r '.data[] | "  \(.model_name)\t\(.litellm_params.model // "?")\t\(.litellm_params.litellm_credential_name // (if .litellm_params.api_key != null then "explicit-api_key" else "NONE" end))"' \
        | sort | column -t -s $'\t'
    echo ""

    info "${BOLD}VIRTUAL KEYS${CL} (consumer-facing auth into litellm)"
    _remote_curl "curl -sf 'http://localhost:4000/key/list?return_full_object=true' -H 'Authorization: Bearer ${master}'" \
        | jq -r '.keys[]? | "  \(.key_alias // "unnamed")\tblocked=\(.blocked // false)\tspend=\(.spend // 0)"' \
        | column -t -s $'\t'
    echo ""

    info "${BOLD}TEAMS${CL}"
    _remote_curl "curl -sf http://localhost:4000/team/list -H 'Authorization: Bearer ${master}'" \
        | jq -r '.[] | "  \(.team_alias)\tmodels=\(.models | join(","))\tbudget=\(.max_budget // "unlimited")\tspend=\(.spend // 0)"' \
        | column -t -s $'\t'
}

# ── add ────────────────────────────────────────────────────────────────────
cmd_add() {
    [[ -n "${NAME}" ]]     || die "--name is required"
    [[ -n "${PROVIDER}" ]] || die "--provider is required"

    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

    local exists name_enc
    name_enc="$(_urlencode "${NAME}")"
    exists="$(_remote_curl "curl -s -o /dev/null -w '%{http_code}' 'http://localhost:4000/credentials/by_name/${name_enc}' -H 'Authorization: Bearer ${master}'")"
    [[ "${exists}" != "200" ]] || die "credential '${NAME}' already exists — use 'rotate' to change its value"

    if [[ -z "${KEY}" ]]; then
        printf 'New api_key value for "%s" (hidden): ' "${NAME}" >&2
        read -rs KEY; echo >&2
    fi
    [[ -n "${KEY}" ]] || die "key cannot be empty"

    info "Creating credential '${NAME}' (provider: ${PROVIDER}) on ${LITELLM_HOST}..."
    # Build the JSON body locally with jq (safe escaping for spaces/parens/
    # quotes), base64 it, and pass ONLY the base64 blob + master key as ssh
    # argv (both space-free) — ssh flattens argv into a single remote-shell
    # string, so any arg containing spaces/special chars gets re-split and
    # breaks (confirmed live: a credential name with spaces/parens produced
    # "syntax error near unexpected token '('"). Never pass raw
    # names/values with special characters as ssh command-line args.
    local body_b64 result
    body_b64="$(jq -cn --arg n "${NAME}" --arg k "${KEY}" --arg p "${PROVIDER}" \
        '{credential_name:$n, credential_values:{api_key:$k}, credential_info:{custom_llm_provider:$p}}' \
        | base64 -w0)"
    result="$(ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" bash -s -- "${master}" "${body_b64}" <<'EOSH'
MASTER="$1"; BODY_B64="$2"
curl -sf -X POST http://localhost:4000/credentials \
    -H "Authorization: Bearer ${MASTER}" -H "Content-Type: application/json" \
    --data-raw "$(echo "${BODY_B64}" | base64 -d)"
EOSH
    )" || die "add failed: could not reach ${LITELLM_HOST}"

    echo "${result}" | jq -e '.success == true' >/dev/null 2>&1 \
        || die "add failed: unexpected response: ${result}"
    info "${GN}✓${CL} Credential '${NAME}' created. Wire a model to it: assign-model --model <name> --credential \"${NAME}\""
}

# ── rotate ─────────────────────────────────────────────────────────────────
cmd_rotate() {
    [[ -n "${NAME}" ]] || die "--name is required (must already exist — use 'add' for a new credential)"

    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

    local exists name_enc
    name_enc="$(_urlencode "${NAME}")"
    exists="$(_remote_curl "curl -s -o /dev/null -w '%{http_code}' 'http://localhost:4000/credentials/by_name/${name_enc}' -H 'Authorization: Bearer ${master}'")"
    [[ "${exists}" == "200" ]] || die "credential '${NAME}' not found — use 'add' to create it"

    local usage_count
    usage_count="$(_remote_curl "curl -sf http://localhost:4000/model/info -H 'Authorization: Bearer ${master}'" \
        | jq --arg n "${NAME}" '[.data[] | select(.litellm_params.litellm_credential_name == $n)] | length')"

    if [[ "${ASSUME_YES}" -ne 1 ]]; then
        printf 'Rotate "%s", used by %s model(s) — continue? [y/N] ' "${NAME}" "${usage_count}" >&2
        read -r CONFIRM
        [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { info "Aborted — no change made."; exit 0; }
    fi

    if [[ -z "${KEY}" ]]; then
        printf 'New api_key value for "%s" (hidden): ' "${NAME}" >&2
        read -rs KEY; echo >&2
    fi
    [[ -n "${KEY}" ]] || die "key cannot be empty"

    info "Rotating credential '${NAME}' on ${LITELLM_HOST} (${usage_count} model(s) affected, no per-model action needed)..."
    local body_b64 result
    body_b64="$(jq -cn --arg k "${KEY}" '{credential_values:{api_key:$k}}' | base64 -w0)"
    result="$(ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" bash -s -- "${master}" "${name_enc}" "${body_b64}" <<'EOSH'
MASTER="$1"; NAME_ENC="$2"; BODY_B64="$3"
curl -sf -X PATCH "http://localhost:4000/credentials/${NAME_ENC}" \
    -H "Authorization: Bearer ${MASTER}" -H "Content-Type: application/json" \
    --data-raw "$(echo "${BODY_B64}" | base64 -d)"
EOSH
    )" || die "rotate failed: could not reach ${LITELLM_HOST}"

    echo "${result}" | jq -e '.credential_name' >/dev/null 2>&1 \
        || die "rotate failed: unexpected response: ${result}"
    info "${GN}✓${CL} Credential '${NAME}' rotated. ${usage_count} model(s) automatically use the new value — no restart needed."
}

# ── assign-model ───────────────────────────────────────────────────────────
cmd_assign_model() {
    [[ -n "${MODEL}" ]]      || die "--model is required"
    [[ -n "${CREDENTIAL}" ]] || die "--credential is required"

    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

    local exists cred_enc
    cred_enc="$(_urlencode "${CREDENTIAL}")"
    exists="$(_remote_curl "curl -s -o /dev/null -w '%{http_code}' 'http://localhost:4000/credentials/by_name/${cred_enc}' -H 'Authorization: Bearer ${master}'")"
    [[ "${exists}" == "200" ]] || die "credential '${CREDENTIAL}' not found — use 'add' first"

    local model_id
    model_id="$(_remote_curl "curl -sf http://localhost:4000/model/info -H 'Authorization: Bearer ${master}'" \
        | jq -r --arg n "${MODEL}" '.data[] | select(.model_name == $n) | .model_info.id' | head -1)"
    [[ -n "${model_id}" && "${model_id}" != "null" ]] || die "model '${MODEL}' not found"

    info "Wiring model '${MODEL}' (${model_id}) to credential '${CREDENTIAL}'..."
    local body_b64 result
    body_b64="$(jq -cn --arg m "${MODEL}" --arg c "${CREDENTIAL}" --arg id "${model_id}" \
        '{model_name:$m, litellm_params:{litellm_credential_name:$c}, model_info:{id:$id}}' \
        | base64 -w0)"
    result="$(ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" bash -s -- "${master}" "${body_b64}" <<'EOSH'
MASTER="$1"; BODY_B64="$2"
curl -sf -X POST http://localhost:4000/model/update \
    -H "Authorization: Bearer ${MASTER}" -H "Content-Type: application/json" \
    --data-raw "$(echo "${BODY_B64}" | base64 -d)"
EOSH
    )" || die "assign-model failed: could not reach ${LITELLM_HOST}"

    echo "${result}" | jq -e '.model_name' >/dev/null 2>&1 \
        || die "assign-model failed: unexpected response: ${result}"
    info "${GN}✓${CL} '${MODEL}' now uses credential '${CREDENTIAL}'."
}

# ── Main ──────────────────────────────────────────────────────────────────
case "${VERB}" in
    inspect)      cmd_inspect ;;
    add)          cmd_add ;;
    rotate)       cmd_rotate ;;
    assign-model) cmd_assign_model ;;
    *) die "unknown verb: ${VERB} (expected: inspect | add | rotate | assign-model)" ;;
esac
