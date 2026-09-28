#!/usr/bin/env bash
#
# test-validate-module-tier-source.sh — standalone tests for the scope/source
# lint (validate-module-tier-source.sh; ADR-007b, ADR-022e). Scope is derived
# from `stack`; `tier` is retired and read only as a fallback (#676). FAST, offline, temp
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

f_off="$(mkfix found_off  '{"stack":"foundation","source":"official"}')"
f_com="$(mkfix found_com  '{"stack":"foundation","source":"community"}')"
f_priv="$(mkfix found_priv '{"stack":"foundation","source":"private"}')"
f_def="$(mkfix found_def  '{"stack":"foundation"}')"                 # source defaults official
a_off="$(mkfix app_off    '{"stack":"ai","source":"official"}')"
a_com="$(mkfix app_com    '{"stack":"ai","source":"community"}')"
a_priv="$(mkfix app_priv  '{"stack":"ai","source":"private"}')"
a_loc="$(mkfix app_loc    '{"stack":"ai","source":"local"}')"
nostack="$(mkfix nostack  '{"source":"official"}')"
t_com="$(mkfix tier_com   '{"tier":"foundation","source":"community"}')"      # no stack: tier decides, one release
contra="$(mkfix contra    '{"stack":"communication","tier":"foundation","source":"community"}')"
badtier="$(mkfix badtier  '{"stack":"ai","tier":"weird","source":"official"}')"
badsrc="$(mkfix badsrc    '{"stack":"ai","source":"weird"}')"

# a site-scoped module (the foundation stack) must come from an official source
run "$f_off"  && ok "foundation stack + official passes"            || bad "foundation+official should pass"
run "$f_def"  && ok "foundation stack (source defaulted) passes"    || bad "foundation default source should pass"
run "$f_com"  && bad "foundation stack + community should FAIL"      || ok "foundation stack + community rejected (lint rule)"
run "$f_priv" && bad "foundation stack + private should FAIL"        || ok "foundation stack + private rejected (lint rule)"
run --allow-fork "$f_com" && ok "foundation stack + community + --allow-fork passes" \
                          || bad "--allow-fork should permit a foundation fork"

# environment-scoped: any source valid
run "$a_off"  && ok "app stack + official passes"   || bad "app+official should pass"
run "$a_com"  && ok "app stack + community passes"  || bad "app+community should pass"
run "$a_priv" && ok "app stack + private passes"    || bad "app+private should pass"
run "$a_loc"  && ok "app stack + local passes"      || bad "app+local should pass"

# scope follows the stack (ADR-022e v1.1); tier is retired (#676)
run "$nostack" && ok "no stack: installs environment-scoped (warned)" || bad "a module without a stack should warn, not fail"
# Captured, not piped: `grep -q` stops early, the lint dies of SIGPIPE, and
# pipefail would report that as a failure.
_out="$("$LINT" "$nostack" 2>&1)"
grep -q "no 'stack'" <<< "$_out" && ok "…and is warned about" || bad "a missing stack should be warned about"
run "$t_com"   && bad "no stack + tier:foundation + community should FAIL (tier fallback)" \
               || ok "no stack: a retired tier:foundation still makes it site-scoped, for one release"
run "$contra"  && ok "stack communication + tier:foundation + community passes: the stack decides" \
               || bad "a tier contradicting the stack must be ignored"
_out="$("$LINT" "$contra" 2>&1)"
grep -q "is ignored" <<< "$_out" && ok "…and the ignored tier is named" || bad "the contradicting tier should be named as ignored"
run "$badtier" && ok "a bogus tier only warns — it is retired, not checked" || bad "a retired tier must not fail the lint"
run "$badsrc"  && bad "invalid source enum should FAIL" || ok "invalid source enum rejected"

# ── maturity: status + version (#248) ───────────────────────────────────────
# What a module may claim about itself. A maturity out of range fails; a
# deployment state in a released module fails; the version form and the two
# contradictions warn (the author decides which side is wrong).
warns() { "$LINT" "$@" 2>&1 | grep -c "SCOPE/SOURCE:.*\(version\|status\|claims stable\|earned\)" ; }

m_ok="$(mkfix mat_ok     '{"stack":"ai","status":"Testing","version":"0.2.0"}')"
m_bad="$(mkfix mat_bad   '{"stack":"ai","status":"Ready","version":"0.2.0"}')"
m_arch="$(mkfix mat_arch '{"stack":"ai","status":"archived","version":"0.2.0"}')"
m_ext="$(mkfix mat_ext   '{"stack":"ai","status":"external","version":"0.2.0"}')"
m_two="$(mkfix mat_two   '{"stack":"ai","status":"Testing","version":"0.2"}')"
m_dev1="$(mkfix mat_dev1 '{"stack":"ai","status":"Development","version":"1.2.0"}')"
m_prod0="$(mkfix mat_p0  '{"stack":"ai","status":"Production","version":"0.9.0"}')"
m_none="$(mkfix mat_none '{"stack":"ai"}')"

run "$m_ok"    && ok "a maturity in range passes"                  || bad "Testing 0.2.0 should pass"
run "$m_bad"   && bad "an unknown status should FAIL"              || ok "an unknown status is rejected"
run "$m_arch"  && bad "status archived in a module should FAIL"    || ok "a deployment state (archived) is rejected in a module"
run "$m_ext"   && bad "status external in a module should FAIL"    || ok "a deployment state (external) is rejected in a module"
run "$m_two"   && ok "a two-part version passes (warned, not refused)" || bad "0.2 should warn, not fail"
[[ "$(warns "$m_two")" -ge 1 ]]   && ok "…and is warned about"                   || bad "0.2 should be warned about"
run "$m_dev1"  && ok "1.2.0 while Development passes"              || bad "the contradiction should warn, not fail"
[[ "$(warns "$m_dev1")" -ge 1 ]]  && ok "…warned: stable version, Development status" || bad "no warning for 1.2.0 + Development"
run "$m_prod0" && ok "Production below 1.0.0 passes"               || bad "the contradiction should warn, not fail"
[[ "$(warns "$m_prod0")" -ge 1 ]] && ok "…warned: Production under 1.0.0"        || bad "no warning for Production 0.9.0"
run "$m_none"  && ok "a module claiming neither passes (warned)"   || bad "missing status/version should warn, not fail"
[[ "$(warns "$m_none")" -ge 2 ]]  && ok "…warned about both"                     || bad "missing status/version should warn twice"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
