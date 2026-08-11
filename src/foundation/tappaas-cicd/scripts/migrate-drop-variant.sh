#!/usr/bin/env bash
#
# migrate-drop-variant.sh — retire the legacy .variant field from installed
# module configs (#438).
#
# WHY: .variant used to be MIRRORED from --environment onto every config
# installed into a non-default environment, and several readers (provider
# pairing, name-suffix stripping) took .variant rather than .environment. That
# mirror is gone: installs now write .environment only, and every reader takes
# .environment. A config still carrying .variant is harmless but stale — this
# script removes it, after proving the removal is safe.
#
# SAFE means, per config:
#   - .environment is present and equal to .variant  → drop .variant, nothing else changes
#   - .environment is absent, but the config FILENAME carries the variant as its
#     suffix (<base>-<variant>.json)                 → adopt .environment, then drop .variant
#   - .environment is present but DIFFERENT           → refuse; a human must decide
#   - the resulting environment is not registered     → refuse; environment file is missing
#
# Read-only by default: prints the plan and exits. Pass --apply to write.
# Every changed file is backed up first.
#
# Usage:
#   migrate-drop-variant.sh                 # dry run — show the plan
#   migrate-drop-variant.sh --apply         # perform the migration
#   migrate-drop-variant.sh --config-dir D  # operate on a different config dir
#   migrate-drop-variant.sh --apply --yes   # skip the confirmation prompt
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Logging + resolve_default_environment come from the shared library.
_lib="/home/tappaas/bin/common-install-routines.sh"
[[ -r "${_lib}" ]] || _lib="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)/common-install-routines.sh"
# shellcheck disable=SC1090
. "${_lib}"

APPLY=false
ASSUME_YES=false
BACKUP_DIR=""

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [--apply] [--config-dir <dir>] [--yes]

Retire the legacy .variant field from installed module configs (#438).

Options:
  --apply             Write the changes (default is a read-only plan).
  --config-dir <dir>  Config directory to operate on (default: ${CONFIG_DIR}).
  --yes, -y           Skip the confirmation prompt when applying.
  -h, --help          Show this help.

Exit codes:
  0  nothing to do, or the plan/migration completed with no blocked configs
  1  one or more configs are BLOCKED and need a human decision
  2  usage error
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)      APPLY=true; shift ;;
        --yes|-y)     ASSUME_YES=true; shift ;;
        --config-dir) [[ -n "${2:-}" ]] || { usage; exit 2; }; CONFIG_DIR="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            error "unknown option: $1"; usage; exit 2 ;;
    esac
done

[[ -d "${CONFIG_DIR}" ]] || die "config directory not found: ${CONFIG_DIR}"

# ── Environment registry ─────────────────────────────────────────────
# An environment is valid if it is 'mgmt', the resolved default environment, or
# has a config/environments/<env>.json file.
DEFAULT_ENV="$(resolve_default_environment 2>/dev/null || true)"

env_is_registered() {
    local env="$1"
    [[ "${env}" == "mgmt" ]] && return 0
    [[ -n "${DEFAULT_ENV}" && "${env}" == "${DEFAULT_ENV}" ]] && return 0
    [[ -f "${CONFIG_DIR}/environments/${env}.json" ]] && return 0
    return 1
}

info "${BOLD}TAPPaaS .variant retirement (#438)${CL}"
info "  config dir          : ${CONFIG_DIR}"
info "  default environment : ${DEFAULT_ENV:-<none resolvable>}"
info "  mode                : $([[ "${APPLY}" == true ]] && echo APPLY || echo 'DRY RUN (use --apply to write)')"
echo ""

# ── Plan ─────────────────────────────────────────────────────────────
# Rows are accumulated as "<action>\t<file>\t<variant>\t<environment>\t<detail>".
PLAN_FILE="$(mktemp)"
cleanup() { rm -f "${PLAN_FILE}"; return 0; }
trap cleanup EXIT

n_clean=0; n_drop=0; n_adopt=0; n_blocked=0

shopt -s nullglob
for cfg in "${CONFIG_DIR}"/*.json; do
    base="$(basename "${cfg}" .json)"

    # Skip the non-module configs that live alongside module configs.
    case "${base}" in
        site|zones|zones.rename|cert-refids|module-fields|configuration|\
        switch-configuration-actual|switch-configuration-desired) continue ;;
    esac

    # Not a module config (no .location) → leave alone.
    jq -e 'has("location")' "${cfg}" >/dev/null 2>&1 || continue

    variant="$(jq -r '.variant // ""' "${cfg}" 2>/dev/null || echo "")"
    environment="$(jq -r '.environment // ""' "${cfg}" 2>/dev/null || echo "")"

    if [[ -z "${variant}" ]]; then
        n_clean=$((n_clean + 1))
        continue
    fi

    if [[ -n "${environment}" && "${environment}" == "${variant}" ]]; then
        if env_is_registered "${environment}"; then
            printf 'DROP\t%s\t%s\t%s\t%s\n' "${cfg}" "${variant}" "${environment}" \
                "environment matches variant" >> "${PLAN_FILE}"
            n_drop=$((n_drop + 1))
        else
            printf 'BLOCKED\t%s\t%s\t%s\t%s\n' "${cfg}" "${variant}" "${environment}" \
                "environment '${environment}' is NOT registered (no environments/${environment}.json)" >> "${PLAN_FILE}"
            n_blocked=$((n_blocked + 1))
        fi
    elif [[ -n "${environment}" && "${environment}" != "${variant}" ]]; then
        printf 'BLOCKED\t%s\t%s\t%s\t%s\n' "${cfg}" "${variant}" "${environment}" \
            "CONFLICT: .environment and .variant disagree — a human must decide which is right" >> "${PLAN_FILE}"
        n_blocked=$((n_blocked + 1))
    else
        # .environment absent. Only safe if the FILENAME carries the variant as
        # its suffix — that is what proves the deployment really is that
        # environment's instance (<base>-<variant>.json).
        if [[ "${base}" == *"-${variant}" ]]; then
            if env_is_registered "${variant}"; then
                printf 'ADOPT\t%s\t%s\t%s\t%s\n' "${cfg}" "${variant}" "${variant}" \
                    "filename suffix confirms the environment; will set .environment then drop .variant" >> "${PLAN_FILE}"
                n_adopt=$((n_adopt + 1))
            else
                printf 'BLOCKED\t%s\t%s\t%s\t%s\n' "${cfg}" "${variant}" "-" \
                    "filename suffix says '${variant}' but that environment is NOT registered" >> "${PLAN_FILE}"
                n_blocked=$((n_blocked + 1))
            fi
        else
            printf 'BLOCKED\t%s\t%s\t%s\t%s\n' "${cfg}" "${variant}" "-" \
                "no .environment and the filename is unsuffixed — cannot prove which environment this is" >> "${PLAN_FILE}"
            n_blocked=$((n_blocked + 1))
        fi
    fi
done
shopt -u nullglob

# ── Report ───────────────────────────────────────────────────────────
if [[ ! -s "${PLAN_FILE}" ]]; then
    info "  ${GN}✓${CL} No config carries .variant — nothing to migrate (${n_clean} module configs already clean)."
    exit 0
fi

info "${BOLD}Plan${CL}"
while IFS=$'\t' read -r action file variant environment detail; do
    name="$(basename "${file}")"
    case "${action}" in
        DROP)    info  "  ${GN}drop${CL}   ${name}  (.variant=${variant}) — ${detail}" ;;
        ADOPT)   info  "  ${YW}adopt${CL}  ${name}  (.environment=${environment}, then drop .variant) — ${detail}" ;;
        BLOCKED) error "  blocked ${name}  (.variant=${variant}, .environment=${environment}) — ${detail}" ;;
    esac
done < "${PLAN_FILE}"

echo ""
info "  clean already : ${n_clean}"
info "  drop .variant : ${n_drop}"
info "  adopt + drop  : ${n_adopt}"
info "  blocked       : ${n_blocked}"

if [[ "${n_blocked}" -gt 0 ]]; then
    echo ""
    warn "  ${n_blocked} config(s) need a human decision. Resolve those first — they are"
    warn "  skipped by --apply, which migrates only the safe rows."
fi

if [[ "${APPLY}" != true ]]; then
    echo ""
    info "Dry run only. Re-run with ${BOLD}--apply${CL} to write these changes."
    [[ "${n_blocked}" -gt 0 ]] && exit 1
    exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────
if [[ "${ASSUME_YES}" != true ]]; then
    echo ""
    read -r -p "Apply the ${n_drop} drop + ${n_adopt} adopt change(s)? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { info "Aborted — nothing written."; exit 0; }
fi

BACKUP_DIR="${CONFIG_DIR}/.variant-migration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"
info "  backups → ${BACKUP_DIR}"

changed=0
while IFS=$'\t' read -r action file variant environment detail; do
    [[ "${action}" == "BLOCKED" ]] && continue
    name="$(basename "${file}")"
    cp -p "${file}" "${BACKUP_DIR}/${name}"

    tmp="$(mktemp)"
    if [[ "${action}" == "ADOPT" ]]; then
        jq --arg e "${environment}" '.environment = $e | del(.variant)' "${file}" > "${tmp}"
    else
        jq 'del(.variant)' "${file}" > "${tmp}"
    fi

    # Only replace on a valid, non-empty result — never truncate a live config.
    if [[ -s "${tmp}" ]] && jq -e . "${tmp}" >/dev/null 2>&1; then
        mv "${tmp}" "${file}"
        info "  ${GN}✓${CL} ${name}"
        changed=$((changed + 1))
    else
        rm -f "${tmp}"
        error "  ${name}: jq produced invalid output — left unchanged (backup at ${BACKUP_DIR}/${name})"
    fi
done < "${PLAN_FILE}"

echo ""
info "${BOLD}Migrated ${changed} config(s).${CL} Backups: ${BACKUP_DIR}"

# ── Post-check: every dependency still resolves to a deployed provider ──
echo ""
info "${BOLD}Verifying dependency resolution${CL}"
unresolved=0
shopt -s nullglob
for cfg in "${CONFIG_DIR}"/*.json; do
    jq -e 'has("location")' "${cfg}" >/dev/null 2>&1 || continue
    module="$(basename "${cfg}" .json)"
    env="$(jq -r '.environment // ""' "${cfg}" 2>/dev/null || echo "")"
    while read -r dep; do
        [[ -n "${dep}" ]] || continue
        provider="$(resolve_provider_module "${dep%%:*}" "${env}")"
        if [[ ! -f "${CONFIG_DIR}/${provider}.json" ]]; then
            error "  ${module} (env='${env}') → ${dep}: resolves to '${provider}', which is NOT deployed"
            unresolved=$((unresolved + 1))
        fi
    done < <(jq -r '.dependsOn // [] | .[]' "${cfg}" 2>/dev/null || true)
done
shopt -u nullglob

if [[ "${unresolved}" -eq 0 ]]; then
    info "  ${GN}✓${CL} every dependency resolves to a deployed provider"
else
    error "  ${unresolved} unresolved dependency/ies — review before running any update."
    exit 1
fi

[[ "${n_blocked}" -gt 0 ]] && exit 1
exit 0
