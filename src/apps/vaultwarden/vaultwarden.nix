# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - VaultWarden Password Manager
# ============================================================================
# Version: 1.0.0
# Date: 2026-02-17
# Author: @ErikDaniel007 (TAPPaaS)
# Product: VaultWarden (Bitwarden-compatible) password manager
#
# Architecture:
# - Native NixOS services.vaultwarden (lightweight, no container)
# - SQLite backend (default, sufficient for SMB/home use)
# - Environment file for secrets (ADMIN_TOKEN, DOMAIN, SMTP)
#
# Network: DMZ zone (VLAN 610, 10.6.0.0/24)
# Firewall: ports 22 (SSH) + 8222 (VaultWarden HTTP)
# Secrets: Auto-generated ADMIN_TOKEN on first boot
# Backups: Daily vault data backup, 30-day retention
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning - change versions here only
  versions = {
    vaultwardenPkg = pkgs.vaultwarden;
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

  networking.hostName = lib.mkDefault "vaultwarden";
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
      8222  # VaultWarden HTTP API
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
    jq
    openssl
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
  # VAULTWARDEN PASSWORD MANAGER
  # ============================================================================

  services.vaultwarden = {
    enable = true;
    package = versions.vaultwardenPkg;
    backupDir = "/var/backup/vaultwarden";

    # Environment file for secrets: ADMIN_TOKEN, DOMAIN, SMTP settings
    # Auto-generated on first boot (see generate-vaultwarden-secrets below)
    environmentFile = "/var/lib/vaultwarden/vaultwarden.env";

    config = {
      SIGNUPS_ALLOWED = false;

      # Listen on all interfaces — accessed via Caddy reverse proxy in DMZ
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = 8222;
      ROCKET_LOG = "critical";

      # DOMAIN, ADMIN_TOKEN, and SMTP_* are set via environmentFile
    };
  };

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.generate-vaultwarden-secrets = {
    description = "Generate VaultWarden secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "vaultwarden.service" ];

    unitConfig.ConditionPathExists = "!/var/lib/vaultwarden/vaultwarden.env";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-vaultwarden-secrets" ''
        ADMIN_TOKEN="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        ${pkgs.coreutils}/bin/mkdir -p /var/lib/vaultwarden
        ${pkgs.coreutils}/bin/chown vaultwarden:vaultwarden /var/lib/vaultwarden

        cat > /var/lib/vaultwarden/vaultwarden.env <<EOF
# VaultWarden secrets - auto-generated on first boot
# Edit DOMAIN and SMTP settings for your deployment
ADMIN_TOKEN=$ADMIN_TOKEN
DOMAIN=https://vaultwarden.example.com

# SMTP configuration - update for your mail server
# See: https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_FROM=vaultwarden@example.com
SMTP_FROM_NAME=TAPPaaS VaultWarden
SMTP_USERNAME=
SMTP_PASSWORD=
EOF
        ${pkgs.coreutils}/bin/chmod 600 /var/lib/vaultwarden/vaultwarden.env
        ${pkgs.coreutils}/bin/chown vaultwarden:vaultwarden /var/lib/vaultwarden/vaultwarden.env

        echo "================================================"
        echo "VAULTWARDEN ADMIN TOKEN generated and saved to:"
        echo "/var/lib/vaultwarden/vaultwarden.env"
        echo "To view: sudo cat /var/lib/vaultwarden/vaultwarden.env"
        echo "================================================"
      '';
    };
  };

  # ============================================================================
  # BACKUP STRATEGY
  # ============================================================================

  # The built-in services.vaultwarden.backupDir enables the upstream backup
  # service which copies the SQLite database to /var/backup/vaultwarden daily.

  # Daily backup archive of vault data + environment (03:00)
  systemd.services.vaultwarden-backup-archive = {
    description = "Archive VaultWarden backup data";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "vaultwarden-backup-archive" ''
        TIMESTAMP=$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S)
        ARCHIVE_DIR="/var/backup/vaultwarden-archives"
        ${pkgs.coreutils}/bin/mkdir -p "$ARCHIVE_DIR"

        ${pkgs.gnutar}/bin/tar -czf "$ARCHIVE_DIR/vaultwarden-backup-$TIMESTAMP.tar.gz" \
          -C / \
          var/backup/vaultwarden \
          var/lib/vaultwarden/vaultwarden.env \
          2>/dev/null || true

        ${pkgs.coreutils}/bin/chmod 600 "$ARCHIVE_DIR/vaultwarden-backup-$TIMESTAMP.tar.gz"
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.vaultwarden-backup-archive = {
    description = "Daily VaultWarden backup archive timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  # Cleanup old backups - 30 day retention
  systemd.services.cleanup-backups = {
    description = "Cleanup old VaultWarden backups";
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
    "d /var/backup/vaultwarden 0700 vaultwarden vaultwarden -"
    "d /var/backup/vaultwarden-archives 0700 root root -"
    "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
