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
# The repository and the organisation belong to the local Forgejo user the
# forgejo services act as (service-lib.sh). The consumer pulls over SSH
# (pinhole.json: TCP 22 from the consumer to Forgejo).
#
# Idempotent. Called by install-module.sh / update-module.sh when a module
# declares dependsOn ["forgejo:repo"].
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
mapfile -t EDITORS < <(jq -r '.config["forgejo:repo"].repoEditors // [] | .[]' "${CONSUMING_JSON}")

ORG="websites"
REPO="${CONSUMING_VMNAME}"
KEY_TITLE="tappaas-${CONSUMING_VMNAME}"

info "${BOLD}forgejo:repo install-service${CL}: wiring ${BL}${CONSUMING_MODULE}${CL}"
info "  repository: ${ORG}/${REPO} on ${FORGEJO_HOST}   consumer: ${CONSUMING_HOST}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would ensure ${ORG}/${REPO}, a read-only deploy key from ${CONSUMING_HOST}, and /etc/secrets/forgejo-repo.* there"
    exit 0
fi

fsvc_wait
fsvc_token

# ── Organisation and repository ───────────────────────────────────────────────
if ! fsvc_api GET "/orgs/${ORG}" >/dev/null 2>&1; then
    fsvc_api POST /orgs "$(jq -nc --arg o "${ORG}" '{username: $o, full_name: "Websites", visibility: "private",
        description: "Content of the sites TAPPaaS publishes"}')" >/dev/null \
        || die "could not create the organisation ${ORG}"
    info "  ${GN}✓${CL} organisation ${ORG} created"
fi
if REPO_JSON="$(fsvc_api GET "/repos/${ORG}/${REPO}" 2>/dev/null)"; then
    info "  ${GN}✓${CL} repository ${ORG}/${REPO} exists"
else
    REPO_JSON="$(fsvc_api POST "/orgs/${ORG}/repos" "$(jq -nc --arg r "${REPO}" '{name: $r, private: true,
        auto_init: false, default_branch: "main", description: "Website content: Markdown pages, served as HTML"}')")" \
        || die "could not create ${ORG}/${REPO}"
    STARTER="$(printf '%s\n' '---' 'title: Welcome' '---' '' '# Welcome' '' \
        'This page is `index.md` in this site'"'"'s Forgejo repository. Edit it, commit, and the site shows the' \
        'new text within a minute. Every `.md` file is a page: `about.md` is `/about`.' | base64 -w0)"
    fsvc_api POST "/repos/${ORG}/${REPO}/contents/index.md" "$(jq -nc --arg c "${STARTER}" \
        '{content: $c, message: "Starter page", branch: "main"}')" >/dev/null \
        || die "could not write the starter page into ${ORG}/${REPO}"
    REPO_JSON="$(fsvc_api GET "/repos/${ORG}/${REPO}")"
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
KEYS="$(fsvc_api GET "/repos/${ORG}/${REPO}/keys")" || die "could not list the deploy keys of ${ORG}/${REPO}"
if [[ "$(jq -r --arg t "${KEY_TITLE}" --arg k "${PUBKEY_BARE}" \
        '[.[] | select(.title == $t and (.key | split(" ") | .[0:2] | join(" ")) == $k and .read_only)] | length' <<<"${KEYS}")" == "0" ]]; then
    for id in $(jq -r --arg t "${KEY_TITLE}" '.[] | select(.title == $t) | .id' <<<"${KEYS}"); do
        fsvc_api DELETE "/repos/${ORG}/${REPO}/keys/${id}" >/dev/null || true
    done
    fsvc_api POST "/repos/${ORG}/${REPO}/keys" "$(jq -nc --arg t "${KEY_TITLE}" --arg k "${PUBKEY_BARE}" \
        '{title: $t, key: $k, read_only: true}')" >/dev/null || die "could not add the deploy key to ${ORG}/${REPO}"
    info "  ${GN}✓${CL} read-only deploy key ${KEY_TITLE} added"
else
    info "  ${GN}✓${CL} read-only deploy key ${KEY_TITLE} in place"
fi

# ── Editors ───────────────────────────────────────────────────────────────────
for who in "${EDITORS[@]}"; do
    if ! fsvc_api GET "/users/${who}" >/dev/null 2>&1; then
        warn "  ${who} has no Forgejo account yet (signs in once with Authentik first) — added on a later update"
        continue
    fi
    fsvc_api PUT "/repos/${ORG}/${REPO}/collaborators/${who}" '{"permission":"write"}' >/dev/null \
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
