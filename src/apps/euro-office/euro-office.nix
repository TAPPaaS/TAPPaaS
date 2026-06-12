# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Euro-Office DocumentServer
# ============================================================================
# Version: 1.0.0
# Date: 2026-05-01
# Author: @AndreasJe (TAPPaaS)
# Product: Euro-Office DocumentServer (collaborative document editing)
#
# Architecture:
# - Single Podman container (ghcr.io/euro-office/documentserver:v9.3.1, pinned in nix)
# - Container bundles Nginx, PostgreSQL, Redis, RabbitMQ, DocService,
#   FileConverter, AdminPanel, and an example app internally
# - Only port 80 (Nginx) is exposed to the host; all other ports are internal
#
# Network: srv zone (VMID 343, tappaas1), firewall ports 22 (SSH) + 80 (HTTP)
# Secrets: Auto-generated JWT_SECRET (64-char hex) on first boot
# Backups: Daily volume snapshot (stop → tar → restart), 30-day retention
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

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

  networking.hostName = lib.mkDefault "euro-office";
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
      22   # SSH
      80   # HTTP — Nginx inside the container handles all routing
      # Do NOT open 8000, 9000, 3000, 5432, 6379, 5672 — all internal to container
    ];
  };

  # ============================================================================
  # TIME ZONE
  # ============================================================================

  time.timeZone = lib.mkDefault "UTC";

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
    jq
    openssl
  ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================

  nix.settings.trusted-users = [ "root" "@wheel" ];  # Allow remote deployments
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
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.euro-office-init-secrets = {
    description = "Generate Euro-Office JWT secret if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];  # Ensure /etc is mounted before writing secrets

    # Only run once — skip if the secrets file already exists
    unitConfig.ConditionPathExists = "!/etc/secrets/euro-office.env";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "euro-office-init-secrets" ''
        # Generate a 64-character hex JWT secret
        JWT_SECRET="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        # Create secrets directory
        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets

        # Write the secrets env file
        cat > /etc/secrets/euro-office.env <<EOF
JWT_SECRET=$JWT_SECRET
EOF
        ${pkgs.coreutils}/bin/chmod 600 /etc/secrets/euro-office.env

        echo "================================================"
        echo "Euro-Office JWT_SECRET generated and saved to:"
        echo "/etc/secrets/euro-office.env"
        echo "View anytime: sudo cat /etc/secrets/euro-office.env"
        echo "================================================"
      '';
    };
  };

  # ============================================================================
  # CONTAINER RUNTIME
  # ============================================================================

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # EURO-OFFICE CONTAINER
  # ============================================================================

  virtualisation.oci-containers.containers."euro-office" = {
    # Pinned to the latest stable Euro-Office DocumentServer release (v9.3.1,
    # 2026-06-09). Immutable semver tag — NOT :latest/:nightly (mutable, unfit
    # for declarative). Runtime-verified on 2026-06-10: starts clean,
    # /healthcheck=200, /web-apps api.js=200. Keep in sync with update.sh.
    image = "ghcr.io/euro-office/documentserver:v9.3.1";

    environment = {
      ALLOW_PRIVATE_IP_ADDRESS = "true";
      EXAMPLE_ENABLED          = "false";
      ADMINPANEL_ENABLED       = "true";
    };

    # Secrets (JWT_SECRET) loaded from the auto-generated env file
    environmentFiles = [ "/etc/secrets/euro-office.env" ];

    ports = [
      "80:80"  # Host 80 → container Nginx 80
    ];

    volumes = [
      "/var/lib/euro-office/data:/var/www/onlyoffice/Data"  # Persistent document storage
    ];
  };

  # Ensure the container starts only after secrets have been generated
  systemd.services."podman-euro-office" = {
    requires = [ "euro-office-init-secrets.service" ];
    after    = [ "euro-office-init-secrets.service" ];
  };

  # ============================================================================
  # BACKUP STRATEGY — Daily volume snapshot
  # ============================================================================
  #
  # All state (PostgreSQL, Redis, documents) lives inside the container volume.
  # Strategy: stop container → tar the data directory → restart container.
  # Run daily at 02:00; clean up backups older than 30 days monthly.

  systemd.services.euro-office-backup = {
    description = "Euro-Office daily volume backup";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "euro-office-backup" ''
        set -euo pipefail

        BACKUP_DIR="/var/backup/euro-office"
        TIMESTAMP="$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S)"
        ARCHIVE="$BACKUP_DIR/euro-office-data-$TIMESTAMP.tar.gz"

        ${pkgs.coreutils}/bin/mkdir -p "$BACKUP_DIR"

        echo "Stopping euro-office container for consistent snapshot..."
        ${pkgs.podman}/bin/podman stop euro-office || true

        echo "Archiving /var/lib/euro-office/data to $ARCHIVE ..."
        ${pkgs.gnutar}/bin/tar -czf "$ARCHIVE" -C /var/lib/euro-office data

        ${pkgs.coreutils}/bin/chmod 600 "$ARCHIVE"

        echo "Restarting euro-office container..."
        ${pkgs.podman}/bin/podman start euro-office || true
        echo "Backup complete: $ARCHIVE"
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.euro-office-backup = {
    description = "Daily Euro-Office volume backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;  # Run missed backups on boot
    };
  };

  # Cleanup backups older than 30 days (monthly)
  systemd.services.euro-office-cleanup-backups = {
    description = "Cleanup old Euro-Office backups";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "euro-office-cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup/euro-office -type f -mtime +30 -delete
      '';
      User = "root";
    };
  };

  systemd.timers.euro-office-cleanup-backups = {
    description = "Monthly cleanup of old Euro-Office backups";
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
    "d /var/lib/euro-office/data  0700 root root -"  # Persistent document volume
    "d /var/backup/euro-office    0700 root root -"  # Backup destination
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # See: https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion
  # ============================================================================

  system.stateVersion = "25.05";
}
