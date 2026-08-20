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
check "no projection emits .token" \
  "$(code | grep -c '\.token' | tr -d ' ')" "0"

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

echo "  ${pass}/$((pass+fail)) passed"
[ "${fail}" -eq 0 ]
