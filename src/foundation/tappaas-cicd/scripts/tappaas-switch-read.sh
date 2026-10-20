#!/usr/bin/env bash
# tappaas-switch-read.sh — read the site's switches after a sweep (#860).
#
# switch-manager reads a switch only when someone interrogates it (the
# console, Setup, an operator), and the switch-ports gate (#853) judges the
# ports as last read: a port changed in the controller's own UI, or a device
# plugged into an unrecorded port, stayed invisible until then. This runs after
# every sweep, next to the security scan (tappaas-switch-read.service, started
# by update-tappaas on success and on failure):
#
#   1. `switch-manager interrogate --no-park` — read every controller and
#      auto switch into config/switch-configuration-actual.json. Read only: it
#      never parks a port and never applies anything; that stays an operator's
#      or the console's decision.
#   2. the switch-ports gate over what was just read (health-manager validate);
#   3. with --notify, a mail to the site owner (site-notify.sh) when the gate
#      has a finding it did not have after the last read — not every night for
#      the same port.
#
# The findings and when they were read are kept in config/switch-read.json.
#
# Usage: tappaas-switch-read.sh [--if-new-sweep] [--notify]
#   --if-new-sweep  only when a sweep has written a result since the last read
#                   (the unit's mode: update-tappaas also runs hourly, as a no-op)
#   --notify        mail the owner about new findings
# Exit: 0 read (findings are its result, not its failure), 1 a switch could not
# be read or the gate gave no answer.

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

IF_NEW=0; NOTIFY=0
for a in "$@"; do
    case "${a}" in
        --if-new-sweep) IF_NEW=1 ;;
        --notify) NOTIFY=1 ;;
        *) die "tappaas-switch-read: unexpected argument ${a}" ;;
    esac
done

CONF="${CONFIG_DIR:-/home/tappaas/config}"
STATE="${CONF}/switch-read.json"
RESULT="${CONF}/last-update-result.json"
ACTUAL="${CONF}/switch-configuration-actual.json"

if [[ "${IF_NEW}" == 1 ]]; then
    if [[ ! -f "${RESULT}" ]] || { [[ -f "${STATE}" ]] && [[ ! "${RESULT}" -nt "${STATE}" ]]; }; then
        info "no sweep since the last switch read — nothing to do"
        exit 0
    fi
fi
if [[ ! -s "${ACTUAL}" ]] || [[ "$(jq -r '(.switches // {}) | length' "${ACTUAL}" 2>/dev/null)" == "0" ]]; then
    info "no switch in the inventory — nothing to read"
    exit 0
fi

rc=0
info "${BOLD}Reading the switches${CL} (switch-manager interrogate --no-park)"
switch-manager interrogate --no-park || { rc=1; warn "  a switch could not be read — the gate judges it as last read"; }

doc="$(health-manager validate --json 2>/dev/null)" || true
gate="$(jq -c '.gates[]? | select(.name == "switch-ports")' <<<"${doc}" 2>/dev/null)"
if [[ -z "${gate}" ]]; then
    error "health-manager validate gave no switch-ports gate"
    exit 1
fi
status="$(jq -r .status <<<"${gate}")"
info "switch-ports: ${status} — $(jq -r .detail <<<"${gate}")"
now="$(jq -c '[.findings[] | select(.status == "warn") | .text] | sort' <<<"${gate}")"
before="$(jq -c '.findings // [] | sort' "${STATE}" 2>/dev/null || echo '[]')"
new="$(jq -nc --argjson n "${now}" --argjson b "${before}" '$n - $b')"
for t in $(jq -r '.[] | @base64' <<<"${now}"); do info "  [WARN] $(base64 -d <<<"${t}")"; done

if [[ "${NOTIFY}" == 1 && "$(jq length <<<"${new}")" -gt 0 ]]; then
    {
        echo "The switch read after the sweep found $(jq length <<<"${new}") new finding(s) on the site's switch ports:"
        echo ""
        jq -r '.[] | "  - " + .' <<<"${new}"
        echo ""
        echo "All findings now: switch-manager list-ports, or the console's physical view."
        echo "A port nobody uses is parked with: switch-manager update-port <switch> <port> --park"
    } | site-notify.sh --subject "switch ports: $(jq length <<<"${new}") new finding(s)" --what "switch read" \
        || warn "  the notice could not be sent (site-notify.sh)"
fi

tmp="$(mktemp)"
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "${status}" --argjson f "${now}" \
    '{read: $t, status: $s, findings: $f}' > "${tmp}" && mv "${tmp}" "${STATE}"
exit "${rc}"
