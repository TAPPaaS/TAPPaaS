#!/usr/bin/env bash
# test-control-plane-refresh.sh — the #595 regression guard.
#
# Self-contained: no VMs, no cluster, no forge. Builds a throwaway cicd tree
# with stub dispatchers and a local bare git repo, and asserts the contract that
# keeps the mothership able to update ITSELF:
#
#   1. refresh-control-plane.sh pulls, relinks ~/bin and builds components,
#      exiting 0 — the whole refresh in one ungated call.
#   2. A component group that fails to BUILD exits 10 (STALE), not 0 and not a
#      hard error: the sweep proceeds on the previous bins, loudly. Silence here
#      is #467; a hard abort here is what #595 was.
#   3. TAPPAAS_NO_GIT_PULL=1 skips the pull and still relinks + builds.
#   4. update-tappaas runs the refresh as Phase 0, BEFORE Phase 1 touches a
#      module — the pull that carries a fix must not sit behind a test of the
#      broken code.
#   5. update-module.sh's pre-update gate asks for --runtime-only, and test.sh
#      honours it by skipping the source-tree region.
#
# Exits 1 if any assertion fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0
pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-refresh.XXXXXX")"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

# ── Fixture: a bare origin + a checkout, and a minimal cicd tree ─────────────
# The refresh reads the repository list from site.json via get_repositories(),
# so CONFIG_DIR points at a fixture holding one repo: our local bare repo.
git init -q --bare "${TMP}/origin.git"
git -c init.defaultBranch=main clone -q "${TMP}/origin.git" "${TMP}/work" >/dev/null 2>&1
(
    cd "${TMP}/work"
    git config user.email t@t; git config user.name t
    echo one > file.txt
    git add file.txt && git commit -qm one && git branch -M main && git push -q origin main
)
git clone -q "${TMP}/origin.git" "${TMP}/checkout" >/dev/null 2>&1
(
    cd "${TMP}/work"
    echo two > file.txt
    git commit -qam two && git push -q origin main
)

FIXTURE="${TMP}/cicd"
mkdir -p "${FIXTURE}/scripts" "${FIXTURE}/lib" "${FIXTURE}/manager" "${FIXTURE}/controller"
cp "${CICD_DIR}/scripts/refresh-control-plane.sh" "${FIXTURE}/scripts/"
cp "${CICD_DIR}/lib/common-install-routines.sh" "${CICD_DIR}/lib/repo-sync.sh" "${FIXTURE}/lib/"
# A script that must end up linked into the fixture's bin dir.
printf '#!/usr/bin/env bash\necho marker\n' > "${FIXTURE}/scripts/marker-tool.sh"
chmod +x "${FIXTURE}/scripts/marker-tool.sh"

mkdir -p "${TMP}/config"
cat > "${TMP}/config/site.json" <<JSON
{"name":"t","repositories":[{"name":"TAPPaaS","url":"${TMP}/origin.git","branch":"main","path":"${TMP}/checkout"}]}
JSON

# Stub dispatchers: record that they ran; $STUB_RC decides whether they succeed.
for d in manager controller; do
    cat > "${FIXTURE}/${d}/install.sh" <<STUB
#!/usr/bin/env bash
echo "${d}" >> "\${STUB_LOG}"
exit "\${STUB_RC:-0}"
STUB
    chmod +x "${FIXTURE}/${d}/install.sh"
done

run_refresh() {
    # CONFIG_DIR is what get_repositories() reads; TAPPAAS_BIN + TAPPAAS_CICD_DIR
    # keep every write inside the temp tree.
    env CONFIG_DIR="${TMP}/config" \
        TAPPAAS_CICD_DIR="${FIXTURE}" \
        TAPPAAS_BIN="${TMP}/bin" \
        STUB_LOG="${TMP}/stub.log" \
        "$@" \
        "${FIXTURE}/scripts/refresh-control-plane.sh" >"${TMP}/out" 2>&1
}

# ── 1. A clean refresh pulls, links and builds, and exits 0 ─────────────────
: > "${TMP}/stub.log"
rc=0; run_refresh || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    pass "clean refresh exits 0"
else
    fail "clean refresh exited ${rc} (expected 0)"; sed 's/^/      /' "${TMP}/out"
fi
if [[ "$(cat "${TMP}/checkout/file.txt" 2>/dev/null)" == "two" ]]; then
    pass "repository pulled to the origin tip"
else
    fail "repository was NOT pulled (file.txt != 'two')"
fi
if [[ -L "${TMP}/bin/marker-tool.sh" ]]; then
    pass "scripts/*.sh relinked into the bin dir"
else
    fail "marker-tool.sh was not linked into the bin dir"
fi
if [[ "$(sort "${TMP}/stub.log" | tr '\n' ' ')" == "controller manager " ]]; then
    pass "both component dispatchers ran"
else
    fail "dispatchers did not both run: $(tr '\n' ' ' < "${TMP}/stub.log")"
fi

# ── 2. A failing component build is STALE (rc 10), not success, not fatal ───
: > "${TMP}/stub.log"
rc=0; run_refresh STUB_RC=3 || rc=$?
if [[ "${rc}" -eq 10 ]]; then
    pass "failed component build exits 10 (STALE)"
else
    fail "failed component build exited ${rc} (expected 10)"
fi
if grep -q "STALE" "${TMP}/out"; then
    pass "the stale-bins condition is named in the output"
else
    fail "a failed component build was not reported as STALE"
fi
# Both dispatchers still get their chance — one bad component must not stop the
# other from rebuilding.
if [[ "$(wc -l < "${TMP}/stub.log")" -eq 2 ]]; then
    pass "a failing dispatcher does not abort the loop"
else
    fail "the dispatcher loop aborted early on a failure"
fi

# ── 3. TAPPAAS_NO_GIT_PULL=1 skips the pull, still relinks + builds ─────────
(cd "${TMP}/work" && echo three > file.txt && git commit -qam three && git push -q origin main)
: > "${TMP}/stub.log"
rc=0; run_refresh TAPPAAS_NO_GIT_PULL=1 || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    pass "--no-git-pull refresh exits 0"
else
    fail "--no-git-pull refresh exited ${rc}"
fi
if [[ "$(cat "${TMP}/checkout/file.txt")" == "two" ]]; then
    pass "TAPPAAS_NO_GIT_PULL=1 left the checkout unpulled"
else
    fail "TAPPAAS_NO_GIT_PULL=1 pulled anyway"
fi
if [[ "$(wc -l < "${TMP}/stub.log")" -eq 2 ]]; then
    pass "TAPPAAS_NO_GIT_PULL=1 still rebuilds the components"
else
    fail "TAPPAAS_NO_GIT_PULL=1 skipped the component build"
fi

# ── 4. The refresh is Phase 0 — ahead of Phase 1 ───────────────────────────
# The ratchet #595 describes exists precisely when the refresh sits inside a
# module update. Assert the call site by ORDER in main(), not by its presence.
_main_py="${CICD_DIR}/update-tappaas/src/update_tappaas/main.py"
if [[ -f "${_main_py}" ]]; then
    _n_refresh="$(grep -n 'control_plane = refresh_control_plane()' "${_main_py}" | head -1 | cut -d: -f1)"
    _n_phase1="$(grep -n 'Phase 1: Updating foundation modules' "${_main_py}" | head -1 | cut -d: -f1)"
    if [[ -n "${_n_refresh}" && -n "${_n_phase1}" && "${_n_refresh}" -lt "${_n_phase1}" ]]; then
        pass "update-tappaas refreshes the control plane before Phase 1"
    else
        fail "#595: the control-plane refresh is not ahead of Phase 1 in main()"
    fi
    if grep -q '"control_plane": control_plane' "${_main_py}"; then
        pass "the refresh outcome reaches last-update-result.json"
    else
        fail "#595: a skipped/stale refresh is not recorded in the result artefact"
    fi
else
    fail "update-tappaas main.py not found at ${_main_py}"
fi

# ── 5. The pre-update gate is runtime-only, and test.sh honours it ──────────
# Since #635 the gate calls test-module.sh through run_graded_test.
if grep -qE 'test-module\.sh --runtime-only|run_graded_test "\$\{PRE_TEST_LOG\}" --runtime-only' \
    "${CICD_DIR}/manager/module-manager/update-module.sh"; then
    pass "update-module.sh's pre-update gate asks for --runtime-only"
else
    fail "#595: the pre-update gate still runs a module's source-tree checks"
fi
if grep -q 'RUNTIME_ONLY="${TAPPAAS_TEST_RUNTIME_ONLY:-0}"' "${CICD_DIR}/test.sh" \
   && grep -q 'if \[\[ "${RUNTIME_ONLY}" == "1" \]\]; then' "${CICD_DIR}/test.sh"; then
    pass "test.sh reads TAPPAAS_TEST_RUNTIME_ONLY and gates the source-tree region"
else
    fail "#595: test.sh does not gate its source-tree checks on --runtime-only"
fi
# --deep must still run them: the deep sweep is where source drift belongs.
if grep -q '\[\[ "${DEEP}" == "1" \]\] && RUNTIME_ONLY=0' "${CICD_DIR}/test.sh"; then
    pass "--deep still runs the source-tree checks"
else
    fail "--deep no longer runs the source-tree checks"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
