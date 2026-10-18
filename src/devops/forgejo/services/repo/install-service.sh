#!/usr/bin/env bash
#
# TAPPaaS Forgejo Repo Service — Install
#
# Gives a consuming module a Forgejo repository its content lives in, and lets
# the consumer's VM read it:
#
#   - the repository websites/<consumer vmname>, private, created on the first
#     install with a starter index.md (never overwritten after that);
#   - a read-only deploy key: the key pair is made on the consumer's VM
#     (/etc/secrets/forgejo-repo.key), only its public half leaves it;
#   - /etc/secrets/forgejo-repo.env (REPO_SSH_URL, REPO_WEB_URL, REPO_BRANCH)
#     and /etc/secrets/forgejo-repo.known_hosts (Forgejo's host key) on the
#     consumer's VM;
#   - write access for the people in the consumer's repoEditors field.
#
# The repository and the organisation belong to a local Forgejo user,
# tappaas-sites (no admin rights); its API token stays on tappaas-cicd
# (/home/tappaas/secrets/forgejo-sites.token). The consumer pulls over SSH
# (pinhole.json: TCP 22 from the consumer to Forgejo).
#
# Idempotent. Called by install-module.sh / update-module.sh when a module
# declares dependsOn ["forgejo:repo"].
#
# Usage: install-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

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

CONSUMING_JSON="${CONFIG_DIR}/${CONSUMING_MODULE}.json"
[[ -f "${CONSUMING_JSON}" ]] || die "consuming module config not found: ${CONSUMING_JSON}"
CONSUMING_VMNAME="$(jq -r '.vmname' "${CONSUMING_JSON}")"
CONSUMING_ZONE="$(jq -r '.zone0' "${CONSUMING_JSON}")"
CONSUMING_ENV="$(jq -r '.environment // ""' "${CONSUMING_JSON}")"
CONSUMING_HOST="${CONSUMING_VMNAME}.${CONSUMING_ZONE}.internal"
mapfile -t EDITORS < <(jq -r '.config["forgejo:repo"].repoEditors // [] | .[]' "${CONSUMING_JSON}")

PROVIDER_MODULE="$(resolve_provider_module "forgejo" "${CONSUMING_ENV}")"
PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
[[ -f "${PROVIDER_JSON}" ]] || die "forgejo provider config not found: ${PROVIDER_JSON} (is ${PROVIDER_MODULE} installed?)"
FORGEJO_HOST="$(jq -r '.vmname' "${PROVIDER_JSON}").$(jq -r '.zone0' "${PROVIDER_JSON}").internal"
API="http://${FORGEJO_HOST}:3000/api/v1"

ORG="websites"
REPO="${CONSUMING_VMNAME}"
SVC_USER="tappaas-sites"
KEY_TITLE="tappaas-${CONSUMING_VMNAME}"
TOKEN_FILE="/home/tappaas/secrets/forgejo-sites.token"

info "${BOLD}forgejo:repo install-service${CL}: wiring ${BL}${CONSUMING_MODULE}${CL}"
info "  repository: ${ORG}/${REPO} on ${FORGEJO_HOST}   consumer: ${CONSUMING_HOST}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would ensure ${ORG}/${REPO}, a read-only deploy key from ${CONSUMING_HOST}, and /etc/secrets/forgejo-repo.* there"
    exit 0
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)
forgejo_run() { ssh "${SSH_OPTS[@]}" "tappaas@${FORGEJO_HOST}" 'bash -s' "$@"; }
consumer_run() { ssh "${SSH_OPTS[@]}" "tappaas@${CONSUMING_HOST}" 'bash -s' "$@"; }

# A Forgejo that is still starting (a sweep restarts it) answers in a moment.
for _i in $(seq 1 36); do
    curl -sf --max-time 5 "${API}/version" >/dev/null && break
    [[ ${_i} -eq 36 ]] && die "Forgejo's API at ${API} did not answer within 180s"
    sleep 5
done

# ── The API token of tappaas-sites ────────────────────────────────────────────
# api <method> <path> [json] — prints the body, returns non-zero on a non-2xx.
api() {
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

TOKEN=""
[[ -s "${TOKEN_FILE}" ]] && TOKEN="$(cat "${TOKEN_FILE}")"
if [[ -z "${TOKEN}" ]] || ! api GET /user >/dev/null 2>&1; then
    info "  Creating the API token of ${SVC_USER} on ${FORGEJO_HOST}"
    TOKEN="$(forgejo_run <<EOSH
set -euo pipefail
if ! sudo forgejo-admin admin user list | awk 'NR>1 {print \$2}' | grep -qx '${SVC_USER}'; then
    sudo forgejo-admin admin user create --username '${SVC_USER}' --email '${SVC_USER}@tappaas.invalid' \
        --fullname 'TAPPaaS sites' --random-password --must-change-password=false >/dev/null
fi
sudo forgejo-admin admin user generate-access-token --username '${SVC_USER}' --token-name "tappaas-\$(date +%s)" \
    --scopes 'write:organization,write:repository,read:user' --raw
EOSH
)" || die "could not create the API token of ${SVC_USER} on ${FORGEJO_HOST}"
    [[ -n "${TOKEN}" ]] || die "Forgejo returned an empty token"
    install -d -m 0700 "$(dirname "${TOKEN_FILE}")"
    ( umask 077; printf '%s' "${TOKEN}" > "${TOKEN_FILE}" )
    api GET /user >/dev/null || die "the new token of ${SVC_USER} is refused by ${API}"
fi

# ── Organisation and repository ───────────────────────────────────────────────
if ! api GET "/orgs/${ORG}" >/dev/null 2>&1; then
    api POST /orgs "$(jq -nc --arg o "${ORG}" '{username: $o, full_name: "Websites", visibility: "private",
        description: "Content of the sites TAPPaaS publishes"}')" >/dev/null \
        || die "could not create the organisation ${ORG}"
    info "  ${GN}✓${CL} organisation ${ORG} created"
fi
if REPO_JSON="$(api GET "/repos/${ORG}/${REPO}" 2>/dev/null)"; then
    info "  ${GN}✓${CL} repository ${ORG}/${REPO} exists"
else
    REPO_JSON="$(api POST "/orgs/${ORG}/repos" "$(jq -nc --arg r "${REPO}" '{name: $r, private: true,
        auto_init: false, default_branch: "main", description: "Website content: Markdown pages, served as HTML"}')")" \
        || die "could not create ${ORG}/${REPO}"
    STARTER="$(printf '%s\n' '---' 'title: Welcome' '---' '' '# Welcome' '' \
        'This page is `index.md` in this site'"'"'s Forgejo repository. Edit it, commit, and the site shows the' \
        'new text within a minute. Every `.md` file is a page: `about.md` is `/about`.' | base64 -w0)"
    api POST "/repos/${ORG}/${REPO}/contents/index.md" "$(jq -nc --arg c "${STARTER}" \
        '{content: $c, message: "Starter page", branch: "main"}')" >/dev/null \
        || die "could not write the starter page into ${ORG}/${REPO}"
    REPO_JSON="$(api GET "/repos/${ORG}/${REPO}")"
    info "  ${GN}✓${CL} repository ${ORG}/${REPO} created with a starter page"
fi
SSH_URL="$(jq -r '.ssh_url' <<<"${REPO_JSON}")"
WEB_URL="$(jq -r '.html_url' <<<"${REPO_JSON}")"
BRANCH="$(jq -r '.default_branch // "main"' <<<"${REPO_JSON}")"

# ── The consumer's deploy key ─────────────────────────────────────────────────
PUBKEY="$(consumer_run <<EOSH
set -euo pipefail
[ -d /etc/secrets ] || sudo install -d -m 700 /etc/secrets
sudo test -s /etc/secrets/forgejo-repo.key || sudo ssh-keygen -q -t ed25519 -N '' -C '${KEY_TITLE}' -f /etc/secrets/forgejo-repo.key
sudo chmod 600 /etc/secrets/forgejo-repo.key
sudo cat /etc/secrets/forgejo-repo.key.pub
EOSH
)" || die "could not read or make the deploy key on ${CONSUMING_HOST}"
PUBKEY_BARE="$(awk '{print $1" "$2}' <<<"${PUBKEY}")"
KEYS="$(api GET "/repos/${ORG}/${REPO}/keys")" || die "could not list the deploy keys of ${ORG}/${REPO}"
if [[ "$(jq -r --arg t "${KEY_TITLE}" --arg k "${PUBKEY_BARE}" \
        '[.[] | select(.title == $t and (.key | split(" ") | .[0:2] | join(" ")) == $k and .read_only)] | length' <<<"${KEYS}")" == "0" ]]; then
    for id in $(jq -r --arg t "${KEY_TITLE}" '.[] | select(.title == $t) | .id' <<<"${KEYS}"); do
        api DELETE "/repos/${ORG}/${REPO}/keys/${id}" >/dev/null || true
    done
    api POST "/repos/${ORG}/${REPO}/keys" "$(jq -nc --arg t "${KEY_TITLE}" --arg k "${PUBKEY_BARE}" \
        '{title: $t, key: $k, read_only: true}')" >/dev/null || die "could not add the deploy key to ${ORG}/${REPO}"
    info "  ${GN}✓${CL} read-only deploy key ${KEY_TITLE} added"
else
    info "  ${GN}✓${CL} read-only deploy key ${KEY_TITLE} in place"
fi

# ── Editors ───────────────────────────────────────────────────────────────────
for who in "${EDITORS[@]}"; do
    if ! api GET "/users/${who}" >/dev/null 2>&1; then
        warn "  ${who} has no Forgejo account yet (signs in once with Authentik first) — added on a later update"
        continue
    fi
    api PUT "/repos/${ORG}/${REPO}/collaborators/${who}" '{"permission":"write"}' >/dev/null \
        && info "  ${GN}✓${CL} ${who} may edit ${ORG}/${REPO}" || warn "  could not add ${who} to ${ORG}/${REPO}"
done

# ── What the consumer needs to pull ──────────────────────────────────────────
SSH_HOST="$(sed -E 's/^[^@]+@([^:/]+).*/\1/' <<<"${SSH_URL}")"
HOSTKEY="$(forgejo_run <<'EOSH'
cat /etc/ssh/ssh_host_ed25519_key.pub
EOSH
)" || die "could not read Forgejo's host key"
consumer_run <<EOSH || die "could not write /etc/secrets/forgejo-repo.env on ${CONSUMING_HOST}"
set -euo pipefail
write() { local t; t=\$(sudo mktemp /etc/secrets/.forgejo-repo.XXXXXX); printf '%s\n' "\$2" | sudo tee "\$t" >/dev/null; sudo chmod 600 "\$t"
          if sudo cmp -s "\$t" "\$1"; then sudo rm -f "\$t"; else sudo mv -f "\$t" "\$1"; fi; }
write /etc/secrets/forgejo-repo.known_hosts '${SSH_HOST} $(awk '{print $1" "$2}' <<<"${HOSTKEY}")'
write /etc/secrets/forgejo-repo.env 'REPO_SSH_URL=${SSH_URL}
REPO_WEB_URL=${WEB_URL}
REPO_BRANCH=${BRANCH}'
EOSH
info "  ${GN}✓${CL} /etc/secrets/forgejo-repo.env on ${CONSUMING_HOST}"

info ""
info "  ${GN}${BOLD}✓ forgejo:repo wired for ${CONSUMING_MODULE}${CL}"
info "    Repository : ${WEB_URL}"
info "    Clone      : ${SSH_URL} (read-only from ${CONSUMING_HOST})"
