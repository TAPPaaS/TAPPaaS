#!/usr/bin/env bash
#
# test-pipefail-grep-q.sh — a test script under pipefail pipes nothing into
# `grep -q`; it uses `grep -c … >/dev/null`.
#
# grep -q exits at its first match, the writer then dies of SIGPIPE, and under
# pipefail the pipeline fails — a match reads as a miss. On Linux it shows once
# the writer outgrows one pipe buffer; on macOS it mostly hides. It broke
# test-nixos-canon.sh and cluster/test.sh in deep runs (2026-10-08, 2026-10-15).
# grep -c reads all its input, so the writer always finishes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# A pipe (not ||) into grep with -q among its short flags, on a live line.
PIPE_Q='(^|[^|])\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q'

# Prints file:line for each offence, when the file runs under pipefail.
pipe_into_grep_q() {
    local f="$1"
    grep -cE 'set .*pipefail' "${f}" >/dev/null || return 0
    grep -nE "${PIPE_Q}" "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|${f}:|"
}

echo "── the rule, on fixtures ──"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
P='|'
printf 'set -uo pipefail\nsed p f %s grep -qE x && echo y\n' "${P}" > "${T}/q.sh"
printf 'set -uo pipefail\nsed p f %s grep -iq x && echo y\n' "${P}" > "${T}/iq.sh"
printf 'set -uo pipefail\nsed p f %s grep -cE x >/dev/null && echo y\n' "${P}" > "${T}/c.sh"
printf 'set -uo pipefail\ntrue %s%s grep -q x f\n' "${P}" "${P}" > "${T}/or.sh"
printf 'set -uo pipefail\n# sed p f %s grep -q x\n' "${P}" > "${T}/comment.sh"
printf 'set -u\nsed p f %s grep -q x\n' "${P}" > "${T}/nopipefail.sh"
[[ -n "$(pipe_into_grep_q "${T}/q.sh")" ]] && ok "a pipe into grep -qE: flagged" || bad "grep -qE not flagged"
[[ -n "$(pipe_into_grep_q "${T}/iq.sh")" ]] && ok "q after another flag: flagged" || bad "grep -iq not flagged"
[[ -z "$(pipe_into_grep_q "${T}/c.sh")" ]] && ok "grep -c >/dev/null passes" || bad "grep -c flagged"
[[ -z "$(pipe_into_grep_q "${T}/or.sh")" ]] && ok "|| grep -q is no pipe" || bad "|| grep -q flagged"
[[ -z "$(pipe_into_grep_q "${T}/comment.sh")" ]] && ok "a comment passes" || bad "a comment flagged"
[[ -z "$(pipe_into_grep_q "${T}/nopipefail.sh")" ]] && ok "without pipefail it is no race" || bad "a no-pipefail file flagged"

echo "── the tree's test scripts ──"
found=""
while IFS= read -r -d '' f; do
    found+="$(pipe_into_grep_q "${f}")"$'\n'
done < <(find "${SRC}" -name 'test*.sh' -not -path '*/node_modules/*' -print0)
found="$(grep -v '^$' <<<"${found}" || true)"
if [[ -z "${found}" ]]; then
    ok "no test script under pipefail pipes into grep -q"
else
    while IFS= read -r l; do bad "${l#"${SRC}/"} — use grep -c … >/dev/null"; done <<<"${found}"
fi

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
