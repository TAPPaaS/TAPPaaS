#!/usr/bin/env bash
# test-template-contract.sh — ADR-007 P10 component-contract unit test.
#
# Self-contained: no VMs, no cluster, no network. Asserts the P10 contract for
# the manager/ and controller/ TEMPLATE skeletons and the per-directory
# dispatchers:
#   1. Both TEMPLATEs ship executable install/update/test.sh
#   2. manager TEMPLATE ships validate.sh; controller TEMPLATE does NOT
#   3. The dispatcher runs a scaffolded component and SKIPS TEMPLATE/
#   4. ShellCheck (-S warning) is clean on dispatchers + TEMPLATE verb scripts
#
# Exits 1 if any assertion fails.
set -euo pipefail

# scripts/test -> tappaas-cicd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0

pass() {
    printf '  \xe2\x9c\x93 %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf '  \xe2\x9c\x97 %s\n' "$1"
    FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
# Check 1: both TEMPLATEs ship executable install/update/test.sh
# ---------------------------------------------------------------------------
echo "[1] mandatory verb scripts present and executable"
for kind in manager controller; do
    tdir="${CICD_DIR}/${kind}/TEMPLATE"
    for verb in install update test; do
        f="${tdir}/${verb}.sh"
        if [[ -f "${f}" && -x "${f}" ]]; then
            pass "${kind}/TEMPLATE/${verb}.sh exists and is executable"
        else
            fail "${kind}/TEMPLATE/${verb}.sh missing or not executable"
        fi
    done
done

# ---------------------------------------------------------------------------
# Check 2: managers ship validate.sh; controllers do not
# ---------------------------------------------------------------------------
echo "[2] validate.sh present for managers, absent for controllers"
if [[ -f "${CICD_DIR}/manager/TEMPLATE/validate.sh" ]]; then
    pass "manager/TEMPLATE/validate.sh exists"
else
    fail "manager/TEMPLATE/validate.sh missing (managers must ship it)"
fi
if [[ ! -e "${CICD_DIR}/controller/TEMPLATE/validate.sh" ]]; then
    pass "controller/TEMPLATE/validate.sh absent"
else
    fail "controller/TEMPLATE/validate.sh present (controllers must not ship it)"
fi

# ---------------------------------------------------------------------------
# Check 3: dispatch behaviour in an ISOLATED temp tree
#   - copy the REAL manager/test.sh dispatcher
#   - scaffold a fake component 'demo/' from manager/TEMPLATE/ whose test.sh
#     writes a marker into the temp dir
#   - drop a TEMPLATE/ whose test.sh writes a FORBIDDEN marker
#   - run the copied dispatcher (cwd = temp dir)
#   - assert: demo marker EXISTS, TEMPLATE forbidden-marker does NOT
# ---------------------------------------------------------------------------
echo "[3] dispatcher runs scaffolded component and skips TEMPLATE/"
TMPDIR_TEST=""
cleanup() {
    [[ -n "${TMPDIR_TEST}" && -d "${TMPDIR_TEST}" ]] && rm -rf "${TMPDIR_TEST}"
}
trap cleanup EXIT

TMPDIR_TEST="$(mktemp -d)"
demo_marker="${TMPDIR_TEST}/demo.marker"
forbidden_marker="${TMPDIR_TEST}/forbidden.marker"

# Copy the real dispatcher (it locates children via its own BASH_SOURCE dir,
# so running it from the temp tree iterates the temp tree's children).
cp "${CICD_DIR}/manager/test.sh" "${TMPDIR_TEST}/test.sh"
chmod +x "${TMPDIR_TEST}/test.sh"

# Scaffold a component from the real manager/TEMPLATE with zero edits above it.
cp -r "${CICD_DIR}/manager/TEMPLATE" "${TMPDIR_TEST}/demo"
cat >"${TMPDIR_TEST}/demo/test.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "${demo_marker}"
EOF
chmod +x "${TMPDIR_TEST}/demo/test.sh"

# A TEMPLATE/ that must be SKIPPED.
mkdir -p "${TMPDIR_TEST}/TEMPLATE"
cat >"${TMPDIR_TEST}/TEMPLATE/test.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "${forbidden_marker}"
EOF
chmod +x "${TMPDIR_TEST}/TEMPLATE/test.sh"

# Run the dispatcher with cwd = temp dir.
( cd "${TMPDIR_TEST}" && ./test.sh >/dev/null 2>&1 ) || true

if [[ -f "${demo_marker}" ]]; then
    pass "scaffolded demo component ran via dispatcher"
else
    fail "scaffolded demo component did NOT run via dispatcher"
fi
if [[ ! -f "${forbidden_marker}" ]]; then
    pass "dispatcher skipped TEMPLATE/"
else
    fail "dispatcher ran TEMPLATE/ (must be skipped)"
fi

# ---------------------------------------------------------------------------
# Check 4: ShellCheck (-S warning) on dispatchers + TEMPLATE verb scripts
# ---------------------------------------------------------------------------
echo "[4] shellcheck -S warning on dispatchers and TEMPLATE scripts"
if command -v shellcheck >/dev/null 2>&1; then
    sc_targets=(
        "${CICD_DIR}/manager/install.sh"
        "${CICD_DIR}/manager/update.sh"
        "${CICD_DIR}/manager/test.sh"
        "${CICD_DIR}/controller/install.sh"
        "${CICD_DIR}/controller/update.sh"
        "${CICD_DIR}/controller/test.sh"
        "${CICD_DIR}/manager/TEMPLATE/install.sh"
        "${CICD_DIR}/manager/TEMPLATE/update.sh"
        "${CICD_DIR}/manager/TEMPLATE/test.sh"
        "${CICD_DIR}/manager/TEMPLATE/validate.sh"
        "${CICD_DIR}/manager/TEMPLATE/manager.sh"
        "${CICD_DIR}/controller/TEMPLATE/install.sh"
        "${CICD_DIR}/controller/TEMPLATE/update.sh"
        "${CICD_DIR}/controller/TEMPLATE/test.sh"
        "${CICD_DIR}/controller/TEMPLATE/controller.sh"
    )
    for t in "${sc_targets[@]}"; do
        if [[ ! -f "${t}" ]]; then
            fail "shellcheck target missing: ${t#"${CICD_DIR}/"}"
            continue
        fi
        if shellcheck -S warning "${t}" >/dev/null 2>&1; then
            pass "shellcheck clean: ${t#"${CICD_DIR}/"}"
        else
            fail "shellcheck issues: ${t#"${CICD_DIR}/"}"
        fi
    done
else
    echo "  - shellcheck not on PATH; skipped (not a failure)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
