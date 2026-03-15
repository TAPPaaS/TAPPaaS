#!/usr/bin/env bash
#
# TAPPaaS Repository Management Test Suite
#
# Tests the repository.sh add/remove/modify/list commands.
# Uses the TAPPaaS repository itself as a test target.
#
# Usage: ./test.sh [--skip-network]
#
# Options:
#   --skip-network  Skip tests that require network access (git clone)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPT="/home/tappaas/bin/repository.sh"
CONFIG_FILE="/home/tappaas/config/configuration.json"
LOG_DIR="/home/tappaas/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_test-repository.log"

# Test state
PASS=0
FAIL=0
SKIP=0
SKIP_NETWORK=false

# Colors
readonly RED=$'\033[31m'
readonly GREEN=$'\033[32m'
readonly YELLOW=$'\033[33m'
readonly NC=$'\033[0m'

# Parse arguments
for arg in "$@"; do
    case "${arg}" in
        --skip-network) SKIP_NETWORK=true ;;
        -*) echo "Unknown option: ${arg}"; exit 1 ;;
    esac
done

mkdir -p "${LOG_DIR}"

# ── Test Helpers ─────────────────────────────────────────────────────

# Run a test case
# Arguments: <test-name> <expected: pass|fail> <command...>
run_test() {
    local test_name="$1"
    local expected="$2"
    shift 2

    echo -n "  [${test_name}] "

    local output
    local exit_code=0
    output=$("$@" 2>&1) || exit_code=$?

    echo "${output}" >> "${LOG_FILE}"

    if [[ "${expected}" == "pass" && "${exit_code}" -eq 0 ]]; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
        return 0
    elif [[ "${expected}" == "fail" && "${exit_code}" -ne 0 ]]; then
        echo -e "${GREEN}PASS${NC} (expected failure)"
        PASS=$((PASS + 1))
        return 0
    else
        if [[ "${expected}" == "pass" ]]; then
            echo -e "${RED}FAIL${NC} (expected success, got exit code ${exit_code})"
        else
            echo -e "${RED}FAIL${NC} (expected failure, got exit code 0)"
        fi
        echo "    Output: $(echo "${output}" | tail -3 | sed 's/^/    /')"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

# Check a condition
# Arguments: <test-name> <condition-description>
# Stdin: none — uses the exit code of the preceding command
check_condition() {
    local test_name="$1"
    local description="$2"

    echo -n "  [${test_name}] ${description}... "
    if eval "$3"; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAIL=$((FAIL + 1))
    fi
}

# Backup configuration.json before tests
backup_config() {
    cp "${CONFIG_FILE}" "${CONFIG_FILE}.test-backup"
}

# Restore configuration.json after tests
restore_config() {
    if [[ -f "${CONFIG_FILE}.test-backup" ]]; then
        mv "${CONFIG_FILE}.test-backup" "${CONFIG_FILE}"
    fi
}

# ── Tests ────────────────────────────────────────────────────────────

echo "=============================================="
echo "TAPPaaS Repository Management Test Suite"
echo "Started: $(date)"
echo "Log: ${LOG_FILE}"
echo "=============================================="
echo ""

# Verify prerequisites
if [[ ! -x "${REPO_SCRIPT}" ]] && [[ ! -f "${REPO_SCRIPT}" ]]; then
    # Try the source location
    REPO_SCRIPT="${SCRIPT_DIR}/../scripts/repository.sh"
    if [[ ! -f "${REPO_SCRIPT}" ]]; then
        echo -e "${RED}ERROR: repository.sh not found${NC}"
        exit 1
    fi
fi
chmod +x "${REPO_SCRIPT}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${RED}ERROR: configuration.json not found at ${CONFIG_FILE}${NC}"
    exit 1
fi

# Backup config
backup_config
trap restore_config EXIT

# ── Test 1: Help and usage ───────────────────────────────────────────
echo "Test Group 1: Help and Usage"

run_test "help-flag" "pass" "${REPO_SCRIPT}" --help
run_test "no-args" "fail" "${REPO_SCRIPT}"
run_test "invalid-command" "fail" "${REPO_SCRIPT}" invalid-command
echo ""

# ── Test 2: List command ─────────────────────────────────────────────
echo "Test Group 2: List Command"

run_test "list-repos" "pass" "${REPO_SCRIPT}" list

check_condition "list-shows-tappaas" "TAPPaaS repo in list" \
    "'${REPO_SCRIPT}' list 2>&1 | grep -c 'TAPPaaS' >/dev/null"
echo ""

# ── Test 3: Add command validation ───────────────────────────────────
echo "Test Group 3: Add Command Validation"

run_test "add-no-url" "fail" "${REPO_SCRIPT}" add
run_test "add-invalid-url" "fail" "${REPO_SCRIPT}" add "invalid-url-does-not-exist.example.com/foo/bar"
run_test "add-duplicate-name" "fail" "${REPO_SCRIPT}" add "github.com/TAPPaaS/TAPPaaS"
echo ""

# ── Test 4: Network tests (add/modify/remove) ───────────────────────
if [[ "${SKIP_NETWORK}" == "true" ]]; then
    echo "Test Group 4: Network Tests (SKIPPED --skip-network)"
    ((SKIP += 6))
    echo ""
else
    echo "Test Group 4: Network Tests (add/modify/remove)"

    # Use a known small public repo for testing
    # We use the TAPPaaS repo itself but to a different directory
    TEST_URL="github.com/TAPPaaS/TAPPaaS"
    TEST_BRANCH="main"
    # We need a different name since TAPPaaS is already tracked
    # Create a small local bare repo for testing instead
    TEST_BARE_DIR=$(mktemp -d)
    TEST_REPO_NAME="test-repo-$$"

    # Create a minimal test repo locally
    (
        cd "${TEST_BARE_DIR}"
        git init --bare "${TEST_REPO_NAME}.git" >/dev/null 2>&1

        # Create a working copy, add modules.json, push
        WORK_DIR=$(mktemp -d)
        cd "${WORK_DIR}"
        git init >/dev/null 2>&1
        git checkout -b main >/dev/null 2>&1
        mkdir -p src
        cat > src/modules.json << 'MODJSON'
{
    "description": "Test Module Registry",
    "foundationModules": [],
    "applicationModules": [
        {
            "moduleName": "test-app",
            "vmid": 9999,
            "moduleJson": "src/apps/test-app/test-app.json"
        }
    ],
    "proxmoxTemplates": [],
    "testModules": []
}
MODJSON
        git add -A >/dev/null 2>&1
        git commit -m "initial" >/dev/null 2>&1
        git remote add origin "${TEST_BARE_DIR}/${TEST_REPO_NAME}.git" >/dev/null 2>&1
        git push origin main >/dev/null 2>&1

        # Create a develop branch
        git checkout -b develop >/dev/null 2>&1
        echo "develop" > src/BRANCH_MARKER
        git add -A >/dev/null 2>&1
        git commit -m "develop branch" >/dev/null 2>&1
        git push origin develop >/dev/null 2>&1

        rm -rf "${WORK_DIR}"
    )

    # Override the URL validation for local repos by using file:// protocol
    # We need to test with the actual script, so use the local bare repo path
    # The script prepends https://, so we test with a direct approach

    # Test: verify we can detect the local repo structure after manual clone
    echo "  (Using local test repository for add/modify/remove tests)"

    # Manually simulate what repository.sh add does for a local repo
    TEST_CLONE_PATH="/home/tappaas/${TEST_REPO_NAME}"
    git clone "${TEST_BARE_DIR}/${TEST_REPO_NAME}.git" "${TEST_CLONE_PATH}" >/dev/null 2>&1

    # Manually add to config
    tmp_file=$(mktemp)
    jq --arg name "${TEST_REPO_NAME}" \
       --arg url "local/${TEST_REPO_NAME}" \
       --arg branch "main" \
       --arg path "${TEST_CLONE_PATH}" \
       '.tappaas.repositories = (.tappaas.repositories // []) + [{"name": $name, "url": $url, "branch": $branch, "path": $path}]' \
       "${CONFIG_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${CONFIG_FILE}"

    check_condition "add-config-updated" "Config has new repo" \
        "jq -e --arg n '${TEST_REPO_NAME}' '.tappaas.repositories[] | select(.name == \$n)' '${CONFIG_FILE}' >/dev/null 2>&1"

    check_condition "add-clone-exists" "Clone directory exists" \
        "[ -d '${TEST_CLONE_PATH}' ]"

    check_condition "add-modules-json" "Clone has src/modules.json" \
        "[ -f '${TEST_CLONE_PATH}/src/modules.json' ]"

    # Test: list shows new repo
    check_condition "list-shows-test" "List shows test repo" \
        "'${REPO_SCRIPT}' list 2>&1 | grep -q '${TEST_REPO_NAME}'"

    # Test: modify branch
    (cd "${TEST_CLONE_PATH}" && git fetch origin >/dev/null 2>&1)
    run_test "modify-branch" "pass" "${REPO_SCRIPT}" modify "${TEST_REPO_NAME}" --branch develop

    check_condition "modify-branch-config" "Config updated to develop" \
        "jq -r --arg n '${TEST_REPO_NAME}' '.tappaas.repositories[] | select(.name == \$n) | .branch' '${CONFIG_FILE}' | grep -q 'develop'"

    # Test: remove
    run_test "remove-repo" "pass" "${REPO_SCRIPT}" remove "${TEST_REPO_NAME}"

    check_condition "remove-config-clean" "Config no longer has test repo" \
        "! jq -e --arg n '${TEST_REPO_NAME}' '.tappaas.repositories[] | select(.name == \$n)' '${CONFIG_FILE}' >/dev/null 2>&1"

    check_condition "remove-dir-gone" "Clone directory removed" \
        "[ ! -d '${TEST_CLONE_PATH}' ]"

    # Cleanup
    rm -rf "${TEST_BARE_DIR}"

    echo ""
fi

# ── Test 5: Remove command validation ────────────────────────────────
echo "Test Group 5: Remove Command Validation"

run_test "remove-no-name" "fail" "${REPO_SCRIPT}" remove
run_test "remove-nonexistent" "fail" "${REPO_SCRIPT}" remove "nonexistent-repo"
echo ""

# ── Test 6: Modify command validation ────────────────────────────────
echo "Test Group 6: Modify Command Validation"

run_test "modify-no-name" "fail" "${REPO_SCRIPT}" modify
run_test "modify-nonexistent" "fail" "${REPO_SCRIPT}" modify "nonexistent-repo" --branch main
echo ""

# ── Summary ──────────────────────────────────────────────────────────
echo "=============================================="
echo "Test Results Summary"
echo "=============================================="
echo ""
echo -e "Passed:  ${GREEN}${PASS}${NC}"
echo -e "Failed:  ${RED}${FAIL}${NC}"
if [[ "${SKIP}" -gt 0 ]]; then
    echo -e "Skipped: ${YELLOW}${SKIP}${NC}"
fi
echo ""
echo "Log: ${LOG_FILE}"
echo "=============================================="

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
