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
echo "== check-ha-health threshold logic (offline, #146) =="
# Exercises the wedge detector without touching the cluster: TAPPAAS_HA_STATUS_FILE
# substitutes a canned `ha-manager status`, TAPPAAS_HA_STATE isolates the history.
CHH="${here}/check-ha-health.sh"
if [[ -x "$CHH" ]]; then
    _tmp="$(mktemp -d)"
    _status="${_tmp}/status"
    _state="${_tmp}/state"

    # A steady cluster must be silent and exit 0.
    cat >"${_status}" <<'EOF'
quorum OK
master tappaas3 (active, Tue Aug 11 15:50:33 2026)
service vm:110 (tappaas1, started)
service vm:130 (tappaas1, started)
EOF
    # Run the checker and report the exit code we got vs the one we wanted.
    _chh() {  # _chh <expected-rc> <label> [extra args...]
        local want="$1" label="$2"; shift 2
        local got=0
        TAPPAAS_HA_STATUS_FILE="${_status}" TAPPAAS_HA_STATE="${_state}" \
            "$CHH" --quiet "$@" >/dev/null 2>&1 || got=$?
        if [[ "$got" -eq "$want" ]]; then ok "${label}"; else bad "${label} (rc ${got}, want ${want})"; fi
    }

    _chh 0 "steady cluster → exit 0"

    # A service that has JUST entered 'migrate' is within the grace period.
    cat >"${_status}" <<'EOF'
service vm:110 (tappaas1, started)
service vm:130 (tappaas2, migrate)
EOF
    _chh 0 "new 'migrate' within threshold → exit 0" --threshold 600
    if grep -q 'vm:130' "${_state}"; then ok "transitional state recorded in history"
    else bad "history did not record vm:130"; fi

    # Backdate the first-seen stamp: the same state is now wedged.
    awk -F'\t' 'BEGIN{OFS="\t"} {print $1, $2, $3 - 4000}' "${_state}" >"${_state}.bak" \
        && mv "${_state}.bak" "${_state}"
    _chh 2 "long-running 'migrate' → exit 2 (wedged)" --threshold 600

    # Once it settles, the history is cleared so the next episode starts fresh.
    cat >"${_status}" <<'EOF'
service vm:110 (tappaas1, started)
service vm:130 (tappaas1, started)
EOF
    _chh 0 "settled service → exit 0"
    if [[ -s "${_state}" ]]; then bad "history not cleared after settling"
    else ok "history cleared after settling"; fi

    # 'freeze' is deliberate (node maintenance), not a wedge — even at threshold 0.
    cat >"${_status}" <<'EOF'
service vm:130 (tappaas1, freeze)
EOF
    _chh 0 "'freeze' treated as steady → exit 0" --threshold 0

    rm -rf -- "${_tmp}"
else
    bad "check-ha-health.sh not executable"
fi

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
        # dist-test mirrors the tree from the tappaas-cicd root (shared
        # lib/ts/tsconfig.base.json sets rootDir there), so the compiled test
        # lives under manager/health-manager/.
        if run_ts "node '${DIST_TEST}/manager/health-manager/test/unit/inspect.test.js'"; then
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
