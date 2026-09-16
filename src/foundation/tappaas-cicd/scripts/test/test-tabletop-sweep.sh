#!/usr/bin/env bash
# test-tabletop-sweep.sh — how the Test 9z sweep judges one suite.
#
# The sweep runs every scripts/test/test-*.sh and turns an exit code into a
# verdict. That verdict is the one part of test.sh nothing else can reach, and
# it decides whether a result is believed: for months two source-tree suites
# failed on every run through the test harness (which ships a COPY of the
# working tree, so `git ls-files` has nothing to read), and a permanent red
# teaches everyone to stop looking at the colour.
#
# So: 0 passes, 77 SKIPS WITH ITS REASON SHOWN, anything else fails. Extracted
# and run in isolation with stubbed pass/fail/skip, the way the zone-reference
# helpers are tested.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
T="${CICD}/test.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT INT TERM
awk '/^tabletop_verdict\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${T}" > "${d}/verdict.sh"
[[ -s "${d}/verdict.sh" ]] || { echo "  ✗ tabletop_verdict() not found in test.sh"; exit 1; }

cat > "${d}/harness.sh" <<'EOF'
pass() { echo "PASS|$1"; }
fail() { echo "FAIL|$1"; }
skip() { echo "SKIP|$1"; }
. "${VERDICT}"
tabletop_verdict "$1" "$2" "$3"
EOF

verdict() { VERDICT="${d}/verdict.sh" bash "${d}/harness.sh" "$1" "$2" "$3" 2>/dev/null; }

out="$(verdict some-test.sh 0 '  ✓ a thing')"
ck "exit 0 passes" "PASS|some-test.sh" "${out}"

out="$(verdict some-test.sh 1 'a line
  ✗ the thing broke')"
ck "exit 1 fails, naming the rerun" "FAIL|some-test.sh failed — rerun: scripts/test/some-test.sh" "${out}"

out="$(verdict src-check.sh 77 'no TAPPaaS git work tree here — this source-tree check runs on a clone')"
ck "exit 77 skips" "SKIP|src-check.sh — no TAPPaaS git work tree here — this source-tree check runs on a clone" "${out}"

out="$(verdict src-check.sh 77 'first line
second line
the reason nobody would otherwise see')"
ck "…and prints the reason, not the whole output" \
   "SKIP|src-check.sh — the reason nobody would otherwise see" "${out}"

# 77 is "cannot run here", never "would fail here": any other code is a failure,
# including the ones a shell hands back for a crash.
for rc in 2 66 78 127 139; do
    out="$(verdict some-test.sh "${rc}" 'boom')"
    case "${out}" in
        FAIL\|*) ck "exit ${rc} is a failure, not a skip" ok ok ;;
        *)       ck "exit ${rc} is a failure, not a skip" ok "${out}" ;;
    esac
done

# The two source-tree suites must actually use the protocol — that is what the
# permanent red was.
for s in test-tracked-exec-mode.sh test-split-horizon-single-writer.sh; do
    grep -q 'exit 77' "${HERE}/${s}" \
        && ck "${s} skips rather than failing off a checkout" ok ok \
        || ck "${s} skips rather than failing off a checkout" ok missing
done

# …and must still RUN where there is a checkout: a skip that fires everywhere
# is a deleted test wearing a hat.
if git -C "${HERE}" rev-parse --show-toplevel >/dev/null 2>&1; then
    for s in test-tracked-exec-mode.sh test-split-horizon-single-writer.sh; do
        "${HERE}/${s}" >/dev/null 2>&1; rc=$?
        ck "${s} runs here (this is a checkout)" 0 "${rc}"
    done
else
    echo "  ⊘ the two source-tree suites are not exercised (no checkout here)"
fi

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
