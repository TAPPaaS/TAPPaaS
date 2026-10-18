# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Woodpecker CI
# ============================================================================
# Self-contained NixOS configuration, applied by update-os.sh on install and
# every update (built on the mothership against the release's nixpkgs).
#
# Woodpecker (Apache-2.0) runs the pipelines of the site's Forgejo
# repositories: Forgejo tells it about a push (a webhook), it runs the
# repository's .woodpecker/*.yaml in containers and reports back.
#
#   - the server (UI, API, webhooks) on :8000, behind the firewall's Caddy; its
#     agents connect on 127.0.0.1:9000 only;
#   - sign-in with Forgejo (forgejo:oauth), which signs in with Authentik:
#     there are no Woodpecker passwords;
#   - one agent on this VM, running pipeline steps as Docker containers. No
#     plugin may run privileged;
#   - pipeline containers reach the internet, the site's DNS and Caddy (for the
#     clone from Forgejo) — never another address on the site's networks
#     (woodpecker-egress), so a pipeline cannot reach the site's other services.
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  moduleCfg = if builtins.pathExists ./woodpecker.json
              then builtins.fromJSON (builtins.readFile ./woodpecker.json)
              else {};
  vmname = moduleCfg.vmname or "woodpecker";
  zone0 = moduleCfg.zone0 or "";
  internalHost = "${vmname}${lib.optionalString (zone0 != "") ".${zone0}"}.internal";
  proxyDomain = moduleCfg.proxyDomain or "";
  published = proxyDomain != "" && (moduleCfg.proxyPublished or true);
  publicUrl = if published then "https://${proxyDomain}" else "http://${internalHost}:8000";
  admins = moduleCfg.woodpeckerAdmins or [];

  # The server's and the agent's environments: the shared agent secret (made
  # here once) and the Forgejo client forgejo:oauth wrote.
  envScript = pkgs.writeShellScript "woodpecker-env" ''
    set -euo pipefail
    install -d -m 0700 /var/lib/woodpecker-secrets /run/woodpecker
    s=/var/lib/woodpecker-secrets/agent-secret
    [ -s "$s" ] || (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 32 > "$s")
    readvar() { [ -r "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | tail -1; }
    o=/etc/secrets/forgejo-oauth.env
    umask 077
    {
      echo "WOODPECKER_AGENT_SECRET=$(cat "$s")"
      echo "WOODPECKER_FORGEJO_URL=$(readvar "$o" FORGEJO_URL)"
      echo "WOODPECKER_FORGEJO_CLIENT=$(readvar "$o" FORGEJO_CLIENT_ID)"
      echo "WOODPECKER_FORGEJO_SECRET=$(readvar "$o" FORGEJO_CLIENT_SECRET)"
    } > /run/woodpecker/server.env.new
    mv /run/woodpecker/server.env.new /run/woodpecker/server.env
    echo "WOODPECKER_AGENT_SECRET=$(cat "$s")" > /run/woodpecker/agent.env
  '';

  # What a pipeline container may reach beyond the internet: the site's
  # resolvers, and Forgejo's address (Caddy, or Forgejo itself when it is not
  # published) for the clone. Everything else on a private network is refused.
  # Docker keeps the DOCKER-USER chain for rules of the host's own.
  egressScript = pkgs.writeShellScript "woodpecker-egress" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.iptables pkgs.iproute2 pkgs.gawk pkgs.gnused pkgs.getent pkgs.coreutils ]}
    up="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    [ -n "$up" ] || { echo "woodpecker-egress: no default route yet"; exit 1; }
    # Before forgejo:oauth has run there is no Forgejo address yet: fence
    # everything private, and woodpecker-reconfigure re-runs this once there is.
    url=""
    if [ -r /etc/secrets/forgejo-oauth.env ]; then
      url="$(sed -n 's/^FORGEJO_URL=//p' /etc/secrets/forgejo-oauth.env | tail -1)"
    fi
    hostport="''${url#*://}"; hostport="''${hostport%%/*}"
    fhost="''${hostport%%:*}"
    case "$url" in https://*) fport=443 ;; *) fport=80 ;; esac
    [ "$hostport" != "$fhost" ] && fport="''${hostport##*:}"
    iptables -N DOCKER-USER 2>/dev/null || true
    iptables -F DOCKER-USER
    iptables -A DOCKER-USER -o "$up" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    for ns in $(awk '/^nameserver/ && $2 !~ /:/ {print $2}' /etc/resolv.conf); do
      iptables -A DOCKER-USER -o "$up" -d "$ns" -p udp --dport 53 -j RETURN
      iptables -A DOCKER-USER -o "$up" -d "$ns" -p tcp --dport 53 -j RETURN
    done
    if [ -n "$fhost" ]; then
      ips="$(getent ahostsv4 "$fhost" | awk '{print $1}' | sort -u)" || true
      # Without Forgejo's address a pipeline cannot clone: fail, and systemd
      # tries again (Restart=on-failure), rather than fence it out quietly.
      [ -n "$ips" ] || { echo "woodpecker-egress: $fhost does not resolve — retrying"; exit 1; }
      for ip in $ips; do
        iptables -A DOCKER-USER -o "$up" -d "$ip" -p tcp --dport "$fport" -j RETURN
      done
    fi
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
      iptables -A DOCKER-USER -o "$up" -d "$net" -j REJECT --reject-with icmp-port-unreachable
    done
    iptables -A DOCKER-USER -j RETURN
    echo "woodpecker-egress: pipelines reach the internet, DNS and ''${fhost:-no forge}:$fport; other private addresses refused"
  '';
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
    /etc/nixos/tappaas-backup.nix
  ];

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "woodpecker";
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 8000 ];
  };

  # -- SSH: keys only ----------------------------------------------------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Docker: the pipelines' runtime ----------------------------------------
  virtualisation.docker = {
    enable = true;
    autoPrune = { enable = true; dates = "weekly"; flags = [ "--all" "--filter" "until=168h" ]; };
  };
  environment.systemPackages = with pkgs; [ jq curl ];

  systemd.services.woodpecker-env = {
    description = "Woodpecker: the server's and agent's environment";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = envScript; };
  };

  systemd.services.woodpecker-egress = {
    description = "Woodpecker: what pipeline containers may reach";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    partOf = [ "docker.service" ];
    wantedBy = [ "docker.service" "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = egressScript; Restart = "on-failure"; RestartSec = 10; };
  };

  # -- The server ----------------------------------------------------------------
  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = publicUrl;
      WOODPECKER_SERVER_ADDR = ":8000";
      WOODPECKER_GRPC_ADDR = "127.0.0.1:9000";
      WOODPECKER_FORGEJO = "true";
      # Forgejo delivers its webhooks inside the zone, not through Caddy.
      WOODPECKER_EXPERT_WEBHOOK_HOST = "http://${internalHost}:8000";
      # Anyone with a Forgejo account may sign in; the admins are named.
      WOODPECKER_OPEN = "true";
      WOODPECKER_ADMIN = lib.concatStringsSep "," admins;
      WOODPECKER_DISABLE_USER_AGENT_REGISTRATION = "true";
      WOODPECKER_LOG_LEVEL = "info";
    };
    environmentFile = [ "/run/woodpecker/server.env" ];
  };
  systemd.services.woodpecker-server = {
    requires = [ "woodpecker-env.service" ];
    after = [ "woodpecker-env.service" ];
    # Starts once forgejo:oauth has written the Forgejo client.
    unitConfig.ConditionPathExists = "/etc/secrets/forgejo-oauth.env";
  };

  # -- One agent on this VM ----------------------------------------------------
  services.woodpecker-agents.agents.docker = {
    enable = true;
    extraGroups = [ "docker" ];
    environment = {
      WOODPECKER_SERVER = "127.0.0.1:9000";
      WOODPECKER_BACKEND = "docker";
      DOCKER_HOST = "unix:///run/docker.sock";
      WOODPECKER_MAX_WORKFLOWS = "2";
      WOODPECKER_HEALTHCHECK_ADDR = "127.0.0.1:3000";
    };
    environmentFile = [ "/run/woodpecker/agent.env" ];
  };
  systemd.services.woodpecker-agent-docker = {
    requires = [ "woodpecker-env.service" "docker.service" ];
    after = [ "woodpecker-env.service" "docker.service" "woodpecker-egress.service" "woodpecker-server.service" ];
    wants = [ "woodpecker-egress.service" ];
  };

  # A new or changed Forgejo client (forgejo:oauth writes it): rebuild the
  # environment and restart, so a sign-in uses it at once.
  systemd.paths.woodpecker-oauth = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = { PathChanged = [ "/etc/secrets/forgejo-oauth.env" ]; Unit = "woodpecker-reconfigure.service"; };
  };
  systemd.services.woodpecker-reconfigure = {
    description = "Woodpecker: apply a new Forgejo client";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart woodpecker-env.service woodpecker-egress.service woodpecker-server.service woodpecker-agent-docker.service";
    };
  };

  system.stateVersion = "25.05";
}
