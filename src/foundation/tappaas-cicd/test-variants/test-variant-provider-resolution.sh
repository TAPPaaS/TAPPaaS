#!/usr/bin/env bash
#
# test-variant-provider-resolution.sh — dependency provider resolution (#438).
#
# Regression cover for the defect where install-module.sh resolved EVERY
# consumer's dependencies against the SHARED provider, regardless of the
# environment being installed into: main() blanked the value it forwarded
# (`variant=""`) before Step 3 (check_service_available) and Step 5
# (resolve_provider_module) used it.
#
# WHY A SEPARATE SUITE: test-variant-config.sh already exercised
# resolve_provider_module directly, and passed throughout — the bug was never in
# the resolver, it was in what the CALLER forwarded. These tests therefore go
# through check_service_available (the integration point) and assert the
# forwarding contract in install-module.sh itself.
#
# Two failure modes, distinguished by whether a shared provider also exists:
#   shared exists  → silently resolves to the shared provider (wrong instance)
#   shared absent  → dies "provider module 'X' is not installed" (hard stop)
#
# Offline: no cluster, no VMs.
#

set -uo pipefail
# No `set -e`: the negative cases below intentionally return non-zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly INSTALL_MODULE="${SCRIPT_DIR}/../manager/module-manager/install-module.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export CONFIG_DIR="${WORK}/config"
mkdir -p "${CONFIG_DIR}"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

echo "test-variant-provider-resolution: dependency provider resolution (#438)"

# ── Fixtures ─────────────────────────────────────────────────────────
# A provider needs: a config with .provides + .location, and a real service
# directory holding an executable install-service.sh (check_service_available
# validates all three).
make_provider() {
    local name="$1" service="$2" srcdir="${WORK}/src/$3"
    mkdir -p "${srcdir}/services/${service}"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${srcdir}/services/${service}/install-service.sh"
    chmod +x "${srcdir}/services/${service}/install-service.sh"
    jq -n --arg s "${service}" --arg l "${srcdir}" \
        '{ provides: [$s], location: $l }' > "${CONFIG_DIR}/${name}.json"
}

# litellm: BOTH a shared instance and a demo-environment instance (Erik's case).
make_provider litellm      models litellm
make_provider litellm-demo models litellm
# coturn: ONLY the demo-environment instance, no shared counterpart.
make_provider coturn-demo  turn   coturn
# cluster: environment-agnostic foundation provider, deployed once, unsuffixed.
make_provider cluster      vm     cluster

# ── PR-01/02: shared + dedicated both exist → the environment's one wins ──
# The silently-wrong case. Pre-fix, PR-01 resolved to "litellm": the consumer got
# a virtual key on the SHARED instance instead of its own environment's.
assert_eq "$(resolve_provider_module litellm demo)" "litellm-demo" \
    "PR-01 shared+dedicated: environment 'demo' resolves to litellm-demo"
assert_eq "$(resolve_provider_module litellm "")"   "litellm" \
    "PR-02 shared+dedicated: blank environment resolves to litellm (the pre-fix answer)"

# ── PR-03/04: dedicated only → resolution must not invent a shared name ──
# The hard-stop case: pre-fix this reached check_service_available as "coturn",
# which is not deployed, and install died in Step 3.
assert_eq "$(resolve_provider_module coturn demo)" "coturn-demo" \
    "PR-03 dedicated-only: environment 'demo' resolves to coturn-demo"
if check_service_available "coturn:turn" "install-service.sh" "demo" 2>/dev/null; then
    pass "PR-04 dedicated-only: check_service_available passes with the environment forwarded"
else
    fail "PR-04 dedicated-only: check_service_available rejected a deployed provider"
fi

# ── PR-05: the same check with a blank environment must FAIL ─────────
# Pins the regression: if a caller ever blanks the value again, this flips.
if check_service_available "coturn:turn" "install-service.sh" "" 2>/dev/null; then
    fail "PR-05 dedicated-only: blank environment unexpectedly passed (is the shared fallback too lenient?)"
else
    pass "PR-05 dedicated-only: blank environment fails (documents the pre-fix breakage)"
fi

# ── PR-06: foundation dep from inside an environment still reaches the
# single shared instance. This fallback is load-bearing — every environment's
# consumers depend on the one cluster/network/identity deployment.
if check_service_available "cluster:vm" "install-service.sh" "demo" 2>/dev/null; then
    pass "PR-06 foundation dep: cluster:vm resolves from environment 'demo' (shared fallback preserved)"
else
    fail "PR-06 foundation dep: cluster:vm no longer reachable from an environment"
fi

# ── PR-07: mgmt / default environments are unsuffixed by design, so
# forwarding their name must land on the base config. This is what makes it safe
# for install-module.sh to forward ${environment} unconditionally.
assert_eq "$(resolve_provider_module cluster mgmt)" "cluster" \
    "PR-07 unsuffixed env: cluster+mgmt resolves to cluster"

# ── PR-08: the forwarding contract in install-module.sh ──────────────
# The resolver was always correct; the defect was the caller passing "". Assert
# that EVERY resolution call site forwards the environment, so a regression is
# caught here rather than on a live multi-environment site.
#
# The count is 4, not the original 2: #501 (2886f41, integratesWith) added an
# elif branch to the check_service_available site and a second
# resolve_provider_module for the optional-integration provider. The assertion
# was not updated with it, so this has been failing on main ever since.
if [[ -r "${INSTALL_MODULE}" ]]; then
    _bad=$(grep -cE '(check_service_available|resolve_provider_module).*\$\{variant\}' "${INSTALL_MODULE}" || true)
    _good=$(grep -cE '(check_service_available|resolve_provider_module).*\$\{environment\}' "${INSTALL_MODULE}" || true)
    assert_eq "${_bad}"  "0" "PR-08a install-module.sh forwards no \${variant} to the resolution helpers"
    assert_eq "${_good}" "4" "PR-08b install-module.sh forwards \${environment} at every resolution call site"
else
    fail "PR-08 install-module.sh not readable at ${INSTALL_MODULE}"
fi

# ── PR-09: repo-wide sweep — no live reader of the retired .variant ──
# The field is read TWO ways, and an early pass of #438 caught only the first:
#   direct   jq -r '.variant ...'  /  read_module_config | jq '.variant'
#   INDIRECT get_config_value 'variant'   ← invisible to a '.variant' grep, and
#            used by network:proxy + identity, which nearly every module depends
#            on (domain, dnsMode, TLS cert refid, OIDC redirect URIs).
# Sweep for both. migrate-drop-variant.sh is the one legitimate reader: it exists
# to remove the field.
_SRC="${SCRIPT_DIR}/../../.."
_readers=$(grep -rIn --include=*.sh --include=*.ts --include=*.py \
    -e "get_config_value ['\"]variant" \
    -e "jq -r '\.variant" \
    -e '\.variant //' \
    "${_SRC}/foundation" "${_SRC}/apps" 2>/dev/null \
    | grep -v 'migrate-drop-variant.sh' \
    | grep -v "$(basename "${BASH_SOURCE[0]}")" \
    | grep -v 'del(.variant)' \
    | grep -vE ':[0-9]+: *#' || true)

if [[ -z "${_readers}" ]]; then
    pass "PR-09 repo sweep: no live reader of the retired .variant field"
else
    fail "PR-09 repo sweep: .variant is still read — these must move to .environment:"
    printf '        %s\n' "${_readers}" >&2
fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
