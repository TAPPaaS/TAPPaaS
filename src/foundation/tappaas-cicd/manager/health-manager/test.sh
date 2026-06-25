#!/usr/bin/env bash
# manager/health-manager/test.sh
#
# Two tiers:
#   1. Bash smoke — every legacy entry script parses (bash -n) and resolves on PATH.
#   2. TypeScript — `tsc --noEmit` clean (src) + the offline unit suite passes
#      (FakeClusterClient; no SSH / no Proxmox). Mirrors people-manager/test.sh.
# Exit non-zero on any failure.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; rc=1; }

echo "== health-manager bash smoke =="
for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    if bash -n "${f}"; then ok "${b} parses"; else bad "${b} syntax"; fi
    command -v "${b}" >/dev/null 2>&1 && ok "${b} on PATH" || bad "${b} not on PATH"
done

echo ""
echo "== health-manager TypeScript unit tests =="

run_ts() {
    # Prefer a tsc/node already on PATH, else fall back to nix-shell.
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
        bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then
        nix-shell -p typescript nodejs_22 --run "$1"
    else
        return 127
    fi
}

UNIT_TSCONFIG="${here}/test/unit/tsconfig.json"
DIST_TEST="${here}/dist-test"
if [[ -f "$UNIT_TSCONFIG" ]]; then
    rm -rf -- "$DIST_TEST"
    if run_ts "tsc --noEmit -p '${here}/tsconfig.json'" >/dev/null 2>&1; then
        ok "tsc --noEmit clean (src)"
    else
        bad "tsc --noEmit reported type errors (src)"
    fi
    if run_ts "tsc -p '${UNIT_TSCONFIG}'" >/dev/null 2>&1; then
        ok "TypeScript unit tests compile"
        if run_ts "node '${DIST_TEST}/test/unit/inspect.test.js'"; then
            ok "TypeScript inspect/gate unit tests pass"
        else
            bad "TypeScript inspect/gate unit tests FAILED"
        fi
    else
        bad "TypeScript unit tests failed to compile"
    fi
    rm -rf -- "$DIST_TEST"
else
    bad "unit test tsconfig not found: ${UNIT_TSCONFIG}"
fi

exit "${rc}"
