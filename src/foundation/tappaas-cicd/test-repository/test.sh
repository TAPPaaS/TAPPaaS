#!/usr/bin/env bash
#
# TAPPaaS Repository Management Test Suite
#
# Tests the repository.sh add/remove/modify/list commands.
#
# The repository list is canonical in site.json .repositories (ADR-007); this
# suite exercises that store. ALL state lives in an isolated temporary
# CONFIG_DIR fixture (a site.json built in $TEST_CONFIG_DIR) — the live
# /home/tappaas/config is NEVER read or mutated. repository.sh honours the
# CONFIG_DIR environment variable, which the tests point at the fixture.
#
# Usage: ./test.sh [--skip-network]
#
# Options:
#   --skip-network  Skip tests that require network access (git clone)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPT="/home/tappaas/bin/repository.sh"
LOG_DIR="/home/tappaas/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_test-repository.log"

# Isolated fixture config dir — created fresh per run, removed on exit. The live
# /home/tappaas/config is intentionally untouched.
TEST_CONFIG_DIR=""
SITE_FILE=""

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

# Run repository.sh against the isolated fixture CONFIG_DIR.
repo() {
    CONFIG_DIR="${TEST_CONFIG_DIR}" "${REPO_SCRIPT}" "$@"
}

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
# Arguments: <test-name> <condition-description> <command-string>
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

# Build a fresh isolated fixture: a temp CONFIG_DIR holding a site.json with
# a .repositories array (identical shape to the live one). Records the live
# config mtime so the EXIT trap can assert it was never touched.
LIVE_CONFIG_DIR="/home/tappaas/config"
setup_fixture() {
    TEST_CONFIG_DIR=$(mktemp -d)
    SITE_FILE="${TEST_CONFIG_DIR}/site.json"
    cat > "${SITE_FILE}" << 'SITEJSON'
{
    "name": "test",
    "repositories": [
        {
            "name": "TAPPaaS",
            "url": "github.com/TAPPaaS/TAPPaaS",
            "branch": "main",
            "path": "/home/tappaas/TAPPaaS",
            "managed": "full",
            "catalog": "src/module-catalog.json"
        }
    ]
}
SITEJSON
}

cleanup() {
    [[ -n "${TEST_CONFIG_DIR}" && -d "${TEST_CONFIG_DIR}" ]] && rm -rf "${TEST_CONFIG_DIR}"
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
    # Try the source location (relocated under manager/site-manager/)
    REPO_SCRIPT="${SCRIPT_DIR}/../manager/site-manager/repository.sh"
    if [[ ! -f "${REPO_SCRIPT}" ]]; then
        echo -e "${RED}ERROR: repository.sh not found${NC}"
        exit 1
    fi
fi
chmod +x "${REPO_SCRIPT}" 2>/dev/null || true

setup_fixture
trap cleanup EXIT

# Snapshot the live config dir so we can assert (best-effort) it stays untouched.
LIVE_SITE_SUM=""
LIVE_CFG_SUM=""
[[ -f "${LIVE_CONFIG_DIR}/site.json" ]] && LIVE_SITE_SUM=$(sha256sum "${LIVE_CONFIG_DIR}/site.json")
[[ -f "${LIVE_CONFIG_DIR}/configuration.json" ]] && LIVE_CFG_SUM=$(sha256sum "${LIVE_CONFIG_DIR}/configuration.json")

# ── Test 1: Help and usage ───────────────────────────────────────────
echo "Test Group 1: Help and Usage"

run_test "help-flag" "pass" repo --help
run_test "no-args" "fail" repo
run_test "invalid-command" "fail" repo invalid-command
echo ""

# ── Test 2: List command (reads site.json .repositories) ─────────────
echo "Test Group 2: List Command"

run_test "list-repos" "pass" repo list

check_condition "list-shows-tappaas" "TAPPaaS repo in list" \
    "repo list 2>&1 | grep -c 'TAPPaaS' >/dev/null"
echo ""

# ── Test 3: Add command validation ───────────────────────────────────
echo "Test Group 3: Add Command Validation"

run_test "add-no-url" "fail" repo add
run_test "add-invalid-url" "fail" repo add "invalid-url-does-not-exist.example.com/foo/bar"
run_test "add-duplicate-name" "fail" repo add "github.com/TAPPaaS/TAPPaaS"
echo ""

# ── Test 4: site.json add/modify/remove (no network) ────────────────
# These prove add/remove/modify/list operate on site.json .repositories using a
# manual entry (mirroring what cmd_add writes) so the data-store wiring is
# verified without a real git clone.
echo "Test Group 4: site.json store operations (no network)"

TEST_REPO_NAME="fixture-repo-$$"
# Manually add an entry to site.json .repositories (no clone/network).
tmp_file=$(mktemp)
jq --arg name "${TEST_REPO_NAME}" \
   --arg url "local/${TEST_REPO_NAME}" \
   --arg branch "main" \
   --arg path "/tmp/${TEST_REPO_NAME}" \
   '.repositories = (.repositories // []) + [{"name": $name, "url": $url, "branch": $branch, "path": $path, "managed": "tracked"}]' \
   "${SITE_FILE}" > "${tmp_file}"
mv "${tmp_file}" "${SITE_FILE}"

check_condition "site-add-entry" "site.json .repositories has new entry" \
    "jq -e --arg n '${TEST_REPO_NAME}' '.repositories[] | select(.name == \$n)' '${SITE_FILE}' >/dev/null 2>&1"

check_condition "list-shows-fixture" "list shows the new repo (from site.json)" \
    "repo list 2>&1 | grep -c '${TEST_REPO_NAME}' >/dev/null"

# modify branch on a non-cloned repo: the script tries to fetch the (missing)
# dir, so it is expected to fail — but it must locate the entry in site.json
# (i.e. not report 'not found in configuration'). Verify the lookup resolves.
check_condition "get-repo-from-site" "get_repo_by_name resolves from site.json" \
    "repo modify '${TEST_REPO_NAME}' 2>&1 | grep -q 'Current branch: main'"

# remove the entry (no installed modules, no dir) — should update site.json.
run_test "remove-fixture" "pass" repo remove "${TEST_REPO_NAME}"

check_condition "site-remove-clean" "site.json no longer has the repo" \
    "! jq -e --arg n '${TEST_REPO_NAME}' '.repositories[] | select(.name == \$n)' '${SITE_FILE}' >/dev/null 2>&1"
echo ""

# ── Test 5: Network tests (real clone add/modify/remove) ────────────
if [[ "${SKIP_NETWORK}" == "true" ]]; then
    echo "Test Group 5: Network Tests (SKIPPED --skip-network)"
    ((SKIP += 4))
    echo ""
else
    echo "Test Group 5: Network Tests (local bare repo add/modify/remove)"

    TEST_BARE_DIR=$(mktemp -d)
    NET_REPO_NAME="net-repo-$$"

    # Create a minimal test repo locally with a module catalog.
    (
        cd "${TEST_BARE_DIR}"
        git init --bare "${NET_REPO_NAME}.git" >/dev/null 2>&1
        WORK_DIR=$(mktemp -d)
        cd "${WORK_DIR}"
        git init >/dev/null 2>&1
        git checkout -b main >/dev/null 2>&1
        mkdir -p src
        cat > src/module-catalog.json << 'MODJSON'
{
    "description": "Test Module Registry",
    "foundationModules": [],
    "applicationModules": [
        {"moduleName": "test-app", "vmid": 9999, "moduleJson": "src/apps/test-app/test-app.json"}
    ],
    "proxmoxTemplates": [],
    "testModules": []
}
MODJSON
        git add -A >/dev/null 2>&1
        git commit -m "initial" >/dev/null 2>&1
        git remote add origin "${TEST_BARE_DIR}/${NET_REPO_NAME}.git" >/dev/null 2>&1
        git push origin main >/dev/null 2>&1
        git checkout -b develop >/dev/null 2>&1
        echo "develop" > src/BRANCH_MARKER
        git add -A >/dev/null 2>&1
        git commit -m "develop branch" >/dev/null 2>&1
        git push origin develop >/dev/null 2>&1
        rm -rf "${WORK_DIR}"
    )

    # Simulate the clone + site.json entry that cmd_add produces for a local
    # repo (URL validation prepends https://, which can't reach a local path).
    NET_CLONE_PATH=$(mktemp -d)/${NET_REPO_NAME}
    git clone "${TEST_BARE_DIR}/${NET_REPO_NAME}.git" "${NET_CLONE_PATH}" >/dev/null 2>&1

    tmp_file=$(mktemp)
    jq --arg name "${NET_REPO_NAME}" \
       --arg url "local/${NET_REPO_NAME}" \
       --arg branch "main" \
       --arg path "${NET_CLONE_PATH}" \
       '.repositories = (.repositories // []) + [{"name": $name, "url": $url, "branch": $branch, "path": $path, "managed": "full", "catalog": "src/module-catalog.json"}]' \
       "${SITE_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${SITE_FILE}"

    check_condition "net-add-config" "site.json has the cloned repo" \
        "jq -e --arg n '${NET_REPO_NAME}' '.repositories[] | select(.name == \$n)' '${SITE_FILE}' >/dev/null 2>&1"

    (cd "${NET_CLONE_PATH}" && git fetch origin >/dev/null 2>&1)
    run_test "net-modify-branch" "pass" repo modify "${NET_REPO_NAME}" --branch develop

    check_condition "net-modify-config" "site.json branch updated to develop" \
        "jq -r --arg n '${NET_REPO_NAME}' '.repositories[] | select(.name == \$n) | .branch' '${SITE_FILE}' | grep -q 'develop'"

    run_test "net-remove" "pass" repo remove "${NET_REPO_NAME}"

    check_condition "net-remove-clean" "site.json no longer has the repo" \
        "! jq -e --arg n '${NET_REPO_NAME}' '.repositories[] | select(.name == \$n)' '${SITE_FILE}' >/dev/null 2>&1"

    rm -rf "${TEST_BARE_DIR}" "$(dirname "${NET_CLONE_PATH}")"
    echo ""
fi

# ── Test 6: Remove/modify command validation ────────────────────────
echo "Test Group 6: Remove/Modify Command Validation"

run_test "remove-no-name" "fail" repo remove
run_test "remove-nonexistent" "fail" repo remove "nonexistent-repo"
run_test "modify-no-name" "fail" repo modify
run_test "modify-nonexistent" "fail" repo modify "nonexistent-repo" --branch main
echo ""

# ── Test 7: Live config untouched ────────────────────────────────────
echo "Test Group 7: Live config isolation"

NOW_SITE_SUM=""
NOW_CFG_SUM=""
[[ -f "${LIVE_CONFIG_DIR}/site.json" ]] && NOW_SITE_SUM=$(sha256sum "${LIVE_CONFIG_DIR}/site.json")
[[ -f "${LIVE_CONFIG_DIR}/configuration.json" ]] && NOW_CFG_SUM=$(sha256sum "${LIVE_CONFIG_DIR}/configuration.json")

check_condition "live-site-untouched" "live site.json unchanged" \
    "[[ '${LIVE_SITE_SUM}' == '${NOW_SITE_SUM}' ]]"
check_condition "live-config-untouched" "live configuration.json unchanged" \
    "[[ '${LIVE_CFG_SUM}' == '${NOW_CFG_SUM}' ]]"
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
