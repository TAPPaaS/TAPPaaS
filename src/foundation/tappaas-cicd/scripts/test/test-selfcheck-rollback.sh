#!/usr/bin/env bash
#
# test-selfcheck-rollback.sh — the control plane verifies itself, and undoes a
# bad generation (#713, ADR-028 D10).
#
# Every guest has a net: update-module.sh snapshots it, rebuilds, tests, and
# rolls the guest back when the tests fail. The mothership had none, and it
# rebuilds FIRST — so it is both the most exposed machine and the only one that
# could not undo a bad nixpkgs revision. A `nixos-rebuild switch` returning 0
# into a control plane that cannot resolve a config was simply not noticed.
#
# Two halves are asserted here:
#   1. tappaas-selfcheck.sh actually fails when the control plane is broken —
#      driven with stubs, since a real bad generation cannot be built in a test;
#   2. tappaas-self-rebuild.sh captures the way back BEFORE switching and uses
#      it when the check fails.
#
# Tabletop: stubs and greps, no rebuild, nothing switched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFCHECK="${HERE}/../tappaas-selfcheck.sh"
REBUILD="${HERE}/../tappaas-self-rebuild.sh"
[[ -x "${SELFCHECK}" && -f "${REBUILD}" ]] || {
    echo "self-rebuild scripts not found beside this suite — cannot run here."; exit 77; }

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/selfcheck.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
BIN="${TMP}/bin"; mkdir -p "${BIN}"

# A control plane that works: every manager answers --help, the catalogue lists,
# systemctl reports whatever we put in FAILED_UNITS.
make_stubs() {
    local mgr_rc="${1:-0}" list_rc="${2:-0}"
    for mgr in module-manager site-manager network-manager backup-manager \
               health-manager identity-manager environment-manager; do
        cat > "${BIN}/${mgr}" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--help" ]]; then exit ${mgr_rc}; fi
if [[ "\$1" == "module" && "\$2" == "list" ]]; then exit ${list_rc}; fi
exit 0
EOF
        chmod +x "${BIN}/${mgr}"
    done
    cat > "${BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
# only `--failed --no-legend --plain` is used by the script under test
printf '%s\n' ${FAILED_UNITS:-}
EOF
    chmod +x "${BIN}/systemctl"
    # `timeout` must stay real, but the stubs must win over the system managers.
    cat > "${BIN}/runuser" <<'EOF'
#!/usr/bin/env bash
# tests run as one user; strip `-u <user> --` and exec the rest
shift 2; [[ "$1" == "--" ]] && shift; exec "$@"
EOF
    chmod +x "${BIN}/runuser"
}

run_check() {  # $1 = baseline file (or ""), sets RC/OUT
    local baseline="$1" args=()
    [[ -n "${baseline}" ]] && args=(--baseline "${baseline}")
    OUT="$(PATH="${BIN}:${PATH}" TAPPAAS_USER="$(id -un)" \
           "${SELFCHECK}" "${args[@]}" 2>&1)"
    RC=$?
}

echo "── a healthy control plane passes ──"
make_stubs 0 0
: > "${TMP}/base"
FAILED_UNITS="" run_check "${TMP}/base"
[[ "${RC}" -eq 0 ]] && ok "exit 0 when everything answers" || bad "exit ${RC} on a healthy plane: ${OUT}"

echo "── a manager that will not run fails the check ──"
# This is the shape a bad nixpkgs revision takes: the CLIs are built from the
# same revision as the system, so they stop starting.
make_stubs 1 0
FAILED_UNITS="" run_check "${TMP}/base"
[[ "${RC}" -ne 0 ]] && ok "non-zero when a manager will not run" || bad "passed with a dead manager"
[[ "${OUT}" == *"will not run"* ]] && ok "and says which one" || bad "no diagnosis in output"

echo "── a config cascade that stops resolving fails the check ──"
make_stubs 0 1
FAILED_UNITS="" run_check "${TMP}/base"
[[ "${RC}" -ne 0 ]] && ok "non-zero when the catalogue will not resolve" || bad "passed with an unresolvable catalogue"

echo "── newly failed units are caught; pre-existing ones are not ──"
make_stubs 0 0
printf 'already-broken.service\n' > "${TMP}/base2"
FAILED_UNITS="already-broken.service" run_check "${TMP}/base2"
[[ "${RC}" -eq 0 ]] && ok "a unit that was already failing is not a regression" \
                    || bad "pre-existing failure treated as new: ${OUT}"
FAILED_UNITS="already-broken.service
freshly-broken.service" run_check "${TMP}/base2"
[[ "${RC}" -ne 0 ]] && ok "a unit that failed during the switch is caught" || bad "missed a newly failed unit"
[[ "${OUT}" == *"freshly-broken.service"* ]] && ok "and names it" || bad "did not name the new failure"

echo "── the sweep's own unit never counts as a regression ──"
# tappaas-selfcheck runs INSIDE update-tappaas.service, whose last-run state is
# whatever the previous sweep left; counting it would fail every rebuild that
# follows a failed sweep.
: > "${TMP}/base3"
FAILED_UNITS="update-tappaas.service" run_check "${TMP}/base3"
[[ "${RC}" -eq 0 ]] && ok "update-tappaas.service is excluded" || bad "the sweep's own unit failed the check"

echo "── the rebuild captures the way back before switching ──"
_pre="$(sed -n '1,/nixos-rebuild switch --flake/p' "${REBUILD}")"
[[ "${_pre}" == *"GEN_BEFORE="* ]] \
    && ok "the previous generation is captured before the switch" \
    || bad "GEN_BEFORE is not captured before the rebuild — nothing to roll back to"
[[ "${_pre}" == *"--record"* ]] \
    && ok "the failed-unit baseline is recorded before the switch" \
    || bad "no baseline recorded before the switch"
grep -q 'switch-to-configuration" switch' "${REBUILD}" \
    && ok "the rebuild rolls back by switching the captured generation" \
    || bad "the rebuild has no rollback"
grep -q 'readlink -f /nix/var/nix/profiles/system' "${REBUILD}" \
    && ok "it rolls back to the generation it replaced, not a relative --rollback" \
    || bad "rollback target is not the captured generation"
# A rollback that fails must not look like a rollback that worked.
grep -q 'ROLLBACK FAILED' "${REBUILD}" \
    && ok "a failed rollback says so, with the manual command" \
    || bad "a failed rollback is silent"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
