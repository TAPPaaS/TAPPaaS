#!/usr/bin/env bash
# tappaas-render-fragments.sh — the generated NixOS fragments the mothership's
# own build imports, written as root before either rebuild path:
#
#   update-tappaas.service   tappaas-self-rebuild.sh calls it (ADR-017 D3)
#   tappaas-rebuild@<vm>     ExecStartPre, for `update-module.sh tappaas-cicd`
#                            and `module modify tappaas-cicd` outside the unit
#
# Before #770 they were written only on the first path, so the helper rebuilt
# with whatever /etc/nixos held — the journal client was dropped on hrossen
# (2026-10-06) because its fragment had never been written there.
#
#   /etc/nixos/tappaas-site.nix      the site's time and locale (#408, #472)
#                                    and its Nix signing key (ADR-033 D8)
#   /etc/nixos/tappaas-logging.nix   the journal client (#770), only while
#                                    logging is deployed and tappaas-cicd
#                                    declares logging:logs
#
# Sourced from the CHECKOUT, not ~tappaas/bin — root already builds this system
# from that tree, so it is no new trust, while ~tappaas/bin is a path root must
# not read code from.

set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin

debug() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m $*"; }
warn()  { echo -e "\033[33m[Warning]\033[m $*"; }

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD_DIR="$(dirname "${_here}")"
VMNAME="$(jq -r '.vmname // .config.vmname // "tappaas-cicd"' /home/tappaas/config/tappaas-cicd.json 2>/dev/null || echo tappaas-cicd)"
[[ "${VMNAME}" =~ ^[A-Za-z0-9-]+$ ]] || { warn "bad vmname '${VMNAME}'"; exit 1; }

# The site's Nix signing key (ADR-033 D8), created here the first time: every
# guest system update-os.sh copies is signed with it, and tappaas-site.nix
# below carries its public half.
_nsk="${CICD_DIR}/lib/nix-site-key.sh"
if [[ -f "${_nsk}" ]]; then
    # shellcheck source=../lib/nix-site-key.sh
    if . "${_nsk}" && nix_site_key_ensure; then
        debug "site Nix signing key: $(nix_site_key_public)"
    else
        warn "could not create the site's Nix signing key — guest systems are copied unchecked until it exists"
    fi
fi

# The site's own time and locale (#408, #472).
_sl="${CICD_DIR}/lib/site-locale.sh"
if [[ -f "${_sl}" ]]; then
    # shellcheck source=../lib/site-locale.sh
    if . "${_sl}" 2>/dev/null && declare -F render_site_nix >/dev/null 2>&1; then
        _mgmt_zone="$(jq -r '(.zone0 // "mgmt")' /home/tappaas/config/tappaas-cicd.json 2>/dev/null || echo mgmt)"
        if render_site_nix "${_mgmt_zone}" > /etc/nixos/tappaas-site.nix.new 2>/dev/null; then
            mv -f /etc/nixos/tappaas-site.nix.new /etc/nixos/tappaas-site.nix
            debug "wrote /etc/nixos/tappaas-site.nix from site.json"
        else
            rm -f /etc/nixos/tappaas-site.nix.new
            warn "could not render the site's time/locale — the mothership keeps what it has"
        fi
    fi
fi

# The mothership's journal client (#770), the fragment every NixOS VM gets
# (lib/log-shipping.sh), rendered here because this host is not built by
# update-os.sh. Removed when logging is not deployed.
_lsh="${CICD_DIR}/lib/log-shipping.sh"
if [[ -f "${_lsh}" ]]; then
    # shellcheck source=../lib/log-shipping.sh
    if . "${_lsh}" 2>/dev/null && declare -F render_logging_nix >/dev/null 2>&1; then
        if CONFIG_DIR=/home/tappaas/config log_shipping_wanted tappaas-cicd; then
            # Its push secret (#165 §1), from the store every VM's comes from;
            # the logging VM learns a new one at logging:logs' next sync.
            if ! { _pw="$(log_shipping_password "${VMNAME}")" \
                   && { [ -d /etc/secrets ] || install -d -m 0755 /etc/secrets; } \
                   && printf '%s' "${_pw}" | install -m 0600 -o root -g root /dev/stdin "${LOG_SHIPPING_VM_SECRET}"; }; then
                warn "could not write the mothership's log push secret — its journal is refused until it is"
            fi
            if render_logging_nix "${VMNAME}" mgmt \
                    "$(CONFIG_DIR=/home/tappaas/config log_shipping_drop_regex tappaas-cicd)" \
                    > /etc/nixos/tappaas-logging.nix.new 2>/dev/null; then
                mv -f /etc/nixos/tappaas-logging.nix.new /etc/nixos/tappaas-logging.nix
            else
                rm -f /etc/nixos/tappaas-logging.nix.new
                warn "could not render the journal client — the mothership keeps what it has"
            fi
        else
            rm -f /etc/nixos/tappaas-logging.nix "${LOG_SHIPPING_VM_SECRET}"
        fi
    fi
fi
