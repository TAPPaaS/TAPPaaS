#!/usr/bin/env bash
#
# TAPPaaS Module Tester with Dependency-Recursive Testing
#
# Tests a TAPPaaS module by first running each dependency's
# test-service.sh script (e.g., cluster:vm verifies the VM is up,
# network:proxy verifies the reverse proxy), then running the
# module's own test.sh.
#
# Usage: test-module.sh [options] <module-name>
#
# Arguments:
#   module-name   Name of the module to test (must have a
#                 <module-name>.json in /home/tappaas/config/)
#
# Options:
#   -h, --help        Show this help message
#   --deep            Run extended/heavy tests (exports TAPPAAS_TEST_DEEP=1)
#   --runtime-only    Skip source-tree checks; test only the live system (#595)
#   --vmid <id>       Test a non-default VM instance (exports
#                     TAPPAAS_VMID_OVERRIDE; consistent with install-module.sh)
#   --zone0 <zone>    Test against a non-default zone (exports
#                     TAPPAAS_ZONE0_OVERRIDE)
#   --debug           Show Debug-level messages (also set via TAPPAAS_DEBUG=1)
#   --silent          Suppress Info-level messages
#
# The --vmid/--zone0 overrides flow to the dependency test-service.sh scripts
# and the module's own test.sh (which read TAPPAAS_VMID_OVERRIDE /
# TAPPAAS_ZONE0_OVERRIDE, falling back to the module config). The config file
# itself is not modified.
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#   2  Fatal error (module unreachable, config missing, etc.)
#
# Examples:
#   test-module.sh openwebui
#   test-module.sh --deep litellm
#   test-module.sh openwebui --vmid 313 --zone0 srv-cust
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
# --runtime-only: run ONLY checks that say something about the live system, and
# skip a module's source-tree checks (offline unit suites, generated-doc drift,
# grep guards over the repo). Set by the callers that use test.sh as a GATE on a
# mutation — update-module.sh's pre-update test — where a source-tree defect
# must not abort the update of a healthy module (#595). An operator running
# test-module.sh by hand, and the deep sweep, still run everything.
OPT_RUNTIME_ONLY="${TAPPAAS_TEST_RUNTIME_ONLY:-0}"

# ── Test result helpers ───────────────────────────────────────────────

test_pass() {
    info "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# Like test_pass but routes the ✓ line to [Debug] (still counts the pass) — for
# sub-checks that are noise when green (e.g. config validation).
test_pass_quiet() {
    debug "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

test_fail() {
    error "  ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# module_test_dependencies <module> — one "<coordinate> required|optional" line
# per service relationship, in declaration order: dependsOn first, then
# integratesWith. Both can synthesise a firewall rule (#632), so both are tested
# (#684); only the origin differs, and with it what an absent provider means.
module_test_dependencies() {
    read_module_config "$1" 2>/dev/null | jq -r '
        ((.dependsOn // [])      | .[] | "\(.) required"),
        ((.integratesWith // []) | .[] | "\(.) optional")' 2>/dev/null
}

test_skip() {
    info "  ${YW}⊘${CL} $1 (skipped)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}
# A skip Test Step 2 has already warned about: counted, shown only as detail.
test_skip_quiet() {
    debug "  ${YW}⊘${CL} $1 (skipped)"
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
    -h, --help        Show this help message
    --deep            Run extended/heavy tests (exports TAPPAAS_TEST_DEEP=1)
    --runtime-only    Skip source-tree checks; test only the live system (#595)
    --vmid <id>       Test a non-default VM instance (override config vmid)
    --zone0 <zone>    Test against a non-default zone (override config zone0)
    --debug           Show Debug-level messages (also via TAPPAAS_DEBUG=1)
    --silent          Suppress Info-level messages

Exit codes:
    0  All tests passed
    1  One or more tests failed
    2  Fatal error (requires rollback/reinstall)

Examples:
    ${SCRIPT_NAME} openwebui
    ${SCRIPT_NAME} --deep litellm
    ${SCRIPT_NAME} openwebui --vmid 313 --zone0 srv-cust
EOF
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local module=""
    local opt_vmid="" opt_zone0=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   usage; exit 0 ;;
            --deep)      OPT_DEEP=1; shift ;;
            --runtime-only) OPT_RUNTIME_ONLY=1; shift ;;
            --vmid)      [[ -n "${2:-}" ]] || { fatal "--vmid requires a value"; exit 2; }; opt_vmid="$2"; shift 2 ;;
            --zone0)     [[ -n "${2:-}" ]] || { fatal "--zone0 requires a value"; exit 2; }; opt_zone0="$2"; shift 2 ;;
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

    if [[ -n "${opt_vmid}" && ! "${opt_vmid}" =~ ^[0-9]+$ ]]; then
        fatal "--vmid must be numeric (got '${opt_vmid}')"
        exit 2
    fi

    # Export options so child test scripts (dependency test-service.sh and the
    # module's own test.sh) can read them. The --vmid/--zone0 overrides let a
    # non-default instance be tested without editing the module config.
    export TAPPAAS_TEST_DEEP="${OPT_DEEP}"
    export TAPPAAS_TEST_RUNTIME_ONLY="${OPT_RUNTIME_ONLY}"
    export TAPPAAS_DEBUG="${OPT_DEBUG}"
    [[ -n "${opt_vmid}" ]] && export TAPPAAS_VMID_OVERRIDE="${opt_vmid}"
    [[ -n "${opt_zone0}" ]] && export TAPPAAS_ZONE0_OVERRIDE="${opt_zone0}"

    local module_json="${CONFIG_DIR}/${module}.json"

    # Decorative banner → [Debug]; the caller (e.g. update-module Step 6) already
    # prints a one-line "…: ${module}" header, so keep the console compact.
    debug "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    debug "${BOLD}║  TAPPaaS Module Test: ${BL}${module}${CL}"
    if [[ "${OPT_DEEP}" -eq 1 ]]; then
        debug "${BOLD}║  Mode: ${YW}deep${CL}"
    fi
    [[ -n "${opt_vmid}" ]]  && debug "${BOLD}║  Override: ${YW}vmid=${opt_vmid}${CL}"
    [[ -n "${opt_zone0}" ]] && debug "${BOLD}║  Override: ${YW}zone0=${opt_zone0}${CL}"
    debug "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate module config ───────────────────────────────
    info "${BOLD}Test Step 1: Validate module configuration${CL}"

    if [[ ! -f "${module_json}" ]]; then
        fatal "Module config not found: ${module_json} — is the module installed?"
        exit 2
    fi

    if check_json "${module_json}"; then
        test_pass_quiet "Module config is valid"
    else
        fatal "JSON validation failed for ${module}"
        exit 2
    fi

    debug "Config file: ${module_json}"

    # ── Step 2: Check dependency test-service.sh availability ────────
    info "${BOLD}Test Step 2: Check dependency test availability${CL}"

    # Both relationship lists (#684). rules-manager synthesises an auto-pinhole
    # from dependsOn AND integratesWith (#632), so a service declared either way
    # can carry a live firewall rule — and a rule no test visits is a rule that
    # fails silently. They differ in one thing only: an integratesWith provider
    # that is not installed is the documented no-op (#501), so it is quiet, where
    # a missing dependsOn provider is a fault worth naming.
    local dep_lines
    dep_lines="$(module_test_dependencies "${module}")"

    # A provider is found through the CONSUMER's environment (#718): a provider
    # deployed as <provider>-<env>.json is not <provider>.json, and looking it up
    # by the coordinate's bare prefix skipped its service test while the run
    # stayed green. Same resolver install-module and update-module use (#438).
    local environment
    environment="$(read_module_config "${module}" 2>/dev/null | jq -r '.environment // empty' 2>/dev/null)" || environment=""

    if [[ -z "${dep_lines}" ]]; then
        debug "  No dependencies declared"
    else
        while read -r dep origin; do
            [[ -n "${dep}" ]] || continue
            local provider_module
            provider_module="$(resolve_provider_module "${dep%%:*}" "${environment}")"
            local service_name="${dep##*:}"
            local provider_dir

            if provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                local svc_test="${provider_dir}/services/${service_name}/test-service.sh"
                if [[ -f "${svc_test}" ]]; then
                    debug "  ${GN}✓${CL} ${dep} — test-service.sh found"
                else
                    warn "${dep} — no test-service.sh (will skip)"
                fi
            elif [[ "${origin}" == optional ]]; then
                debug "  ${dep}: provider not installed — skipping optional integration"
            else
                warn "${dep} — provider module directory not found (will skip)"
            fi
        done <<< "${dep_lines}"
    fi

    # ── Step 3: Call dependency test-service.sh scripts ──────────────
    info "${BOLD}Test Step 3: Run dependency service tests${CL}"

    if [[ -z "${dep_lines}" ]]; then
        debug "  No dependency services to test"
    else
        while read -r dep origin; do
            [[ -n "${dep}" ]] || continue
            local provider_module
            provider_module="$(resolve_provider_module "${dep%%:*}" "${environment}")"
            local service_name="${dep##*:}"
            local provider_dir

            if ! provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                test_skip_quiet "${dep} — provider not found"
                continue
            fi

            ensure_scripts_executable "${provider_dir}"
            local svc_test="${provider_dir}/services/${service_name}/test-service.sh"

            if [[ ! -x "${svc_test}" ]]; then
                test_skip_quiet "${dep} — no test-service.sh"
                continue
            fi

            debug "  Running ${BL}${dep}${CL} test-service.sh for '${module}'..."
            # Capture the service-test output: [Debug] when green, surfaced on failure.
            local _svc_out _svc_rc _sl
            _svc_out="$("${svc_test}" "${module}" 2>&1)" && _svc_rc=0 || _svc_rc=$?
            if [[ ${_svc_rc} -eq 0 ]]; then
                if [[ -n "${_svc_out}" ]]; then
                    while IFS= read -r _sl; do debug "  ${_sl}"; done <<<"${_svc_out}"
                fi
                test_pass_quiet "${dep} service tests passed"
            else
                if [[ -n "${_svc_out}" ]]; then printf '%s\n' "${_svc_out}" >&2; fi
                if [[ ${_svc_rc} -eq 2 ]]; then
                    fatal "${dep} service test reported a fatal error"
                    FATAL=true
                fi
                test_fail "${dep} service tests failed"
            fi
        done <<< "${dep_lines}"
    fi

    # ── Step 4: Call the module's own test.sh ────────────────────────
    info "${BOLD}Test Step 4: Run module test.sh${CL}"

    local module_dir
    if module_dir=$(get_module_dir "${module}" 2>/dev/null); then
        ensure_scripts_executable "${module_dir}"
        if [[ -x "${module_dir}/test.sh" ]]; then
            debug "  Running ${module_dir}/test.sh..."
            cd "${module_dir}"
            # Capture the test output: route it to [Debug] when green (it's noise),
            # but surface it in full on failure so it stays diagnosable.
            local _test_out _test_rc _tl
            _test_out="$(./test.sh "${module}" 2>&1)" && _test_rc=0 || _test_rc=$?
            if [[ ${_test_rc} -eq 0 ]]; then
                if [[ -n "${_test_out}" ]]; then
                    while IFS= read -r _tl; do debug "  ${_tl}"; done <<<"${_test_out}"
                fi
                test_pass_quiet "Module test.sh passed"
            else
                if [[ -n "${_test_out}" ]]; then printf '%s\n' "${_test_out}" >&2; fi
                if [[ ${_test_rc} -eq 2 ]]; then
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
