#!/usr/bin/env bash
# pbs-pulse.sh — put the pulse on the backup node (ADR-031 D1).
#
# The pulse watches this site's backup buddies from outside their site, and this
# site from its own backup node; the script itself is ../pulse/pulse.sh. This
# library writes its config and installs it, from every backup update:
#
#   pulse_config_json <pbs-host>   the pulse.json for this site, on stdout
#   pulse_ensure <pbs-host>        install script, config and timer on that Host
#
# The config is derived, never edited on the node: site.json gives the site and
# the operator's address; the PBS's own remotes give each buddy we pull from
# (host, port, certificate fingerprint); config/pull-<name>.json gives the
# buddy's contact (`backup-manager peer add … --contact`); config/remote-<name>.json
# gives each buddy that pulls us (its login, for when it last pulled; its contact).
#
# PULSE_NODE_SSH (tests) replaces `ssh root@<host>`: `cmd <host> <command…>`.

PULSE_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../pulse" && pwd)"

_pulse_ssh() {  # _pulse_ssh <host> <command…>  (stdin passes through)
    local host="$1"; shift
    if [[ -n "${PULSE_NODE_SSH:-}" ]]; then ${PULSE_NODE_SSH} "${host}" "$@"; return; fi
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${host}.mgmt.internal" "$@"
}

_pulse_ipv4() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }

pulse_config_json() {
    local host="$1" cfgdir="${PBS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"
    local remotes fw ms
    # Addresses, not names: the firewall is the site's DNS, and a pulse that
    # needs it to resolve the firewall cannot report the firewall.
    fw="$(_pulse_ipv4 firewall.mgmt.internal)"
    ms="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
    remotes="$(_pulse_ssh "${host}" "proxmox-backup-manager remote list --output-format json" </dev/null 2>/dev/null)"
    jq -e 'type == "array"' <<< "${remotes}" >/dev/null 2>&1 || remotes="[]"
    local contacts="{}" f n
    for f in "${cfgdir}"/pull-*.json; do
        [[ -f "${f}" ]] || continue
        n="$(basename "${f}" .json)"; n="${n#pull-}"
        contacts="$(jq -c --arg n "${n}" --arg c "$(jq -r '.contact // ""' "${f}")" '. + {($n): $c}' <<< "${contacts}")"
    done
    local pulled="[]"
    for f in "${cfgdir}"/remote-*.json; do
        [[ -f "${f}" ]] || continue
        pulled="$(jq -c --slurpfile r "${f}" '. + [ $r[0] | select((.authId // "") != "")
                    | {name, authId} + (if (.contact // "") != "" then {contact} else {} end) ]' <<< "${pulled}")"
    done
    jq -n \
        --arg site "$(jq -r '.name // ""' "${cfgdir}/site.json" 2>/dev/null)" \
        --arg email "$(jq -r '.email // ""' "${cfgdir}/site.json" 2>/dev/null)" \
        --arg fw "${fw}" --arg ms "${ms}" \
        --argjson remotes "${remotes}" --argjson contacts "${contacts}" --argjson pulled "${pulled}" '
        {site: $site, email: $email, uplink: "deb.debian.org",
         firewall: $fw, mothership: $ms, pbs: "localhost",
         buddies: [ $remotes[] | .name as $n | select($contacts | has($n))
                    | {name, host, port: (.port // 8007),
                       fingerprint: (.fingerprint // ""), contact: $contacts[$n]} ],
         pulledBy: $pulled}
        | with_entries(select(.value != ""))'
}

pulse_ensure() {
    local host="$1" json
    [[ -n "${host}" ]] || { warn "  pulse: no backup node recorded — not installed"; return 1; }
    json="$(pulse_config_json "${host}")" || { warn "  pulse: could not build its config"; return 1; }
    _pulse_ssh "${host}" "install -d -m 0755 /etc/tappaas /var/lib/tappaas/pulse && cat > /usr/local/sbin/tappaas-pulse && chmod 0755 /usr/local/sbin/tappaas-pulse" \
        < "${PULSE_SRC_DIR}/pulse.sh" || { warn "  pulse: could not install the script on ${host}"; return 1; }
    _pulse_ssh "${host}" "cat > /etc/tappaas/pulse.json && chmod 0644 /etc/tappaas/pulse.json" <<< "${json}" \
        || { warn "  pulse: could not write ${host}:/etc/tappaas/pulse.json"; return 1; }
    _pulse_ssh "${host}" 'cat > /etc/systemd/system/tappaas-pulse.service <<EOF
[Unit]
Description=TAPPaaS pulse: is the backup buddy alive, and is this site? (ADR-031)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tappaas-pulse
EOF
cat > /etc/systemd/system/tappaas-pulse.timer <<EOF
[Unit]
Description=TAPPaaS pulse every 5 minutes (ADR-031)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now tappaas-pulse.timer >/dev/null 2>&1' </dev/null \
        || { warn "  pulse: could not enable its timer on ${host}"; return 1; }
    info "  ${GN}✓${CL} pulse on ${host}: $(jq -r '([.buddies[]?.name] | if length == 0 then "no buddy we pull" else "watching buddy " + join(", ") end)
        + ([.pulledBy[]?.name] | if length == 0 then "" else "; the pull by " + join(", ") end)' <<< "${json}"), and this site"
}
