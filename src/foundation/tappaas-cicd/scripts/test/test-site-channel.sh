#!/usr/bin/env bash
#
# test-site-channel.sh — the release channel a site takes (ADR-028 D9).
#
# `channel` is a promise about risk; the branch a repository tracks is where the
# code sits. They are expected to agree, and the tooling warns rather than
# refuses when they do not — an operator moving a site between channels changes
# two things, and for a moment they disagree.
#
# Two moves are not warnings but gates, because both take a site BACKWARDS:
#
#   * towards production — older code. ADR-025 migrations are forward-only, so
#     a migration the site has already applied cannot be undone by switching
#     channel; the older code simply reads a config shape it does not know.
#   * onto a branch whose newest migration is older than the newest this site
#     has applied — the same fact, reached from the branch side.
#
# Both are allowed with --force. Neither happens by accident.
#
# Tabletop: fixtures and greps, no site touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="$(cd "${HERE}/../../manager/site-manager" 2>/dev/null && pwd)"
SCHEMA="$(cd "${HERE}/../../../schemas" 2>/dev/null && pwd)/site-fields.json"
[[ -n "${SM}" && -f "${SM}/repository.sh" && -f "${SCHEMA}" ]] || {
    echo "site-manager not found beside this suite — cannot run here."; exit 77; }

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "── the field exists, and says what it is ──"
if command -v jq >/dev/null 2>&1; then
    _vals="$(jq -r '.properties.channel.enum // [] | join(",")' "${SCHEMA}")"
    [[ "${_vals}" == "unstable,staging,production" ]] \
        && ok "schema enumerates unstable, staging, production (in risk order)" \
        || bad "schema enum is '${_vals}'"
    [[ "$(jq -r '.properties.channel.default' "${SCHEMA}")" == "production" ]] \
        && ok "a site defaults to production — the safe answer for a site nobody chose for" \
        || bad "channel does not default to production"
    # The rank order is load-bearing: "towards production" is what needs --force.
    _first="$(jq -r '.properties.channel.enum[0]' "${SCHEMA}")"
    [[ "${_first}" == "unstable" ]] \
        && ok "unstable ranks first, so 'towards production' is a well-defined direction" \
        || bad "enum order does not encode the direction"
else
    bad "jq not available"
fi

echo "── site modify: the option and its gate ──"
MAIN="${SM}/src/main.ts"
grep -q '"--channel <c>"' "${MAIN}" \
    && ok "site modify offers --channel" || bad "no --channel option in site modify"
grep -q 'rank(v) > rank(from)' "${MAIN}" \
    && ok "a move towards production is detected by rank, not by name" \
    || bad "no directional check on a channel change"
grep -q 'Re-run with --force if that is what you mean' "${MAIN}" \
    && ok "and is refused without --force, saying so" || bad "backwards move is not gated"
grep -q 'migrations (ADR-025) do not run backwards' "${MAIN}" \
    && ok "the refusal explains WHY, not just that it refused" \
    || bad "the refusal does not give the reason"
# The warning must not become a refusal: disagreement is a legitimate moment.
grep -q 'leaves them disagreeing\|but it tracks' "${MAIN}" "${SM}/repository.sh" \
    && ok "a channel/branch disagreement warns rather than refusing" \
    || bad "disagreement is not reported"

echo "── repository modify: branch vs channel, and the migration floor ──"
REPO="${SM}/repository.sh"
grep -q "channel is '\${_chan}', which expects branch" "${REPO}" \
    && ok "switching a branch warns when it leaves the channel behind" \
    || bad "branch switch does not check the channel"
grep -q 'name}" == "TAPPaaS"' "${REPO}" \
    && ok "only the TAPPaaS repository is held to the train's branches" \
    || bad "the channel check is applied to every repository"
grep -q 'git ls-tree -r --name-only "origin/\${new_branch}"' "${REPO}" \
    && ok "the target branch's migrations are read from the forge, without checking it out" \
    || bad "no migration check against the target branch"
grep -q 'Refusing to move a site behind its own migrations' "${REPO}" \
    && ok "a branch behind this site's migrations is refused without --force" \
    || bad "the migration floor is not enforced"
grep -q 'force}" != "true"' "${REPO}" \
    && ok "…and --force is what lifts it" || bad "--force does not lift the migration gate"

echo "── the two gates are gates, not refusals in disguise ──"
# Every gate must be passable: a release tool that cannot be overridden gets
# worked around with a text editor, which is worse.
for _needle in 'warn "  --force given: switching anyway' '--force given: setting the channel anyway'; do
    # `--` first: a needle that begins with -- is otherwise read as an option.
    grep -qF -- "${_needle}" "${REPO}" "${MAIN}" \
        && ok "override path exists and announces itself: ${_needle:0:34}…" \
        || bad "no override path for: ${_needle:0:34}…"
done

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
