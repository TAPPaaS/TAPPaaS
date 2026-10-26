#!/usr/bin/env bash
# pbs-pulse.sh — put the pulse on the backup node (ADR-031 D1).
#
# The pulse watches this site's backup buddies from outside their site, and this
# site from its own backup node; the script itself is ../pulse/pulse.sh. This
# library writes its config and installs it, from every backup update:
#
#   pulse_config_json <pbs-host>   the pulse.json for this site, on stdout
#   pulse_ensure <pbs-host> [json] install script, config and timer on that Host
#                                  (json: another config, e.g. a satellite's)
#   pulse_satellite_json           a satellite's pulse.json: the home site's tunnel
#
# The config is derived, never edited on the node: site.json gives the site and
# the operator's address; the PBS's own remotes give each buddy we pull from
# (host, port, certificate fingerprint); config/pull-<name>.json gives the
# buddy's contact (`backup-manager peer add … --contact`); config/remote-<name>.json
# gives each buddy that pulls us (its login, for when it last pulled; its contact).
#
# The backup node is a cluster node (reached as <node>.mgmt.internal) or a
# `debianhost` machine (reached by its recorded `address`). A machine has no mail
# system of its own, so it gets postfix as the nodes have it: loopback only,
# delivering directly (ADR-031 D4) — it then needs outbound SMTP, as the nodes do.
#
# PULSE_NODE_SSH (tests) replaces `ssh root@<host>`: `cmd <host> <command…>`.

PULSE_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../pulse" && pwd)"

# Where the backup node is reached: a name with a dot as is, a machine by its
# recorded address, a cluster node (its record is a pvehost instance) as
# <node>.mgmt.internal.
pulse_host_addr() {
    local host="$1" cfgdir="${PBS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}" addr
    [[ "${host}" == *.* ]] && { printf '%s\n' "${host}"; return 0; }
    addr="$(jq -r 'if (.kind // "") == "machine" then (.address // "") else "" end' "${cfgdir}/${host}.json" 2>/dev/null)"
    if [[ -n "${addr}" ]] && ! jq -e '(.moduleSource // "") | test("(^|/)pvehost/*$")' "${cfgdir}/${host}.json" >/dev/null 2>&1; then
        printf '%s\n' "${addr}"
    else
        printf '%s\n' "${host}.mgmt.internal"
    fi
}

_pulse_ssh() {  # _pulse_ssh <host> <command…>  (stdin passes through)
    local host="$1"; shift
    if [[ -n "${PULSE_NODE_SSH:-}" ]]; then ${PULSE_NODE_SSH} "${host}" "$@"; return; fi
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@$(pulse_host_addr "${host}")" "$@"
}

# What the pulse needs on the backup node: jq and openssl, and a mail system. A
# Proxmox node has them all; a Debian machine gets what it lacks, postfix set up
# as the nodes have it (loopback only, direct delivery).
pulse_deps_ensure() {
    local host="$1"
    _pulse_ssh "${host}" 'bash -s' <<'REMOTE'
set -e
need=""
command -v jq >/dev/null || need="${need} jq"
command -v openssl >/dev/null || need="${need} openssl"
[ -x /usr/sbin/sendmail ] || need="${need} postfix"
[ -n "${need}" ] || exit 0
export DEBIAN_FRONTEND=noninteractive
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname -f 2>/dev/null || hostname)" | debconf-set-selections
apt-get update -qq >/dev/null
# shellcheck disable=SC2086
apt-get install -y -qq ${need} >/dev/null
if [ -x /usr/sbin/postconf ] && echo "${need}" | grep -qw postfix; then
    postconf -e inet_interfaces=loopback-only mydestination='$myhostname, localhost'
    systemctl restart postfix
fi
echo "installed${need}"
REMOTE
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

# A satellite watches its home site from outside (ADR-031 P3): the home firewall
# keeps the infra tunnel's handshake fresh, and a stale one means the site is gone.
pulse_satellite_json() {
    local cfgdir="${PBS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"
    jq -n --arg site "$(jq -r '.name // ""' "${cfgdir}/site.json" 2>/dev/null)" \
          --arg email "$(jq -r '.email // ""' "${cfgdir}/site.json" 2>/dev/null)" '
        {site: $site, email: $email, uplink: "deb.debian.org",
         tunnels: [ {name: "home", iface: "wg-infra"} ]} | with_entries(select(.value != ""))'
}

pulse_ensure() {
    local host="$1" json="${2:-}"
    [[ -n "${host}" ]] || { warn "  pulse: no host given — not installed"; return 1; }
    if [[ -z "${json}" ]]; then
        json="$(pulse_config_json "${host}")" || { warn "  pulse: could not build its config"; return 1; }
    fi
    local _m
    _m="$(pulse_deps_ensure "${host}" 2>&1)" || { warn "  pulse: could not install what it needs on ${host}: ${_m}"; return 1; }
    [[ -n "${_m}" ]] && info "  ${host}: ${_m}"
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
    debug "  pulse on ${host}: $(jq -r 'if (.tunnels | length) > 0 then "watching the home site through " + ([.tunnels[].iface] | join(", "))
        else ([.buddies[]?.name] | if length == 0 then "no buddy we pull" else "watching buddy " + join(", ") end)
            + ([.pulledBy[]?.name] | if length == 0 then "" else "; the pull by " + join(", ") end) + ", and this site" end' <<< "${json}")"
}
