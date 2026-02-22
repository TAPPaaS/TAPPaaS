# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Authentik Identity Provider
# ============================================================================
# Version: 1.0.0
# Date: 2026-02-17
# Author: @ErikDaniel007 (TAPPaaS)
# Product: Authentik IdP with PostgreSQL + Redis backend
#
# Architecture:
# - PostgreSQL 16 (user/group/policy storage)
# - Redis 7 (caching, sessions, task queue)
# - Authentik Server container (web UI + API, ports 9000/9443)
# - Authentik Worker container (background tasks, LDAP sync, email)
#
# Network: zone "srv" (VLAN 210, 10.2.10.0/24)
# Firewall: ports 22 (SSH) + 9000 (HTTP) + 9443 (HTTPS)
# Secrets: Auto-generated AUTHENTIK_SECRET_KEY on first boot
# Backups: Daily PostgreSQL dump (02:00), config tar (02:45), 30-day retention
#
# Changelog v1.0.0 (2026-02-17):
# - Removed VaultWarden (moved to separate module in src/apps/vaultwarden/)
# - Full Authentik setup with server + worker containers
# - PostgreSQL 16 with ensureDatabases/ensureUsers
# - Redis for caching/sessions/task queue
# - Auto-generated secrets on first boot
# - Daily backup timers with 30-day retention
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning - change versions here only
  versions = {
    authentik   = "2025.2.1";
    postgresPkg = pkgs.postgresql_16;
    redisPkg    = pkgs.redis;
  };
in
{
  # ============================================================================
  # IMPORTS
  # ============================================================================

  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ============================================================================
  # BOOT CONFIGURATION
  # ============================================================================

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # ============================================================================
  # CLOUD-INIT
  # ============================================================================

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # ============================================================================
  # NETWORKING
  # ============================================================================

  networking.hostName = lib.mkDefault "identity";
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };

  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      9000  # Authentik HTTP
      9443  # Authentik HTTPS
    ];
  };

  # ============================================================================
  # TIME ZONE
  # ============================================================================

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # ============================================================================
  # USERS & SECURITY
  # ============================================================================

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ============================================================================
  # SYSTEM PACKAGES
  # ============================================================================

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    git
    lsof
    jq
    openssl
    postgresql
  ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================

  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # ============================================================================
  # ESSENTIAL SERVICES
  # ============================================================================

  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  programs.ssh.startAgent = true;

  # ============================================================================
  # DATABASE - PostgreSQL 16
  # ============================================================================

  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "authentik" ];
    ensureUsers = [
      { name = "authentik"; ensureDBOwnership = true; }
    ];

    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';

    settings = {
      max_connections = 100;
      shared_buffers = "1GB";
      effective_cache_size = "2GB";
      maintenance_work_mem = "256MB";
      work_mem = "16MB";
      checkpoint_completion_target = 0.9;
      wal_buffers = "16MB";
      default_statistics_target = 100;
      random_page_cost = 1.1;
      effective_io_concurrency = 200;
      wal_level = "replica";
      archive_mode = "off";
    };
  };

  # ============================================================================
  # CACHING & SESSIONS - Redis 7
  # ============================================================================

  services.redis.servers."authentik" = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
    settings = {
      maxmemory = "512mb";
      maxmemory-policy = "allkeys-lru";
      maxclients = 10000;
      timeout = 300;
      tcp-keepalive = 60;
    };
    save = [
      [900 1]
      [300 10]
      [60 10000]
    ];
  };

  # ============================================================================
  # CONTAINER RUNTIME
  # ============================================================================

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.generate-authentik-secrets = {
    description = "Generate Authentik secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "podman-authentik-server.service" "podman-authentik-worker.service" ];

    unitConfig.ConditionPathExists = "!/etc/secrets/authentik.env";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-authentik-secrets" ''
        SECRET_KEY="$(${pkgs.openssl}/bin/openssl rand -base64 60 | tr -d '\n')"

        mkdir -p /etc/secrets

        cat > /etc/secrets/authentik.env <<EOF
AUTHENTIK_SECRET_KEY=$SECRET_KEY
AUTHENTIK_POSTGRESQL__HOST=localhost
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_REDIS__HOST=localhost
AUTHENTIK_REDIS__PORT=6379
AUTHENTIK_LOG_LEVEL=info
AUTHENTIK_DISABLE_STARTUP_ANALYTICS=true
EOF
        chmod 600 /etc/secrets/authentik.env

        echo "================================================"
        echo "AUTHENTIK SECRET KEY generated and saved to:"
        echo "/etc/secrets/authentik.env"
        echo "================================================"
      '';
    };
  };

  environment.etc."secrets/authentik-template.env" = {
    text = ''
      AUTHENTIK_SECRET_KEY=your_secret_key_here
      AUTHENTIK_POSTGRESQL__HOST=localhost
      AUTHENTIK_POSTGRESQL__PORT=5432
      AUTHENTIK_POSTGRESQL__USER=authentik
      AUTHENTIK_POSTGRESQL__NAME=authentik
      AUTHENTIK_REDIS__HOST=localhost
      AUTHENTIK_REDIS__PORT=6379
      AUTHENTIK_LOG_LEVEL=info
      AUTHENTIK_DISABLE_STARTUP_ANALYTICS=true
      # Optional SMTP configuration:
      # AUTHENTIK_EMAIL__HOST=smtp.example.com
      # AUTHENTIK_EMAIL__PORT=587
      # AUTHENTIK_EMAIL__USERNAME=authentik@example.com
      # AUTHENTIK_EMAIL__PASSWORD=
      # AUTHENTIK_EMAIL__USE_TLS=true
      # AUTHENTIK_EMAIL__USE_SSL=false
      # AUTHENTIK_EMAIL__FROM=authentik@example.com
    '';
    mode = "0600";
  };

  # ============================================================================
  # AUTHENTIK SERVER CONTAINER (Web UI + API)
  # ============================================================================

  virtualisation.oci-containers.containers.authentik-server = {
    image = "ghcr.io/goauthentik/server:${versions.authentik}";
    volumes = [
      "/var/lib/authentik/media:/media"
      "/var/lib/authentik/templates:/templates"
    ];
    environmentFiles = [ "/etc/secrets/authentik.env" ];
    extraOptions = [
      "--network=host"
      "--log-driver=journald"
    ];
    cmd = [ "server" ];
  };

  systemd.services.podman-authentik-server = {
    after = [ "postgresql.service" "redis-authentik.service" "generate-authentik-secrets.service" ];
    requires = [ "postgresql.service" "redis-authentik.service" ];
  };

  # ============================================================================
  # AUTHENTIK WORKER CONTAINER (Background tasks)
  # ============================================================================

  virtualisation.oci-containers.containers.authentik-worker = {
    image = "ghcr.io/goauthentik/server:${versions.authentik}";
    volumes = [
      "/var/lib/authentik/media:/media"
      "/var/lib/authentik/templates:/templates"
      "/var/lib/authentik/certs:/certs"
    ];
    environmentFiles = [ "/etc/secrets/authentik.env" ];
    extraOptions = [
      "--network=host"
      "--log-driver=journald"
    ];
    cmd = [ "worker" ];
  };

  systemd.services.podman-authentik-worker = {
    after = [ "postgresql.service" "redis-authentik.service" "generate-authentik-secrets.service" ];
    requires = [ "postgresql.service" "redis-authentik.service" ];
  };

  # ============================================================================
  # BACKUP STRATEGY
  # ============================================================================

  # Layer 1: PostgreSQL dumps (daily 02:00)
  services.postgresqlBackup = {
    enable = true;
    databases = [ "authentik" ];
    startAt = "*-*-* 02:00:00";
    location = "/var/backup/postgresql";
    compression = "gzip";
  };

  # Layer 2: Redis RDB snapshots (daily 02:30)
  systemd.services.redis-backup = {
    description = "Redis backup service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "redis-backup" ''
        ${versions.redisPkg}/bin/redis-cli SAVE
        ${pkgs.coreutils}/bin/cp /var/lib/redis-authentik/dump.rdb \
          /var/backup/redis/dump-$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S).rdb
      '';
      User = "redis-authentik";
      Group = "redis-authentik";
    };
  };

  systemd.timers.redis-backup = {
    description = "Daily Redis backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
    };
  };

  # Layer 3: Config + secrets + media backup (daily 02:45)
  systemd.services.authentik-env-backup = {
    description = "Backup Authentik environment and media files";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/authentik-env";
      ExecStart = pkgs.writeShellScript "authentik-env-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/authentik-env/authentik-env-$(date +%F).tar.gz \
          -C / etc/secrets var/lib/authentik 2>/dev/null || true
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.authentik-env-backup = {
    description = "Daily Authentik environment file backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:45:00";
      Persistent = true;
    };
  };

  # Cleanup old backups (monthly)
  systemd.services.cleanup-backups = {
    description = "Cleanup old backups";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup -type f -mtime +30 -delete
      '';
      User = "root";
    };
  };

  systemd.timers.cleanup-backups = {
    description = "Monthly cleanup of old backups";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /var/backup/postgresql 0700 postgres postgres -"
    "d /var/backup/redis 0700 redis-authentik redis-authentik -"
    "d /var/backup/authentik-env 0700 root root -"
    "d /var/lib/authentik 0755 root root -"
    "d /var/lib/authentik/media 0755 root root -"
    "d /var/lib/authentik/templates 0755 root root -"
    "d /var/lib/authentik/certs 0755 root root -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
