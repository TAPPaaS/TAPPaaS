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

echo "  ${pass}/$((pass+fail)) passed"
[ "${fail}" -eq 0 ]
