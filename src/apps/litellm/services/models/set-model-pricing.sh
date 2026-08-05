#!/usr/bin/env bash
#
# TAPPaaS LiteLLM Models Service — Set Pricing & Limits
#
# Sets input_cost_per_token, output_cost_per_token and max_input_tokens on DB-stored models, so
# LiteLLM can account spend and enforce budgets.
#
# WHY THIS EXISTS:
# A model added through the admin UI or POST /model/new is stored in the database (db_model: true),
# and LiteLLM fills in nothing the caller did not supply. Two omissions look harmless and are not:
#
#   input_cost_per_token absent  -> spend stays at 0.0 against a billing provider. Any max_budget on
#                                   a consuming key then measures nothing, and a budget that
#                                   measures nothing reads as headroom.
#   max_input_tokens absent      -> nothing downstream can check a declared context ceiling against
#                                   what the provider actually serves.
#
# Neither surfaces as an error. The proxy works, requests succeed, and the only symptom is a spend
# figure that stays plausible-looking at zero.
#
# WHY NOT scripts/rotate-provider-key.sh:
# Its Step 3 repairs a missing api_key by DELETE + POST /model/new carrying only {model, api_key}.
# That drops every other litellm_params entry — including api_base, which any non-default provider
# needs. This script uses /model/update and merges into the params it read, so it changes only the
# fields named on the command line and knows nothing about any particular provider.
#
# Usage:
#   set-model-pricing.sh --vmname <litellm-vm> --model <model_name> \
#       [--input-cost-per-1m <N>] [--output-cost-per-1m <N>] \
#       [--max-input-tokens <N>] [--currency <CODE>] [--apply]
#
#   set-model-pricing.sh --vmname <litellm-vm> --from-file <pricing.json> [--apply]
#
# Costs are given per 1M tokens — the unit providers publish — and divided here. LiteLLM stores a
# bare number with no currency, so a proxy mixing currencies produces a total that means nothing.
# Declare --currency and keep one currency per proxy.
#
# Dry-run is the default. Nothing is written without --apply.
#
# pricing.json shape (keep the file with your deployment, not with this script — rates and model
# aliases are instance-specific and go stale):
#   { "currency": "EUR",
#     "models": [ { "model_name": "<alias>",
#                   "input_cost_per_1m": 0.75,
#                   "output_cost_per_1m": 2.25,
#                   "max_input_tokens": 131072 } ] }

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME=""; MODEL=""; FROM_FILE=""
IN_COST_1M=""; OUT_COST_1M=""; MAX_IN=""; CURRENCY=""
APPLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmname)              VMNAME="$2";      shift 2 ;;
        --model)               MODEL="$2";       shift 2 ;;
        --from-file)           FROM_FILE="$2";   shift 2 ;;
        --input-cost-per-1m)   IN_COST_1M="$2";  shift 2 ;;
        --output-cost-per-1m)  OUT_COST_1M="$2"; shift 2 ;;
        --max-input-tokens)    MAX_IN="$2";      shift 2 ;;
        --currency)            CURRENCY="$2";    shift 2 ;;
        --apply)               APPLY=1;          shift ;;
        -h|--help) sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "${VMNAME}" ]] || die "--vmname is required"
[[ -n "${MODEL}" || -n "${FROM_FILE}" ]] || die "either --model or --from-file is required"
[[ -z "${FROM_FILE}" || -f "${FROM_FILE}" ]] || die "pricing file not found: ${FROM_FILE}"

MODULE_JSON="${CONFIG_DIR}/${VMNAME}.json"
[[ -f "${MODULE_JSON}" ]] || die "module config not found: ${MODULE_JSON}"
LITELLM_ZONE="$(jq -r '.zone0' "${MODULE_JSON}")"
LITELLM_HOST="${VMNAME}.${LITELLM_ZONE}.internal"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
ssh-keygen -R "${LITELLM_HOST}" >/dev/null 2>&1 || true

info "${BOLD}litellm:models set-pricing${CL}: ${BL}${VMNAME}${CL} (${LITELLM_HOST})"
[[ "${APPLY}" -eq 1 ]] || info "  ${YW}dry-run${CL} — nothing is written without --apply"

MASTER=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" \
    "sudo grep '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-") \
    || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"
[[ -n "${MASTER}" ]] || die "LITELLM_MASTER_KEY is empty on ${LITELLM_HOST}"

MODEL_INFO=$(ssh "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" \
    "curl -sf http://localhost:4000/model/info -H 'Authorization: Bearer ${MASTER}'") \
    || die "could not call /model/info on ${LITELLM_HOST}"

# Work list: model_name<TAB>in_per_1m<TAB>out_per_1m<TAB>max_in
if [[ -n "${FROM_FILE}" ]]; then
    [[ -n "${CURRENCY}" ]] || CURRENCY="$(jq -r '.currency // "UNSET"' "${FROM_FILE}")"
    WORK=$(jq -r '.models[] | [.model_name, (.input_cost_per_1m // ""), (.output_cost_per_1m // ""), (.max_input_tokens // "")] | @tsv' "${FROM_FILE}")
else
    WORK=$(printf '%s\t%s\t%s\t%s\n' "${MODEL}" "${IN_COST_1M}" "${OUT_COST_1M}" "${MAX_IN}")
fi

[[ -n "${CURRENCY}" ]] || warn "  no --currency declared — LiteLLM stores a bare number; a proxy mixing currencies totals nonsense"
[[ -n "${CURRENCY}" ]] && info "  currency: ${CURRENCY} (per 1M tokens, divided to per-token below)"

CHANGED=0; SKIPPED=0; FAILED=0

while IFS=$'\t' read -r M_NAME M_IN M_OUT M_MAXIN; do
    [[ -n "${M_NAME}" ]] || continue

    ROW=$(echo "${MODEL_INFO}" | jq -c --arg m "${M_NAME}" '.data[] | select(.model_name == $m)' | head -1)
    if [[ -z "${ROW}" ]]; then
        warn "  ${M_NAME}: not registered on this proxy — skipped"
        SKIPPED=$((SKIPPED + 1)); continue
    fi

    MODEL_ID=$(echo "${ROW}" | jq -r '.model_info.id')
    CUR_IN=$(echo  "${ROW}" | jq -r '.model_info.input_cost_per_token  // "null"')
    CUR_OUT=$(echo "${ROW}" | jq -r '.model_info.output_cost_per_token // "null"')
    CUR_MAX=$(echo "${ROW}" | jq -r '.model_info.max_input_tokens      // "null"')

    # Per-token from per-1M. awk rather than bc: bc is absent on a NixOS deploy host, and printf
    # would round a 1e-9 rate away entirely. %.12f keeps the precision LiteLLM needs.
    NEW_IN="";  [[ -n "${M_IN}"    ]] && NEW_IN=$(awk  -v v="${M_IN}"  'BEGIN{printf "%.12f", v/1000000}')
    NEW_OUT=""; [[ -n "${M_OUT}"   ]] && NEW_OUT=$(awk -v v="${M_OUT}" 'BEGIN{printf "%.12f", v/1000000}')

    info "  ${BL}${M_NAME}${CL} (${MODEL_ID})"
    info "    input  : ${CUR_IN} -> ${NEW_IN:-<unchanged>}"
    info "    output : ${CUR_OUT} -> ${NEW_OUT:-<unchanged>}"
    info "    max_in : ${CUR_MAX} -> ${M_MAXIN:-<unchanged>}"

    if [[ "${APPLY}" -eq 0 ]]; then CHANGED=$((CHANGED + 1)); continue; fi

    # Merge into the EXISTING litellm_params. /model/update replaces the object wholesale, so a
    # partial payload silently drops api_base and everything else the row carried.
    #
    # The id belongs in model_info.id — LiteLLM's UpdateDeployment shape is
    # {model_name, litellm_params, model_info}. A top-level model_id is rejected with
    # "model_info not provided", which reads as a payload problem rather than a placement one.
    PAYLOAD=$(echo "${ROW}" | jq -c \
        --arg id "${MODEL_ID}" \
        --arg name "${M_NAME}" \
        --argjson nin  "${NEW_IN:-null}" \
        --argjson nout "${NEW_OUT:-null}" \
        --argjson nmax "${M_MAXIN:-null}" '
        .litellm_params
        | (if $nin  != null then .input_cost_per_token  = $nin  else . end)
        | (if $nout != null then .output_cost_per_token = $nout else . end)
        | (if $nmax != null then .max_input_tokens      = $nmax else . end)
        | { model_name: $name, litellm_params: ., model_info: { id: $id } }')

    # `ssh -n` is load-bearing: without it ssh consumes this loop's stdin and swallows the rest of
    # the work list, so only the first model is ever processed — and the summary reports one
    # failure rather than N never attempted.
    #
    # `curl -s` without -f on purpose: -f discards the response body, turning a 400 that explains
    # exactly what the API rejected into an empty string indistinguishable from a network failure.
    RESP=$(ssh -n "${SSH_OPTS[@]}" "tappaas@${LITELLM_HOST}" \
        "curl -s -w '\n%{http_code}' -X POST http://localhost:4000/model/update \
            -H 'Authorization: Bearer ${MASTER}' \
            -H 'Content-Type: application/json' \
            --data-raw '${PAYLOAD}'" 2>&1) || true

    HTTP_CODE=$(printf '%s' "${RESP}" | tail -1)
    BODY=$(printf '%s' "${RESP}" | sed '$d')

    if [[ "${HTTP_CODE}" == "200" ]]; then
        info "    ${GN}✓${CL} updated"
        CHANGED=$((CHANGED + 1))
    else
        warn "    update failed (HTTP ${HTTP_CODE:-none}) — row left untouched"
        [[ -n "${BODY}" ]] && warn "      ${BODY:0:400}"
        FAILED=$((FAILED + 1))
    fi
done <<< "${WORK}"

info ""
if [[ "${APPLY}" -eq 1 ]]; then
    info "  ${GN}✓${CL} ${CHANGED} model(s) updated · ${SKIPPED} skipped · ${FAILED} failed"
    # A mutation response is not proof of persistence, and the router refreshes on its own cadence:
    # an immediate re-read can show some rows updated and others not, with all writes having
    # returned 200. Re-read after a short pause rather than trusting either the write or the first
    # read. Same caution as scripts/litellm-credentials.sh documents for /credentials.
    info "  Verify (allow ~20s for the router to refresh):"
    info "    curl /model/info | jq '.data[] | {model_name, cost: .model_info.input_cost_per_token}'"
else
    info "  ${YW}dry-run${CL} — ${CHANGED} model(s) would change, ${SKIPPED} skipped. Re-run with --apply."
fi
[[ "${FAILED}" -eq 0 ]]
