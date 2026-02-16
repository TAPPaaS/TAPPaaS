# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# ============================================================================
# TAPPaaS - LiteLLM AI proxy
# ============================================================================
# Version: 0.9.1
# Date: 2026-02-13
# Author: @ErikDaniel007 (TAPPaaS)
# Product: LiteLLM proxy with PostgreSQL + Redis backend
#
# Architecture:
# - PostgreSQL 15 (model configs + usage tracking)
# - Redis 7 (response caching)
# - LiteLLM container (unified API gateway)
#
# Network: Self-managed DHCP, firewall ports 22 (SSH) + 4000 (LiteLLM API)
# Secrets: Auto-generated master key on first boot
# Backups: Daily PostgreSQL/Redis/config backups, 30-day retention
#
# Changelog v0.9.1 (2026-02-13):
# - Fixed Redis backup (was using --rdb replication tool instead of SAVE)
# - Added filesystem dependency to secrets generation (boot safety)
# - Removed broken WAL archiving (daily pg_dump already provides recovery)
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning - change versions here only
  versions = {
    litellm     = "v1.81.3.rc.2";
    postgresPkg = pkgs.postgresql_15;
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
  boot.growPartition = lib.mkDefault true;  # Auto-expand root partition on resize

  # ============================================================================
  # CLOUD-INIT
  # ============================================================================
  
  services.cloud-init = {
    enable = true;
    network.enable = false;  # We handle networking ourselves with NetworkManager
  };

  # ============================================================================
  # NETWORKING
  # ============================================================================
  
  networking.hostName = lib.mkDefault "litellm";
  networking.networkmanager.enable = true;
  # Match ethernet by type, not interface name (ens18/eth0/enp0s18 varies)
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };
  
  # Prevent systemd-networkd conflicts with NetworkManager
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  # Serial console for VM debugging (bypass KVM console)
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      22    # SSH
      4000  # LiteLLM API
    ];
    # Stateful firewall: outbound connections auto-allowed (e.g. to external Langfuse)
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
    postgresql  # psql CLI for debugging
  ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================
  
  nix.settings.trusted-users = [ "root" "@wheel" ];  # Allow remote deployments
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Automatic garbage collection - 30 day retention (dev-friendly)
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
  
  services.qemuGuest.enable = true;  # Proxmox/QEMU integration
  
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  
  programs.ssh.startAgent = true;

  # ============================================================================
  # DATABASE - PostgreSQL 15
  # ============================================================================
  
  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "litellm" ];
    ensureUsers = [
      { name = "litellm"; ensureDBOwnership = true; }
    ];
    
    # Passwordless local access (LiteLLM container via host network)
    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
    
    # Tuning for 2-4GB RAM VM
    settings = {
      max_connections = 100;
      shared_buffers = "1GB";
      effective_cache_size = "2GB";
      maintenance_work_mem = "256MB";
      work_mem = "16MB";

      # Performance tuning
      checkpoint_completion_target = 0.9;
      wal_buffers = "16MB";
      default_statistics_target = 100;
      random_page_cost = 1.1;  # SSD
      effective_io_concurrency = 200;

      # WAL archiving disabled - daily pg_dump backups provide sufficient recovery
      # (Previous WAL archive command was broken due to missing full paths)
      wal_level = "replica";
      archive_mode = "off";
    };
  };

  # ============================================================================
  # CACHING - Redis 7
  # ============================================================================
  
  services.redis.servers."litellm" = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";  # Localhost only
    settings = {
      maxmemory = "512mb";  # Kleiner dan 8GB setup
      maxmemory-policy = "allkeys-lru";
      maxclients = 10000;
      timeout = 300;
      tcp-keepalive = 60;
    };
    save = [
      [900 1]      # Save after 900s if ≥1 key changed
      [300 10]     # Save after 300s if ≥10 keys changed
      [60 10000]   # Save after 60s if ≥10000 keys changed
    ];
  };

  # ============================================================================
  # CONTAINER RUNTIME
  # ============================================================================
  
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # LITELLM CONFIGURATION
  # ============================================================================
  
  # LiteLLM config file - mounted read-only into container
  environment.etc."litellm/config.yaml" = {
    text = ''
      general_settings:
        master_key: os.environ/LITELLM_MASTER_KEY
        database_url: "postgresql://litellm@localhost:5432/litellm"
        database_connection_pool_limit: 25
        database_connection_timeout: 60
        proxy_batch_write_at: 60
        disable_spend_logs: false
        
        # Public endpoints - no authentication
        public_routes:
          - "/health"
          - "/health/liveliness"
          - "/health/readiness"

      router_settings:
        redis_host: "localhost"
        redis_port: 6379
        routing_strategy: "simple-shuffle"

      litellm_settings:
        cache: true
        cache_type: "redis"
        cache_params:
          type: "redis"
          host: "localhost"
          port: 6379
          max_connections: 100
        load_models_from_db: true
        set_verbose: true
        json_logs: true
        request_timeout: 60
        max_retries: 3
        log_raw_request_response: false
    '';
    mode = "0644";
  };

  # Secrets template - reference for manual setup
  environment.etc."secrets/litellm-template.env" = {
    text = ''
      LITELLM_MASTER_KEY=sk-your_master_key_here
      STORE_MODEL_IN_DB=True
    '';
    mode = "0600";
  };

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================
  
  systemd.services.generate-litellm-secrets = {
    description = "Generate LiteLLM secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];  # Ensure /etc is mounted before writing secrets
    before = [ "podman-litellm.service" ];

    # Only run if secrets file doesn't exist
    unitConfig.ConditionPathExists = "!/etc/secrets/litellm.env";
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-litellm-secrets" ''
        # Generate secure random master key
        MASTER_KEY="sk-$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        
        # Create secrets directory
        mkdir -p /etc/secrets
        
        # Write secrets file
        cat > /etc/secrets/litellm.env <<EOF
LITELLM_MASTER_KEY=$MASTER_KEY
STORE_MODEL_IN_DB=False
OPENROUTER_API_KEY=
PERPLEXITY_API_KEY=
EOF
        chmod 600 /etc/secrets/litellm.env
        
        # Display master key for admin to save
        echo "================================================"
        echo "LITELLM MASTER KEY (save this!):"
        echo "$MASTER_KEY"
        echo "================================================"
        echo "Saved to: /etc/secrets/litellm.env"
        echo "View anytime: sudo cat /etc/secrets/litellm.env"
      '';
    };
  };

  # ============================================================================
  # LITELLM CONTAINER
  # ============================================================================
  
  virtualisation.oci-containers.containers.litellm = {
    image = "ghcr.io/berriai/litellm:${versions.litellm}";
    volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
    environmentFiles = [ "/etc/secrets/litellm.env" ];
    extraOptions = [ 
      "--network=host"           # Access localhost PostgreSQL/Redis
      "--log-driver=journald"    # Logs to systemd journal
    ];
    cmd = [ 
      "--config" "/app/config.yaml" 
      "--port" "4000" 
      "--host" "0.0.0.0" 
      "--num_workers" "4"  
    ];
  };

  # Ensure LiteLLM starts after dependencies are ready
  systemd.services.podman-litellm = {
    after = [ "postgresql.service" "redis-litellm.service" ];
    requires = [ "postgresql.service" "redis-litellm.service" ];
  };

  # ============================================================================
  # BACKUP STRATEGY - 3 layers
  # ============================================================================
  
  # Layer 1: PostgreSQL dumps (daily 02:00)
  services.postgresqlBackup = {
    enable = true;
    databases = [ "litellm" ];
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
        # Trigger synchronous save to disk
        ${versions.redisPkg}/bin/redis-cli SAVE

        # Copy snapshot with timestamp
        ${pkgs.coreutils}/bin/cp /var/lib/redis-litellm/dump.rdb \
          /var/backup/redis/dump-$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S).rdb
      '';
      User = "redis-litellm";
      Group = "redis-litellm";
    };
  };

  systemd.timers.redis-backup = {
    description = "Daily Redis backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;  # Run missed backups on boot
    };
  };

  # Layer 3: Config + secrets backup (daily 02:45)
  systemd.services.litellm-env-backup = {
    description = "Backup LiteLLM environment files";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/litellm-env";
      ExecStart = pkgs.writeShellScript "litellm-env-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/litellm-env/litellm-env-$(date +%F).tar.gz \
          -C / etc/secrets etc/litellm 2>/dev/null || true
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.litellm-env-backup = {
    description = "Daily LiteLLM environment file backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:45:00";
      Persistent = true;
    };
  };

  # Cleanup old backups (monthly) - prevent disk fill
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
    "d /var/backup/redis 0755 redis-litellm redis-litellm -"
    "d /var/backup/litellm-env 0755 root root -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # See: https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion
  # ============================================================================
  
  system.stateVersion = "25.05";
}