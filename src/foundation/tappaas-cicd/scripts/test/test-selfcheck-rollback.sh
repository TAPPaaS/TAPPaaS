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
# The system PATH as this machine really has it, minus the stub directory: on
# NixOS /bin and /usr/bin hold `env` and no shell, so a fabricated
# "/usr/bin:/bin" cannot start bash and every check fails for the wrong reason.
SYS_PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -v "^${BIN}$" | paste -sd: -)"

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
    cat > "${BIN}/systemctl" <<EOF
#!/usr/bin/env bash
# \`show update-tappaas.service -p Environment --value\`: the unit's PATH, which
# holds the managers; \`--failed --no-legend --plain\`: FAILED_UNITS.
if [[ "\$1" == "show" ]]; then echo "LOCALE_ARCHIVE=/x PATH=${BIN}:${SYS_PATH} TZDIR=/y"; exit 0; fi
printf '%s\n' \${FAILED_UNITS:-}
EOF
    chmod +x "${BIN}/systemctl"
    # `timeout` must stay real, but the stubs must win over the system managers.
    # Faithful to the real runuser in the two ways that broke #713 on a live
    # site: the child starts from ROOT's system-only PATH (no ~tappaas/bin),
    # and argv is executed directly — no shell, so a builtin or a function
    # passed through it does not exist.
    cat > "${BIN}/runuser" <<EOF
#!/usr/bin/env bash
shift 2; [[ "\$1" == "--" ]] && shift
export PATH=${SYS_PATH}
exec "\$@"
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

echo "── run as root: the managers are checked through runuser (#713) ──"
# The rebuild runs this as root. The first live run (hrossen, 2026-09-23)
# failed 8 of 9 checks on a healthy mothership — every manager "not on
# tappaas's PATH" — rolled the generation back and aborted the sweep, because
# the check passed a builtin and a function through runuser, into a child that
# had root's PATH. Driven here with a different TAPPAAS_USER, so as_tappaas
# takes the runuser branch the tests above never reached.
make_stubs 0 0
OUT="$(PATH="${BIN}:${PATH}" TAPPAAS_USER="not-$(id -un)" "${SELFCHECK}" --baseline "${TMP}/base" 2>&1)"; RC=$?
[[ "${RC}" -eq 0 ]] && ok "a healthy control plane passes when checked through runuser" \
                    || bad "healthy plane failed through runuser (exit ${RC}): ${OUT}"
make_stubs 1 0
OUT="$(PATH="${BIN}:${PATH}" TAPPAAS_USER="not-$(id -un)" "${SELFCHECK}" --baseline "${TMP}/base" 2>&1)"; RC=$?
[[ "${RC}" -ne 0 && "${OUT}" == *"will not run"* ]] \
    && ok "…and a dead manager still fails it there" \
    || bad "dead manager passed through runuser (exit ${RC})"
grep -qE 'as_tappaas (command|bounded)' "${SELFCHECK}" \
    && bad "a builtin or function is passed to as_tappaas (runuser cannot run it)" \
    || ok "only programs are passed to as_tappaas"

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
