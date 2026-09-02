#!/usr/bin/env bash
#
# set-module-field.sh — write field values into a DEPLOYED module config.
#
# The write step of `module-manager module modify <m> --set field=value …`
# (ADR-020 D2 step 0). The manager has already run the static pre-gate; this
# performs the write and nothing else.
#
# THREE THINGS IT IS CAREFUL ABOUT:
#
#   1. It edits the DEPLOYED config only — never the module's git source.
#      Desired drifting from Released is the expected, annotated state, not
#      something to sync back (ADR-020 Resolved Question 3). This is why it is
#      not copy-update-json.sh, which copies the source over the deployment.
#   2. It runs as `tappaas`, never under sudo. A config file that becomes
#      root-owned drops out of the sweep (#525) — the same ownership invariant
#      ADR-019 states.
#   3. It writes through jq_module_write, so a Pattern-A config (fields nested
#      under .config."<module>:<service>") is updated IN PLACE rather than
#      sprouting a duplicate top-level key. A field set in two places is
#      ambiguous once flattened, which `validate` reports as an error (#161).
#
# Values are typed from module-fields.json: an integer field is written as a
# JSON number and a boolean as a JSON boolean, so `--set cores=8` does not leave
# a string where every reader expects a number.
#
# Usage: set-module-field.sh <module> --set <field>=<value> [--set <field>=<value>]...
#
# Exit: 0 written · 1 error · 2 usage

# The jq programs below are single-quoted on purpose: $f and $v are JQ variables
# bound by --arg/--argjson, not shell expansions.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
readonly SCHEMA_FILE="/home/tappaas/TAPPaaS/src/foundation/schemas/module-fields.json"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

usage() {
    echo "Usage: ${SCRIPT_NAME} <module> --set <field>=<value> [--set <field>=<value>]..." >&2
    exit 2
}

MODULE=""
declare -a PAIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --set)     [[ -n "${2:-}" ]] || usage; PAIRS+=("$2"); shift ;;
        -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "${SCRIPT_NAME}: unknown option '$1'" >&2; usage ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" && ${#PAIRS[@]} -gt 0 ]] || usage

# #533/#525: never run this as root — a root-owned config drops out of the sweep.
if [[ "$(id -u)" -eq 0 ]]; then
    error "${SCRIPT_NAME} must run as the operator, not root — a root-owned config drops out of the update sweep (#525)"
    exit 1
fi

TARGET="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${TARGET}" ]] || { error "Module config not found: ${TARGET} — is '${MODULE}' deployed?"; exit 1; }

field_type() {
    jq -r --arg f "$1" '.fields[$f].type // "string"' "${SCHEMA_FILE}" 2>/dev/null || echo string
}

for pair in "${PAIRS[@]}"; do
    field="${pair%%=*}"
    value="${pair#*=}"
    [[ -n "${field}" && "${pair}" == *"="* ]] || { error "${SCRIPT_NAME}: '--set ${pair}' is not field=value"; exit 1; }

    case "$(field_type "${field}")" in
        integer|number)
            [[ "${value}" =~ ^-?[0-9]+$ ]] \
                || { error "${field} is declared numeric in module-fields.json, but '${value}' is not a number"; exit 1; }
            jq_module_write "${MODULE}" '.[$f] = $v' --argjson v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
        boolean)
            case "${value}" in
                true|false) ;;
                *) error "${field} is declared boolean in module-fields.json, but '${value}' is neither true nor false"; exit 1 ;;
            esac
            jq_module_write "${MODULE}" '.[$f] = $v' --argjson v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
        array|object)
            # A container value must be given as JSON; anything else would land
            # as a string and silently fail to behave like a list.
            jq -e . >/dev/null 2>&1 <<< "${value}" \
                || { error "${field} is a container field — give its value as JSON (got '${value}')"; exit 1; }
            jq_module_write "${MODULE}" '.[$f] = $v' --argjson v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
        *)
            jq_module_write "${MODULE}" '.[$f] = $v' --arg v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
    esac
    info "  set ${field}=${value} in ${TARGET}"
done

exit 0
