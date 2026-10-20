#!/usr/bin/env bash
# lib/provision.sh — provisioning helpers for the satellite module (ADR-010).
# Renders what goes onto the machine — the Debian config files — from the
# instance's config and the derived SAT_* defaults below. (A NixOS satellite was
# an option until #712 retired it; ADR-010 §5.1.)
# Validated live 2026-07-01. Sourced by lib/satellite-lib.sh. shellcheck shell=bash

SATELLITE_SRC="${SATELLITE_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SATELLITE_DEBIAN_SRC="${SATELLITE_DEBIAN_SRC:-${SATELLITE_SRC}/debian}"

# --- DERIVED DEFAULTS (single source of truth) --------------------------------
# NOT exposed in satellite.json (ADR-010 "sensible defaults"). Operators only pick
# roles/provider/host/S3; everything below is defaulted here. Env-overridable for
# advanced/multi-satellite use (e.g. a second satellite needs its own /31).
: "${SAT_SAT_ADDR:=10.255.0.0}"   # /31 satellite end
: "${SAT_HOME_ADDR:=10.255.0.1}"  # /31 home (OPNsense) end
: "${SAT_WGPORT:=51820}"          # infra tunnel UDP listener
: "${SAT_ADMIN_WGPORT:=51821}"    # admin-vpn relay + OPNsense admin-WG listen
: "${SAT_KEEPALIVE:=25}"          # PersistentKeepalive (home side; keeps CGNAT pinhole open)
: "${SAT_REBOOT_TIME:=03:30}"     # Debian (Option 3) unattended-upgrades auto-reboot window
: "${SAT_PROXY_PROTOCOL:=false}"  # reverse-proxy: PROXY-protocol v2 (gate on until Caddy expects it)
: "${SAT_SSH_TIMEOUT:=12h}"       # sshPort: nginx drops a relayed session idle this long
# The pull vault's settings (the `backup` role, set by --lockdown, ADR-010 §8.4.4)
# live in `vault` — `backup` is the module's backup POLICY, which module add
# writes on every module. A config from before the move kept them in `backup`.
SAT_VAULT='(.vault // .backup // {})'
# backup role (P6) — the satellite PULLS from home. Datastore + retention defaults.
: "${SAT_DATASTORE_NAME:=tappaas-offsite}"          # local PBS datastore (pull destination)
: "${SAT_DATASTORE_PATH:=/srv/pbs/tappaas-offsite}" # on a ZFS dataset for a real vault
: "${SAT_REMOTE_NAME:=home}"                        # PBS 'remote' pointing at home PBS
: "${SAT_HOME_PBS_PORT:=8007}"
: "${SAT_SYNC_SCHEDULE:=daily}"
: "${SAT_REMOVE_VANISHED:=false}"                   # home deleting a snapshot must NOT delete our copy
: "${SAT_PRUNE_SCHEDULE:=daily}"
: "${SAT_PRUNE_KEEP:=--keep-daily 7 --keep-weekly 4 --keep-monthly 6}"

# --- sshPort: SSH to the mothership through the satellite (ADR-010 §4.4.2) ----
# Off unless the config sets `sshPort`; then only the sources in `sshAllow` are
# admitted. Absent, null or 0 is off.

# sat_cfg_ssh_port <config-json> — the port, or nothing when it is off.
sat_cfg_ssh_port() {
    jq -r 'if (.sshPort // 0) == 0 then empty else .sshPort end' "$1" 2>/dev/null
}

# sat_check_ssh_config <config-json> — rc 0 when sshPort/sshAllow are usable;
# else prints why on stderr and returns 1. Used by check-config.sh (module add,
# modify --set) and by install/update/test on the deployed config.
sat_check_ssh_config() {
    local cfg="$1" port bad
    port="$(jq -r '.sshPort // 0' "${cfg}")"
    [[ "${port}" == 0 ]] && return 0
    if ! jq -e '.sshPort | type == "number" and . == floor and . >= 1 and . <= 65535' "${cfg}" >/dev/null; then
        echo "satellite: sshPort must be a port number (1-65535), not '${port}'" >&2; return 1
    fi
    case " 22 80 443 ${SAT_WGPORT} ${SAT_ADMIN_WGPORT} ${SAT_HOME_PBS_PORT} " in
        *" ${port} "*) echo "satellite: sshPort ${port} is taken on the satellite (22 is its own sshd; 80, 443, ${SAT_WGPORT}, ${SAT_ADMIN_WGPORT} and ${SAT_HOME_PBS_PORT} its relays) — pick another, e.g. 2222" >&2; return 1 ;;
    esac
    [[ "$(jq -r '.management // "managed"' "${cfg}")" == managed ]] \
        || { echo "satellite: sshPort on a locked-down satellite is refused — a vault opens no path to the mothership" >&2; return 1; }
    if ! jq -e '(.sshAllow | type) == "array" and (.sshAllow | length) > 0' "${cfg}" >/dev/null 2>&1; then
        echo "satellite: sshPort needs sshAllow — the addresses or networks admitted, e.g. --set 'sshAllow=[\"198.51.100.7\"]'; it is never open to everyone" >&2
        return 1
    fi
    bad="$(jq -r '.sshAllow[] | select(type != "string"
              or (test("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([1-9]|[12][0-9]|3[0-2]))?$") | not)
              or (split("/")[0] | split(".") | map(tonumber) | any(. > 255))
              or (split("/") as $p | ($p[1] // "32" | tonumber) as $n
                  | ($p[0] | split(".") | map(tonumber) | .[0]*16777216 + .[1]*65536 + .[2]*256 + .[3])
                    % pow(2; 32 - $n) != 0))' "${cfg}" 2>/dev/null)" || bad="(unreadable)"
    if [[ -n "${bad}" ]]; then
        echo "satellite: sshAllow takes IPv4 addresses or networks (a.b.c.d, or a.b.c.0/n with no host bits, n 1-32), not: $(paste -sd' ' - <<< "${bad}")" >&2
        return 1
    fi
    return 0
}

# Read back the satellite's wg-infra PUBLIC key over SSH, with retries for the
# post-install reboot. Post-reformat the satellite trusts ONLY the OPERATOR key
# (the provisioning key is gone — §7.3), and cicd must NOT hold the operator key.
# So this uses the ambient SSH agent (run `module-manager module add satellite` over an
# agent-forwarded session, `ssh -A`, so your operator key is reachable). An
# explicit key file can be passed as $2 when available. Args: <root@ip> [key]
sat_read_pubkey() {
    local target="$1" key="${2:-}" pub ident=()
    [[ -n "${key}" ]] && ident=(-i "${key}" -o IdentitiesOnly=yes)
    for _ in $(seq 1 30); do
        pub="$(ssh "${ident[@]}" -o StrictHostKeyChecking=accept-new \
                 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
                 "${target}" 'wg show wg-infra public-key' 2>/dev/null)" || true
        [[ -n "${pub}" ]] && { echo "${pub}"; return 0; }
        sleep 10
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# DEBIAN SATELLITE (ADR-010 Option 3) — how every satellite is provisioned.
# Same SAT_* derived values, same OPNsense home side; renders plain Debian config
# files, and provisions an already-booted
# Debian host over SSH. See satellite/debian/README.md.
# ═══════════════════════════════════════════════════════════════════════════

# Render the per-role Debian config files from the operator JSON + derived
# SAT_* defaults + the home OPNsense pubkey, into <out-dir>. Only the files a
# role needs are written (provision-debian.sh is role-gated to match).
# SAT_PBS_CLIENTS (a CIDR, set while the satellite is the Site's PBS Host —
# ADR-010 §8.4.3): the nodes that push to its PBS, admitted through the tunnel —
# into the AllowedIPs, and to :8007 on the tunnel interface only.
# MANAGEMENT in roles.env says who patches the machine (ADR-010 §8.4.2/§8.4.4):
# `managed` — the sweep does, so the mothership's key (cicd_key.pub, when given)
# is authorized and unattended-upgrades stays off; `unmanaged` — it patches
# itself, and that key is removed.
# Args: <config-json> <home-pubkey> <out-dir> [cicd-pubkey-file]
sat_gen_debian_configs() {
    local cfg="$1" home_pub="$2" out="$3" cicd_pub="${4:-}"
    local roles mgmt pp="" ssh_port ssh_allow
    roles="$(jq -r '(.roles // []) | join(" ")' "${cfg}")"
    mgmt="$(jq -r '.management // "managed"' "${cfg}")"
    ssh_port="$(sat_cfg_ssh_port "${cfg}")"
    ssh_allow="$(jq -r '(.sshAllow // [])[]' "${cfg}")"
    [[ "$(jq -r '(.host.operatorSshKeys // []) | length' "${cfg}")" -gt 0 ]] \
        || { echo "ERROR: ${cfg} has no host.operatorSshKeys (operator out-of-band key required)" >&2; return 1; }
    _sat_has_role() { [[ " ${roles} " == *" $1 "* ]]; }
    mkdir -p "${out}"

    printf 'ROLES="%s"\nMANAGEMENT="%s"\nSSH_PORT="%s"\n' "${roles}" "${mgmt}" "${ssh_port}" > "${out}/roles.env"
    if [[ -n "${cicd_pub}" ]]; then cp "${cicd_pub}" "${out}/cicd_key.pub"; fi

    jq -r '(.host.operatorSshKeys // [])[]' "${cfg}" > "${out}/operator_authorized_keys"

    # WireGuard infra tunnel (always). Private key stays in a 0600 keyfile on-host
    # (injected via PostUp) — never in this rendered config. Home dials in, so no
    # Endpoint here; the [Peer] is added once the OPNsense pubkey is known.
    {
        echo "# GENERATED by the satellite module — WireGuard infra tunnel (ADR-010)."
        echo "# No private key here: injected via PostUp from /etc/wireguard/wg-infra.key (0600)."
        echo "[Interface]"
        echo "Address = ${SAT_SAT_ADDR}/31"
        echo "ListenPort = ${SAT_WGPORT}"
        echo "PostUp = wg set %i private-key /etc/wireguard/wg-infra.key"
        if [[ -n "${home_pub}" ]]; then
            # AllowedIPs = what the satellite routes INTO the tunnel. Base: the OPNsense
            # /31 end. The backup role adds the home PBS host so the satellite can PULL
            # from it over the tunnel (edge -> home PBS:8007 is allowed on OPNsense).
            local allowed="${SAT_HOME_ADDR}/32" pbs_host
            if _sat_has_role backup; then
                pbs_host="$(jq -r "${SAT_VAULT}.pull.homePbsHost // empty" "${cfg}")"
                [[ -n "${pbs_host}" ]] && allowed="${allowed}, ${pbs_host}/32"
            fi
            [[ -n "${SAT_PBS_CLIENTS:-}" ]] && allowed="${allowed}, ${SAT_PBS_CLIENTS}"
            echo ""
            echo "[Peer]"
            echo "PublicKey = ${home_pub}"
            echo "AllowedIPs = ${allowed}"
        fi
    } > "${out}/wg-infra.conf"

    # Host firewall (+ admin-vpn NAT relay) — nftables. Role-gated allows.
    {
        echo "#!/usr/sbin/nft -f"
        echo "# GENERATED by the satellite module — host firewall$(_sat_has_role admin-vpn && echo ' + admin-vpn NAT relay')."
        echo "flush ruleset"
        echo ""
        echo "table inet filter {"
        echo "  chain input {"
        echo "    type filter hook input priority filter; policy drop;"
        echo "    ct state established,related accept"
        echo "    ct state invalid drop"
        echo "    iif lo accept"
        echo "    ip protocol icmp accept"
        echo "    ip6 nexthdr ipv6-icmp accept"
        echo "    tcp dport 22 accept        # operator SSH (out-of-band)"
        echo "    udp dport ${SAT_WGPORT} accept       # infra tunnel"
        _sat_has_role reverse-proxy && echo "    tcp dport { 80, 443 } accept  # reverse-proxy passthrough"
        _sat_has_role admin-vpn     && echo "    udp dport ${SAT_ADMIN_WGPORT} accept       # admin-vpn relay"
        [[ -n "${ssh_port}" ]] && echo "    ip saddr { $(paste -sd, - <<< "${ssh_allow}" | sed 's/,/, /g') } tcp dport ${ssh_port} accept  # sshPort: the mothership's SSH, allow-listed sources"
        [[ -n "${SAT_PBS_CLIENTS:-}" ]] && echo "    iifname \"wg-infra\" ip saddr ${SAT_PBS_CLIENTS} tcp dport ${SAT_HOME_PBS_PORT} accept  # the Site's PBS: its nodes push here (ADR-010 §8.4.3)"
        echo "  }"
        echo "  chain forward {"
        echo "    type filter hook forward priority filter; policy drop;"
        echo "    ct state established,related accept"
        _sat_has_role admin-vpn && echo "    ip daddr ${SAT_HOME_ADDR} udp dport ${SAT_ADMIN_WGPORT} accept  # admin-vpn: relay -> OPNsense over tunnel"
        echo "  }"
        echo "  chain output { type filter hook output priority filter; policy accept; }"
        echo "}"
        if _sat_has_role admin-vpn; then
            echo ""
            echo "# admin-vpn BLIND UDP relay — DNAT :${SAT_ADMIN_WGPORT} to the OPNsense admin-WG"
            echo "# listener over the infra tunnel; the satellite holds no admin keys (ADR-010 §6)."
            echo "table ip adminvpn {"
            echo "  chain prerouting {"
            echo "    type nat hook prerouting priority dstnat; policy accept;"
            echo "    udp dport ${SAT_ADMIN_WGPORT} dnat to ${SAT_HOME_ADDR}:${SAT_ADMIN_WGPORT}"
            echo "  }"
            echo "  chain postrouting {"
            echo "    type nat hook postrouting priority srcnat; policy accept;"
            echo "    ip daddr ${SAT_HOME_ADDR} udp dport ${SAT_ADMIN_WGPORT} masquerade"
            echo "  }"
            echo "}"
        fi
    } > "${out}/nftables.conf"

    # nginx L4 stream passthrough (ADR-010 §2/§5.8): :443/:80 for reverse-proxy,
    # :sshPort to the mothership's SSH. nginx sees the real client, so the
    # sshPort allow-list is enforced here as well as in nftables.
    if _sat_has_role reverse-proxy || [[ -n "${ssh_port}" ]]; then
        [[ "${SAT_PROXY_PROTOCOL}" == "true" ]] && pp=$'\n      proxy_protocol on;'
        {
        cat <<EOF
# GENERATED by the satellite module — nginx L4 stream passthrough (ADR-010 §2).
# The satellite NEVER terminates TLS: all :443 -> Caddy-on-OPNsense over the tunnel;
# :80 too (Caddy issues the redirect). Single-purpose config (stream only).
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 1024; }
stream {
EOF
        if _sat_has_role reverse-proxy; then
            cat <<EOF
    server {
      listen 443;
      proxy_pass ${SAT_HOME_ADDR}:443;${pp}
    }
    server {
      listen 80;
      proxy_pass ${SAT_HOME_ADDR}:80;${pp}
    }
EOF
        fi
        if [[ -n "${ssh_port}" ]]; then
            local a
            echo "    # sshPort: blind TCP passthrough to the mothership's sshd (OPNsense forwards"
            echo "    # ${SAT_HOME_ADDR}:${ssh_port} to it); SSH authenticates end to end."
            echo "    server {"
            echo "      listen ${ssh_port};"
            while IFS= read -r a; do [[ -n "${a}" ]] && echo "      allow ${a};"; done <<< "${ssh_allow}"
            echo "      deny all;"
            echo "      proxy_timeout ${SAT_SSH_TIMEOUT};"
            echo "      proxy_pass ${SAT_HOME_ADDR}:${ssh_port};"
            echo "    }"
        fi
        echo "}"
        } > "${out}/nginx-stream.conf"
    fi

    # admin-vpn — enable IP forwarding for the relay.
    if _sat_has_role admin-vpn; then
        printf 'net.ipv4.ip_forward = 1\n' > "${out}/99-tappaas-ipforward.conf"
    fi

    # self-patching — unattended-upgrades (always). Security origin + reboot window.
    cat > "${out}/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat > "${out}/52tappaas-unattended-upgrades" <<EOF
// GENERATED by the satellite module — TAPPaaS unattended-upgrades policy (ADR-010).
// Security-origin auto-patching + a scheduled auto-reboot window. For a vault this
// is deliberately conservative (security updates only, not a full dist-upgrade).
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${SAT_REBOOT_TIME}";
EOF
}

# Assemble a Debian deploy dir: the rendered configs + the on-host installer.
# Args: <configs-dir> ; echoes the deploy dir (== configs-dir, with the script added).
sat_assemble_debian_deploy() {
    local cfgdir="$1" f
    for f in provision-debian.sh set-management.sh; do
        cp "${SATELLITE_DEBIAN_SRC}/${f}" "${cfgdir}/${f}"
        chmod +x "${cfgdir}/${f}"
    done
    echo "${cfgdir}"
}

# Ship a deploy dir to the satellite and run the given on-host scripts from it,
# in order, in one session. Args: <deploy-dir> <root@ip> <key-or-""> <script>...
sat_deploy_run() {
    local d="$1" target="$2" key="$3" ident=() cmd="cd /root/tappaas-satellite" s
    shift 3
    [[ -n "${key}" ]] && ident=(-i "${key}" -o IdentitiesOnly=yes)
    local sshopt=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    ssh "${ident[@]}" "${sshopt[@]}" "${target}" 'rm -rf /root/tappaas-satellite && mkdir -p /root/tappaas-satellite' \
        || { echo "ERROR: cannot reach ${target} over SSH" >&2; return 1; }
    scp "${ident[@]}" "${sshopt[@]}" -r "${d}/." "${target}:/root/tappaas-satellite/" >/dev/null \
        || { echo "ERROR: scp of the deploy dir to ${target} failed" >&2; return 1; }
    for s in "$@"; do cmd+=" && bash ./${s}"; done
    ssh "${ident[@]}" "${sshopt[@]}" "${target}" "${cmd}"
}

# Provision an already-booted Debian host: ship the deploy dir and run the
# installer over SSH. No reformat. Uses the operator's key via
# the ambient agent (run install over `ssh -A`); an explicit key may be passed.
# set-management.sh runs last: whether the mothership may log in is settled only
# once the rest is in place (ADR-010 §8.4). Args: <deploy-dir> <root@ip> [key]
sat_provision_debian() {
    sat_deploy_run "$1" "$2" "${3:-}" provision-debian.sh set-management.sh
}

# Render the backup-role config (backup.env) from the satellite JSON + SAT_*
# defaults, into <out-dir>. If a home-PBS read-only token is available (env
# TAPPAAS_SAT_PBS_TOKEN, or a file at $TAPPAAS_SAT_PBS_TOKEN_FILE), write it as the
# 0600 pbs-remote-token so provision-backup.sh can wire the pull; otherwise leave
# it out (provision-backup.sh sets up PBS+datastore and prints the token runbook).
# Args: <config-json> <out-dir>
sat_gen_backup_config() {
    local cfg="$1" out="$2"
    mkdir -p "${out}"
    local ds_name ds_path pbs_host pbs_store authid fp sched homen
    local v="${SAT_VAULT}"
    ds_name="$(jq -r --arg d "${SAT_DATASTORE_NAME}" "${v}.datastore.name // \$d" "${cfg}")"
    ds_path="$(jq -r --arg d "${SAT_DATASTORE_PATH}" "${v}.datastore.path // \$d" "${cfg}")"
    pbs_host="$(jq -r "${v}.pull.homePbsHost // empty" "${cfg}")"
    pbs_store="$(jq -r "${v}.pull.homeDatastore // \"tappaas\"" "${cfg}")"
    authid="$(jq -r "${v}.pull.authId // \"satellite@pbs!pull\"" "${cfg}")"
    fp="$(jq -r "${v}.pull.fingerprint // empty" "${cfg}")"
    sched="$(jq -r --arg d "${SAT_SYNC_SCHEDULE}" "${v}.pull.schedule // \$d" "${cfg}")"
    homen="$(jq -r "${v}.pull.homeNs // empty" "${cfg}")"
    cat > "${out}/backup.env" <<EOF
# GENERATED by the satellite module — satellite backup role (ADR-010 P6, pull model).
DATASTORE_NAME="${ds_name}"
DATASTORE_PATH="${ds_path}"
HOME_PBS_HOST="${pbs_host}"
HOME_PBS_PORT="${SAT_HOME_PBS_PORT}"
HOME_PBS_DATASTORE="${pbs_store}"
HOME_PBS_NS="${homen}"
REMOTE_NAME="${SAT_REMOTE_NAME}"
REMOTE_AUTHID="${authid}"
REMOTE_FINGERPRINT="${fp}"
SYNC_JOB_ID="offsite-${SAT_REMOTE_NAME}"
SYNC_NS="remote/${SAT_REMOTE_NAME}"
SYNC_SCHEDULE="${sched}"
REMOVE_VANISHED="${SAT_REMOVE_VANISHED}"
PRUNE_SCHEDULE="${SAT_PRUNE_SCHEDULE}"
PRUNE_KEEP="${SAT_PRUNE_KEEP}"
EOF
    # Home read-only token SECRET (never committed; out-of-band). Optional.
    local tok=""
    [[ -n "${TAPPAAS_SAT_PBS_TOKEN:-}" ]] && tok="${TAPPAAS_SAT_PBS_TOKEN}"
    [[ -z "${tok}" && -n "${TAPPAAS_SAT_PBS_TOKEN_FILE:-}" && -s "${TAPPAAS_SAT_PBS_TOKEN_FILE}" ]] \
        && tok="$(< "${TAPPAAS_SAT_PBS_TOKEN_FILE}")"
    if [[ -n "${tok}" ]]; then
        ( umask 077; printf '%s' "${tok}" > "${out}/pbs-remote-token" )
    fi
}

# Ship provision-backup.sh into an already-assembled deploy dir. Args: <deploy-dir>
sat_assemble_backup_deploy() {
    cp "${SATELLITE_DEBIAN_SRC}/provision-backup.sh" "$1/provision-backup.sh"
    chmod +x "$1/provision-backup.sh"
}

# Run the backup-role installer on the satellite. Args: <deploy-dir> <root@ip> [key]
sat_provision_backup() {
    local d="$1" target="$2" key="${3:-}" ident=()
    [[ -n "${key}" ]] && ident=(-i "${key}" -o IdentitiesOnly=yes)
    local sshopt=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    scp "${ident[@]}" "${sshopt[@]}" -r "${d}/." "${target}:/root/tappaas-satellite/" >/dev/null \
        || { echo "ERROR: scp backup deploy to ${target} failed" >&2; return 1; }
    ssh "${ident[@]}" "${sshopt[@]}" "${target}" \
        'cd /root/tappaas-satellite && bash ./provision-backup.sh'
}

# Ensure ONE least-privilege edge(/31) -> <dest>:<port> pass rule on the OPNsense
# WireGuard interface (idempotent by description). The satellite is a semi-trusted
# relay: it gets ROLE-GATED reach to exactly these endpoints and NOTHING else
# (ADR-010 §4.3). Does NOT apply — batch, then call the apply once. Validated live
# 2026-07-03: without these the satellite's tunnelled traffic is dropped by OPNsense.
# Args: <description> <TCP|UDP> <dest-net> <dest-port>
sat_ensure_edge_rule() {
    local desc="$1" proto="$2" dest="$3" port="$4"
    command -v _ow_api >/dev/null 2>&1 || { echo "opnsense-wg lib not loaded" >&2; return 1; }
    local exist
    exist="$(_ow_api /api/firewall/filter/searchRule | jq -r --arg d "${desc}" '.rows[]? | select(.description==$d) | .uuid' | head -1)"
    [[ -n "${exist}" ]] && { echo "exists"; return 0; }
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"rule\":{\"enabled\":\"1\",\"action\":\"pass\",\"interface\":\"wireguard\",\"direction\":\"in\",\"ipprotocol\":\"inet\",\"protocol\":\"${proto}\",\"source_net\":\"${SAT_SAT_ADDR}/31\",\"destination_net\":\"${dest}\",\"destination_port\":\"${port}\",\"description\":\"${desc}\"}}" \
        /api/firewall/filter/addRule | jq -r '.result // empty'
}

# Ensure the role-gated edge firewall rules for the active roles, then apply once.
# reverse-proxy: edge -> Caddy :80/:443. admin-vpn: edge -> OPNsense admin-WG (udp).
# (backup's edge -> home-PBS:8007 is handled by sat_ensure_edge_pbs_rule, which
# needs the operator-supplied home PBS host.) Args: <roles-csv>
sat_ensure_edge_rules() {
    local roles="$1"
    if [[ ",${roles}," == *,reverse-proxy,* ]]; then
        sat_ensure_edge_rule "tappaas-satellite edge->caddy 80"  TCP "${SAT_HOME_ADDR}" 80  >/dev/null
        sat_ensure_edge_rule "tappaas-satellite edge->caddy 443" TCP "${SAT_HOME_ADDR}" 443 >/dev/null
    fi
    if [[ ",${roles}," == *,admin-vpn,* ]]; then
        sat_ensure_edge_rule "tappaas-satellite edge->admin-wg" UDP "${SAT_HOME_ADDR}" "${SAT_ADMIN_WGPORT}" >/dev/null
    fi
    _ow_api -X POST /api/firewall/filter/apply >/dev/null
}

# OPNsense least-privilege rule for the backup role: edge (/31) -> home PBS:8007,
# so the satellite can PULL over the tunnel — and NOTHING else in the cluster
# becomes reachable (ADR-010 §3.3). Idempotent. Args: <home-pbs-host>
sat_ensure_edge_pbs_rule() {
    local pbs_host="$1"
    [[ -n "${pbs_host}" ]] || { echo "no home PBS host — skipped" >&2; return 0; }
    local r; r="$(sat_ensure_edge_rule "tappaas-satellite edge->home-pbs" TCP "${pbs_host}" "${SAT_HOME_PBS_PORT}")"
    [[ "${r}" == "exists" ]] || _ow_api -X POST /api/firewall/filter/apply >/dev/null
    echo "${r}"
}
