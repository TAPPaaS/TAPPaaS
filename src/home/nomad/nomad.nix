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
#     config; the Command Center's URL written by update.sh.
#
# NOMAD is not published outside the site and has no login of its own: the
# client networks reach it at http://nomad.<zone>.internal:8080, and the apps
# on their own ports, as the module's ingress rules allow.
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
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
    url="$(cat /var/lib/project-nomad/url 2>/dev/null || true)"
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

  # 8080: the Command Center. The content apps' ports are published by Docker,
  # which programs its own forwarding; the site firewall decides who reaches them.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 8080 ];
  };

  # -- SSH: keys only ----------------------------------------------------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Docker: the Command Center manages its apps through the socket --------
  virtualisation.docker = {
    enable = true;
    autoPrune = { enable = true; dates = "weekly"; };
  };

  environment.systemPackages = with pkgs; [ jq docker-compose ];

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

  system.stateVersion = "25.05";
}
