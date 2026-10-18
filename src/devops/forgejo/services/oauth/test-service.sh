#!/usr/bin/env bash
#
# TAPPaaS Forgejo OAuth Service — Test
#
#   1. the application tappaas-<consumer> exists, confidential
#   2. the consumer has /etc/secrets/forgejo-oauth.env
#   3. Forgejo accepts the consumer's client id and secret (a token request
#      with a made-up code is refused as invalid_grant, not as a bad client)
#
# Usage: test-service.sh <consuming-module-name>

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../service-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../service-lib.sh"

[[ -n "${1:-}" ]] || die "Usage: $0 <consuming-module-name>"
fsvc_init "$1"
APP="tappaas-${CONSUMING_VMNAME}"
FAILED=0
ok()  { info "  ${GN}✓${CL} $1"; }
bad() { error "  ✗ $1"; FAILED=$((FAILED + 1)); }

info "${BOLD}forgejo:oauth for ${CONSUMING_MODULE}${CL}"
TOKEN="$(cat "${FSVC_TOKEN_FILE}" 2>/dev/null)"
CUR="$(fsvc_api GET "/user/applications/oauth2?limit=50" 2>/dev/null | jq -c --arg n "${APP}" '[.[] | select(.name == $n)] | first // empty' 2>/dev/null)"
[[ -n "${CUR}" && "$(jq -r .confidential_client <<<"${CUR}")" == "true" ]] \
    && ok "OAuth2 application ${APP}: $(jq -r '.redirect_uris | join(", ")' <<<"${CUR}")" \
    || bad "no confidential OAuth2 application ${APP} in Forgejo"

ENVF="$(consumer_run <<<'sudo cat /etc/secrets/forgejo-oauth.env' 2>/dev/null)"
ID="$(sed -n 's/^FORGEJO_CLIENT_ID=//p' <<<"${ENVF}")"
SECRET="$(sed -n 's/^FORGEJO_CLIENT_SECRET=//p' <<<"${ENVF}")"
[[ -n "${ID}" && -n "${SECRET}" ]] && ok "${CONSUMING_HOST} has /etc/secrets/forgejo-oauth.env" \
    || bad "/etc/secrets/forgejo-oauth.env missing or incomplete on ${CONSUMING_HOST}"
[[ -n "${CUR}" && "${ID}" == "$(jq -r .client_id <<<"${CUR}")" ]] && ok "its client id is the application's" \
    || bad "the client id on ${CONSUMING_HOST} is not the application's"

_err="$(curl -s --max-time 15 -X POST "http://${FORGEJO_HOST}:3000/login/oauth/access_token" \
        --data-urlencode grant_type=authorization_code --data-urlencode code=tappaas-test \
        --data-urlencode "client_id=${ID}" --data-urlencode "client_secret=${SECRET}" \
        --data-urlencode "redirect_uri=$(jq -r '.redirect_uris[0] // empty' <<<"${CUR}")" | jq -r '.error // empty' 2>/dev/null)"
[[ "${_err}" == "invalid_grant" ]] && ok "Forgejo accepts the client's secret (a made-up code is refused as invalid_grant)" \
    || bad "Forgejo refuses the client itself (${_err:-no answer}) — the secret on ${CONSUMING_HOST} is stale"

[[ ${FAILED} -eq 0 ]]
