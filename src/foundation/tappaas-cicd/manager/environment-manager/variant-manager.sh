#!/usr/bin/env bash
#
# variant-manager.sh — manage TAPPaaS variants (ADR-005, #316).
#
# A variant is an isolated module instance (tenant/environment) with its own
# public domain, optional dedicated zone, TLS certificate, and DNS mode. Variants
# are registered in configuration.json under `tappaas.variants`; the empty-string
# key "" is the default variant used by installs without --variant.
#
# Commands:
#   add <name> --domain <d> [opts]   Register a variant (optionally create a zone)
#   list                             Table of all variants
#   show <name>                      Detailed view of one variant
#   remove <name> [--force]          Remove a variant (fails if modules deployed)
#
# `add` options:
#   --domain <domain>        (required) public domain for this variant
#   --zone <existing>        use an existing zone (must be in zones.json)
#   --add-zone               create a new dedicated zone named <name>
#   --from-zone <src>        zone to inherit type/bridge/ACLs from (with --add-zone)
#   --vlan <num>             override auto VLAN allocation (with --add-zone)
#   --dns-mode <mode>        wildcard (default) | per-service
#   --description "<text>"   human description
#   --no-activate            edit zones.json but do not call zone-manager (testing)
#
# Naming: variant names are [a-zA-Z0-9-]. When --add-zone is used the variant name
# is ALSO used as the zone key, which must match the camelCase zone rule
# ^[a-z][a-zA-Z0-9]*$ (no hyphens) — see #278.
#

# jq filter programs throughout this script are intentionally single-quoted;
# their $-variables are jq variables bound via --arg, not shell expansions.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null \
    || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-install-routines.sh"

readonly CONFIG_FILE="${CONFIG_DIR}/configuration.json"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"

# Variant VLAN allocation (sub-id 60-99 within a type band) lives in the shared
# zone-controller now — see ZONE_SUB_MIN/MAX in zone-controller.sh.

usage() {
    cat <<EOF
${SCRIPT_NAME} — manage TAPPaaS variants (ADR-005)

Usage:
  ${SCRIPT_NAME} add <name> --domain <domain> [options]
  ${SCRIPT_NAME} list
  ${SCRIPT_NAME} show <name>
  ${SCRIPT_NAME} remove <name> [--force]

add options:
  --domain <domain>      (required) public domain for this variant
  --zone <existing>      use an existing zone
  --add-zone             create a new dedicated zone named <name>
  --from-zone <src>      inherit type/bridge/ACLs from this zone (with --add-zone)
  --vlan <num>           override auto VLAN selection (with --add-zone)
  --dns-mode <mode>      wildcard (default) | per-service
  --description "<text>" human description
  --no-activate          do not call zone-manager after creating the zone

Examples:
  ${SCRIPT_NAME} add "" --domain tappaas.org
  ${SCRIPT_NAME} add demo --domain demo.tappaas.org --dns-mode per-service
  ${SCRIPT_NAME} add tenant1 --domain t1.example.com --add-zone --from-zone srvHome
EOF
}

# Atomically rewrite a JSON file from a jq filter. Args: <file> <jq-args...> <filter>
# (mirrors zone-state.sh: jq -> temp -> validate -> mv).
jq_write() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp)"
    if ! jq "$@" "${file}" > "${tmp}"; then
        rm -f "${tmp}"; die "jq failed updating ${file}"
    fi
    if ! jq empty "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"; die "jq produced invalid JSON for ${file}"
    fi
    mv "${tmp}" "${file}"
}

variant_exists() {
    jq -e --arg v "$1" '(.tappaas.variants // {}) | has($v)' "${CONFIG_FILE}" >/dev/null 2>&1
}

# Count installed module configs belonging to a variant: <module>-<variant>.json.
count_variant_modules() {
    local variant="$1" n=0 f
    [[ -z "${variant}" ]] && { echo 0; return; }  # default variant: modules are unsuffixed; skip
    shopt -s nullglob
    for f in "${CONFIG_DIR}"/*-"${variant}".json; do
        # Must actually carry variant == <variant> to avoid matching a module
        # whose name merely ends in -<variant>.
        if [[ "$(jq -r '.variant // ""' "${f}" 2>/dev/null)" == "${variant}" ]]; then
            n=$((n + 1))
        fi
    done
    shopt -u nullglob
    echo "${n}"
}

# ── add ──────────────────────────────────────────────────────────────
cmd_add() {
    local name="${1:-}"; shift || true
    [[ $# -ge 0 ]] || true
    local domain="" zone="" add_zone=0 from_zone="" vlan="" dns_mode="wildcard"
    local description="" activate=1

    # `name` may legitimately be the empty string (default variant); only reject
    # a missing positional (i.e. an option where the name should be).
    if [[ -z "${name}" && "${name}" != "" ]]; then :; fi
    case "${name}" in --*) die "add requires a variant name (use \"\" for the default)";; esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)      domain="${2:-}"; shift 2;;
            --zone)        zone="${2:-}"; shift 2;;
            --add-zone)    add_zone=1; shift;;
            --from-zone)   from_zone="${2:-}"; shift 2;;
            --vlan)        vlan="${2:-}"; shift 2;;
            --dns-mode)    dns_mode="${2:-}"; shift 2;;
            --description) description="${2:-}"; shift 2;;
            --no-activate) activate=0; shift;;
            *) die "Unknown option for add: $1";;
        esac
    done

    # Validation
    [[ -n "${domain}" ]] || die "add: --domain is required"
    if [[ -n "${name}" && ! "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        die "Invalid variant name '${name}' — use letters, digits and hyphens (not at the ends)"
    fi
    [[ "${domain}" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Invalid domain '${domain}'"
    case "${dns_mode}" in wildcard|per-service) ;; *) die "Invalid --dns-mode '${dns_mode}' (wildcard|per-service)";; esac
    [[ -f "${CONFIG_FILE}" ]] || die "configuration.json not found at ${CONFIG_FILE}"

    if variant_exists "${name}"; then
        die "Variant '${name}' already exists (use 'remove' first to replace it)"
    fi
    [[ -n "${zone}" && "${add_zone}" -eq 1 ]] && die "Use either --zone or --add-zone, not both"

    # Resolve / create the zone
    local zone_name=""
    if [[ -n "${zone}" ]]; then
        jq -e --arg z "${zone}" 'has($z)' "${ZONES_FILE}" >/dev/null 2>&1 \
            || die "Zone '${zone}' not found in ${ZONES_FILE}"
        zone_name="${zone}"
    elif [[ "${add_zone}" -eq 1 ]]; then
        # Delegate the whole zone lifecycle to the zone-controller: authoring +
        # OPNsense reconcile + zones.json distribution + Proxmox per-VM trunks +
        # node bridge-vids. The previous inline path applied only the firewall-VM
        # trunk and skipped node bridge-vids, so a module VM placed off the firewall
        # node got no IP (#335-family gap; see docs/design/zone-controller.md).
        # A variant's dedicated zone is named after the variant.
        zone_name="${name}"
        command -v zone-controller >/dev/null 2>&1 \
            || die "zone-controller not on PATH — cannot create variant zone '${name}'"
        local zc_args=(add "${name}" --variant "${name}")
        [[ -n "${from_zone}" ]] && zc_args+=(--from-zone "${from_zone}")
        [[ -n "${vlan}" ]] && zc_args+=(--vlan "${vlan}")
        [[ "${activate}" -eq 0 ]] && zc_args+=(--no-activate)
        zone-controller "${zc_args[@]}" || die "zone-controller add failed for '${name}'"
    fi

    # Write the variant entry
    jq_write "${CONFIG_FILE}" \
        --arg v "${name}" --arg d "${domain}" --arg m "${dns_mode}" \
        --arg z "${zone_name}" --arg desc "${description}" '
        .tappaas.variants = (.tappaas.variants // {})
        | .tappaas.variants[$v] = (
            { domain: $d, tlsCertRefid: "", dnsMode: $m, description: $desc }
            + (if $z == "" then {} else { zone: $z } end))'

    info "${GN}✓${CL} Variant '${BL}${name:-<default>}${CL}' registered (domain=${domain}, dnsMode=${dns_mode}${zone_name:+, zone=${zone_name}})"

    # ── ADR-006: create this variant's Authentik role groups (idempotent) ──
    # <variant>-admins / <variant>-users under a `<variant>` parent group. Best
    # effort — a missing/unreachable identity module must not fail variant add.
    if [[ -n "${name}" && -x /home/tappaas/bin/roles-ensure.sh ]]; then
        /home/tappaas/bin/roles-ensure.sh --variant "${name}" \
            || warn "roles-ensure --variant ${name} failed — create its role groups later with: roles-ensure.sh --variant ${name}"
    fi
}

# Variant zone authoring (VLAN allocation, inheritance, jq write) + the full
# OPNsense/Proxmox activation now lives in the shared `zone-controller add`
# primitive (src/foundation/tappaas-cicd/scripts/zone-controller.sh; see
# docs/design/zone-controller.md). cmd_add delegates to it so both variant-manager
# and a hands-on operator go through one path that also applies node bridge-vids.

# ── list ─────────────────────────────────────────────────────────────
cmd_list() {
    [[ -f "${CONFIG_FILE}" ]] || die "configuration.json not found at ${CONFIG_FILE}"
    printf '%-16s %-28s %-12s %-12s %-8s %s\n' "VARIANT" "DOMAIN" "ZONE" "DNS-MODE" "CERT" "MODULES"
    printf '%-16s %-28s %-12s %-12s %-8s %s\n' "-------" "------" "----" "--------" "----" "-------"
    # Count via length, NOT emptiness of the key list: the default variant's key
    # is the empty string, so `keys[]` of {"": ...} yields an empty line that a
    # `-z` check would mistake for "no variants".
    local count names name
    count="$(jq '(.tappaas.variants // {}) | length' "${CONFIG_FILE}" 2>/dev/null || echo 0)"
    if [[ "${count}" -eq 0 ]]; then
        info "No variants registered (legacy single-domain install)."
        return 0
    fi
    names="$(jq -r '(.tappaas.variants // {}) | keys[]' "${CONFIG_FILE}")"
    while IFS= read -r name; do
        local domain zone dns cert modcount disp
        domain="$(jq -r --arg v "${name}" '.tappaas.variants[$v].domain // "-"' "${CONFIG_FILE}")"
        zone="$(jq -r --arg v "${name}" '.tappaas.variants[$v].zone // "-"' "${CONFIG_FILE}")"
        dns="$(jq -r --arg v "${name}" '.tappaas.variants[$v].dnsMode // "wildcard"' "${CONFIG_FILE}")"
        cert="$(jq -r --arg v "${name}" 'if (.tappaas.variants[$v].tlsCertRefid // "") == "" then "no" else "yes" end' "${CONFIG_FILE}")"
        modcount="$(count_variant_modules "${name}")"
        disp="${name:-<default>}"
        printf '%-16s %-28s %-12s %-12s %-8s %s\n' "${disp}" "${domain}" "${zone}" "${dns}" "${cert}" "${modcount}"
    done <<< "${names}"
}

# ── show ─────────────────────────────────────────────────────────────
cmd_show() {
    local name="${1:-}"
    [[ -f "${CONFIG_FILE}" ]] || die "configuration.json not found at ${CONFIG_FILE}"
    variant_exists "${name}" || die "Variant '${name:-<default>}' not registered"
    info "Variant: ${BL}${name:-<default>}${CL}"
    jq --arg v "${name}" '.tappaas.variants[$v]' "${CONFIG_FILE}"
    info "Deployed modules: $(count_variant_modules "${name}")"
}

# ── remove ───────────────────────────────────────────────────────────
cmd_remove() {
    local name="${1:-}"; shift || true
    local force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --force) force=1; shift;; *) die "Unknown option for remove: $1";; esac
    done
    [[ -f "${CONFIG_FILE}" ]] || die "configuration.json not found at ${CONFIG_FILE}"
    variant_exists "${name}" || die "Variant '${name:-<default>}' not registered"

    local mods
    mods="$(count_variant_modules "${name}")"
    if [[ "${mods}" -gt 0 && "${force}" -eq 0 ]]; then
        die "Variant '${name}' still has ${mods} deployed module(s) — delete them first or pass --force"
    fi
    [[ "${mods}" -gt 0 ]] && warn "Removing variant '${name}' with ${mods} module(s) still deployed (--force)"

    # If this variant owns a dedicated zone (named after the variant and tagged
    # with .variant == <variant>), tear it down via the zone-controller
    # (mgmt.access-to + OPNsense interface + node trunks/bridge-vids). Variants
    # that reuse an existing shared --zone are left untouched.
    if jq -e --arg z "${name}" '(.[$z].variant // "") == $z' "${ZONES_FILE}" >/dev/null 2>&1; then
        if command -v zone-controller >/dev/null 2>&1; then
            info "Variant '${name}' owns dedicated zone '${name}' — deleting via zone-controller"
            local zc_del=(delete "${name}")
            [[ "${force}" -eq 1 ]] && zc_del+=(--force)
            zone-controller "${zc_del[@]}" \
                || warn "zone-controller delete '${name}' returned non-zero; clean up the zone manually"
        else
            warn "zone-controller not on PATH — dedicated zone '${name}' left in zones.json; remove it manually"
        fi
    fi

    jq_write "${CONFIG_FILE}" --arg v "${name}" 'del(.tappaas.variants[$v])'
    info "${GN}✓${CL} Variant '${name:-<default>}' removed"
}

# ── dispatch ─────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"; shift || true
    case "${cmd}" in
        add)    cmd_add "$@";;
        list)   cmd_list "$@";;
        show)   cmd_show "$@";;
        remove) cmd_remove "$@";;
        -h|--help|help|"") usage;;
        *) error "Unknown command: ${cmd}"; usage; exit 1;;
    esac
}

main "$@"
