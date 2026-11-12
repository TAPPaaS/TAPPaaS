#!/usr/bin/env bash
#
# security-monitoring.sh — the site's security monitoring switch and the
# security log retention (ADR-050 D1, D2). Sourceable only; needs
# metrics-shipping.sh (its _ms_put and the logging VM), which it sources.
#
# site.json `security`:
#   monitoring     on | off; not set: off on a small site, on otherwise
#   retentionDays  days the security streams are kept; not set: 90, 180 at large
#
# Loki keeps the security streams longer than its 30 days through its runtime
# config (/etc/tappaas-loki/runtime.yaml on the logging VM), which it re-reads
# by itself: no restart. Off, the file holds no override and every stream is
# kept 30 days.
#
# Functions:
#   security_monitoring              on | off
#   security_retention_days          days
#   security_streams                 the LogQL selectors that are security streams, one per line
#   render_loki_runtime              the runtime config, on stdout
#   security_sync_logging            the runtime config and CrowdSec's credentials onto
#                                    the logging VM
#   security_crowdsec_password       the logging VM's CrowdSec machine password (made
#                                    on first use, kept on the mothership)
#   security_firewall_lapi           the firewall's local API address (its mgmt address)
#   render_crowdsec_credentials      the logging VM's local_api_credentials.yaml, on stdout
#
# CrowdSec (ADR-050 D4): the logging VM runs a CrowdSec log processor that reads
# Loki (sshd, Authentik, Proxmox's API) and reports to the local API on the
# firewall, whose bouncer bans in pf. network's crowdsec-converge.sh registers
# the machine there with the same password; this writes its credentials to the
# logging VM. The processor runs only while the credentials file exists.

if [[ -z "${_SECURITY_MONITORING_LOADED:-}" ]]; then
_SECURITY_MONITORING_LOADED=1

# shellcheck source=metrics-shipping.sh
. "${METRICS_SHIPPING_LIB:-$(dirname "${BASH_SOURCE[0]}")/metrics-shipping.sh}"

SECURITY_LOKI_RUNTIME="/etc/tappaas-loki/runtime.yaml"
SECURITY_CROWDSEC_CREDS="/etc/secrets/crowdsec-lapi.yaml"
SECURITY_CROWDSEC_MACHINE="tappaas-logging"
SECURITY_CROWDSEC_PW_FILE="${SECURITY_CROWDSEC_PW_FILE:-/home/tappaas/.crowdsec-logging-machine}"
SECURITY_LAPI_PORT=8080

security_crowdsec_password() {
    if [[ ! -s "${SECURITY_CROWDSEC_PW_FILE}" ]]; then
        ( umask 077; head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40 > "${SECURITY_CROWDSEC_PW_FILE}" ) || return 1
    fi
    cat "${SECURITY_CROWDSEC_PW_FILE}"
}

# The firewall's mgmt address: where its local API listens for the logging VM.
security_firewall_lapi() {
    local ip
    [[ -n "${SECURITY_FIREWALL_IP:-}" ]] && { echo "${SECURITY_FIREWALL_IP}"; return; }
    ip="$(getent hosts "${FIREWALL_FQDN:-firewall.mgmt.internal}" 2>/dev/null | awk '{print $1; exit}')"
    [[ "${ip}" =~ ^[0-9.]+$ ]] || { echo "security: cannot resolve the firewall's mgmt address" >&2; return 1; }
    echo "${ip}"
}

render_crowdsec_credentials() {
    local pw ip
    pw="$(security_crowdsec_password)" || return 1
    ip="$(security_firewall_lapi)" || return 1
    printf 'url: http://%s:%s/\nlogin: %s\npassword: %s\n' "${ip}" "${SECURITY_LAPI_PORT}" "${SECURITY_CROWDSEC_MACHINE}" "${pw}"
}

# security_monitoring is log-shipping.sh's: the NixOS fragment reads it too.

security_retention_days() {
    local d; d="$(jq -r '.security.retentionDays // empty' "$(_ms_site)" 2>/dev/null || true)"
    if [[ "${d}" =~ ^[0-9]+$ && "${d}" -ge 30 && "${d}" -le 730 ]]; then echo "${d}"; return; fi
    [[ "$(_ms_size)" == large ]] && echo 180 || echo 90
}

# What is kept as security: audit records (guests' journal transport, the
# nodes' audisp syslog), logins (sshd everywhere, Proxmox's API, Authentik's
# events), the firewall's blocks and audit log, and what CrowdSec and Suricata
# say. Labels as the logging module sets them (log-shipping.sh, logging.nix).
security_streams() {
    cat <<'EOF'
{transport="audit"}
{unit=~"sshd.*"}
{host="identity", container=~"authentik-.*"}
{source="opnsense", unit=~"filterlog|audit|api|sshd.*|crowdsec.*|suricata"}
{source="proxmox", unit=~"sshd.*|pvedaemon|pveproxy|audisp.*|audit.*"}
EOF
}

render_loki_runtime() {
    local days
    echo "# GENERATED on the mothership (lib/security-monitoring.sh). Do not edit here."
    if [[ "$(security_monitoring)" != on ]]; then
        echo "# Security monitoring is off: every stream is kept for Loki's retention_period."
        echo "overrides: {}"
        return 0
    fi
    days="$(security_retention_days)"
    echo "# Security streams are kept ${days} days (site.json security.retentionDays, or by size)."
    echo "overrides:"
    echo "  fake:"
    echo "    retention_stream:"
    while IFS= read -r sel; do
        [[ -n "${sel}" ]] || continue
        printf "      - selector: '%s'\n        priority: 1\n        period: %sh\n" "${sel}" "$((days * 24))"
    done < <(security_streams)
}

security_sync_logging() {
    local vm content
    [[ -f "$(_ls_config_dir)/logging.json" ]] || return 0
    vm="$(_ls_logging_vm)"
    content="$(render_loki_runtime)" || return 1
    _ms_put "${vm}" "${SECURITY_LOKI_RUNTIME}" 0644 root:root "${content}
" >/dev/null || return 1
    if [[ "$(security_monitoring)" == on ]]; then
        # CrowdSec's credentials; the processor (re)starts when they changed or
        # it is not running. The group exists once logging's NixOS has it.
        local creds c
        creds="$(render_crowdsec_credentials)" || return 1
        c="$(_ms_put "${vm}" "${SECURITY_CROWDSEC_CREDS}" 0640 root:crowdsec "${creds}")" || return 1
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" \
            "if [ -n '${c}' ] || ! systemctl is-active -q crowdsec; then sudo systemctl restart crowdsec; fi" || return 1
        echo "security: monitoring on, security logs kept $(security_retention_days) days, CrowdSec reads Loki"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" \
            "sudo rm -f ${SECURITY_CROWDSEC_CREDS}; sudo systemctl stop crowdsec 2>/dev/null || true" || return 1
        echo "security: monitoring off"
    fi
}

fi
