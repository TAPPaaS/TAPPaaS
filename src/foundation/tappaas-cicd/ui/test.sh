#!/usr/bin/env bash
#
# ui/test.sh — tests for the console (ADR-034).
#
# FAST (default, offline): tsc --noEmit on the backend, then the unit suite over
# hrossen's captured outputs (test/fixtures) with a fake runner — the access
# filter and the gate's headers, the setup-token rule (T6), the reads and their
# cache, the routes, Activity and the jumps. No live service, no socket.
# The front end: its type-check and build when its node_modules are present.
#
# DEEP (TAPPAAS_TEST_DEEP=1 or --deep): the installed console answers
# /api/v1/status on loopback (tappaas-console.service).
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
set -uo pipefail
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

run_ts() {
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
        bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then
        nix-shell -p typescript nodejs_22 --run "$1"
    else
        return 127
    fi
}

DIST_TEST="${HERE}/dist-test"
cleanup() { [[ -n "${DIST_TEST:-}" && -d "${DIST_TEST}" ]] && rm -rf -- "${DIST_TEST}"; return 0; }
trap cleanup EXIT INT TERM

echo "== console backend: TypeScript build + unit tests =="
rm -rf -- "${DIST_TEST}"
if run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1; then
    ok "tsc --noEmit clean (src)"
else
    bad "tsc --noEmit reported type errors (src): run tsc -p ${HERE}/tsconfig.json"
fi
if run_ts "tsc -p '${HERE}/test/unit/tsconfig.json'" >/dev/null 2>&1; then
    ok "unit tests compile"
    _ran=0
    for _js in "${DIST_TEST}/ui/test/unit/"*.test.js; do
        [[ -f "${_js}" ]] || continue
        _ran=$((_ran + 1))
        if run_ts "CONSOLE_FIXTURES='${HERE}/test/fixtures' node '${_js}'" >/dev/null 2>&1; then
            ok "$(basename "${_js}" .test.js) unit tests pass"
        else
            bad "$(basename "${_js}" .test.js) unit tests FAILED (rerun: CONSOLE_FIXTURES=${HERE}/test/fixtures node ${_js})"
        fi
    done
    [[ "${_ran}" -gt 0 ]] && ok "swept ${_ran} unit test file(s)" || bad "no compiled unit tests found to run"
else
    bad "unit tests failed to compile"
fi

echo ""
echo "== console front end =="
if [[ -d "${HERE}/web/node_modules" ]]; then
    if (cd "${HERE}/web" && run_ts "npx tsc --noEmit -p tsconfig.json") >/dev/null 2>&1; then
        ok "front end type-checks"
    else
        bad "front end type errors (cd web && npx tsc --noEmit)"
    fi
else
    echo "  skip: web/node_modules absent (the nix build installs and builds the front end)"
fi

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo ""
    echo "== DEEP: the installed console answers =="
    if systemctl is-active --quiet tappaas-console.service 2>/dev/null; then
        if curl -fsS --max-time 10 "http://127.0.0.1:9097/api/v1/status" | grep -q '"version"'; then
            ok "tappaas-console answers /api/v1/status on loopback"
        else
            bad "tappaas-console is active but /api/v1/status does not answer"
        fi
    else
        echo "  SKIP: tappaas-console.service is not active here"
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
