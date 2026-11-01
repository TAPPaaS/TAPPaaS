#!/usr/bin/env bash
#
# test-console-visual.sh — the console's visual loop from the tree tests
# (docs/plans/console-gui-pipeline.md §7): ui/web/e2e/run.sh captures every
# page at four sizes against the console in fixture mode, compares with the
# baseline and runs the flows (ui/web/e2e/flows: Remove node, Add node step 1,
# Ack, the output panel). About 3 minutes, so a developer and pre-push check.
#
# Exits 77 (the sweep's "cannot run here", test.sh Test 9z) where the loop
# cannot run: no Playwright runner in ui/web/node_modules (that directory is in
# git, so its presence alone says nothing), no Chromium, or the pre-update gate
# (TAPPAAS_TEST_RUNTIME_ONLY=1): it is never part of an update.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI="$(cd "${HERE}/../../ui" && pwd)"
WEB="${UI}/web"
PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

if [[ "${TAPPAAS_TEST_RUNTIME_ONLY:-0}" == "1" ]]; then
    echo "the visual loop is a source-tree check, not part of an update"
    exit 77
fi
NODE=node
[[ -x /opt/homebrew/bin/node ]] && NODE=/opt/homebrew/bin/node
if ! command -v "${NODE}" >/dev/null 2>&1; then
    echo "node is not installed here"
    exit 77
fi
if [[ ! -d "${WEB}/node_modules/@playwright/test" ]]; then
    echo "ui/web/node_modules/@playwright absent (cd ui/web && npm ci)"
    exit 77
fi
if ! (cd "${WEB}" && "${NODE}" -e 'const { chromium } = require("@playwright/test"); process.exit(require("fs").existsSync(chromium.executablePath()) ? 0 : 1)') 2>/dev/null; then
    echo "Playwright's Chromium is not installed (cd ui/web && npx playwright install chromium)"
    exit 77
fi

echo "── the visual loop: capture, compare, flows ──"
LOG="${WEB}/e2e/out/run.log"
mkdir -p "$(dirname "${LOG}")"
T0=$(date +%s)
if "${WEB}/e2e/run.sh" >"${LOG}" 2>&1; then
    ok "run.sh clean in $(( $(date +%s) - T0 )) s: no route differs from the baseline"
else
    bad "run.sh failed: read ${WEB}/e2e/out/report.md (log ${LOG})"
    tail -15 "${LOG}" | sed 's/^/      /'
fi
REPORT="${WEB}/e2e/out/report.md"
if grep -qE '^ok: .*passed' <(sed -n '/^## Flows/,$p' "${REPORT}" 2>/dev/null); then
    ok "the flows pass ($(sed -n '/^## Flows/,$p' "${REPORT}" | grep -oE '[0-9]+ passed[^(]*' | head -1 | sed 's/ *$//'))"
else
    bad "the flows did not all pass: ${WEB}/e2e/out/flows.log"
fi

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
