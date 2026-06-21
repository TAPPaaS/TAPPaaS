#!/usr/bin/env bash
#
# setup-switches.sh — registration & setup of switches that carry TAPPaaS traffic (#351, ADR-008)
#
# Runs on the cicd mothership (where switch-manager + the vendor plugins live),
# normally at the end of the platform install (install-platform.sh) but also
# re-runnable any time. It walks you through registering each switch BRAND, one
# at a time, into switch-configuration-actual.json so zone-reconcile / switch-
# manager keep the physical switch VLANs in sync with zones.json.
#
# Flow: pick a brand (auto-discovered from the plugin library, plus "Other") →
# choose how to manage it (the choices depend on the brand's plugin architecture)
# → register switch(es)/controller and node-uplink ports → loop for more brands.
#
#   brand has no plugin ("Other")     → manual only
#   controller-arch brand (UniFi)     → manual | use existing controller | install a controller
#   device-arch brand (MikroTik, tbd) → manual | register each switch by IP
#
# "manual" records the node-uplink ports (TAPPaaS prints which VLANs to tag, you
# apply them by hand, then `switch-manager confirm`). Controller/device modes let
# the plugin program the switch via `switch-manager reconcile --apply`.
#
# This step is switch-only. WiFi SSID→VLAN is setup-wlan-secrets.sh + ap-manager.
#
# Usage:
#   setup-switches.sh                 interactive
#   setup-switches.sh --non-interactive   refuse to prompt (CI/bootstrap default)
#   setup-switches.sh --help
#
# Env (for tests): SWITCH_MANAGER, INSTALL_MODULE, UNIFI_CRED, UNIFI_SETUP_CREDS.
#

set -euo pipefail

# shellcheck source=../../tappaas-cicd/lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
readonly PLUGIN_DIR="/home/tappaas/TAPPaaS/src/foundation/firewall/scripts/plugins"
ACTUAL="${ACTUAL:-${CONFIG_DIR}/switch-configuration-actual.json}"

# Injectable so tests can stub the helpers.
SWITCH_MANAGER="${SWITCH_MANAGER:-switch-manager}"
INSTALL_MODULE="${INSTALL_MODULE:-install-module.sh}"
UNIFI_CRED="${UNIFI_CRED:-/home/tappaas/.unifi-os-credentials.txt}"
UNIFI_SETUP_CREDS="${UNIFI_SETUP_CREDS:-/home/tappaas/Community/src/larsrossen/network/unifi-os/setup-credentials.sh}"

INTERACTIVE=1

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

ask() { local p="$1" d="${2:-}" a; read -r -p "${p}" a < /dev/tty || true; echo "${a:-$d}"; }

# Prompt for a menu choice in 1..<max>; re-prompt on anything else (no silent exit).
ask_choice() {
    local max="$1" c
    while true; do
        c="$(ask "  choice (1-${max}): ")"
        if [[ "${c}" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= max )); then echo "${c}"; return 0; fi
        warn "  please enter a number 1-${max} (or Ctrl-C to exit)" >&2
    done
}

# ── Plugin discovery / metadata ──────────────────────────────────────

discover_brands() {
    local p b
    for p in "${PLUGIN_DIR}"/*.sh; do
        b="$(basename "$p" .sh)"; [[ "$b" == "manual" ]] && continue; echo "$b"
    done
}

# Architecture a brand's plugin declares: "controller" | "device" | "" (none).
plugin_arch_of() {
    local brand="$1"; local p="${PLUGIN_DIR}/${brand}.sh"
    [[ -f "$p" ]] || { echo ""; return 0; }
    # shellcheck disable=SC1090
    ( . "$p"; declare -F plugin_arch >/dev/null && plugin_arch || echo "" )
}

# The TAPPaaS module that provides a controller for this brand (install path).
plugin_module_of() {
    local brand="$1"; local p="${PLUGIN_DIR}/${brand}.sh"
    [[ -f "$p" ]] || { echo ""; return 0; }
    # shellcheck disable=SC1090
    ( . "$p"; declare -F plugin_controller_module >/dev/null && plugin_controller_module || echo "" )
}

# ── Shared helpers ───────────────────────────────────────────────────

_cred_url() { awk -F= '/^url=/{sub(/^url=/,"");print;exit}' "${UNIFI_CRED}" 2>/dev/null; }

switches_of_controller() {
    jq -r --arg c "$1" '.switches // {} | to_entries[] | select(.value.controller==$c) | .key' "${ACTUAL}" 2>/dev/null
}

# Registered controller names for a given vendor (from actual).
controllers_of_vendor() {
    jq -r --arg v "$1" '.controllers // {} | to_entries[] | select(.value.vendor==$v) | .key' "${ACTUAL}" 2>/dev/null
}

# Condensed inventory: one line per switch, only the TAPPaaS-MANAGED ports (those
# with a type) indented below, plus a count of the remaining untouched ports.
print_inventory() {
    local n; n=$(jq -r '.switches // {} | length' "${ACTUAL}" 2>/dev/null || echo 0)
    if [[ "${n:-0}" -eq 0 ]]; then info "No switches registered yet."; return 0; fi
    info "${BOLD}Registered switches (${n}):${CL}"
    jq -r '
      .switches // {} | to_entries[] |
      ((.value.ports // {}) | to_entries) as $ports
      | ($ports | map(select(.value.type != null))) as $managed
      | "  \(.key)  [\(.value.vendor) · \(.value.managed)\(if .value.controller then " · via "+.value.controller else "" end)]",
      ( $managed[] |
        "      port \(.key): \(.value.type) → \(.value.target // "?")\(if .value.targetPort then "/"+.value.targetPort else "" end)  "
        + ( if .value.mode=="access" then "access \(.value.nativeVlan // 0)"
            else "trunk " + (if (.value.taggedVlans|type)=="array" then (.value.taggedVlans|map(tostring)|join(",")) else "(pending reconcile)" end) end ) ),
      ( (($ports|length) - ($managed|length)) as $rest
        | if $rest > 0 then "      (+\($rest) other port(s) left untouched)" else empty end )
    ' "${ACTUAL}" 2>/dev/null
    return 0
}

# Register node-uplink ports on <switch> via <op> (add-port|update-port).
register_uplinks() {
    local sw="$1" op="${2:-add-port}" node port iface
    info "Register the ports on '${sw}' that connect to TAPPaaS nodes (these are VLAN trunks)."
    info "Press ENTER on an empty node name when done."
    while true; do
        node="$(ask "  node name (e.g. tappaas1; blank to finish): ")"
        [[ -z "${node}" ]] && break
        port="$(ask "    switch port for ${node}: ")"
        if [[ -z "${port}" ]]; then warn "    no port given — skipped"; continue; fi
        iface="$(ask "    node interface (e.g. eth0; ENTER to skip): ")"
        local args=("${op}" "${sw}" "${port}" --type node --target "${node}")
        if [[ -n "${iface}" ]]; then args+=(--target-port "${iface}"); fi
        "${SWITCH_MANAGER}" "${args[@]}" || warn "    could not register port ${port} on ${sw}"
    done
}

# UniFi controller credentials present? Offer setup-credentials.sh if not.
ensure_unifi_creds() {
    if [[ -s "${UNIFI_CRED}" ]]; then
        info "  ${GN}✓${CL} using existing UniFi controller credentials (${UNIFI_CRED})"; return 0
    fi
    warn "  No controller credentials found (${UNIFI_CRED})."
    if [[ -x "${UNIFI_SETUP_CREDS}" ]]; then
        local a; a="$(ask "  Register them now via setup-credentials.sh? [Y/n]: " Y)"
        [[ "${a,,}" == n* ]] && return 1
        "${UNIFI_SETUP_CREDS}" || { warn "  credential setup did not complete"; return 1; }
        [[ -s "${UNIFI_CRED}" ]] && return 0 || return 1
    fi
    warn "  setup-credentials.sh not found at ${UNIFI_SETUP_CREDS} — register credentials, then re-run."
    return 1
}

# ── Management modes ─────────────────────────────────────────────────

# manual: configure by hand (works for any brand; uses manual.sh via managed:manual).
# Loops so several switches of the same brand can be registered. No IP prompt —
# a manual switch needs none (add one later with add-switch if you ever automate it).
do_manual() {
    local brand="$1" name
    info "${BOLD}${brand}: manual.${CL} TAPPaaS will tell you which VLANs to tag; you apply them by hand."
    while true; do
        name="$(ask "  switch name (label, e.g. core-sw; blank when done): ")"
        [[ -z "${name}" ]] && break
        if ! "${SWITCH_MANAGER}" add-switch "${name}" --vendor "${brand}" --managed manual; then
            warn "  could not add switch '${name}' — skipped"; continue
        fi
        register_uplinks "${name}" add-port
        echo
    done
}

# Upload a controller's switches and annotate their node-uplink ports.
annotate_controller_switches() {
    local cname="$1" sw any=0
    info "Uploading switches from controller '${cname}'..."
    "${SWITCH_MANAGER}" interrogate || warn "  interrogate reported issues"
    while IFS= read -r sw; do
        [[ -z "${sw}" ]] && continue; any=1
        echo; info "${BOLD}switch '${sw}'${CL} — annotate the ports that uplink to TAPPaaS nodes:"
        register_uplinks "${sw}" update-port
    done < <(switches_of_controller "${cname}")
    [[ "${any}" -eq 1 ]] || warn "  no switches uploaded (is anything adopted on the controller?)"
}

# Use a controller already registered in the inventory.
do_use_registered_controller() {
    local cname="$1"
    ensure_unifi_creds || { warn "  controller credentials not ready — register them and re-run."; return 0; }
    annotate_controller_switches "${cname}"
}

# controller (existing/new): register a controller from credentials, then upload.
do_existing_controller() {
    local brand="$1" cname url
    ensure_unifi_creds || { warn "  controller not ready — register credentials and re-run."; return 0; }
    cname="$(ask "  controller name (label) [${brand}-controller]: " "${brand}-controller")"
    url="$(ask "  controller URL/IP [$(_cred_url)]: " "$(_cred_url)")"
    [[ -n "${url}" ]] || { warn "  no controller URL — skipped"; return 0; }
    "${SWITCH_MANAGER}" add-controller "${cname}" --vendor "${brand}" --ip "${url}" \
        || { warn "  could not add controller '${cname}' (already registered? use 'Use it')"; return 0; }
    annotate_controller_switches "${cname}"
}

# controller (install): install the controller module, then guide to registration.
do_install_controller() {
    local brand="$1" module; module="$(plugin_module_of "${brand}")"
    [[ -n "${module}" ]] || { warn "  no controller module known for ${brand}"; return 0; }
    info "${BOLD}Installing the ${module} controller module...${CL}"
    if command -v "${INSTALL_MODULE}" >/dev/null 2>&1 || [[ -x "${INSTALL_MODULE}" ]]; then
        "${INSTALL_MODULE}" "${module}" || warn "  module install reported issues — review before continuing."
    else
        info "  Run:  ${BL:-}install-module.sh ${module}${CL:-}"
    fi
    info "Then finish controller setup:"
    info "  1. Open the controller web UI and complete first-time setup (create the admin)."
    info "  2. Register its credentials:  ${BL:-}${UNIFI_SETUP_CREDS}${CL:-}"
    info "  3. Re-run ${BL:-}setup-switches.sh${CL:-} and choose '${brand} → use existing controller'."
}

# device-arch (e.g. MikroTik): each switch has its own API; register per IP.
do_device() {
    local brand="$1" name ip
    info "${BOLD}${brand}: per-switch API.${CL} Register each switch by its management IP."
    while true; do
        name="$(ask "  switch name (blank to finish): ")"; [[ -z "${name}" ]] && break
        ip="$(ask "    management IP for ${name}: ")"
        [[ -n "${ip}" ]] || { warn "    no IP — skipped"; continue; }
        "${SWITCH_MANAGER}" add-switch "${name}" --vendor "${brand}" --managed auto --ip "${ip}" \
            || { warn "    could not add switch '${name}'"; continue; }
        "${SWITCH_MANAGER}" interrogate >/dev/null 2>&1 || true
        register_uplinks "${name}" update-port
    done
}

# Controller-arch brand (e.g. UniFi): detect an existing controller first and
# suggest using it; otherwise offer manual / use-existing / install.
do_controller_brand() {
    local brand="$1" registered first
    registered="$(controllers_of_vendor "${brand}")"
    first="$(head -1 <<<"${registered}")"
    info "How do you want to manage your ${brand} switch(es)?"
    if [[ -n "${first}" ]]; then
        info "  (a ${brand} controller is already registered: ${first})"
        echo "    1) Use controller '${first}' (upload its switches + set node uplinks)"
        echo "    2) Manual (configure by hand)"
        echo "    3) Register another controller"
        case "$(ask_choice 3)" in
            1) do_use_registered_controller "${first}" ;;
            2) do_manual "${brand}" ;;
            3) do_existing_controller "${brand}" ;;
        esac
    elif [[ -s "${UNIFI_CRED}" ]]; then
        info "  (${brand} controller credentials are present — a controller is set up)"
        echo "    1) Use that controller (register it + upload its switches)"
        echo "    2) Manual (configure by hand)"
        echo "    3) Install/register a different controller"
        case "$(ask_choice 3)" in
            1) do_existing_controller "${brand}" ;;
            2) do_manual "${brand}" ;;
            3) do_install_controller "${brand}" ;;
        esac
    else
        info "  (no ${brand} controller found)"
        echo "    1) Manual (configure by hand)"
        echo "    2) Use an existing ${brand} controller"
        echo "    3) Install a ${brand} controller"
        case "$(ask_choice 3)" in
            1) do_manual "${brand}" ;;
            2) do_existing_controller "${brand}" ;;
            3) do_install_controller "${brand}" ;;
        esac
    fi
}

# ── Brand selection + dispatch (one iteration) ──────────────────────

register_one_brand() {
    local brands=() i choice brand arch
    mapfile -t brands < <(discover_brands)
    echo
    info "${BOLD}What is the vendor of your switch?${CL} (known brands are auto-detected)"
    for i in "${!brands[@]}"; do echo "    $((i+1))) ${brands[$i]}"; done
    echo "    $(( ${#brands[@]} + 1 ))) Other / unmanaged brand (manual only)"
    choice="$(ask_choice $(( ${#brands[@]} + 1 )))"
    if (( choice <= ${#brands[@]} )); then
        brand="${brands[$((choice-1))]}"
    else
        brand="$(ask "  brand name (label, e.g. netgear): " other)"
        do_manual "${brand}"; return 0
    fi

    arch="$(plugin_arch_of "${brand}")"
    case "${arch}" in
        controller) do_controller_brand "${brand}" ;;
        device)
            info "How do you want to manage your ${brand} switch(es)?"
            echo "    1) Manual (configure by hand)"
            echo "    2) Register each switch by IP (auto-configure)"
            case "$(ask_choice 2)" in
                1) do_manual "${brand}" ;;
                2) do_device "${brand}" ;;
            esac ;;
        *)
            do_manual "${brand}" ;;
    esac
}

run_loop() {
    info "${BOLD}Registration & setup of switches that carry TAPPaaS traffic.${CL}"
    print_inventory   # show what is already registered
    while true; do
        register_one_brand
        echo
        print_inventory   # summary after finishing this brand
        echo
        [[ "$(ask "  Register switches of another brand? [y/N]: " N)" =~ ^[Yy] ]] || break
    done
    echo; info "Reconciling all switches with zones.json (applying / printing what to tag)..."
    "${SWITCH_MANAGER}" reconcile --apply || warn "  some switches need manual VLAN tagging — see the output above"
    echo; info "${GN}Done.${CL} Review any time with: ${BL:-}switch-manager list${CL:-} / ${BL:-}switch-manager delta${CL:-}"
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) INTERACTIVE=0; shift ;;
            -h|--help)         usage; exit 0 ;;
            *) die "unknown argument '$1' (try --help)" ;;
        esac
    done
    command -v "${SWITCH_MANAGER}" >/dev/null 2>&1 || [[ -x "${SWITCH_MANAGER}" ]] \
        || die "switch-manager not found (run this on the cicd mothership)"
    if [[ "${INTERACTIVE}" == "0" || ! -t 0 ]]; then
        info "Switch setup skipped (non-interactive). Configure switches later with:"
        info "  ${BL:-}setup-switches.sh${CL:-}"
        return 0
    fi
    run_loop
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
