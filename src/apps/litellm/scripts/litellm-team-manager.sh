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
#   litellm-team-manager.sh key list [--alias <alias>] [--vmname <name>]
#   litellm-team-manager.sh key info  --alias <alias> [--vmname <name>]
#
# The bare verbs are team verbs and keep working unchanged. `key` is a second
# entity, read-only: minting belongs to the installer that owns the consumer and
# revoking to its delete-service, which already does both.
#
# Examples:
#   litellm-team-manager.sh list
#   litellm-team-manager.sh new  --alias gridtefy-itops
#   litellm-team-manager.sh info --alias gridtefy-rnd
#   litellm-team-manager.sh delete --alias gridtefy-itops --yes
#   litellm-team-manager.sh key list
#   litellm-team-manager.sh key info --alias litellm-svc-openwebui

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

VMNAME="litellm"
VERB="${1:-}"
shift 2>/dev/null || true

# -h/--help arrives as $1, i.e. as the VERB, and was shifted away before the
# option loop below could ever see it — so `--help` died with "unknown verb".
# Handle it here, where it actually lands.
case "${VERB}" in
    -h|--help|help)
        sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
        exit 0 ;;
esac

# Optional entity keyword. `team` is accepted as an explicit synonym for the
# bare verbs so both spellings read the same; `key` selects the second entity.
ENTITY=""
case "${VERB}" in
    key|team) ENTITY="${VERB}"; VERB="${1:-}"; shift 2>/dev/null || true ;;
esac

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

[[ -n "${VERB}" ]] || die "verb required: list | new | info | delete, or key list|info (use --help)"

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

# One remote call, one honest failure story.
#
# WHY: every call site used `curl -sf`. -f makes curl exit non-zero and print
# NOTHING on any HTTP >= 400, so both the status and the server's explanation
# were discarded; each caller then reported the only thing it still knew —
# "could not reach <host>" — about a host that had in fact answered. Measured:
# `delete` reported the host unreachable while `list` succeeded against the same
# host over the same ssh seconds later.
#
# Two failure classes, kept apart because the remedies are opposites:
#   transport  ssh or connect failed — the host really is unreachable
#   http       the host answered non-2xx — it is reachable and refusing
#
# Secrets stay off the command line: the master key and any body are passed as
# positional arguments to `bash -s`, the same way the original heredocs did.
#
# Usage: _api <METHOD> <path> [<body-json>]
#   success: echoes the response body, returns 0
#   failure: returns 1 with API_FAIL_* set — pass them to _api_fail
API_FAIL_KIND=""; API_FAIL_STATUS=""; API_FAIL_BODY=""

_api() {
    local method="$1" rpath="$2" body="${3:-}"
    local master body_b64 out status
    API_FAIL_KIND=""; API_FAIL_STATUS=""; API_FAIL_BODY=""

    master="$(_master_key)" || { API_FAIL_KIND="transport"; return 1; }
    [[ -n "${master}" ]] || { API_FAIL_KIND="masterkey"; return 1; }
    body_b64="$(printf '%s' "${body}" | base64 -w0)"

    # `|| true` on the ssh: a non-zero here can mean either an ssh failure or a
    # curl that ran fine and wrote a status we still want to read. The empty
    # output check below tells those apart, so the status is never thrown away.
    out="$(ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" bash -s -- \
             "${master}" "${method}" "${rpath}" "${body_b64}" 2>/dev/null <<'EOSH' || true
MASTER="$1"; METHOD="$2"; RPATH="$3"; BODY_B64="$4"
if [ -n "${BODY_B64}" ]; then
    curl -s -X "${METHOD}" "http://localhost:4000${RPATH}" \
        -H "Authorization: Bearer ${MASTER}" -H "Content-Type: application/json" \
        --data-raw "$(echo "${BODY_B64}" | base64 -d)" -w '\n%{http_code}'
else
    curl -s -X "${METHOD}" "http://localhost:4000${RPATH}" \
        -H "Authorization: Bearer ${MASTER}" -w '\n%{http_code}'
fi
EOSH
    )"

    # No output at all means curl never produced a status line → transport.
    [[ -n "${out}" ]] || { API_FAIL_KIND="transport"; return 1; }

    status="${out##*$'\n'}"
    API_FAIL_BODY="${out%$'\n'*}"
    API_FAIL_STATUS="${status}"

    case "${status}" in
        2??) printf '%s' "${API_FAIL_BODY}"; API_FAIL_BODY=""; return 0 ;;
        *)   API_FAIL_KIND="http"; return 1 ;;
    esac
}

# Turn an _api failure into a message that names what was actually observed.
_api_fail() {
    local what="$1"
    case "${API_FAIL_KIND}" in
        transport) die "${what}: could not reach ${LITELLM_HOST} (ssh or connect failed)" ;;
        masterkey) die "${what}: LITELLM_MASTER_KEY is empty on ${LITELLM_HOST}" ;;
        *)         die "${what}: ${LITELLM_HOST} answered HTTP ${API_FAIL_STATUS}${API_FAIL_BODY:+ — ${API_FAIL_BODY}}" ;;
    esac
}

# Resolve team_id from alias — returns empty string if not found.
_team_id_for_alias() {
    local alias="$1" raw
    raw="$(_api GET /team/list)" || _api_fail "team/list"
    printf '%s' "${raw}" \
        | jq -r --arg a "${alias}" '.[] | select(.team_alias == $a) | .team_id' \
        | head -1
}

# ── list ───────────────────────────────────────────────────────────────────
cmd_list() {
    info "${BOLD}LiteLLM Teams${CL}: ${BL}${VMNAME}${CL} (${LITELLM_HOST})"
    echo ""

    local raw
    raw="$(_api GET /team/list)" || _api_fail "team/list"
    printf '%s' "${raw}" \
        | jq -r '.[] | "  \(.team_alias)\t\(.team_id)\tspend=\(.spend // 0)\tbudget=\(.max_budget // "unlimited")\tblocked=\(.blocked)"' \
        | column -t -s $'\t'
}

# ── new ────────────────────────────────────────────────────────────────────
cmd_new() {
    [[ -n "${ALIAS}" ]] || die "--alias is required"

    local existing
    existing="$(_team_id_for_alias "${ALIAS}")"
    if [[ -n "${existing}" ]]; then
        info "${BOLD}Team '${ALIAS}' already exists${CL} (team_id: ${existing}) — no action taken."
        exit 0
    fi

    info "Creating team '${ALIAS}' on ${LITELLM_HOST}..."
    local result
    result="$(_api POST /team/new "$(jq -cn --arg a "${ALIAS}" '{team_alias: $a}')")" \
        || _api_fail "team/new"

    local team_id
    team_id="$(echo "${result}" | jq -r '.team_id // empty')"
    [[ -n "${team_id}" ]] || die "team/new failed — unexpected response: ${result}"
    info "${GN}✓${CL} Team '${ALIAS}' created (team_id: ${team_id})"
}

# ── info ───────────────────────────────────────────────────────────────────
cmd_info() {
    [[ -n "${ALIAS}" ]] || die "--alias is required"

    local team_id
    team_id="$(_team_id_for_alias "${ALIAS}")"
    [[ -n "${team_id}" ]] || die "team '${ALIAS}' not found — use 'team list' to see all teams"

    info "${BOLD}Team: ${ALIAS}${CL} (${team_id})"
    echo ""

    local raw
    raw="$(_api GET "/team/info?team_id=${team_id}")" || _api_fail "team/info"

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

    local team_id
    team_id="$(_team_id_for_alias "${ALIAS}")"
    [[ -n "${team_id}" ]] || die "team '${ALIAS}' not found — use 'team list' to see all teams"

    if [[ "${ASSUME_YES}" -ne 1 ]]; then
        printf 'Delete team "%s" (%s)? Virtual keys scoped to this team will lose their budget scope. [y/N] ' \
            "${ALIAS}" "${team_id}" >&2
        read -r CONFIRM
        [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { info "Aborted — no change made."; exit 0; }
    fi

    info "Deleting team '${ALIAS}' (${team_id})..."
    local result
    result="$(_api DELETE /team/delete "$(jq -cn --arg id "${team_id}" '{team_ids: [$id]}')")" \
        || _api_fail "team/delete"

    echo "${result}" | jq -e '.deleted_team' >/dev/null 2>&1 \
        || die "delete failed — unexpected response: ${result}"
    info "${GN}✓${CL} Team '${ALIAS}' deleted."
}

# ── key (read-only) ────────────────────────────────────────────────────────
# WHY this entity exists: a module teardown that fails to revoke leaves a
# VALID credential behind, and nothing on the manager surface could say so —
# list/new/info/delete were all team-scoped while /key/list was reachable only
# from inside the install and delete services. "Is that key gone?" had no
# supported answer, so the only way to check was a hand-written curl against the
# production instance, which is precisely what a manager exists to avoid.
#
# The key material is never printed. /key/list returns .token; it is the handle
# the delete-service revokes by, and it has no business on a terminal or in a
# log, so every projection below names its fields explicitly rather than
# dumping the record.

cmd_key_list() {
    local raw n
    raw="$(_api GET '/key/list?return_full_object=true')" || _api_fail "key/list"
    n="$(printf '%s' "${raw}" | jq --arg a "${ALIAS}" \
        '[ .keys[]? | select($a == "" or .key_alias == $a) ] | length')"

    info "${BOLD}LiteLLM virtual keys${CL}: ${BL}${VMNAME}${CL} (${LITELLM_HOST})"
    echo ""
    if [[ "${n}" -eq 0 ]]; then
        info "  no key matches${ALIAS:+ alias '${ALIAS}'}"
        return 0
    fi
    printf '%s' "${raw}" | jq -r --arg a "${ALIAS}" '
        .keys[]? | select($a == "" or .key_alias == $a)
        | "  \(.key_alias // "(no alias)")\t\(.team_id // "-")\tspend=\(.spend // 0)\tbudget=\(.max_budget // "unlimited")"
    ' | column -t -s $'\t'
}

# Exit 1 when the alias does not exist. That is the point: it makes "this key is
# gone" a testable assertion rather than a reading of prose.
cmd_key_info() {
    [[ -n "${ALIAS}" ]] || die "--alias is required"
    local raw entry
    raw="$(_api GET '/key/list?return_full_object=true')" || _api_fail "key/list"
    entry="$(printf '%s' "${raw}" | jq -c --arg a "${ALIAS}" \
        'first(.keys[]? | select(.key_alias == $a)) // empty')"

    if [[ -z "${entry}" ]]; then
        info "key '${ALIAS}' does not exist on ${LITELLM_HOST}"
        return 1
    fi
    printf '%s' "${entry}" | jq '{
        key_alias, team_id, spend, max_budget, expires, created_at, blocked
    }'
}

# ── Main ──────────────────────────────────────────────────────────────────
case "${ENTITY}:${VERB}" in
    key:list)   cmd_key_list ;;
    key:info)   cmd_key_info ;;
    key:*)      die "unknown verb 'key ${VERB}' (expected: list | info)" ;;
    *:list)     cmd_list ;;
    *:new)      cmd_new ;;
    *:info)     cmd_info ;;
    *:delete)   cmd_delete ;;
    *) die "unknown verb: ${VERB} (expected: list | new | info | delete, or key list|info)" ;;
esac
