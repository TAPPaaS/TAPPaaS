#!/usr/bin/env bash
#
# TAPPaaS — reconcile the Authentik role groups for the current variant set
# (ADR-006 Phase 2, issue #56). Idempotent: safe to re-run any time.
#
# What it guarantees exists in Authentik:
#   * tappaas-installers           — global superuser (platform root); never per-variant
#   * for the DEFAULT scope (variant ""):  parent group `tappaas`
#       └─ tappaas-admins, tappaas-users
#   * for every registered variant <v> in configuration.json tappaas.variants:
#       parent group `<v>`  └─ <v>-admins, <v>-users
#
# Group names are globally unique (so they stay unambiguous in the
# X-Authentik-Groups header / OIDC groups claim); each carries
# attributes.tappaas = {variant, role} for attribute-based tooling. Per-module
# admin groups (<scope>-<module>-admins) are opt-in and created at module
# install (ADR-006 §6), not here.
#
# Run from the cicd mothership. Called by identity/update.sh and hooked into
# variant-manager add/remove.
#
# Usage:
#   roles-ensure.sh                 # reconcile installers + default + every variant
#   roles-ensure.sh --variant acme  # reconcile installers + default + just `acme`
#   roles-ensure.sh --help
#
# Override the CLI for testing:  AUTHENTIK_MANAGER="/path/to/wrapper" roles-ensure.sh

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONFIG_FILE="${CONFIG_DIR}/configuration.json"
AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"
INSTALLERS_GROUP="tappaas-installers"
ONLY_VARIANT=""
ONLY_VARIANT_SET=0

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) ONLY_VARIANT="${2:-}"; ONLY_VARIANT_SET=1; shift 2 ;;
        --help|-h) usage 0 ;;
        *) error "unknown argument: $1"; usage 1 ;;
    esac
done

# The default variant "" maps to the parent group `tappaas`; a named variant
# maps to a parent group of the same name.
scope_prefix() { [[ -z "$1" ]] && echo "tappaas" || echo "$1"; }

# Ensure one scope's parent + child role groups (idempotent).
ensure_scope() {
    local variant="$1" prefix
    prefix="$(scope_prefix "${variant}")"
    info "  scope '${variant:-<default>}' → parent group '${prefix}'"
    ${AUTHENTIK_MANAGER} group-ensure "${prefix}" \
        --attr "tappaas.variant=${variant}" --attr "tappaas.scope=true" >/dev/null
    ${AUTHENTIK_MANAGER} group-ensure "${prefix}-admins" --parent "${prefix}" \
        --attr "tappaas.variant=${variant}" --attr "tappaas.role=admin" >/dev/null
    ${AUTHENTIK_MANAGER} group-ensure "${prefix}-users" --parent "${prefix}" \
        --attr "tappaas.variant=${variant}" --attr "tappaas.role=user" >/dev/null
    info "    ✓ ${prefix}-admins, ${prefix}-users"
}

main() {
    [[ -f "${CONFIG_FILE}" ]] || { error "configuration.json not found at ${CONFIG_FILE}"; exit 1; }

    info "Reconciling Authentik role groups (ADR-006)…"
    if ! ${AUTHENTIK_MANAGER} test >/dev/null 2>&1; then
        error "authentik-manager cannot reach Authentik (check ~/.authentik-credentials.txt)"
        exit 1
    fi

    # 1. Global Installer — the only is_superuser group; never per-variant.
    info "  global → ${INSTALLERS_GROUP} (superuser)"
    ${AUTHENTIK_MANAGER} group-ensure "${INSTALLERS_GROUP}" --superuser \
        --attr "tappaas.role=installer" >/dev/null

    # 2. The default scope always exists (default roles when no variants).
    ensure_scope ""

    # 3. Named variant scopes.
    if [[ "${ONLY_VARIANT_SET}" -eq 1 ]]; then
        if [[ -n "${ONLY_VARIANT}" ]]; then
            if ! jq -e --arg v "${ONLY_VARIANT}" '(.tappaas.variants // {}) | has($v)' "${CONFIG_FILE}" >/dev/null; then
                warn "variant '${ONLY_VARIANT}' is not registered in configuration.json — ensuring its groups anyway"
            fi
            ensure_scope "${ONLY_VARIANT}"
        fi
    else
        local v
        while IFS= read -r v; do
            [[ -z "${v}" ]] && continue        # "" already handled as the default scope
            ensure_scope "${v}"
        done < <(jq -r '(.tappaas.variants // {}) | keys[]' "${CONFIG_FILE}")
    fi

    info "✓ role groups reconciled"
}

main "$@"
