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
info "${_SUMMARY}"

# ── Configure OPNsense to forward syslog to this VM ──────────────────
# Idempotent: matches the destination by description ("tappaas-logging").
# Skipped when firewallType != opnsense (deployment uses a different firewall).
info "${BOLD}Configure OPNsense syslog forwarding${CL}"

FIREWALL_TYPE="$(get_config_value 'firewallType' 'opnsense')"
SYSLOG_TARGET="${VMNAME}.${ZONE0NAME}.internal"
SYSLOG_DESC="tappaas-logging"

if [[ "${FIREWALL_TYPE}" != "opnsense" ]]; then
    info "  firewallType=${FIREWALL_TYPE} — skipping (configure manually on your firewall)"
elif ! command -v syslog-manager >/dev/null 2>&1; then
    warn "  syslog-manager CLI not found — rebuild the mothership to pick it up"
    warn "  Manual fallback: System → Settings → Logging / Targets → add ${SYSLOG_TARGET}:1514 (TCP, RFC 5424)"
else
    info "  Target: ${SYSLOG_TARGET}:1514 (TCP, RFC 5424)"
    # Capture syslog-manager's chatter ("OK", "Destination … already correct",
    # "Reconfiguring syslog…", "syslog reconfigured") and route it to [Debug] —
    # it is noise on the console, useful only when troubleshooting.
    _sl_out="$(syslog-manager add-destination \
            --hostname "${SYSLOG_TARGET}" \
            --port 1514 \
            --transport tcp4 \
            --rfc5424 \
            --description "${SYSLOG_DESC}" \
            --no-ssl-verify 2>&1)" && _sl_rc=0 || _sl_rc=$?
    [[ -n "${_sl_out}" ]] && while IFS= read -r _sl_l; do debug "  ${_sl_l}"; done <<<"${_sl_out}"
    if [[ ${_sl_rc} -eq 0 ]]; then
        _sl_out="$(syslog-manager reconfigure --no-ssl-verify 2>&1)" && _sl_rc=0 || _sl_rc=$?
        [[ -n "${_sl_out}" ]] && while IFS= read -r _sl_l; do debug "  ${_sl_l}"; done <<<"${_sl_out}"
        if [[ ${_sl_rc} -eq 0 ]]; then
            info "  ${GN}✓${CL} OPNsense will now forward syslog to ${SYSLOG_TARGET}:1514"
        else
            warn "  Destination saved but OPNsense reconfigure failed — apply manually in the UI"
        fi
    else
        warn "  Could not add OPNsense syslog destination — configure manually via the UI"
    fi
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
info "${BOLD}Configure Proxmox nodes' rsyslog forwarding${CL}"

# Node hostnames from site.json (.hardware.nodes), falling back to
# configuration.json (.tappaas-nodes) — via the shared helper.
mapfile -t NODE_HOSTS < <(get_all_node_hostnames 2>/dev/null)
NODE_COUNT="${#NODE_HOSTS[@]}"

if [[ "${NODE_COUNT}" -lt 1 ]]; then
    warn "  No nodes resolved (site.json/configuration.json) — skipping"
else
    SYSLOG_FQDN="${VMNAME}.${ZONE0NAME}.internal"

    # Generate the rsyslog snippet once, then scp it to each node.
    TMP_CONF="$(mktemp)"
    trap 'rm -f "${TMP_CONF}"' EXIT
    cat > "${TMP_CONF}" <<EOF
# TAPPaaS-managed — ship syslog to Loki via Alloy on ${SYSLOG_FQDN}:1515
# Format: RFC 5424 over TCP with octet-counted framing (RFC 5425)
# Do not edit by hand; this file is regenerated by logging/update.sh.
*.* action(type="omfwd"
           target="${SYSLOG_FQDN}"
           port="1515"
           protocol="tcp"
           template="RSYSLOG_SyslogProtocol23Format"
           TCP_Framing="octet-counted"
           Action.ResumeRetryCount="-1"
           queue.type="LinkedList"
           queue.size="10000")
EOF

    SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
    REMOTE_PATH="/etc/rsyslog.d/99-tappaas-loki.conf"

    for NODE_HOSTNAME in "${NODE_HOSTS[@]}"; do
        [[ -z "${NODE_HOSTNAME}" ]] && continue
        NODE_FQDN="${NODE_HOSTNAME}.mgmt.internal"
        debug "  → ${NODE_HOSTNAME}"

        # PVE 9 / Debian 13 (trixie) ships journald-only by default — install
        # rsyslog if missing. Its default config wires `imjournal` so all
        # journal entries flow through, then our 99-tappaas-loki.conf adds
        # the omfwd forwarder to Alloy. Idempotent.
        # shellcheck disable=SC2086
        if ! ssh ${SSH_OPTS} "root@${NODE_FQDN}" "command -v rsyslogd >/dev/null" 2>/dev/null; then
            debug "    installing rsyslog..."
            # shellcheck disable=SC2086
            if ! ssh ${SSH_OPTS} "root@${NODE_FQDN}" \
                "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsyslog >/dev/null 2>&1"; then
                warn "    ${NODE_HOSTNAME}: rsyslog install failed — skipping"
                continue
            fi
        fi

        # shellcheck disable=SC2086
        if ! scp ${SSH_OPTS} "${TMP_CONF}" "root@${NODE_FQDN}:${REMOTE_PATH}" >/dev/null 2>&1; then
            warn "    ${NODE_HOSTNAME}: scp failed — node unreachable or no SSH key"
            continue
        fi

        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} "root@${NODE_FQDN}" \
            "systemctl enable --now rsyslog >/dev/null 2>&1 && systemctl restart rsyslog" 2>/dev/null; then
            debug "    ${GN}✓${CL} ${NODE_HOSTNAME}: rsyslog → ${SYSLOG_FQDN}:1515"
        else
            warn "    ${NODE_HOSTNAME}: config pushed but rsyslog (enable|restart) failed"
        fi

        install_guest_memory_sampler "${NODE_FQDN}" "${NODE_HOSTNAME}"
    done
fi

# ── The alert webhook's token (#126) ─────────────────────────────────
# Grafana's alert rules post to the mothership's tappaas-alert-receiver, which
# mails through site-notify.sh. The receiver checks a bearer token; its own copy
# is /etc/secrets/tappaas-alert-token here (tappaas-cicd.nix generates it), and
# Grafana reads its copy from the logging VM. Copied only when it differs, and
# Grafana restarted only then: the contact point reads the file at start.
info "${BOLD}Deliver the alert webhook token to Grafana${CL}"
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
        debug "  token already in place"
    elif ssh -o BatchMode=yes -o ConnectTimeout=10 "${_VM}" \
            "sudo install -m 0600 -o grafana -g grafana /dev/stdin ${_VM_TOKEN} && sudo systemctl restart grafana" \
            < "${_ALERT_TOKEN}"; then
        info "  ${GN}✓${CL} token delivered; Grafana restarted to read it"
    else
        warn "  could not deliver the token to ${VMNAME} — alerts cannot reach the mothership until it is"
    fi
fi
