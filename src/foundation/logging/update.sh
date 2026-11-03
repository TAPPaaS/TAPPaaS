#!/usr/bin/env bash
#
# TAPPaaS logging VM update
#
# Update VM and apply module specific updates.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh logging
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "$1")"
# F5 (defensive): vmid is written back to the module config by the cluster:vm
# hook; on the very first install pass it could be absent when update.sh is
# sourced from install.sh right after VM creation. It is DISPLAY-ONLY here, so
# default it rather than let a missing value abort the whole logging install
# under set -e (a Step-6 abort that — before F4 — was hidden). Reconciled next run.
VMID="$(get_config_value 'vmid' 'unknown')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
# Resolve HA node: on a single-node cluster get_default_ha_node returns empty,
# and get_config_value aborts when both key-missing AND default-empty. Pass a
# non-empty placeholder so the banner is optional rather than fatal.
HANODE_DEFAULT="$(get_default_ha_node "$NODE")"
HANODE="$(get_config_value 'HANode' "${HANODE_DEFAULT:-NONE}")"

# One-line target summary — neutral wording so it reads correctly whether this
# runs standalone (update) or sourced from install.sh (install). install.sh
# appends the install-only "Next steps" after sourcing this script.
_SUMMARY="  VM: ${VMNAME} (VMID: ${VMID}), Node: ${NODE}, Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" && "${HANODE}" != "NONE" ]]; then
    _SUMMARY="${_SUMMARY}, HA Node: ${HANODE}"
fi
debug "${_SUMMARY}"

# ── TLS: the internal CA's certificate for this VM (#787, ADR-043 D5) ──
# On every install and update: made once, delivered each time (unchanged files
# leave nginx and Alloy alone), and put there again on each renewal by
# `ca-manager cert renew`. Until it arrives the VM serves a placeholder on its
# TLS ports, and senders stay on the plain ones (log-shipping.sh).
_TLS_NAME="${VMNAME}.${ZONE0NAME}.internal"
if command -v ca-manager >/dev/null 2>&1; then
    if ca-manager cert issue "${VMNAME}" --dns "${_TLS_NAME}" --if-absent >/dev/null 2>&1 \
        && ca-manager cert deliver "${VMNAME}" --host "${_TLS_NAME}" --dir /etc/tappaas-tls --as logging \
              --group tappaas-tls --reload nginx,alloy >/dev/null 2>&1; then
        debug "  TLS: ${_TLS_NAME}'s certificate is on the VM"
    else
        warn "  TLS: ${_TLS_NAME}'s certificate is not on the VM — senders stay on the plain ports:"
        warn "    ca-manager cert issue ${VMNAME} --dns ${_TLS_NAME} --if-absent && ca-manager cert deliver ${VMNAME} --host ${_TLS_NAME} --dir /etc/tappaas-tls --as logging --group tappaas-tls --reload nginx,alloy"
    fi
else
    warn "  TLS: no ca-manager on this mothership yet — senders stay on the plain ports"
fi

# ── The firewall's and the nodes' syslog (ADR-039 D9) ─────────────────
# They are logging:logs consumers like every other (their client is a syslog
# target, lib/log-shipping.sh); set up here too, so a logging that arrives after
# them, or is reinstalled, has their lines at once.
# shellcheck source=../tappaas-cicd/lib/log-shipping.sh
. /home/tappaas/bin/log-shipping.sh
debug "Configure OPNsense syslog forwarding"
FIREWALL_TYPE="$(get_config_value 'firewallType' 'opnsense')"
if [[ "${FIREWALL_TYPE}" != "opnsense" ]]; then
    info "  firewallType=${FIREWALL_TYPE} — skipping (configure manually on your firewall)"
elif _sl_out="$(apply_log_shipping_opnsense 2>&1)"; then
    debug "  ${_sl_out}"
    _sum_opn="OPNsense"
else
    warn "  Could not set OPNsense's syslog destination — configure manually via the UI (System → Settings → Logging / Targets: $(_ls_syslog_target):1514, TCP, RFC 5424)"
    [[ -n "${_sl_out}" ]] && while IFS= read -r _sl_l; do debug "  ${_sl_l}"; done <<<"${_sl_out}"
fi

# install_guest_memory_sampler <node fqdn> <node name> — each guest's memory
# working set, once a minute, through the node's rsyslog into Loki (#663;
# node/tappaas-guest-memory). The service restarts only when a file changed, so
# a routine update leaves no gap in the series.
install_guest_memory_sampler() {
    local fqdn="$1" name="$2" dir="${SCRIPT_DIR}/node" rc=0
    # shellcheck disable=SC2086
    tar -C "${dir}" -cf - tappaas-guest-memory tappaas-guest-memory.service \
        | ssh ${SSH_OPTS} "root@${fqdn}" '
            set -e; t=$(mktemp -d); trap "rm -rf $t" EXIT; tar -C "$t" -xf -
            perl -c "$t/tappaas-guest-memory" >/dev/null 2>&1 || exit 3
            changed=0
            cmp -s "$t/tappaas-guest-memory" /usr/local/sbin/tappaas-guest-memory || {
                install -m 0755 "$t/tappaas-guest-memory" /usr/local/sbin/tappaas-guest-memory; changed=1; }
            cmp -s "$t/tappaas-guest-memory.service" /etc/systemd/system/tappaas-guest-memory.service || {
                install -m 0644 "$t/tappaas-guest-memory.service" /etc/systemd/system/; changed=1
                systemctl daemon-reload; }
            systemctl enable --now tappaas-guest-memory.service >/dev/null 2>&1
            [ "$changed" = 0 ] || systemctl restart tappaas-guest-memory.service
            systemctl is-active --quiet tappaas-guest-memory.service' 2>/dev/null || rc=$?
    case "${rc}" in
        0) debug "    ${GN}✓${CL} ${name}: guest memory sampler running" ;;
        3) warn "    ${name}: the guest memory sampler does not compile on this node's Perl — not installed" ;;
        *) warn "    ${name}: could not install or start the guest memory sampler (rc ${rc})" ;;
    esac
}

# ── Configure Proxmox nodes to forward rsyslog to this VM ────────────
# Each cluster node ships its journal-forwarded syslog (via rsyslog) to the
# Alloy syslog receiver on tcp/1515 (source=proxmox).
# Idempotent: scp overwrites the conf file; rsyslog restart is harmless.
debug "Configure Proxmox nodes' rsyslog forwarding"

# Node hostnames: the cluster's nodes (their pvehost instances) — via the
# shared helper.
mapfile -t NODE_HOSTS < <(get_all_node_hostnames 2>/dev/null)
NODE_COUNT="${#NODE_HOSTS[@]}"

if [[ "${NODE_COUNT}" -lt 1 ]]; then
    warn "  No nodes resolved (site.json/configuration.json) — skipping"
else
    SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
    _rsyslog_ok=0

    for NODE_HOSTNAME in "${NODE_HOSTS[@]}"; do
        [[ -z "${NODE_HOSTNAME}" ]] && continue
        NODE_FQDN="${NODE_HOSTNAME}.mgmt.internal"
        debug "  → ${NODE_HOSTNAME}"

        if _rs_out="$(apply_log_shipping_node "${NODE_HOSTNAME}" 2>&1)"; then
            debug "    ${GN}✓${CL} ${_rs_out}"
            _rsyslog_ok=$((_rsyslog_ok + 1))
        else
            warn "    ${NODE_HOSTNAME}: rsyslog forwarding not set — node unreachable, or rsyslog would not start"
        fi

        install_guest_memory_sampler "${NODE_FQDN}" "${NODE_HOSTNAME}"
    done
    if [[ "${_rsyslog_ok}" -gt 0 ]]; then
        debug "  Proxmox nodes forward syslog to $(_ls_syslog_target):1515 (${_rsyslog_ok} of ${NODE_COUNT})"
        _sum_nodes="${_rsyslog_ok} of ${NODE_COUNT} nodes"
    fi
fi

# ── The alert webhook's token (#126) ─────────────────────────────────
# Grafana's alert rules post to the mothership's tappaas-alert-receiver, which
# mails through site-notify.sh. The receiver checks a bearer token; its own copy
# is /etc/secrets/tappaas-alert-token here (tappaas-cicd.nix generates it), and
# Grafana reads its copy from the logging VM. Copied only when it differs, and
# Grafana restarted only then: the contact point reads the file at start.
debug "Deliver the alert webhook token to Grafana"
_ALERT_TOKEN=/etc/secrets/tappaas-alert-token
_VM_TOKEN=/etc/secrets/grafana-alert-webhook-token
_VM="tappaas@${VMNAME}.${ZONE0NAME}.internal"
if [[ ! -r "${_ALERT_TOKEN}" ]]; then
    warn "  ${_ALERT_TOKEN} not readable here — alerts are evaluated but cannot be delivered until the mothership's rebuild creates it"
else
    _want="$(sha256sum < "${_ALERT_TOKEN}" | cut -d' ' -f1)"
    # sudo reads the file itself: a `< file` redirect would be opened by the
    # unprivileged login, fail, and make every update restart Grafana.
    # shellcheck disable=SC2029  # the path is expanded here on purpose
    _have="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${_VM}" "sudo sha256sum ${_VM_TOKEN} 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
    # shellcheck disable=SC2029  # the elif's path is expanded here on purpose too
    if [[ "${_have}" == "${_want}" ]]; then
        debug "  alert webhook token already in place"
    elif ssh -o BatchMode=yes -o ConnectTimeout=10 "${_VM}" \
            "sudo install -m 0600 -o grafana -g grafana /dev/stdin ${_VM_TOKEN} && sudo systemctl restart grafana" \
            < "${_ALERT_TOKEN}"; then
        info "  ${GN}✓${CL} alert webhook token delivered to Grafana; Grafana restarted to read it"
    else
        warn "  could not deliver the token to ${VMNAME} — alerts cannot reach the mothership until it is"
    fi
fi

# ── Who may push and read (#165 §1) ──────────────────────────────────
# nginx on the VM checks every push against a credential per VM and every
# query against the admin credential; both password files are kept here on the
# mothership and written to the VM when they differ. The mothership's own
# credential is made here, as tappaas, before its own rebuild reads it.
debug "Sync the push and admin credentials to nginx"
# shellcheck source=../tappaas-cicd/lib/log-shipping.sh
. /home/tappaas/bin/log-shipping.sh
log_shipping_password tappaas-cicd >/dev/null || warn "  could not make the mothership's push credential"
if log_shipping_sync_logging; then
    _sum_creds="$(ls "${LOG_SHIPPING_CRED_DIR}" 2>/dev/null | wc -l)"
    debug "  nginx push and admin credentials synced (${_sum_creds} pushing hosts)"
else
    warn "  could not write the credentials to ${VMNAME} — pushes and queries are refused until they are"
fi

# ── Module alert rules (ADR-039) ─────────────────────────────────────
# Each module's rules live in Grafana's database, not in this VM's build: put
# every module's group back, so a rebuilt or restored Grafana has them without
# waiting for each module's next update.
_ALERT_RULES="${SCRIPT_DIR}/../tappaas-cicd/scripts/tappaas-alert-rules.py"
if [[ -f "${_ALERT_RULES}" ]]; then
    if _ar_out="$(python3 -I "${_ALERT_RULES}" apply-all 2>&1)"; then
        _sum_rules="$(grep -c 'rule(s) in module-' <<<"${_ar_out}" || true)"
        debug "  module alert rules re-applied: ${_ar_out//$'\n'/; }"
    else
        warn "  module alert rules: ${_ar_out//$'\n'/; }"
    fi
fi

# One line for what an update re-established (a failure above has warned).
_sum_from="$(printf '%s and ' ${_sum_opn:+"${_sum_opn}"} ${_sum_nodes:+"${_sum_nodes}"} | sed 's/ and $//')"
_sum=""
[[ -n "${_sum_from}" ]] && _sum="syslog from ${_sum_from}"
[[ -n "${_sum_creds:-}" ]] && _sum+="${_sum:+, }credentials for ${_sum_creds} pushing hosts"
[[ "${_sum_rules:-0}" -gt 0 ]] && _sum+="${_sum:+, }alert rules of ${_sum_rules} module(s)"
[[ -n "${_sum}" ]] && info "  ${GN}✓${CL} logging: ${_sum}"
