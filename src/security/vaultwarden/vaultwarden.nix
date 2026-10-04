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
    # The TAPPaaS NixOS baseline every VM shares (#324): ssh, cloud-init, the
    # tappaas user, nix settings, zram/oomd, the NIC and hostname fixes, and the
    # site's own time and locale (it imports tappaas-site.nix). update-os.sh ships
    # it before every rebuild; this file states only what the module adds.
    /etc/nixos/tappaas-common.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    # Always present: update-os.sh ships an empty one, and backup:filesystem
    # overwrites it with the real trigger.
    /etc/nixos/tappaas-backup.nix
  ];

  # ============================================================================
  # NETWORKING
  # ============================================================================

  networking.hostName = let
    cfg = if builtins.pathExists ./vaultwarden.json
          then builtins.fromJSON (builtins.readFile ./vaultwarden.json)
          else {};
  in lib.mkDefault (cfg.vmname or "vaultwarden");

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

  # No time zone here: it is the site's fact, not the module's (#472). It
  # arrives through /etc/nixos/tappaas-site.nix, which the baseline imports.

  # ============================================================================
  # SYSTEM PACKAGES
  # ============================================================================

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq openssl ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # ============================================================================
  # ESSENTIAL SERVICES
  # ============================================================================

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

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
  #
  # It also runs at boot, and on a fresh VM that is before vaultwarden has
  # written anything: its `cp /var/lib/vaultwarden/!(db.*)` matches nothing and
  # fails, so the first activation fails and the install rolls back (hrossen,
  # 2026-10-04). Nothing to back up yet is not a failure: wait for the database.
  # No ordering added: upstream already starts vaultwarden after this backup,
  # and `after = vaultwarden` closed a cycle systemd broke by dropping the job.
  systemd.services.backup-vaultwarden.unitConfig.ConditionPathExists =
    "/var/lib/vaultwarden/db.sqlite3";

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
