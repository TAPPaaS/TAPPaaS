#!/usr/bin/env bash
#
# health-audit.sh — periodic TAPPaaS compliance & drift audit.
#
# A generic, schedulable health check across all installed modules. It answers
# two questions in one correlated pass, with a single exit code suitable for
# cron / CI:
#
#   COMPLIANCE (at-rest)  — is the declared config correct and self-consistent?
#   DRIFT (desired→live)  — does the running cluster, firewall and DNS still
#                           match what the configs declare?
#
# Crucially, the DRIFT pass extends from config-PRESENCE to runtime-
# EFFECTIVENESS where the service test supports it (--deep): a rule existing is
# not the same as traffic flowing. (A presence-only audit once read green while
# ~45% of devices were unreachable — hence the distinction is explicit here.)
#
# Checks:
#   COMPLIANCE
#     C1  configuration valid          validate-configuration.sh (schema/fields)
#     C2  zone references resolve       each zone0/zone1 is a key in zones.json
#   DRIFT
#     D1  cluster reconcile            desired /config vmid vs running (inspect)
#     D2  firewall services            per-module test-service (presence/--deep)
#     D3  DNS canonical resolves       canonical-bearing module FQDN resolves
#
# Usage:
#   health-audit.sh                  # full audit, presence-level
#   health-audit.sh --deep           # + connectivity probes where supported
#   health-audit.sh --module <name>  # audit one module (skips C1/D1 cluster-wide)
#   health-audit.sh --no-cluster     # skip cluster-reachability checks (D1)
#   health-audit.sh --quiet          # cron mode: only warnings/failures + summary
#
# Exit codes:
#   0  no compliance violations, no drift
#   1  one or more checks failed (violation or drift)
#   2  bad arguments
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS_DIR
readonly FW_SERVICES_DIR="/home/tappaas/TAPPaaS/src/foundation/firewall/services"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"

indent() { sed 's/^/      /'; }

# Services whose test-service.sh runs real connectivity/effectiveness probes
# under --deep. Everything else is presence-only — reported honestly so a green
# audit is never mistaken for "traffic flows".
svc_supports_deep() { case "$1" in rules|dns) return 0 ;; *) return 1 ;; esac; }

# ── Arguments ─────────────────────────────────────────────────────────

OPT_DEEP=0
OPT_MODULE=""
OPT_NO_CLUSTER=0
OPT_QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deep)       OPT_DEEP=1; shift ;;
        --module)     OPT_MODULE="${2:-}"; shift 2 ;;
        --no-cluster) OPT_NO_CLUSTER=1; shift ;;
        --quiet)      OPT_QUIET=1; shift ;;
        -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^#\ \?//'; exit 0 ;;
        *)            error "Unknown argument: $1 (try --help)"; exit 2 ;;
    esac
done

FAILS=0
WARNS=0

# Result emitters — pass lines are suppressed in --quiet (cron) mode; warnings
# and failures always print. A failure flips the exit code; a warning does not.
pass() { [[ "${OPT_QUIET}" -eq 1 ]] || info "  ${GN}✓${CL} $*"; }
soft() { warn "  ${YW}!${CL} $*"; WARNS=$((WARNS + 1)); }
fail() { warn "  ${RD}✗${CL} $*"; FAILS=$((FAILS + 1)); }

# Iterate installed module configs (excludes infra/meta files). Single-module
# mode narrows to one. Emits absolute paths.
module_configs() {
    if [[ -n "${OPT_MODULE}" ]]; then
        local p="${CONFIG_DIR}/${OPT_MODULE}.json"
        [[ -f "${p}" ]] || { error "module config not found: ${p}"; exit 2; }
        printf '%s\n' "${p}"
        return
    fi
    while IFS= read -r p; do
        case "$(basename "$p" .json)" in
            configuration|zones|module-fields|firewall.json.bak.*) continue ;;
        esac
        printf '%s\n' "${p}"
    done < <(find "${CONFIG_DIR}" -maxdepth 1 -name '*.json' | sort)
}

# ══ COMPLIANCE (at-rest) ══════════════════════════════════════════════

info "${BOLD}COMPLIANCE — at-rest configuration${CL}"

# C1 — configuration valid (schema / required fields). Cluster-wide only.
if [[ -z "${OPT_MODULE}" ]]; then
    if [[ -x "${SCRIPTS_DIR}/validate-configuration.sh" ]]; then
        if "${SCRIPTS_DIR}/validate-configuration.sh" >/dev/null 2>&1; then
            pass "C1 configuration valid"
        else
            fail "C1 configuration validation found errors (run validate-configuration.sh)"
        fi
    else
        soft "C1 validate-configuration.sh not found — skipped"
    fi
fi

# C2 — every zone a module references (zone0/zone1) is a defined key in
# zones.json. Generic drift/typo guard: catches a config left pointing at a
# renamed or removed zone (the regression class behind the 2026-06-09 incident)
# without hardcoding any particular rename. Modules with no zone0 are skipped.
ZONE_KEYS=""
if [[ -f "${ZONES_FILE}" ]]; then
    ZONE_KEYS=" $(jq -r '(.zones // .) | keys[]?' "${ZONES_FILE}" 2>/dev/null | tr '\n' ' ')"
else
    soft "C2 zones.json not found — zone-reference check skipped"
fi

C2_FAILS_BEFORE="${FAILS}"
if [[ -n "${ZONE_KEYS}" ]]; then
    while IFS= read -r p; do
        bn=$(basename "$p" .json)
        while IFS= read -r z; do
            [[ -z "$z" ]] && continue
            [[ "${ZONE_KEYS}" == *" ${z} "* ]] || fail "C2 ${bn}: zone \"${z}\" not defined in zones.json"
        done < <(jq -r '[.zone0, .zone1] | map(select(. != null and . != "")) | .[]' "$p" 2>/dev/null)
    done < <(module_configs)
    [[ "${FAILS}" -eq "${C2_FAILS_BEFORE}" ]] && pass "C2 all modules: zone references resolve"
fi

# ══ DRIFT (desired → live) ════════════════════════════════════════════

info "${BOLD}DRIFT — desired vs live${CL}"

# D1 — cluster reconcile (informational: drift surfaced, operator judges).
if [[ "${OPT_NO_CLUSTER}" -eq 0 && -z "${OPT_MODULE}" ]]; then
    if [[ -x "${SCRIPTS_DIR}/inspect-cluster.sh" ]]; then
        if [[ "${OPT_QUIET}" -eq 1 ]]; then
            "${SCRIPTS_DIR}/inspect-cluster.sh" >/dev/null 2>&1 \
                || soft "D1 inspect-cluster reported drift — run inspect-cluster.sh"
        else
            info "  D1 cluster reconcile (desired vs running):"
            "${SCRIPTS_DIR}/inspect-cluster.sh" 2>&1 | tail -20 | indent \
                || soft "D1 inspect-cluster reported drift"
        fi
    else
        soft "D1 inspect-cluster.sh not found — skipped"
    fi
fi

# D2 — firewall-service effectiveness, per module per declared firewall:<svc>.
audit_fw_services() {
    local p="$1" bn deps svc tst depth row="" mod_fail=0 n=0
    bn=$(basename "$p" .json)
    deps=$(jq -r '(.dependsOn // [])
                  | map(select(startswith("firewall:")))
                  | map(sub("^firewall:";""))
                  | join(" ")' "$p" 2>/dev/null)
    [[ -z "${deps}" ]] && return 0

    # shellcheck disable=SC2086  # deps is a deliberately space-separated list
    for svc in ${deps}; do
        tst="${FW_SERVICES_DIR}/${svc}/test-service.sh"
        if [[ ! -x "${tst}" ]]; then
            row+=" ${svc}:?"
            continue
        fi
        depth="presence"
        local args=("${bn}")
        if [[ "${OPT_DEEP}" -eq 1 ]] && svc_supports_deep "${svc}"; then
            args+=("--deep"); depth="deep"
        fi
        n=$((n + 1))
        if "${tst}" "${args[@]}" >/dev/null 2>&1; then
            row+=" ${svc}(${depth}):ok"
        else
            row+=" ${svc}(${depth}):FAIL"
            mod_fail=1
        fi
    done

    [[ "${n}" -eq 0 ]] && return 0
    if [[ "${mod_fail}" -eq 1 ]]; then
        fail "D2 ${bn}:${row}"
    else
        pass "D2 ${bn}:${row}"
    fi
}

# D3 — DNS canonical resolves for modules that own one (guest vmname+zone0, or
# firewall:dns). A stable name pointing at nothing is the classic silent drift.
audit_dns_canonical() {
    local p="$1" bn vmname zone0 deps fqdn ip
    bn=$(basename "$p" .json)
    vmname=$(jq -r '.vmname // empty' "$p" 2>/dev/null)
    zone0=$(jq -r '.zone0 // empty' "$p" 2>/dev/null)
    deps=$(jq -r '(.dependsOn // []) | join(",")' "$p" 2>/dev/null)
    [[ -z "${vmname}" || -z "${zone0}" ]] && return 0
    # Only modules that should own a canonical: a guest (vmid) or firewall:dns.
    if [[ -z "$(jq -r '.vmid // empty' "$p" 2>/dev/null)" && ",${deps}," != *",firewall:dns,"* ]]; then
        return 0
    fi
    fqdn="${vmname}.${zone0}.internal"
    ip=$(dig +short A "${fqdn}" 2>/dev/null | head -1)
    if [[ -n "${ip}" ]]; then
        pass "D3 ${fqdn} → ${ip}"
    else
        fail "D3 ${fqdn} — NOT RESOLVING (DNS/DHCP drift)"
    fi
}

while IFS= read -r p; do
    audit_fw_services "$p"
    audit_dns_canonical "$p"
done < <(module_configs)

# ══ Summary ═══════════════════════════════════════════════════════════

echo
if [[ "${OPT_DEEP}" -eq 0 ]]; then
    info "  Presence-level run. Add --deep for connectivity probes (effectiveness)"
    info "  on services that support them: rules, dns."
fi
info "${BOLD}Audit summary: ${FAILS} failure(s), ${WARNS} warning(s)${CL}"

if [[ "${FAILS}" -gt 0 ]]; then
    error "${BOLD}Health audit: DRIFT/VIOLATIONS found — see ✗ above${CL}"
    exit 1
fi
info "${BOLD}Health audit: compliant, no drift${CL}"
exit 0
