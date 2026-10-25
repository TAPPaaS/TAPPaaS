# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Project N.O.M.A.D.
# ============================================================================
# Self-contained NixOS configuration, applied by update-os.sh on install and
# every update (built on the mothership against the release's nixpkgs).
#
# Project N.O.M.A.D. (Apache-2.0, Crosstalk Solutions) is a Docker Compose
# stack: the Command Center ("admin", port 8080) with MySQL and Redis, and a
# disk collector for the storage figures. The Command Center installs the
# content apps itself — Kiwix, Kolibri, Notes, the Supply Depot — as further
# containers through the Docker socket, each on its own host port.
#
# What TAPPaaS changes from the upstream compose:
#   - images pinned to release tags (src/image-pins.json), never :latest;
#   - no updater sidecar: it rewrites the compose file's image tags, which is
#     what a pin bump in this file does instead;
#   - no Dozzle: an unauthenticated log viewer with the Docker socket;
#   - secrets generated once on the VM (/var/lib/project-nomad/.env), never in
#     config.
#
# The Command Center has no login of its own, and through the Docker socket it
# starts any container it is given (custom apps): reaching it is root on this
# VM. So it is reached only at https://nomad.<domain>, through Caddy and the
# Authentik gate (members of admin), from inside the site; the VM refuses port
# 8080 from every other source (nomad-fence below — Docker's published ports
# pass the NixOS firewall by, and the site firewall does not filter between
# neighbours in one zone). The content apps it installs stay on their own
# ports, reached from the client networks at http://nomad.<zone>.internal:<port>;
# nomad-links points the Command Center's tiles there.
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  # The module's config, deployed beside this file by update-os.sh: the name
  # the proxy publishes it under (proxyDomain), and the firewall's IPv6 address
  # in this zone (proxySourceV6, ADR-030 D9) — Caddy's source over IPv6.
  moduleCfg = if builtins.pathExists ./nomad.json
              then builtins.fromJSON (builtins.readFile ./nomad.json)
              else {};
  proxyCfg = (moduleCfg.config or {})."network:proxy" or {};
  proxyDomain = proxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  publicUrl = if proxyDomain != "" then "https://${proxyDomain}" else "";
  proxySourceV6 = moduleCfg.proxySourceV6 or "";

  # Pinned images (src/image-pins.json tracks them, #750). Immutable tags.
  adminImage = "ghcr.io/crosstalk-solutions/project-nomad:v1.35.1";
  diskCollectorImage = "ghcr.io/crosstalk-solutions/project-nomad-disk-collector:v1.31.1";
  mysqlImage = "mysql:8.0.46";
  redisImage = "redis:7.4.11-alpine";

  storage = "/opt/project-nomad";

  compose = pkgs.writeText "project-nomad-compose.yml" ''
    name: project-nomad
    services:
      admin:
        image: ${adminImage}
        container_name: nomad_admin
        restart: unless-stopped
        extra_hosts:
          - "host.docker.internal:host-gateway"
        ports:
          - "8080:8080"
        volumes:
          - ${storage}/storage:/app/storage
          - /var/run/docker.sock:/var/run/docker.sock
        environment:
          - NODE_ENV=production
          - NOMAD_STORAGE_PATH=${storage}/storage
          - PORT=8080
          - LOG_LEVEL=info
          - APP_KEY=''${NOMAD_APP_KEY}
          - HOST=0.0.0.0
          - URL=''${NOMAD_URL}
          - DB_HOST=mysql
          - DB_PORT=3306
          - DB_DATABASE=nomad
          - DB_USER=nomad_user
          - DB_PASSWORD=''${NOMAD_DB_PASSWORD}
          - DB_NAME=nomad
          - DB_SSL=false
          - REDIS_HOST=redis
          - REDIS_PORT=6379
          - DISABLE_COMPRESSION=false
        depends_on:
          mysql:
            condition: service_healthy
          redis:
            condition: service_healthy
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:8080/api/health"]
          interval: 30s
          timeout: 10s
          retries: 3
      mysql:
        image: ${mysqlImage}
        container_name: nomad_mysql
        restart: unless-stopped
        environment:
          - MYSQL_ROOT_PASSWORD=''${NOMAD_DB_ROOT_PASSWORD}
          - MYSQL_DATABASE=nomad
          - MYSQL_USER=nomad_user
          - MYSQL_PASSWORD=''${NOMAD_DB_PASSWORD}
        volumes:
          - ${storage}/mysql:/var/lib/mysql
        healthcheck:
          test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
          interval: 30s
          timeout: 10s
          retries: 10
      redis:
        image: ${redisImage}
        container_name: nomad_redis
        restart: unless-stopped
        volumes:
          - ${storage}/redis:/data
        healthcheck:
          test: ["CMD", "redis-cli", "ping"]
          interval: 30s
          timeout: 10s
          retries: 3
      disk-collector:
        image: ${diskCollectorImage}
        container_name: nomad_disk_collector
        restart: unless-stopped
        volumes:
          - /:/host:ro,rslave
          - ${storage}/storage:/storage
  '';

  # Generates the secrets once, then brings the stack to the compose file.
  nomadUp = pkgs.writeShellScript "project-nomad-up" ''
    set -euo pipefail
    install -d -m 0755 ${storage} ${storage}/storage ${storage}/mysql ${storage}/redis
    install -d -m 0700 /var/lib/project-nomad
    env=/var/lib/project-nomad/.env
    if [ ! -s "$env" ]; then
      umask 077
      {
        echo "NOMAD_APP_KEY=$(${pkgs.openssl}/bin/openssl rand -hex 24)"
        echo "NOMAD_DB_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -hex 24)"
        echo "NOMAD_DB_ROOT_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -hex 24)"
      } > "$env"
    fi
    # The Command Center's own URL: the gated public name.
    url="${publicUrl}"
    [ -n "$url" ] || url="http://$(${pkgs.nettools}/bin/hostname -f):8080"
    sed -i '/^NOMAD_URL=/d' "$env"
    echo "NOMAD_URL=$url" >> "$env"
    # A first boot can reach this before the VM resolves names (the first pull
    # failed on "lookup ghcr.io: no such host"): wait for DNS, and retry the
    # pull rather than fail the activation on a transient.
    for i in $(seq 1 30); do
      ${pkgs.getent}/bin/getent hosts ghcr.io >/dev/null && break
      sleep 10
    done
    for i in 1 2 3 4 5; do
      ${pkgs.docker-compose}/bin/docker-compose -p project-nomad -f ${compose} \
        --env-file "$env" up -d --remove-orphans && exit 0
      echo "project-nomad: up failed (attempt $i of 5), retrying in 30 s" >&2
      sleep 30
    done
    exit 1
  '';
  # Docker's published ports pass the NixOS firewall by, so the fence is in
  # the DOCKER-USER chain Docker keeps for the host's own rules (as woodpecker
  # does). From the uplink: 8080 only from Caddy (the zone's gateway; over IPv6
  # the firewall's address in the zone), and no published port from another
  # machine in this zone — the client networks are routed through the firewall,
  # so their addresses are not this subnet's. A refused connection is reset, so
  # Caddy falls back from IPv6 to IPv4 at once.
  fenceScript = pkgs.writeShellScript "nomad-fence" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.iptables pkgs.iproute2 pkgs.gawk pkgs.coreutils ]}
    up="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    gw="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}')"
    [ -n "$up" ] && [ -n "$gw" ] || { echo "nomad-fence: no default route yet"; exit 1; }
    net4="$(ip -4 -o addr show dev "$up" scope global | awk '{print $4; exit}')"
    fence() { # fence <iptables|ip6tables> <caddy source> <own networks...>
      local t="$1" src="$2"; shift 2
      $t -N DOCKER-USER 2>/dev/null || true
      $t -F DOCKER-USER
      $t -A DOCKER-USER -i "$up" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
      [ -n "$src" ] && $t -A DOCKER-USER -i "$up" -s "$src" -p tcp -m conntrack --ctorigdstport 8080 -j RETURN
      $t -A DOCKER-USER -i "$up" -p tcp -m conntrack --ctorigdstport 8080 -j REJECT --reject-with tcp-reset
      for n in "$@"; do $t -A DOCKER-USER -i "$up" -s "$n" -j DROP; done
      $t -A DOCKER-USER -j RETURN
    }
    fence iptables "$gw" ''${net4:+"$net4"}
    net6="$(ip -6 -o addr show dev "$up" scope global | awk '$4 !~ /^f[cd]/ {print $4; exit}')"
    fence ip6tables "${proxySourceV6}" ''${net6:+"$net6"} fe80::/10
    echo "nomad-fence: 8080 from $gw${lib.optionalString (proxySourceV6 != "") " and ${proxySourceV6}"} only; no published port from ''${net4:-?}''${net6:+ or $net6}"
  '';

  # The Command Center links an app as http://<the address bar's host>:<port>
  # unless the app has a custom URL. Behind the proxy that host is the public
  # name, where the apps are not: give every installed app without a URL of
  # its own the address the client networks reach it at. An URL set by hand
  # is kept.
  # `nomad-links check` prints how many installed apps still lack it.
  linksScript = pkgs.writeShellScriptBin "nomad-links" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.nettools ]}
    . /var/lib/project-nomad/.env
    host="$(hostname -f)"
    portapp="installed = 1 AND ui_location REGEXP '^(https?:)?[0-9]+$'"
    if [ "''${1:-}" = check ]; then
      sql="SELECT COUNT(*) FROM services WHERE $portapp AND (custom_url IS NULL OR custom_url NOT LIKE '%://$host:%');"
    else
      sql="UPDATE services SET custom_url = CASE
             WHEN ui_location REGEXP '^https?:[0-9]+$'
               THEN CONCAT(SUBSTRING_INDEX(ui_location, ':', 1), '://$host:', SUBSTRING_INDEX(ui_location, ':', -1))
             ELSE CONCAT('http://$host:', ui_location) END
           WHERE $portapp AND (custom_url IS NULL OR custom_url = ''');"
    fi
    echo "$sql" | docker exec -i -e MYSQL_PWD="$NOMAD_DB_PASSWORD" nomad_mysql mysql -N -unomad_user nomad
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
  networking.hostName = lib.mkDefault "nomad";

  # The Command Center (8080) and the content apps' ports are published by
  # Docker, which programs its own forwarding past this firewall: who reaches
  # them is the site firewall's ingress rules and nomad-fence.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # -- SSH: keys only ----------------------------------------------------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Docker: the Command Center manages its apps through the socket --------
  virtualisation.docker = {
    enable = true;
    autoPrune = { enable = true; dates = "weekly"; };
  };

  environment.systemPackages = with pkgs; [ jq docker-compose ] ++ [ linksScript ];

  # Readable by update.sh (as tappaas, through sudo) to find where things are.
  environment.etc."project-nomad/compose.yml".source = compose;

  systemd.services.project-nomad = {
    description = "Project N.O.M.A.D. (Command Center, MySQL, Redis)";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker pkgs.coreutils pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = nomadUp;
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose -p project-nomad -f ${compose} down";
      TimeoutStartSec = "15min";
    };
    # A new compose (a pin bump) brings the stack to it on the next switch.
    restartTriggers = [ compose ];
  };

  # The fence, again whenever Docker (re)starts: it builds its chains then.
  systemd.services.nomad-fence = {
    description = "Project N.O.M.A.D.: the Command Center only from Caddy, no app from a zone neighbour";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    partOf = [ "docker.service" ];
    wantedBy = [ "multi-user.target" "docker.service" ];
    before = [ "project-nomad.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = fenceScript; Restart = "on-failure"; RestartSec = 10; };
    restartTriggers = [ fenceScript ];
  };

  systemd.services.nomad-links = {
    description = "Project N.O.M.A.D.: the Command Center's app tiles open the apps at their internal address";
    after = [ "project-nomad.service" ];
    requires = [ "project-nomad.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${linksScript}/bin/nomad-links"; };
  };
  systemd.timers.nomad-links = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnActiveSec = "1min"; OnUnitActiveSec = "2min"; };
  };

  system.stateVersion = "25.05";
}
