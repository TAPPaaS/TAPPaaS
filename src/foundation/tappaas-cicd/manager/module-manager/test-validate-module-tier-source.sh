#!/usr/bin/env bash
#
# test-validate-module-tier-source.sh — standalone tests for the ADR-007b
# tier/source lint (validate-module-tier-source.sh). FAST, offline, temp
# fixtures only. Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${HERE}/validate-module-tier-source.sh"

PASS=0
FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tier-source-test.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

echo "== validate-module-tier-source.sh standalone tests =="

[[ -x "$LINT" ]] && ok "lint script is executable" || bad "lint script not executable: ${LINT}"

mkfix() { printf '%s\n' "$2" > "${WORK}/$1.json"; printf '%s\n' "${WORK}/$1.json"; }

run() { "$LINT" --quiet "$@" >/dev/null 2>&1; }

f_off="$(mkfix found_off  '{"tier":"foundation","source":"official"}')"
f_com="$(mkfix found_com  '{"tier":"foundation","source":"community"}')"
f_priv="$(mkfix found_priv '{"tier":"foundation","source":"private"}')"
f_def="$(mkfix found_def  '{"tier":"foundation"}')"                 # source defaults official
a_off="$(mkfix app_off    '{"tier":"app","source":"official"}')"
a_com="$(mkfix app_com    '{"tier":"app","source":"community"}')"
a_priv="$(mkfix app_priv  '{"tier":"app","source":"private"}')"
a_loc="$(mkfix app_loc    '{"tier":"app","source":"local"}')"
notier="$(mkfix notier    '{"source":"official"}')"
badtier="$(mkfix badtier  '{"tier":"weird","source":"official"}')"
badsrc="$(mkfix badsrc    '{"tier":"app","source":"weird"}')"

# foundation lint rule
run "$f_off"  && ok "foundation+official passes"            || bad "foundation+official should pass"
run "$f_def"  && ok "foundation (source defaulted) passes"  || bad "foundation default source should pass"
run "$f_com"  && bad "foundation+community should FAIL"      || ok "foundation+community rejected (lint rule)"
run "$f_priv" && bad "foundation+private should FAIL"        || ok "foundation+private rejected (lint rule)"
run --allow-fork "$f_com" && ok "foundation+community + --allow-fork passes" \
                          || bad "--allow-fork should permit a foundation fork"

# app: any source valid
run "$a_off"  && ok "app+official passes"   || bad "app+official should pass"
run "$a_com"  && ok "app+community passes"  || bad "app+community should pass"
run "$a_priv" && ok "app+private passes"    || bad "app+private should pass"
run "$a_loc"  && ok "app+local passes"      || bad "app+local should pass"

# enum + mandatory checks
run "$notier"  && bad "missing tier should FAIL"        || ok "missing mandatory tier rejected"
run "$badtier" && bad "invalid tier enum should FAIL"   || ok "invalid tier enum rejected"
run "$badsrc"  && bad "invalid source enum should FAIL" || ok "invalid source enum rejected"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
