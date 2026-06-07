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

# Variant VLAN allocation walks backwards from sub-id 99 down to 60 within a zone
# type (standard zones use 0-59, variants 60-99). ip = 10.<typeId>.<subId>.0/24,
# vlantag = typeId*100 + subId.
readonly VARIANT_SUB_MAX=99
readonly VARIANT_SUB_MIN=60

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
        zone_name="$(create_variant_zone "${name}" "${from_zone}" "${vlan}")"
        if [[ "${activate}" -eq 1 ]]; then
            info "Activating zone '${zone_name}' via zone-manager..."
            if command -v zone-manager >/dev/null 2>&1; then
                zone-manager --execute || warn "zone-manager --execute returned non-zero; activate manually"
            else
                warn "zone-manager not on PATH — activate '${zone_name}' manually"
            fi
        else
            info "Zone '${zone_name}' created in zones.json (activation skipped: --no-activate)"
        fi
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
}

# Create a variant zone in zones.json; echoes the zone name. Inherits from
# --from-zone if given, otherwise a Service-type (typeId 2) default template.
create_variant_zone() {
    local name="$1" src="$2" vlan_override="$3"
    [[ -n "${name}" ]] || die "--add-zone requires a non-empty variant name"
    [[ "${name}" =~ ^[a-z][a-zA-Z0-9]*$ ]] \
        || die "--add-zone: variant name '${name}' must be a camelCase zone name (^[a-z][a-zA-Z0-9]*\$, no hyphens — see #278)"
    [[ -f "${ZONES_FILE}" ]] || die "zones.json not found at ${ZONES_FILE}"
    jq -e --arg z "${name}" 'has($z)|not' "${ZONES_FILE}" >/dev/null 2>&1 \
        || die "Zone '${name}' already exists in ${ZONES_FILE}"

    # Inherit type/typeId/bridge/access-to/pinhole-allowed-from.
    local typeId type bridge access_to pinhole parent
    if [[ -n "${src}" ]]; then
        jq -e --arg z "${src}" 'has($z)' "${ZONES_FILE}" >/dev/null 2>&1 \
            || die "--from-zone '${src}' not found in ${ZONES_FILE}"
        typeId="$(jq -r --arg z "${src}" '.[$z].typeId' "${ZONES_FILE}")"
        type="$(jq -r --arg z "${src}" '.[$z].type' "${ZONES_FILE}")"
        bridge="$(jq -r --arg z "${src}" '.[$z].bridge // "lan"' "${ZONES_FILE}")"
        access_to="$(jq -c --arg z "${src}" '.[$z]["access-to"] // []' "${ZONES_FILE}")"
        pinhole="$(jq -c --arg z "${src}" '.[$z]["pinhole-allowed-from"] // []' "${ZONES_FILE}")"
        parent="${src}"
    else
        typeId="2"; type="Service"; bridge="lan"
        access_to='["internet"]'; pinhole='[]'; parent=""
    fi

    # VLAN allocation
    local sub vt
    if [[ -n "${vlan_override}" ]]; then
        [[ "${vlan_override}" =~ ^[0-9]+$ ]] || die "--vlan must be numeric"
        vt="${vlan_override}"
        # derive subId from the override (last two digits), sanity-check the type
        sub=$((vt % 100))
        jq -e --argjson t "${vt}" 'any(.[]?; .vlantag == $t)' "${ZONES_FILE}" >/dev/null 2>&1 \
            && die "VLAN ${vt} is already in use"
    else
        sub=""
        local s
        for ((s = VARIANT_SUB_MAX; s >= VARIANT_SUB_MIN; s--)); do
            vt=$((typeId * 100 + s))
            if ! jq -e --argjson t "${vt}" 'any(.[]?; (.vlantag // -1) == $t)' "${ZONES_FILE}" >/dev/null 2>&1; then
                sub="${s}"; break
            fi
        done
        [[ -n "${sub}" ]] || die "No free variant VLAN in type ${typeId} (${typeId}${VARIANT_SUB_MIN}-${typeId}${VARIANT_SUB_MAX} all used)"
        vt=$((typeId * 100 + sub))
    fi
    local ip="10.${typeId}.${sub}.0/24"

    info "Creating zone '${name}': type=${type} vlan=${vt} ip=${ip}${parent:+ parent=${parent}}" >&2
    jq_write "${ZONES_FILE}" \
        --arg z "${name}" --arg type "${type}" --arg typeId "${typeId}" \
        --arg subId "${sub}" --argjson vlantag "${vt}" --arg ip "${ip}" \
        --arg bridge "${bridge}" --argjson access "${access_to}" \
        --argjson pinhole "${pinhole}" --arg parent "${parent}" --arg variant "${name}" '
        .[$z] = ({
            type: $type, typeId: $typeId, subId: $subId, vlantag: $vlantag,
            ip: $ip, bridge: $bridge, state: "Active",
            "access-to": $access, "pinhole-allowed-from": $pinhole,
            variant: $variant,
            description: ("Variant zone for " + $variant + (if $parent == "" then "" else " (inherited from " + $parent + ")" end))
        } + (if $parent == "" then {} else { parent: $parent } end))'

    echo "${name}"
}

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
