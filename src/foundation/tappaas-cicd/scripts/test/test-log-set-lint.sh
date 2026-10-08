#!/usr/bin/env bash
#
# test-log-set-lint.sh — a script that defines its own logging set defines all of
# it, `debug` included (#747).
#
# A private set of info/warn/error/die without `debug` turns the next `debug`
# line into "debug: command not found" — three times in one day (2026-09-26).
# The check asks only about DEFINITIONS, which are unambiguous; a check on calls
# drowns in sourced libraries and the word "error" in strings (see the issue).
#
# A file breaks the rule when it defines 3+ of info/warn/error/die, defines no
# `debug`, and does not source common-install-routines unconditionally (that
# supplies `debug`). A `. …/common-install-routines.sh || { fallback }` is not
# unconditional: the fallback is the private set, and it needs `debug` too.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Prints the file when it breaks the rule.
log_set_incomplete() {
    local f="$1" n=0 fn
    for fn in info warn error die; do
        grep -qE "(^|[[:space:];{|&])(function[[:space:]]+)?${fn}[[:space:]]*\(\)" "${f}" && n=$((n + 1))
    done
    (( n >= 3 )) || return 1
    grep -qE "(^|[[:space:];{|&])(function[[:space:]]+)?debug[[:space:]]*\(\)" "${f}" && return 1
    grep -qE "^[[:space:]]*(\.|source)[[:space:]]+[^|]*common-install-routines\.sh[^|]*$" "${f}" && return 1
    echo "${f}"
}

echo "── the rule, on fixtures ──"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
printf 'info() { :; }\nwarn() { :; }\nerror() { :; }\ndie() { :; }\n' > "${T}/no-debug.sh"
printf 'info() { :; }\nwarn() { :; }\nerror() { :; }\ndebug() { :; }\n' > "${T}/full.sh"
printf 'function info() { :; }\nfunction warn() { :; }\nfunction error() { :; }\n' > "${T}/keyword.sh"
printf 'info() { :; }\nwarn() { :; }\nerror() { :; }\ndeclare -F debug >/dev/null || debug() { :; }\n' > "${T}/guarded.sh"
printf '. /home/tappaas/bin/common-install-routines.sh\ninfo() { :; }\nwarn() { :; }\nerror() { :; }\n' > "${T}/sourced.sh"
printf '. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || {\n  info() { :; }\n  warn() { :; }\n  error() { :; }\n}\n' > "${T}/fallback.sh"
printf 'warn() { :; }\ninfo() { :; }\necho "error() is a word here"\n' > "${T}/two.sh"
[[ -n "$(log_set_incomplete "${T}/no-debug.sh")" ]] && ok "four helpers, no debug: flagged" || bad "four helpers, no debug: not flagged"
[[ -n "$(log_set_incomplete "${T}/keyword.sh")" ]] && ok "the \`function\` keyword form: flagged" || bad "the function form: not flagged"
[[ -n "$(log_set_incomplete "${T}/fallback.sh")" ]] && ok "a || fallback set without debug: flagged" || bad "a fallback set: not flagged"
[[ -z "$(log_set_incomplete "${T}/full.sh")" ]] && ok "a full set passes" || bad "a full set flagged"
[[ -z "$(log_set_incomplete "${T}/guarded.sh")" ]] && ok "a guarded \`|| debug()\` counts" || bad "a guarded debug not counted"
[[ -z "$(log_set_incomplete "${T}/sourced.sh")" ]] && ok "an unconditional source supplies debug" || bad "an unconditional source flagged"
[[ -z "$(log_set_incomplete "${T}/two.sh")" ]] && ok "two helpers is not a set" || bad "two helpers flagged"

echo "── the tree ──"
found=""
while IFS= read -r -d '' f; do
    found+="$(log_set_incomplete "${f}")"$'\n'
done < <(find "${SRC}" -name '*.sh' -not -path '*/node_modules/*' -not -path '*/dist*' -print0)
found="$(grep -v '^$' <<<"${found}" || true)"
if [[ -z "${found}" ]]; then
    ok "every script with its own logging set defines debug"
else
    while IFS= read -r f; do bad "${f#"${SRC}/"} defines its own logging set without debug"; done <<<"${found}"
fi

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
