#!/usr/bin/env bash
#
# TAPPaaS Module Tester with Dependency-Recursive Testing
#
# Tests a TAPPaaS module by first running each dependency's
# test-service.sh script (e.g., cluster:vm verifies the VM is up,
# firewall:proxy verifies the reverse proxy), then running the
# module's own test.sh.
#
# Usage: test-module.sh [options] <module-name>
#
# Arguments:
#   module-name   Name of the module to test (must have a
#                 <module-name>.json in /home/tappaas/config/)
#
# Options:
#   -h, --help    Show this help message
#   --deep        Run extended/heavy tests (exports TAPPAAS_TEST_DEEP=1)
#   --debug       Show Debug-level messages (also set via TAPPAAS_DEBUG=1)
#   --silent      Suppress Info-level messages
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#   2  Fatal error (module unreachable, config missing, etc.)
#
# Examples:
#   test-module.sh openwebui
#   test-module.sh --deep litellm
#   test-module.sh --silent --deep vaultwarden
#
# The script performs these steps:
#   1. Validates the module JSON config
#   2. Checks that dependency services have test-service.sh scripts
#   3. Calls each dependency's test-service.sh <module>
#   4. Calls the module's own test.sh <module>
#   5. Reports structured results
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Globals ──────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FATAL=false

# OPT_DEBUG and OPT_SILENT are initialized by common-install-routines.sh
# from TAPPAAS_DEBUG and TAPPAAS_SILENT env vars. --debug/--silent flags
# in main() override them before any output.
OPT_DEEP="${TAPPAAS_TEST_DEEP:-0}"

# ── Test result helpers ───────────────────────────────────────────────

test_pass() {
    info "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

test_fail() {
    error "  ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

test_skip() {
    info "  ${YW}⊘${CL} $1 (skipped)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [options] <module-name>

Test a TAPPaaS module with dependency-recursive service testing.

Arguments:
    module-name    Name of the module (must have config in ${CONFIG_DIR}/)

Options:
    -h, --help     Show this help message
    --deep         Run extended/heavy tests (exports TAPPAAS_TEST_DEEP=1)
    --debug        Show Debug-level messages (also via TAPPAAS_DEBUG=1)
    --silent       Suppress Info-level messages

Exit codes:
    0  All tests passed
    1  One or more tests failed
    2  Fatal error (requires rollback/reinstall)

Examples:
    ${SCRIPT_NAME} openwebui
    ${SCRIPT_NAME} --deep litellm
    ${SCRIPT_NAME} --silent --deep vaultwarden
EOF
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local module=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   usage; exit 0 ;;
            --deep)      OPT_DEEP=1; shift ;;
            --debug)     OPT_DEBUG=1; shift ;;
            --silent)    OPT_SILENT=1; shift ;;
            -*)          fatal "Unknown option: $1"; usage; exit 2 ;;
            *)
                if [[ -z "${module}" ]]; then
                    module="$1"
                else
                    fatal "Unexpected argument: $1"
                    usage
                    exit 2
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${module}" ]]; then
        fatal "Module name is required"
        usage
        exit 2
    fi

    # Export options so child test scripts can read them
    export TAPPAAS_TEST_DEEP="${OPT_DEEP}"
    export TAPPAAS_DEBUG="${OPT_DEBUG}"

    local module_json="${CONFIG_DIR}/${module}.json"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Test: ${BL}${module}${CL}"
    if [[ "${OPT_DEEP}" -eq 1 ]]; then
        info "${BOLD}║  Mode: ${YW}deep${CL}"
    fi
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate module config ───────────────────────────────
    echo ""
    info "${BOLD}Step 1: Validate module configuration${CL}"

    if [[ ! -f "${module_json}" ]]; then
        fatal "Module config not found: ${module_json} — is the module installed?"
        exit 2
    fi

    if check_json "${module_json}"; then
        test_pass "Module config is valid"
    else
        fatal "JSON validation failed for ${module}"
        exit 2
    fi

    debug "Config file: ${module_json}"

    # ── Step 2: Check dependency test-service.sh availability ────────
    echo ""
    info "${BOLD}Step 2: Check dependency test availability${CL}"

    local depends_on
    depends_on=$(jq -r '.dependsOn // [] | .[]' "${module_json}" 2>/dev/null)

    if [[ -z "${depends_on}" ]]; then
        info "  No dependencies declared"
    else
        for dep in ${depends_on}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            if provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                local svc_test="${provider_dir}/services/${service_name}/test-service.sh"
                if [[ -f "${svc_test}" ]]; then
                    info "  ${GN}✓${CL} ${dep} — test-service.sh found"
                else
                    warn "${dep} — no test-service.sh (will skip)"
                fi
            else
                warn "${dep} — provider module directory not found (will skip)"
            fi
        done
    fi

    # ── Step 3: Call dependency test-service.sh scripts ──────────────
    echo ""
    info "${BOLD}Step 3: Run dependency service tests${CL}"

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to test"
    else
        for dep in ${depends_on}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            if ! provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                test_skip "${dep} — provider not found"
                continue
            fi

            ensure_scripts_executable "${provider_dir}"
            local svc_test="${provider_dir}/services/${service_name}/test-service.sh"

            if [[ ! -x "${svc_test}" ]]; then
                test_skip "${dep} — no test-service.sh"
                continue
            fi

            info "  Running ${BL}${dep}${CL} test-service.sh for '${module}'..."
            if "${svc_test}" "${module}"; then
                test_pass "${dep} service tests passed"
            else
                local exit_code=$?
                if [[ ${exit_code} -eq 2 ]]; then
                    fatal "${dep} service test reported a fatal error"
                    FATAL=true
                fi
                test_fail "${dep} service tests failed"
            fi
        done
    fi

    # ── Step 4: Call the module's own test.sh ────────────────────────
    echo ""
    info "${BOLD}Step 4: Run module test.sh${CL}"

    local module_dir
    if module_dir=$(get_module_dir "${module}" 2>/dev/null); then
        ensure_scripts_executable "${module_dir}"
        if [[ -x "${module_dir}/test.sh" ]]; then
            info "  Running ${module_dir}/test.sh..."
            cd "${module_dir}"
            if ./test.sh "${module}"; then
                test_pass "Module test.sh passed"
            else
                local exit_code=$?
                if [[ ${exit_code} -eq 2 ]]; then
                    fatal "Module test.sh reported a fatal error"
                    FATAL=true
                fi
                test_fail "Module test.sh failed"
            fi
        else
            test_skip "No executable test.sh found"
        fi
    else
        test_skip "Module directory not found — cannot run test.sh"
    fi

    # ── Final verdict ─────────────────────────────────────────────────
    echo ""
    if [[ "${FATAL}" == true ]]; then
        fatal "Fatal error detected — module may require rollback/reinstall"
        exit 2
    fi

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        error "Test run FAILED — ${FAIL_COUNT} check(s) did not pass"
        exit 1
    fi

    info "${GN}${BOLD}All tests passed for module '${module}'${CL}"
    exit 0
}

main "$@"
