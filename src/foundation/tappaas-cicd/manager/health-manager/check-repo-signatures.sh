#!/usr/bin/env bash
#
# check-repo-signatures.sh — the signing status of every repository the site
# tracks (ADR-033 D10).
#
# For each repository in site.json it reads what the checkout RUNS — nothing is
# fetched or moved — and says one of:
#
#   verified            HEAD is exactly a release tag, signed by a key the last
#                       verified release lists, and its tree hash matches
#   unsigned-unstable   the branch is unstable (or the repository declares no
#                       channels): nothing is signed there, by design (D1)
#   unsigned-declared   the repository lists no signing keys (D9)
#   ahead-of-release    on a signed channel, but HEAD is past the last verified
#                       release, or the tree has uncommitted changes — the code
#                       running is not what was released (ADR-028 D12 drift)
#   failed              on a signed channel, and HEAD is not a verified release
#
# plus, for any status, the signing keys whose valid-before falls within
# EXPIRY_DAYS (default 60).
#
# Writes ${CONFIG_DIR}/sbom/signatures.json — the evidence an operator hands an
# auditor — and mails the site owner (site-notify.sh) when a repository's status
# CHANGES, never on a run where nothing did. The `signature-status` gate in
# `health-manager validate` reads the file.
#
# Runs at the end of refresh-control-plane.sh, i.e. after every repository sync.
# Exit: 0 written (whatever the statuses), 1 no site.json.
#
# Tests: TAPPAAS_CONFIG_DIR for config/, REPO_SYNC_TRUST_DIR for the trust record,
# TAPPAAS_SITE_NOTIFY for the mailer, FAKE_NOW (epoch) for the clock.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB="${HERE}/../../lib"
CONFIG="${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"
SITE="${CONFIG}/site.json"
OUT_DIR="${CONFIG}/sbom"
OUT="${OUT_DIR}/signatures.json"
TRUST="${REPO_SYNC_TRUST_DIR:-${CONFIG}/.trust}"
EXPIRY_DAYS="${EXPIRY_DAYS:-60}"
NOW="${FAKE_NOW:-$(date +%s)}"
NOTIFY="${TAPPAAS_SITE_NOTIFY:-${HERE}/../../scripts/site-notify.sh}"

info() { echo "$*"; }; warn() { echo "WARN: $*" >&2; }; error() { echo "ERROR: $*" >&2; }
# shellcheck source=../../lib/channels-lib.sh
. "${LIB}/channels-lib.sh"
# shellcheck source=../../lib/verify-repo.sh
. "${LIB}/verify-repo.sh"
# What a checkout already runs is judged by the date its tag was signed: a
# release signed while its key was valid stays verified after the key expires.
# (A site MOVING to a release is checked against today — lib/repo-sync.sh.)
VERIFY_AT=tag

[[ -r "${SITE}" ]] || { error "no site.json at ${SITE}"; exit 1; }

# expiring_keys <signers-file> — `<principal> <yyyymmdd>` for each key whose
# valid-before is within EXPIRY_DAYS (or already past).
expiring_keys() {
    local limit; limit="$(date -u -d "@$(( NOW + EXPIRY_DAYS * 86400 ))" +%Y%m%d 2>/dev/null \
        || date -u -r "$(( NOW + EXPIRY_DAYS * 86400 ))" +%Y%m%d)"
    grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null \
        | sed -n 's/^\([^ ]*\) .*valid-before="\{0,1\}\([0-9]\{8\}\).*/\1 \2/p' \
        | while read -r who until; do [[ "${until}" -le "${limit}" ]] && echo "${who} ${until}"; done
}

# status_of <name> <branch> <path> — one JSON object for the repository.
status_of() {
    local name="$1" branch="$2" path="$3" channel head base rc=0 status reason="" tag="" signer=""
    local last expiring="[]" f
    if [[ -z "${path}" || ! -d "${path}/.git" ]]; then
        jq -n --arg n "${name}" --arg b "${branch}" --arg p "${path}" \
            '{name:$n, branch:$b, path:$p, status:"failed", reason:"no git checkout at the path"}'
        return
    fi
    channel="$(branch_channel "${path}" "${branch}")"
    head="$(git -C "${path}" rev-parse -q --verify HEAD 2>/dev/null)"
    base="$(verify_base "${path}" "${TRUST}" "${name}")"
    last="$(verify_state_commit "${TRUST}" "${name}")"
    f="$(mktemp)"
    if verify_signers_at "${path}" "${base:-HEAD}" "${f}"; then
        expiring="$(expiring_keys "${f}" | jq -R 'split(" ") | {principal: .[0], validBefore: .[1]}' | jq -s .)"
    fi
    rm -f "${f}"
    case "${channel}" in
        staging|production)
            verify_target "${path}" "${head}" "${base:-${head}}" || rc=$?
            case "${rc}" in
                0) status="verified" tag="${VERIFY_TAG}" signer="${VERIFY_SIGNER}"
                   if [[ -n "$(git -C "${path}" status --porcelain 2>/dev/null)" ]]; then
                       status="ahead-of-release" reason="uncommitted changes on top of ${VERIFY_TAG}"
                   fi ;;
                4) status="unsigned-declared" reason="${VERIFY_REASON}" ;;
                *) if [[ -n "${last}" ]] && verify_moves_forward "${path}" "${last}" "${head}"; then
                       status="ahead-of-release"
                       reason="$(git -C "${path}" rev-list --count "${last}..${head}") commit(s) past the last verified release"
                   else
                       status="failed" reason="${VERIFY_REASON}"
                   fi ;;
            esac ;;
        *) status="unsigned-unstable" reason="'${branch}' is ${channel:-not a declared channel}" ;;
    esac
    jq -n --arg n "${name}" --arg b "${branch}" --arg p "${path}" --arg c "${channel:-}" \
          --arg s "${status}" --arg r "${reason}" --arg t "${tag}" --arg g "${signer}" \
          --arg h "${head}" --arg l "${last}" --argjson e "${expiring}" \
        '{name:$n, branch:$b, path:$p, channel:$c, status:$s, commit:$h}
         + (if $t != "" then {tag:$t} else {} end)
         + (if $g != "" then {signer:($g|split(" ")[0]), key:($g|split(" ")[1])} else {} end)
         + (if $l != "" then {lastVerified:$l} else {} end)
         + (if $r != "" then {reason:$r} else {} end)
         + {expiringKeys:$e}'
}

repos="[]"
while IFS=$'\t' read -r name branch path; do
    [[ -n "${name}" ]] || continue
    repos="$(jq --argjson r "$(status_of "${name}" "${branch}" "${path}")" '. + [$r]' <<<"${repos}")"
done < <(site_repos "${SITE}")

mkdir -p "${OUT_DIR}"
prev="$(cat "${OUT}" 2>/dev/null || echo '{}')"
tmp="$(mktemp "${OUT_DIR}/.signatures.XXXXXX")"
jq -n --argjson r "${repos}" --arg at "$(date -u -d "@${NOW}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${NOW}" +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson req "$(jq '.requireSigned // false' "${SITE}")" \
    '{generated:$at, requireSigned:$req, repositories:$r}' >"${tmp}" && mv "${tmp}" "${OUT}"

# One line per repository for the journal; a changed status is mailed.
jq -r '.repositories[] | "  \(.name): \(.status)\(if .tag then " \(.tag)" else "" end)\(if .reason then " — \(.reason)" else "" end)"' "${OUT}"
changes="$(jq -rn --argjson old "${prev}" --slurpfile new "${OUT}" '
    ($old.repositories // [] | map({(.name): .status}) | add // {}) as $o
    | $new[0].repositories[]
    | select(($o[.name] // "new") != .status)
    | "\(.name): \($o[.name] // "first check") -> \(.status)\(if .reason then " (\(.reason))" else "" end)"')"
expiring="$(jq -r '.repositories[] | .name as $n | .expiringKeys[] | "\($n): key \(.principal) valid until \(.validBefore)"' "${OUT}")"
if [[ -n "${changes}" ]] && [[ "${prev}" != "{}" ]]; then
    info "tappaas-repo-signature-changed: $(paste -sd';' <<<"${changes}")"
    if [[ -x "${NOTIFY}" ]]; then
        { echo "The signing status of a repository this site runs has changed (ADR-033):"
          echo; sed 's/^/  /' <<<"${changes}"
          [[ -n "${expiring}" ]] && { echo; echo "Signing keys about to expire:"; sed 's/^/  /' <<<"${expiring}"; }
          echo; echo "Look at:"; echo "  health-manager validate      (the signature-status gate)"; echo "  ${OUT}"
        } | "${NOTIFY}" --what "signature notice" --subject "repository signing status changed" >/dev/null 2>&1 \
            || warn "could not mail the signature notice"
    fi
fi
exit 0
