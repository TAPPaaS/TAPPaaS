#!/usr/bin/env bash
#
# test-team-manager.sh — offline contract tests for litellm-team-manager.sh.
#
# These run without a LiteLLM host on purpose. The defect they cover was a
# REPORTING defect: `curl -sf` discarded the HTTP status, so every failure —
# including a host that answered 4xx — surfaced as "could not reach <host>".
# A live integration test would not have caught it, because the call really did
# fail; only the explanation was wrong. So the assertions bind to the two things
# that make the explanation right: the classification function, and the absence
# of the flag that destroyed the evidence.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TARGET="${SCRIPT_DIR}/litellm-team-manager.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS - $1"; else fail=$((fail+1)); echo "  FAIL - $1 (want '$3' got '$2')"; fi; }

echo "test-team-manager: offline contract"

# ── 1. the flag that hid the cause is gone ─────────────────────────────────
# -f makes curl exit non-zero and print NOTHING on HTTP >= 400. Its presence is
# the signature of the defect, so its absence is the regression guard.
# Code lines only — the WHY comment names the flag on purpose.
code() { grep -vE '^\s*#' "${TARGET}"; }
check "no 'curl -sf' remains in any call site" \
  "$(code | grep -c 'curl -sf' | tr -d ' ')" "0"
check "every remote curl reports its status" \
  "$(grep -c "http_code" "${TARGET}" | tr -d ' ')" "2"

# ── 2. failure classification ──────────────────────────────────────────────
# _api_fail is pure: given the API_FAIL_* globals it selects a message. Extract
# it and drive all three branches with a stubbed die, so a reworded message is
# free but a MISCLASSIFIED one is not.
LITELLM_HOST="litellm.example.internal"
die() { echo "$*"; }
# shellcheck disable=SC1090
eval "$(sed -n '/^_api_fail()/,/^}/p' "${TARGET}")"
# shellcheck disable=SC1090
eval "$(sed -n '/^_team_blockers()/,/^}/p' "${TARGET}")"

API_FAIL_KIND="transport"; API_FAIL_STATUS=""; API_FAIL_BODY=""
out="$(_api_fail 'team/delete')"
check "transport failure says unreachable" \
  "$(grep -c 'could not reach' <<< "${out}")" "1"

API_FAIL_KIND="http"; API_FAIL_STATUS="404"; API_FAIL_BODY='{"detail":"team not found"}'
out="$(_api_fail 'team/delete')"
check "an HTTP error does NOT say unreachable" \
  "$(grep -c 'could not reach' <<< "${out}")" "0"
check "...it names the status it received" \
  "$(grep -c '404' <<< "${out}")" "1"
check "...and quotes the response body" \
  "$(grep -c 'team not found' <<< "${out}")" "1"

API_FAIL_KIND="masterkey"; API_FAIL_STATUS=""; API_FAIL_BODY=""
out="$(_api_fail 'team/list')"
check "an empty master key is its own cause" \
  "$(grep -c 'LITELLM_MASTER_KEY' <<< "${out}")" "1"

# ── 3. the key entity ──────────────────────────────────────────────────────
check "dispatch routes 'key list'" \
  "$(grep -c 'key:list)' "${TARGET}" | tr -d ' ')" "1"
check "dispatch routes 'key info'" \
  "$(grep -c 'key:info)' "${TARGET}" | tr -d ' ')" "1"
check "the bare team verbs still dispatch" \
  "$(grep -cE '^[[:space:]]+\*:(list|new|info|delete)\)' "${TARGET}" | tr -d ' ')" "4"

# The key material must never reach a terminal or a log. /key/list returns
# .token — the handle the delete-service revokes by — so the projections name
# their fields explicitly rather than dumping the record.
# Narrowed after implementing key delete, which must READ the handle to revoke
# by it. The guarantee was always "the key material never reaches a terminal or
# a log" — the old form forbade reading, which is a different and wrong claim.
# Scoped to the two verbs that emit; key delete uses it only as a payload value.
for _f in cmd_key_list cmd_key_info; do
  check "no ${_f} projection emits .token" \
    "$(sed -n "/^${_f}()/,/^}/p" "${TARGET}" | grep -c '\.token')" "0"
done
# An EMISSION is a statement that begins with the emitting command. Matching
# "any line containing printf" also matched `token="$(...)"`, an assignment —
# the coarse form flagged safe code and would have licensed loosening the rule
# to shut it up.
check "key delete never echoes or logs the handle" \
  "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}" | grep -E '^[[:space:]]*(info|warn|error|echo|printf)\b' | grep -c 'token')" "0"

# ── 4. help reaches the user ───────────────────────────────────────────────
# --help arrives as $1, i.e. as the VERB, and used to be shifted away before the
# option loop could see it.
out="$(bash "${TARGET}" --help 2>&1)"
check "--help prints usage instead of dying" \
  "$(grep -q 'Usage:' <<< "${out}" && echo yes)" "yes"
check "...and does not die on an unknown verb" \
  "$(grep -c 'unknown verb' <<< "${out}")" "0"
check "...and documents the key entity" \
  "$(grep -q 'key list' <<< "${out}" && echo yes)" "yes"

# ── key delete: the orphan case the read-only design could not close ────────
# `key list`/`key info` were deliberately read-only: minting belongs to the
# installer that owns the consumer and revoking to its delete-service. That
# holds until the consumer is GONE — then no delete-service exists that could
# ever revoke the key, and an orphan is exactly what the read verbs exist to
# find. Measured 2026-08-20: a virtual key survived the teardown of both its
# consumer and its VM, and nothing on the manager surface could remove it.
check "dispatch routes 'key delete'" \
  "$(grep -c 'key:delete)' "${TARGET}" | tr -d ' ')" "1"

# --alias is checked before anything reaches the network, so this runs offline.
out="$(bash "${TARGET}" key delete 2>&1)"; rc=$?
check "key delete without --alias fails"              "${rc}" "1"
# Bound to the REASON, not just the exit code: an unknown verb also exits 1, so
# rc alone would have passed against a script with no key delete at all. It did,
# on the red-first run — the exact "checks the window while you meant the door"
# case the testing standard names.
check "...and fails for the missing flag, not an unknown verb" \
  "$(grep -c 'alias is required' <<< "${out}")" "1"

# The HITL gate is the point of a destructive verb: --yes must be an explicit
# opt-out, never the default, and the prompt must name what is about to go.
check "key delete confirms unless --yes is given" \
  "$(grep -c 'ASSUME_YES' <<< "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}")" | tr -d ' ')" "1"
check "...and the prompt names the alias" \
  "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}" | grep -c 'Delete key')" "1"

# It must refuse an alias that does not exist rather than reporting success on a
# no-op — the same predicate `key info` carries, for the same reason.
check "an absent alias is refused, not silently accepted" \
  "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}" | grep -c 'does not exist')" "1"

# Revoking goes through _api like every other call, so a 4xx reports its status
# instead of the unreachability message this whole change exists to remove.
check "the revoke goes through _api, not a bare curl" \
  "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}" | grep -c '_api POST /key/delete')" "1"
# Two calls, two classifications: the lookup and the revoke. One would mean a
# failure path reports nothing.
check "...and BOTH its calls are classified by _api_fail" \
  "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}" | grep -c '_api_fail')" "2"

# Every jq inside key delete must be GIVEN its input. A `jq -r '.token'` with no
# <<< or pipe reads stdin and silently yields empty — which is exactly what an
# edit to this function produced while all the grep-based assertions stayed
# green. Structure-only tests cannot see a missing input; this one can.
check "every jq in key delete has an input" \
  "$(sed -n '/^cmd_key_delete()/,/^}/p' "${TARGET}" | grep -E "jq -r " | grep -vcE '<<<|\| *jq|jq [^|]*\$\{|jq -cn')" "0"

check "usage documents key delete" \
  "$(bash "${TARGET}" --help 2>&1 | grep -q 'key delete' && echo yes)" "yes"

# ── team delete must not orphan what points at the team ─────────────────────
# The old prompt WARNED — "Virtual keys scoped to this team will lose their
# budget scope" — and then deleted anyway. A warning the operator must act on
# correctly, every time, under a [y/N], is not a guard.
#
# _team_blockers is pure on purpose: it takes the two API payloads and answers
# "what still points at this team". That makes the rule drivable offline, which
# is the difference between testing the guard and testing that a grep matches.
#
# canon-traverse on "destructive operation guard referential integrity delete"
# returned: "nothing resolved — the canon genuinely does not exist yet". So the
# rule is asserted here, not cited.
check "the guard exists as a pure function" "$(type -t _team_blockers)" "function"

TID="28b2befa-7052-4ab4-b4c3-abe9155e796e"
KEYS_ON='{"keys":[{"key_alias":"worker@vm","team_id":"'"${TID}"'"}]}'
KEYS_OFF='{"keys":[{"key_alias":"other@vm","team_id":"11111111-0000-0000-0000-000000000000"}]}'
KEYS_SLUG='{"keys":[{"key_alias":"legacy@vm","team_id":"some-slug"}]}'
INFO_EMPTY='{"team_info":{},"team_memberships":[]}'
INFO_MEMBER='{"team_info":{},"team_memberships":[{"user_id":"u1","role":"admin"}]}'

_team_blockers "${TID}" "${KEYS_ON}" "${INFO_EMPTY}" >/dev/null 2>&1
check "a key scoped to the team blocks"               "$?" "1"
check "...and the refusal names that key"             "$(_team_blockers "${TID}" "${KEYS_ON}" "${INFO_EMPTY}" 2>&1 | grep -c 'worker@vm')" "1"

_team_blockers "${TID}" "${KEYS_OFF}" "${INFO_EMPTY}" >/dev/null 2>&1
check "a key on ANOTHER team does not block"          "$?" "0"

# A key whose team_id is a slug rather than a UUID is scoped to no real team —
# it is a separate defect and must not make an unrelated team undeletable.
_team_blockers "${TID}" "${KEYS_SLUG}" "${INFO_EMPTY}" >/dev/null 2>&1
check "a slug-scoped key does not block this team"    "$?" "0"

_team_blockers "${TID}" '{"keys":[]}' "${INFO_MEMBER}" >/dev/null 2>&1
check "a remaining member blocks"                     "$?" "1"
check "...and the refusal names that member"          "$(_team_blockers "${TID}" '{"keys":[]}' "${INFO_MEMBER}" 2>&1 | grep -c 'u1')" "1"

_team_blockers "${TID}" '{"keys":[]}' "${INFO_EMPTY}" >/dev/null 2>&1
check "an empty team is not blocked"                  "$?" "0"

# Order matters: refuse before asking. Prompting [y/N] about a delete that will
# be refused teaches the operator that the prompt is noise.
_del="$(sed -n '/^cmd_delete()/,/^}/p' "${TARGET}")"
_blk="$(grep -n '_team_blockers' <<< "${_del}" | head -1 | cut -d: -f1)"
_ask="$(grep -n 'ASSUME_YES' <<< "${_del}" | head -1 | cut -d: -f1)"
check "the guard runs BEFORE the confirmation" \
  "$([[ -n "${_blk}" && -n "${_ask}" && ${_blk} -lt ${_ask} ]] && echo yes)" "yes"

check "the refusal says what to remove first" \
  "$(grep -c 'key delete' <<< "${_del}")" "1"

# ── _api failure detail must survive to the caller ──────────────────────────
# Measured against the live instance: `team delete` reported
#   "team/delete: <host> answered HTTP "
# with an EMPTY status. Cause: _api was called as `x="$(_api ...)"`, a command
# substitution, which is a SUBSHELL — the API_FAIL_* globals it sets there never
# reach the parent, so _api_fail read empty values and fell to its catch-all.
#
# The earlier tests drove _api_fail directly with hand-set globals. They proved
# the classifier maps correctly and said nothing about whether it ever RECEIVES
# anything — the classifier was right and the path was broken.
#
# So the rule is structural: _api's body comes back in a global, never through a
# command substitution, because its failure detail cannot cross one.
check "no call site invokes _api in a command substitution" \
  "$(code | grep -cE '=\"?\$\(_api ')" "0"
# Counting call sites against API_BODY mentions was arithmetic, not a rule — a
# call that does not need the body (the revoke) made it wrong. State the rule
# instead: _api hands the body over through the global and never through stdout.
_apibody="$(sed -n '/^_api()/,/^}/p' "${TARGET}")"
check "_api assigns the body to API_BODY" \
  "$(grep -c 'API_BODY="\${API_FAIL_BODY}"' <<< "${_apibody}")" "1"
check "_api never prints the body to stdout" \
  "$(grep -cE "printf '%s' \"\\\$\{API_FAIL_BODY\}\"" <<< "${_apibody}")" "0"

# ── team/delete takes POST, not DELETE ─────────────────────────────────────
# The endpoint answers 405 Method Not Allowed to an HTTP DELETE. That is the
# root cause of the failure this whole change started from, and it stayed hidden
# for as long as curl -sf discarded the status: the tool reported the host
# unreachable while the host was answering "wrong method". /key/delete already
# used POST, which is why revoking worked and deleting never did.
check "team/delete is called with POST" \
  "$(code | grep -c '_api POST /team/delete')" "1"
check "...and no longer with DELETE" \
  "$(code | grep -c '_api DELETE /team/delete')" "0"

# ── the prompt must claim only what was measured ────────────────────────────
# The guard checks two things: keys carrying this team's id, and memberships.
# It said "Nothing points at it" — a claim about the whole estate. Measured on
# Gridtefy BizOps: it printed that while a key named gridtefy-ops@… carries the
# team_id "gridtefy-bizops", a SLUG matching neither the uuid nor the alias
# ("Gridtefy BizOps" differs in case and spacing). Such a key is scoped to no
# team at all — a separate defect — but the operator should not read a narrow
# check as a broad all-clear.
check "the prompt states what was checked, not an all-clear" \
  "$(sed -n '/^cmd_delete()/,/^}/p' "${TARGET}" | grep -c 'Nothing points at it')" "0"
check "...and names keys and members explicitly" \
  "$(sed -n '/^cmd_delete()/,/^}/p' "${TARGET}" | grep -c 'No keys or members')" "1"

# ── the success check must match what the API returns ──────────────────────
# Measured live: /team/delete answered {"deleted_teams":["<id>"]} — plural — and
# the team WAS removed, while the script asserted `.deleted_team` singular and
# reported "delete failed". A false negative on a destructive verb is its own
# hazard: the operator retries, or believes a deletion did not happen when it
# did. Pre-existing; surfaced only once the endpoint could succeed at all.
check "the delete result is checked as deleted_teams" \
  "$(code | grep -c 'deleted_teams')" "1"
check "...and not as the singular the API never sends" \
  "$(code | grep -cE '\.deleted_team[^s]')" "0"

echo "  ${pass}/$((pass+fail)) passed"
[ "${fail}" -eq 0 ]
