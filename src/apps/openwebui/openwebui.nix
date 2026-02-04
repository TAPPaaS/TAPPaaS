# ----------------------------------------
# TAPPaaS
# Name: Open webui
# Type: APP
# Version: 0.9.0 
# Date: 2026-02-01
# Author: Erik Daniel (Tappaas)
# Products: openwebui, postgres, redis
# ----------------------------------------

{ config, pkgs, lib, ... }:

let
  # ----------------------------------------
  # Version pinning
  # Change versions in one place only
  # ----------------------------------------
  versions = {
    openwebui   = "v0.7.2";             # OpenWebUI container version (upgrade later)
    postgresPkg = pkgs.postgresql_15;   # PostgreSQL version
    redisPkg    = pkgs.redis;           # Redis version
  };
in
{
  # ----------------------------------------
  # Imports
  # ----------------------------------------
  imports = [ ./hardware-configuration.nix ];

  # ----------------------------------------
  # Bootloader
  # ----------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ----------------------------------------
  # Kernel parameters
  # ----------------------------------------
  boot.kernelParams = [ "systemd.unified_cgroup_hierarchy=1" ];

  # ----------------------------------------
  # System Identity
  # ----------------------------------------
  system.stateVersion = "25.05";

  # ----------------------------------------
  # Network Configuration - VLAN Trunk Mode
  # ----------------------------------------
  networking = {
    hostName = lib.mkDefault "openwebui";
    
    # Disable NetworkManager (conflicts with declarative VLAN config)
    networkmanager.enable = false;
    
    # Disable default DHCP
    useDHCP = false;
    
    # Main trunk interface (no IP, no DHCP)
    interfaces.ens18.useDHCP = false;
    
    # VLAN 210 subinterface (srv zone)
    vlans."ens18.210" = {
      id = 210;
      interface = "ens18";
    };
    
    # VLAN interface gets DHCP
    interfaces."ens18.210".useDHCP = true;
    
    # Default gateway via VLAN
    defaultGateway = {
      address = "192.168.210.1";
      interface = "ens18.210";
    };
    
    nameservers = [ "192.168.210.1" ];

    firewall.allowedTCPPorts = [ 22 8080 ];
  };

  # Disable systemd-networkd (conflicts with NetworkManager/declarative)
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  # ----------------------------------------
  # Timezone
  # ----------------------------------------
  time.timeZone = "Europe/Amsterdam";

  # ----------------------------------------
  # Users
  # ----------------------------------------
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
  };

  users.users.svc_openwebui_admin = {
    isSystemUser = true;
    group = "svc_openwebui";
    home = "/var/lib/openwebui";
    createHome = true;
    uid = 1001;
  };

  users.groups.svc_openwebui.gid = 1001;

  # Redis user (needed for backup service)
  users.users.redis = {
    isSystemUser = true;
    createHome = false;
    group = "redis";
  };
  users.groups.redis.gid = 1010;

  # ----------------------------------------
  # Core system services
  # ----------------------------------------
  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.cloud-init = {
    enable = true;
    network.enable = false; # modified - should stay false!
  };

  # ----------------------------------------
  # PostgreSQL service
  # ----------------------------------------
  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "openwebui" ];
    ensureUsers = [
      { name = "openwebui"; ensureDBOwnership = true; }
    ];
    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
    settings = {
      max_connections = 100;
      shared_buffers = "256MB";
    };
  };

  # ----------------------------------------
  # Redis service
  # ----------------------------------------
  services.redis.servers.openwebui = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
    save = [
      [900 1]
      [300 10]
      [60 10000]
    ];
  };

  # ----------------------------------------
  # Podman container runtime
  # ----------------------------------------
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ----------------------------------------
  # OpenWebUI container wrapper
  # ----------------------------------------
  systemd.services.openwebui-wrapper = let
    startScript = pkgs.writeShellScript "openwebui-start" ''
      exec ${pkgs.podman}/bin/podman run \
        --name openwebui \
        --network=host \
        --log-driver=journald \
        --env-file=/etc/secrets/openwebui.env \
        -v /var/lib/openwebui/data:/app/backend/data \
        -v /var/lib/openwebui/models:/app/backend/data/models \
        ghcr.io/open-webui/open-webui:${versions.openwebui}
    '';
  in {
    description = "OpenWebUI via Podman wrapper";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${startScript}";
      ExecStop = "${pkgs.podman}/bin/podman stop openwebui";
      ExecStartPre = pkgs.writeShellScript "openwebui-prestart" ''
        IMAGE="ghcr.io/open-webui/open-webui:${versions.openwebui}"
        if ! ${pkgs.podman}/bin/podman image exists "$IMAGE"; then
          echo "Image $IMAGE not found locally, pulling..."
          ${pkgs.podman}/bin/podman pull "$IMAGE"
        else
          echo "Image $IMAGE already present locally, skipping pull."
        fi
        ${pkgs.podman}/bin/podman rm -f openwebui || true
      '';
      TimeoutStartSec = 600;
      Restart = "always";
      RestartSec = 10;
      Delegate = true;
      NoNewPrivileges = true;
      ProtectSystem = "full";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [
        "/var/lib/openwebui"
        "/sys/fs/cgroup"
        "/sys/fs/cgroup/machine.slice"
      ];
    };
  };

  # ----------------------------------------
  # Environment files
  # ----------------------------------------
  environment.etc."secrets/openwebui.env".text = ''
    DATABASE_URL=postgresql://openwebui:REPLACE_PASSWORD@127.0.0.1:5432/openwebui
    WEBUI_SECRET_KEY=REPLACE_WITH_SECURE_SECRET
    WEBUI_AUTH=True
    WEBUI_NAME=TAPPaaS Open WebUI
    DATA_DIR=/app/backend/data
    OPENWEBUI_PORT=8080
    ENABLE_WEBSOCKET_SUPPORT=true
    WEBSOCKET_MANAGER=redis
    WEBSOCKET_REDIS_URL=redis://127.0.0.1:6379/1
    REDIS_KEY_PREFIX=openwebui
  '';

  environment.etc."secrets/postgres.env".text = ''
    POSTGRES_DB=openwebui
    POSTGRES_USER=openwebui
    POSTGRES_PASSWORD=REPLACE_WITH_SECURE_PASSWORD
  '';

  environment.etc."secrets/redis.env".text = ''
    REDIS_PORT=6379
    REDIS_BIND=127.0.0.1
  '';

  # ----------------------------------------
  # Data directories
  # ----------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/openwebui 0750 svc_openwebui_admin svc_openwebui -"
    "d /var/lib/openwebui/data 0750 svc_openwebui_admin svc_openwebui -"
    "d /var/lib/openwebui/models 0750 svc_openwebui_admin svc_openwebui -"
    "d /var/backup/postgresql 0700 postgres postgres -"
    "d /var/backup/redis 0700 redis redis -"
    "d /var/backup/openwebui-data 0700 root root -"
    "d /var/backup/openwebui-env 0700 root root -"
    "f /etc/openwebui/start.sh 0755 root root -"
  ];

  # ----------------------------------------
  # Backup Services - PostgreSQL
  # ----------------------------------------
  systemd.services.postgresqlBackup = {
    description = "PostgreSQL backup service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "pg-backup" ''
        ${versions.postgresPkg}/bin/pg_dump -U openwebui openwebui | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/openwebui-$(date +%F).sql.gz
      '';
      User = "postgres";
    };
  };

  systemd.timers.postgresqlBackup = {
    description = "Daily PostgreSQL backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:00:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - Redis
  # ----------------------------------------
  systemd.services.redis-backup = {
    description = "Redis backup service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "redis-backup" ''
        ${versions.redisPkg}/bin/redis-cli --rdb /var/backup/redis/dump-$(date +%Y%m%d_%H%M%S).rdb
      '';
      User = "redis";
      Group = "redis";
    };
  };

  systemd.timers.redis-backup = {
    description = "Daily Redis backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:30:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - OpenWebUI container data
  # ----------------------------------------
  systemd.services.openwebui-container-backup = {
    description = "Backup OpenWebUI container data";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/openwebui-data";
      ExecStart = pkgs.writeShellScript "openwebui-data-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/openwebui-data/openwebui-data-$(date +%F).tar.gz \
          -C / var/lib/openwebui/data var/lib/openwebui/models
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.openwebui-container-backup = {
    description = "Daily OpenWebUI container data backup";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:45:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - Environment files
  # ----------------------------------------
  systemd.services.openwebui-env-backup = {
    description = "Backup OpenWebUI environment files";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/openwebui-env";
      ExecStart = pkgs.writeShellScript "openwebui-env-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/openwebui-env/openwebui-env-$(date +%F).tar.gz \
          -C / etc/secrets
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.openwebui-env-backup = {
    description = "Daily OpenWebUI environment file backup";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:50:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - Cleanup old backups
  # ----------------------------------------
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
    timerConfig.OnCalendar = "monthly";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # System packages
  # ----------------------------------------
  environment.systemPackages = with pkgs; [
    vim wget curl htop git podman openssl postgresql redis crun
  ];

  # ----------------------------------------
  # Security settings
  # ----------------------------------------
  security.sudo.wheelNeedsPassword = false;

  # ----------------------------------------
  # Nix CLI and garbage collection
  # ----------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "daily"; options = "--delete-older-than 7d"; };
  nix.optimise = { automatic = true; dates = [ "weekly" ]; };

  # ----------------------------------------
  # System update configuration
  # ----------------------------------------
  system.autoUpgrade = { enable = false; dates = "weekly"; allowReboot = false; };
}