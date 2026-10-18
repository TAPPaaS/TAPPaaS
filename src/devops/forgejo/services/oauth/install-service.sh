#!/usr/bin/env bash
#
# TAPPaaS Forgejo OAuth Service — Install
#
# Lets a consuming module sign its users in with Forgejo (OAuth2): people sign
# in to the consumer with their Forgejo account, which is their Authentik one.
#
#   - an OAuth2 application tappaas-<consumer vmname> in Forgejo, confidential,
#     whose redirect URIs are the consumer's address + its oauthRedirectPaths;
#   - /etc/secrets/forgejo-oauth.env on the consumer's VM: FORGEJO_URL (the
#     address Forgejo builds its links from), FORGEJO_CLIENT_ID and
#     FORGEJO_CLIENT_SECRET.
#
# The consumer's address is its published name (https) when the proxy serves
# it, else <vmname>.<zone>.internal:<proxyPort>; a name published later moves
# the redirect URIs on the next update. Forgejo shows a secret only once: it is
# kept on tappaas-cicd (/home/tappaas/secrets/forgejo-oauth-<vmname>.env), and
# a lost one is replaced by a new one.
#
# Idempotent. Called by install-module.sh / update-module.sh when a module
# declares dependsOn ["forgejo:oauth"].
#
# Usage: install-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../service-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../service-lib.sh"

DRY_RUN=0
CONSUMING_MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force) shift ;;   # ADR-020 D8: nothing here needs downtime
        -*) die "unknown option: $1" ;;
        *) if [[ -z "${CONSUMING_MODULE}" ]]; then CONSUMING_MODULE="$1"; shift
           else die "unexpected argument: $1"; fi ;;
    esac
done
[[ -n "${CONSUMING_MODULE}" ]] || die "Usage: $0 <consuming-module-name> [--dry-run]"

fsvc_init "${CONSUMING_MODULE}"
APP="tappaas-${CONSUMING_VMNAME}"
STORE="/home/tappaas/secrets/forgejo-oauth-${CONSUMING_VMNAME}.env"
mapfile -t PATHS < <(jq -r '.config["forgejo:oauth"].oauthRedirectPaths // [] | .[]' "${CONSUMING_JSON}")
[[ ${#PATHS[@]} -gt 0 ]] || die "${CONSUMING_MODULE} declares no forgejo:oauth.oauthRedirectPaths — where Forgejo may send a signed-in user back to"

# The consumer's address: its published name when the proxy serves it.
DOMAIN="$(module_public_domain "${CONSUMING_VMNAME}" "${CONSUMING_ENV}" "$(cat "${CONSUMING_JSON}")")"
PUB_RC=3
if [[ -n "${DOMAIN}" ]]; then
    network-manager split-horizon-target "${DOMAIN}" >/dev/null 2>&1 && PUB_RC=0 || PUB_RC=$?
fi
if [[ -n "${DOMAIN}" && ( ${PUB_RC} -eq 0 || ${PUB_RC} -eq 1 ) ]]; then
    BASE="https://${DOMAIN}"
else
    BASE="http://${CONSUMING_HOST}:$(jq -r '.config["network:proxy"].proxyPort // 80' "${CONSUMING_JSON}")"
fi
URIS="$(printf '%s\n' "${PATHS[@]}" | jq -R --arg b "${BASE}" '$b + .' | jq -sc .)"

info "${BOLD}forgejo:oauth install-service${CL}: wiring ${BL}${CONSUMING_MODULE}${CL}"
info "  application: ${APP} on ${FORGEJO_HOST}   redirect: $(jq -r 'join(", ")' <<<"${URIS}")"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would ensure the OAuth2 application ${APP} and /etc/secrets/forgejo-oauth.env on ${CONSUMING_HOST}"
    exit 0
fi

fsvc_wait
fsvc_token
ROOT_URL="$(fsvc_root_url)" || die "could not read Forgejo's ROOT_URL on ${FORGEJO_HOST}"

# ── The application ──────────────────────────────────────────────────────────
APPS="$(fsvc_api GET "/user/applications/oauth2?limit=50")" || die "could not list the OAuth2 applications of ${FSVC_USER}"
CUR="$(jq -c --arg n "${APP}" '[.[] | select(.name == $n)] | first // empty' <<<"${APPS}")"
STORED_ID="$(sed -n 's/^FORGEJO_CLIENT_ID=//p' "${STORE}" 2>/dev/null || true)"
BODY="$(jq -nc --arg n "${APP}" --argjson u "${URIS}" '{name: $n, redirect_uris: $u, confidential_client: true}')"
if [[ -z "${CUR}" ]]; then
    NEW="$(fsvc_api POST /user/applications/oauth2 "${BODY}")" || die "could not create the OAuth2 application ${APP}"
    info "  ${GN}✓${CL} OAuth2 application ${APP} created"
elif [[ "$(jq -r .client_id <<<"${CUR}")" != "${STORED_ID}" \
        || "$(jq -c '.redirect_uris | sort' <<<"${CUR}")" != "$(jq -c 'sort' <<<"${URIS}")" ]]; then
    # A changed address, or a secret not kept here: updating an application
    # gives it a new secret, which is then written below.
    NEW="$(fsvc_api PATCH "/user/applications/oauth2/$(jq -r .id <<<"${CUR}")" "${BODY}")" \
        || die "could not update the OAuth2 application ${APP}"
    info "  ${GN}✓${CL} OAuth2 application ${APP} updated (redirect URIs, new secret)"
else
    NEW=""
    info "  ${GN}✓${CL} OAuth2 application ${APP} in place"
fi
if [[ -n "${NEW}" ]]; then
    ID="$(jq -r '.client_id // empty' <<<"${NEW}")"; SECRET="$(jq -r '.client_secret // empty' <<<"${NEW}")"
    [[ -n "${ID}" && -n "${SECRET}" ]] || die "Forgejo returned no client id or secret for ${APP}"
    install -d -m 0700 "$(dirname "${STORE}")"
    ( umask 077; printf 'FORGEJO_CLIENT_ID=%s\nFORGEJO_CLIENT_SECRET=%s\n' "${ID}" "${SECRET}" > "${STORE}" )
fi
ID="$(sed -n 's/^FORGEJO_CLIENT_ID=//p' "${STORE}")"
SECRET="$(sed -n 's/^FORGEJO_CLIENT_SECRET=//p' "${STORE}")"

# ── What the consumer needs ──────────────────────────────────────────────────
consumer_run <<EOSH || die "could not write /etc/secrets/forgejo-oauth.env on ${CONSUMING_HOST}"
set -euo pipefail
[ -d /etc/secrets ] || sudo install -d -m 700 /etc/secrets
t=\$(sudo mktemp /etc/secrets/.forgejo-oauth.XXXXXX)
printf 'FORGEJO_URL=%s\nFORGEJO_CLIENT_ID=%s\nFORGEJO_CLIENT_SECRET=%s\n' '${ROOT_URL}' '${ID}' '${SECRET}' | sudo tee "\$t" >/dev/null
sudo chmod 600 "\$t"
if sudo cmp -s "\$t" /etc/secrets/forgejo-oauth.env; then sudo rm -f "\$t"; else sudo mv -f "\$t" /etc/secrets/forgejo-oauth.env; fi
EOSH
info "  ${GN}✓${CL} /etc/secrets/forgejo-oauth.env on ${CONSUMING_HOST}"

info ""
info "  ${GN}${BOLD}✓ forgejo:oauth wired for ${CONSUMING_MODULE}${CL}"
info "    Forgejo     : ${ROOT_URL}"
info "    Application : ${APP} (client ${ID})"
