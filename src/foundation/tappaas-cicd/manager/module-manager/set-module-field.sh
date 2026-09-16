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
# `--unset <field>` removes a field instead (#648). It is for the one field the
# 3-way merge cannot remove on its own: present in the deployed config, absent
# from the release source and from .orig, and undeclared — merge rule 2b keeps
# it forever and warns on every update. The two cases it refuses are the ones
# where removal would not stick or would break a reader:
#
#   - a field declared in module-fields.json: it has a meaning every reader
#     expects, so change it with --set rather than deleting it;
#   - a field the release still defines (present in .json.orig): the next merge
#     re-adopts it by rule 3, so the removal belongs in the source.
#
# Usage: set-module-field.sh <module> [--set <field>=<value>]... [--unset <field>]...
#
# Exit: 0 written · 1 a write failed partway · 2 usage · 3 REFUSED before any
#       write (the config is untouched — the caller must not tell the operator
#       to go looking for a half-applied change that cannot exist)

# The jq programs below are single-quoted on purpose: $f and $v are JQ variables
# bound by --arg/--argjson, not shell expansions.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# Composed, not the raw schema: definitions live per-service since #567.
readonly SCHEMA_FILE="$(tappaas_schema_file)"

usage() {
    echo "Usage: ${SCRIPT_NAME} <module> [--set <field>=<value>]... [--unset <field>]..." >&2
    exit 2
}

MODULE=""
declare -a PAIRS=()
declare -a UNSETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --set)     [[ -n "${2:-}" ]] || usage; PAIRS+=("$2"); shift ;;
        --unset)   [[ -n "${2:-}" ]] || usage; UNSETS+=("$2"); shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "${SCRIPT_NAME}: unknown option '$1'" >&2; usage ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" && $(( ${#PAIRS[@]} + ${#UNSETS[@]} )) -gt 0 ]] || usage

# #533/#525: never run this as root — a root-owned config drops out of the sweep.
if [[ "$(id -u)" -eq 0 ]]; then
    error "${SCRIPT_NAME} must run as the operator, not root — a root-owned config drops out of the update sweep (#525)"
    exit 3
fi

TARGET="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${TARGET}" ]] || { error "Module config not found: ${TARGET} — is '${MODULE}' deployed?"; exit 3; }

field_type() {
    jq -r --arg f "$1" '.fields[$f].type // "string"' "${SCHEMA_FILE}" 2>/dev/null || echo string
}

# Gate every --unset BEFORE the first --set is written (#648): one modify either
# applies the whole change or none of it, so a refusal here must not leave the
# config carrying half of it.
if [[ ${#UNSETS[@]} -gt 0 ]]; then
    ORIG="${TARGET}.orig"
    unset_flat="$(normalize_module_config < "${TARGET}")" \
        || { error "cannot read ${TARGET}"; exit 3; }
    unset_orig_flat="{}"
    [[ -f "${ORIG}" ]] && unset_orig_flat="$(normalize_module_config < "${ORIG}" 2>/dev/null || echo '{}')"

    for field in "${UNSETS[@]}"; do
        [[ "${field}" != *"="* ]] \
            || { error "${SCRIPT_NAME}: '--unset ${field}' takes a field name, not field=value"; exit 3; }
        jq -e --arg f "${field}" 'has($f)' >/dev/null <<< "${unset_flat}" \
            || { error "${field} is not in ${TARGET} — nothing to unset"; exit 3; }
        if jq -e --arg f "${field}" '.fields | has($f)' >/dev/null "${SCHEMA_FILE}" 2>/dev/null; then
            error "${field} is a declared field — change it with '--set ${field}=<value>' rather than removing it"
            exit 3
        fi
        if jq -e --arg f "${field}" 'has($f)' >/dev/null <<< "${unset_orig_flat}"; then
            error "${field} still comes from the module's release source — the next update re-adopts it; remove it in the source instead"
            exit 3
        fi
    done
fi

# 0 until the first successful write: it is what separates "refused, nothing
# happened" from "stopped partway, go and look".
WROTE=0
refuse_or_fail() { [[ "${WROTE}" -eq 0 ]] && exit 3 || exit 1; }

for pair in "${PAIRS[@]}"; do
    field="${pair%%=*}"
    value="${pair#*=}"
    [[ -n "${field}" && "${pair}" == *"="* ]] || { error "${SCRIPT_NAME}: '--set ${pair}' is not field=value"; refuse_or_fail; }

    case "$(field_type "${field}")" in
        integer|number)
            [[ "${value}" =~ ^-?[0-9]+$ ]] \
                || { error "${field} is declared numeric in module-fields.json, but '${value}' is not a number"; refuse_or_fail; }
            jq_module_write "${MODULE}" '.[$f] = $v' --argjson v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
        boolean)
            case "${value}" in
                true|false) ;;
                *) error "${field} is declared boolean in module-fields.json, but '${value}' is neither true nor false"; refuse_or_fail ;;
            esac
            jq_module_write "${MODULE}" '.[$f] = $v' --argjson v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
        array|object)
            # A container value must be given as JSON; anything else would land
            # as a string and silently fail to behave like a list.
            jq -e . >/dev/null 2>&1 <<< "${value}" \
                || { error "${field} is a container field — give its value as JSON (got '${value}')"; refuse_or_fail; }
            jq_module_write "${MODULE}" '.[$f] = $v' --argjson v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
        *)
            jq_module_write "${MODULE}" '.[$f] = $v' --arg v "${value}" --arg f "${field}" \
                || { error "failed to set ${field}"; exit 1; }
            ;;
    esac
    WROTE=1
    info "  set ${field}=${value} in ${TARGET}"
done

if [[ ${#UNSETS[@]} -gt 0 ]]; then
    for field in "${UNSETS[@]}"; do
        # shellcheck disable=SC2016
        jq_module_write "${MODULE}" 'del(.[$f])' --arg f "${field}" \
            || { error "failed to unset ${field}"; exit 1; }
        info "  unset ${field} in ${TARGET}"
    done
fi

exit 0
