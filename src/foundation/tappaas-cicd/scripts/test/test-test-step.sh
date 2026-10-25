#!/usr/bin/env bash
# test-test-step.sh — a long module test says where it is and how long each
# part took (test_step / test_steps_done in common-install-routines.sh), and the
# long tests use it with a step count that matches.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIR="${HERE}/../../lib/common-install-routines.sh"
SRC="${HERE}/../../../.."

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok: $1"; else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
run() { bash -c '. "$1" >/dev/null 2>&1; eval "$2"' _ "${CIR}" "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

out="$(run 'TEST_STEPS=3; test_step basics; test_step "unit tests"; test_step deep; test_steps_done')"
ck "each step names its place in module-manager's Step 4" \
   "$(sed -n 1p <<<"${out}")" "[Info] Test Step 4: Run module test.sh (step 1/3: basics)"
ck "…and the next one says how long the one before took" \
   "$(sed -n 2p <<<"${out}")" "[Info] Test Step 4: Run module test.sh (step 2/3: unit tests) — step 1 took 0s"
ck "the end lists every step's time" \
   "$(sed -n 4p <<<"${out}")" "[Info]   step times: 1 basics 0s · 2 unit tests 0s · 3 deep 0s (total 0s)"
ck "a count that agrees says nothing more" "$(wc -l <<<"${out}" | tr -d ' ')" "4"
ck "a count that disagrees is a warning" \
   "$(run 'TEST_STEPS=3; test_step a; test_steps_done' | grep -c 'ran 1 step(s) but declares TEST_STEPS=3')" "1"
ck "no steps: test_steps_done says nothing" "$(run 'test_steps_done')" ""
ck "minutes read as minutes" "$(run '_ts_dur 75')" "1m15s"

run "TEST_STEPS=2; TAPPAAS_TEST_PROGRESS='${W}/tty'; TAPPAAS_TEST_MODULE=demo; test_step one; test_step two" >/dev/null
ck "the progress channel gets every step" "$(wc -l < "${W}/tty" | tr -d ' ')" "2"
ck "…named for the module" "$(sed -n 2p "${W}/tty" | sed 's/^ *//')" "demo step 2/2: two — step 1 took 0s"
ck "a channel that cannot be written is not an error" \
   "$(run "TAPPAAS_TEST_PROGRESS=/no/such/dir/tty; test_step x >/dev/null; echo rc=\$?")" "rc=0"

# The long tests declare their steps and close them.
for t in foundation/tappaas-cicd/test.sh foundation/network/test.sh foundation/storage/test.sh; do
    f="${SRC}/${t}"
    ck "${t} declares TEST_STEPS and ends with test_steps_done" \
       "$(grep -c '^ *TEST_STEPS=' "${f}")/$(grep -c '^ *test_steps_done' "${f}")" "1/1"
done

echo "test-test-step: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
