#!/usr/bin/env bash
# test-dispatch-contract.sh — ADR-007 P10 dispatcher-contract unit test.
#
# Self-contained: no VMs, no cluster, no network. Asserts the P10 contract for
# the manager/ and controller/ per-directory dispatchers:
#   1. The dispatcher runs a dropped-in component and SKIPS a TEMPLATE/ dir
#      (the skip guard stays even though the scaffold TEMPLATEs were retired —
#      it keeps any future scaffold/work dir named TEMPLATE inert)
#   2. ShellCheck (-S warning) is clean on all six dispatchers
#
# (The TEMPLATE skeleton dirs themselves were removed in the ADR-007
# post-implementation refactor — a new component is scaffolded by copying the
# nearest real component. See docs/design/ADR007-post-implement-refactor.md.)
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
# Check 1: dispatch behaviour in an ISOLATED temp tree
#   - copy the REAL manager/test.sh dispatcher
#   - drop in a fake component 'demo/' whose test.sh writes a marker
#   - drop a TEMPLATE/ whose test.sh writes a FORBIDDEN marker
#   - run the copied dispatcher (cwd = temp dir)
#   - assert: demo marker EXISTS, TEMPLATE forbidden-marker does NOT
# ---------------------------------------------------------------------------
echo "[1] dispatcher runs a dropped-in component and skips TEMPLATE/"
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

# A dropped-in component: just a directory with an executable test.sh —
# exactly what "adding a component" means under the dispatch contract.
mkdir -p "${TMPDIR_TEST}/demo"
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
    pass "dropped-in demo component ran via dispatcher"
else
    fail "dropped-in demo component did NOT run via dispatcher"
fi
if [[ ! -f "${forbidden_marker}" ]]; then
    pass "dispatcher skipped TEMPLATE/"
else
    fail "dispatcher ran TEMPLATE/ (must be skipped)"
fi

# ---------------------------------------------------------------------------
# Check 2: ShellCheck (-S warning) on the six dispatchers
# ---------------------------------------------------------------------------
echo "[2] shellcheck -S warning on the dispatchers"
if command -v shellcheck >/dev/null 2>&1; then
    sc_targets=(
        "${CICD_DIR}/manager/install.sh"
        "${CICD_DIR}/manager/update.sh"
        "${CICD_DIR}/manager/test.sh"
        "${CICD_DIR}/controller/install.sh"
        "${CICD_DIR}/controller/update.sh"
        "${CICD_DIR}/controller/test.sh"
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
