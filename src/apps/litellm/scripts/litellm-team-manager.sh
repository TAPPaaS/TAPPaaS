#!/usr/bin/env bash
#
# TAPPaaS LiteLLM — Team Management
#
# Teams in LiteLLM scope virtual keys: a key with team_id is budget-isolated
# to that team. dw-controller's mint_litellm_key() assigns ownerOrg as team_id
# when generating a DW virtual key — the team MUST exist before install.
#
# Usage:
#   litellm-team-manager.sh list   [--vmname <name>]
#   litellm-team-manager.sh new    --alias <alias>  [--vmname <name>]
#   litellm-team-manager.sh info   --alias <alias>  [--vmname <name>]
#   litellm-team-manager.sh delete --alias <alias>  [--yes] [--vmname <name>]
#
# Examples:
#   litellm-team-manager.sh list
#   litellm-team-manager.sh new  --alias gridtefy-itops
#   litellm-team-manager.sh info --alias gridtefy-rnd
#   litellm-team-manager.sh delete --alias gridtefy-itops --yes

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

VMNAME="litellm"
VERB="${1:-}"
shift 2>/dev/null || true

ALIAS=""; ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmname) VMNAME="$2"; shift 2 ;;
        --alias)  ALIAS="$2";  shift 2 ;;
        --yes)    ASSUME_YES=1; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "${VERB}" ]] || die "verb required: list | new | info | delete (use --help)"

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
    # $1 = remote curl invocation (already quoted for the remote shell)
    # shellcheck disable=SC2029
    ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" "$1"
}

# Resolve team_id from alias — returns empty string if not found.
_team_id_for_alias() {
    local master="$1" alias="$2"
    _remote_curl "curl -sf http://localhost:4000/team/list -H 'Authorization: Bearer ${master}'" \
        | jq -r --arg a "${alias}" '.[] | select(.team_alias == $a) | .team_id' \
        | head -1
}

# ── list ───────────────────────────────────────────────────────────────────
cmd_list() {
    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"
    [[ -n "${master}" ]] || die "LITELLM_MASTER_KEY is empty on ${LITELLM_HOST}"

    info "${BOLD}LiteLLM Teams${CL}: ${BL}${VMNAME}${CL} (${LITELLM_HOST})"
    echo ""

    _remote_curl "curl -sf http://localhost:4000/team/list -H 'Authorization: Bearer ${master}'" \
        | jq -r '.[] | "  \(.team_alias)\t\(.team_id)\tspend=\(.spend // 0)\tbudget=\(.max_budget // "unlimited")\tblocked=\(.blocked)"' \
        | column -t -s $'\t'
}

# ── new ────────────────────────────────────────────────────────────────────
cmd_new() {
    [[ -n "${ALIAS}" ]] || die "--alias is required"

    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

    local existing
    existing="$(_team_id_for_alias "${master}" "${ALIAS}")"
    if [[ -n "${existing}" ]]; then
        info "${BOLD}Team '${ALIAS}' already exists${CL} (team_id: ${existing}) — no action taken."
        exit 0
    fi

    info "Creating team '${ALIAS}' on ${LITELLM_HOST}..."
    local body_b64 result
    body_b64="$(jq -cn --arg a "${ALIAS}" '{team_alias: $a}' | base64 -w0)"
    result="$(ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" bash -s -- "${master}" "${body_b64}" <<'EOSH'
MASTER="$1"; BODY_B64="$2"
curl -sf -X POST http://localhost:4000/team/new \
    -H "Authorization: Bearer ${MASTER}" -H "Content-Type: application/json" \
    --data-raw "$(echo "${BODY_B64}" | base64 -d)"
EOSH
    )" || die "team/new failed: could not reach ${LITELLM_HOST}"

    local team_id
    team_id="$(echo "${result}" | jq -r '.team_id // empty')"
    [[ -n "${team_id}" ]] || die "team/new failed — unexpected response: ${result}"
    info "${GN}✓${CL} Team '${ALIAS}' created (team_id: ${team_id})"
}

# ── info ───────────────────────────────────────────────────────────────────
cmd_info() {
    [[ -n "${ALIAS}" ]] || die "--alias is required"

    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

    local team_id
    team_id="$(_team_id_for_alias "${master}" "${ALIAS}")"
    [[ -n "${team_id}" ]] || die "team '${ALIAS}' not found — use 'list' to see all teams"

    info "${BOLD}Team: ${ALIAS}${CL} (${team_id})"
    echo ""

    local raw
    raw="$(_remote_curl "curl -sf 'http://localhost:4000/team/info?team_id=${team_id}' -H 'Authorization: Bearer ${master}'")"

    echo "${raw}" | jq '{
        team_alias: .team_info.team_alias,
        team_id:    .team_info.team_id,
        spend:      .team_info.spend,
        max_budget: .team_info.max_budget,
        blocked:    .team_info.blocked,
        models:     .team_info.models,
        members:    [ .team_memberships[]? | {user_id: .user_id, role: .role} ]
    }'
}

# ── delete ─────────────────────────────────────────────────────────────────
cmd_delete() {
    [[ -n "${ALIAS}" ]] || die "--alias is required"

    local master
    master="$(_master_key)" || die "could not read LITELLM_MASTER_KEY from ${LITELLM_HOST}"

    local team_id
    team_id="$(_team_id_for_alias "${master}" "${ALIAS}")"
    [[ -n "${team_id}" ]] || die "team '${ALIAS}' not found — use 'list' to see all teams"

    if [[ "${ASSUME_YES}" -ne 1 ]]; then
        printf 'Delete team "%s" (%s)? Virtual keys scoped to this team will lose their budget scope. [y/N] ' \
            "${ALIAS}" "${team_id}" >&2
        read -r CONFIRM
        [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { info "Aborted — no change made."; exit 0; }
    fi

    info "Deleting team '${ALIAS}' (${team_id})..."
    local body_b64 result
    body_b64="$(jq -cn --arg id "${team_id}" '{team_ids: [$id]}' | base64 -w0)"
    result="$(ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" bash -s -- "${master}" "${body_b64}" <<'EOSH'
MASTER="$1"; BODY_B64="$2"
curl -sf -X DELETE http://localhost:4000/team/delete \
    -H "Authorization: Bearer ${MASTER}" -H "Content-Type: application/json" \
    --data-raw "$(echo "${BODY_B64}" | base64 -d)"
EOSH
    )" || die "team/delete failed: could not reach ${LITELLM_HOST}"

    echo "${result}" | jq -e '.deleted_team' >/dev/null 2>&1 \
        || die "delete failed — unexpected response: ${result}"
    info "${GN}✓${CL} Team '${ALIAS}' deleted."
}

# ── Main ──────────────────────────────────────────────────────────────────
case "${VERB}" in
    list)   cmd_list ;;
    new)    cmd_new ;;
    info)   cmd_info ;;
    delete) cmd_delete ;;
    *) die "unknown verb: ${VERB} (expected: list | new | info | delete)" ;;
esac
