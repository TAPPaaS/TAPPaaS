#!/usr/bin/env bash
#
# TAPPaaS Forgejo Repo Service — Test
#
#   1. the repository websites/<consumer> exists
#   2. the consumer's read-only deploy key is on it
#   3. the consumer has /etc/secrets/forgejo-repo.env and the host key
#   4. the consumer can read the repository over SSH (git ls-remote)
#
# Usage: test-service.sh <consuming-module-name>

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONSUMING_MODULE="${1:-}"
[[ -n "${CONSUMING_MODULE}" ]] || die "Usage: $0 <consuming-module-name>"
CONSUMING_JSON="${CONFIG_DIR}/${CONSUMING_MODULE}.json"
[[ -f "${CONSUMING_JSON}" ]] || die "consuming module config not found: ${CONSUMING_JSON}"
CONSUMING_VMNAME="$(jq -r '.vmname' "${CONSUMING_JSON}")"
CONSUMING_HOST="${CONSUMING_VMNAME}.$(jq -r '.zone0' "${CONSUMING_JSON}").internal"
PROVIDER_MODULE="$(resolve_provider_module "forgejo" "$(jq -r '.environment // ""' "${CONSUMING_JSON}")")"
PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
API="http://$(jq -r '.vmname' "${PROVIDER_JSON}").$(jq -r '.zone0' "${PROVIDER_JSON}").internal:3000/api/v1"
ORG="websites"; REPO="${CONSUMING_VMNAME}"; KEY_TITLE="tappaas-${CONSUMING_VMNAME}"
TOKEN_FILE="/home/tappaas/secrets/forgejo-sites.token"

FAILED=0
ok()  { info "  ${GN}✓${CL} $1"; }
bad() { error "  ✗ $1"; FAILED=$((FAILED + 1)); }

info "${BOLD}forgejo:repo for ${CONSUMING_MODULE}${CL}"
AUTH="Authorization: token $(cat "${TOKEN_FILE}" 2>/dev/null)"
curl -sf --max-time 15 -H "${AUTH}" "${API}/repos/${ORG}/${REPO}" >/dev/null \
    && ok "repository ${ORG}/${REPO} exists" || bad "repository ${ORG}/${REPO} not found (or the token in ${TOKEN_FILE} is refused)"
[[ "$(curl -sf --max-time 15 -H "${AUTH}" "${API}/repos/${ORG}/${REPO}/keys" \
      | jq -r --arg t "${KEY_TITLE}" '[.[] | select(.title == $t and .read_only)] | length' 2>/dev/null)" == "1" ]] \
    && ok "read-only deploy key ${KEY_TITLE} on it" || bad "no read-only deploy key ${KEY_TITLE} on ${ORG}/${REPO}"

remote() { ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes "tappaas@${CONSUMING_HOST}" "$@"; }
[[ "$(remote 'sudo test -s /etc/secrets/forgejo-repo.env && sudo test -s /etc/secrets/forgejo-repo.known_hosts && echo yes' 2>/dev/null)" == "yes" ]] \
    && ok "${CONSUMING_HOST} has /etc/secrets/forgejo-repo.env and Forgejo's host key" || bad "/etc/secrets/forgejo-repo.* missing on ${CONSUMING_HOST}"
remote 'url=$(sudo sed -n "s/^REPO_SSH_URL=//p" /etc/secrets/forgejo-repo.env)
        sudo GIT_SSH_COMMAND="ssh -i /etc/secrets/forgejo-repo.key -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/secrets/forgejo-repo.known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes" \
            git ls-remote "$url" HEAD' >/dev/null 2>&1 \
    && ok "${CONSUMING_HOST} reads the repository over SSH" || bad "${CONSUMING_HOST} cannot read the repository over SSH (pinhole to Forgejo port 22?)"

[[ ${FAILED} -eq 0 ]]
