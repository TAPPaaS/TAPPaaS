# TAPPaaS Forgejo — what forgejo's services share (sourced, not run)
#
# forgejo:repo and forgejo:oauth both act in Forgejo through its API, as one
# local Forgejo user, tappaas-sites (no admin rights). Its token stays on
# tappaas-cicd (/home/tappaas/secrets/forgejo-sites.token) with the scopes it
# was made with beside it; a token missing a scope a service needs is replaced.
#
#   fsvc_init <consuming-module>   CONSUMING_*, PROVIDER_*, FORGEJO_HOST, API
#   fsvc_wait                      Forgejo's API answers (180 s)
#   fsvc_token                     TOKEN, valid and with every scope
#   fsvc_api <method> <path> [json] the body on stdout; non-zero on non-2xx
#   fsvc_root_url                  Forgejo's ROOT_URL, without the trailing /
#   forgejo_run / consumer_run     bash -s on Forgejo's / the consumer's VM
#
# Expects common-install-routines.sh to be sourced first.

FSVC_USER="tappaas-sites"
FSVC_TOKEN_FILE="/home/tappaas/secrets/forgejo-sites.token"
# Every scope any forgejo service needs: one token serves them all.
FSVC_SCOPES="write:organization,write:repository,write:user"
FSVC_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

fsvc_init() {
    CONSUMING_MODULE="$1"
    CONSUMING_JSON="${CONFIG_DIR}/${CONSUMING_MODULE}.json"
    [[ -f "${CONSUMING_JSON}" ]] || die "consuming module config not found: ${CONSUMING_JSON}"
    CONSUMING_VMNAME="$(jq -r '.vmname' "${CONSUMING_JSON}")"
    CONSUMING_ZONE="$(jq -r '.zone0' "${CONSUMING_JSON}")"
    CONSUMING_ENV="$(jq -r '.environment // ""' "${CONSUMING_JSON}")"
    CONSUMING_HOST="${CONSUMING_VMNAME}.${CONSUMING_ZONE}.internal"
    PROVIDER_MODULE="$(resolve_provider_module "forgejo" "${CONSUMING_ENV}")"
    PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
    [[ -f "${PROVIDER_JSON}" ]] || die "forgejo provider config not found: ${PROVIDER_JSON} (is ${PROVIDER_MODULE} installed?)"
    FORGEJO_ZONE="$(jq -r '.zone0' "${PROVIDER_JSON}")"
    FORGEJO_HOST="$(jq -r '.vmname' "${PROVIDER_JSON}").${FORGEJO_ZONE}.internal"
    API="http://${FORGEJO_HOST}:3000/api/v1"
}

forgejo_run() { ssh "${FSVC_SSH_OPTS[@]}" "tappaas@${FORGEJO_HOST}" 'bash -s' "$@"; }
consumer_run() { ssh "${FSVC_SSH_OPTS[@]}" "tappaas@${CONSUMING_HOST}" 'bash -s' "$@"; }

# A Forgejo that is still starting (a sweep restarts it) answers in a moment.
fsvc_wait() {
    local _i
    for _i in $(seq 1 36); do
        curl -sf --max-time 5 "${API}/version" >/dev/null && return 0
        sleep 5
    done
    die "Forgejo's API at ${API} did not answer within 180s"
}

fsvc_api() {
    local method="$1" path="$2" body code
    local -a data=()
    [[ -n "${3:-}" ]] && data=(--data-raw "$3")
    body="$(mktemp)"
    code="$(curl -s -o "${body}" -w '%{http_code}' --max-time 20 -X "${method}" \
        -H "Authorization: token ${TOKEN}" -H 'Content-Type: application/json' \
        "${data[@]}" "${API}${path}")" || code=000
    cat "${body}"; rm -f "${body}"
    [[ "${code}" == 2* ]]
}

fsvc_token() {
    TOKEN=""
    [[ -s "${FSVC_TOKEN_FILE}" ]] && TOKEN="$(cat "${FSVC_TOKEN_FILE}")"
    if [[ -n "${TOKEN}" && "$(cat "${FSVC_TOKEN_FILE}.scopes" 2>/dev/null)" == "${FSVC_SCOPES}" ]] \
       && fsvc_api GET /user >/dev/null 2>&1; then
        return 0
    fi
    info "  Creating the API token of ${FSVC_USER} on ${FORGEJO_HOST} (${FSVC_SCOPES})"
    TOKEN="$(forgejo_run <<EOSH
set -euo pipefail
if ! sudo forgejo-admin admin user list | awk 'NR>1 {print \$2}' | grep -qx '${FSVC_USER}'; then
    sudo forgejo-admin admin user create --username '${FSVC_USER}' --email '${FSVC_USER}@tappaas.invalid' \
        --fullname 'TAPPaaS' --random-password --must-change-password=false >/dev/null
fi
sudo forgejo-admin admin user generate-access-token --username '${FSVC_USER}' --token-name "tappaas-\$(date +%s)" \
    --scopes '${FSVC_SCOPES}' --raw
EOSH
)" || die "could not create the API token of ${FSVC_USER} on ${FORGEJO_HOST}"
    [[ -n "${TOKEN}" ]] || die "Forgejo returned an empty token"
    install -d -m 0700 "$(dirname "${FSVC_TOKEN_FILE}")"
    ( umask 077; printf '%s' "${TOKEN}" > "${FSVC_TOKEN_FILE}"; printf '%s' "${FSVC_SCOPES}" > "${FSVC_TOKEN_FILE}.scopes" )
    fsvc_api GET /user >/dev/null || die "the new token of ${FSVC_USER} is refused by ${API}"
}

# The address Forgejo builds its links and OAuth endpoints from.
fsvc_root_url() {
    local u
    u="$(forgejo_run <<'EOSH'
sudo sed -n 's/^ROOT_URL *= *//p' /var/lib/forgejo/custom/conf/app.ini | head -1
EOSH
)" || return 1
    [[ -n "${u}" ]] || return 1
    printf '%s' "${u%/}"
}
