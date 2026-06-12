# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - coturn TURN/STUN Server
# ============================================================================
# Version: 1.0.0
# Date: 2026-05-12
# Author: @AndreasJe (TAPPaaS)
# Product: coturn (TURN/STUN relay for Nextcloud Talk WebRTC)
#
# Architecture:
# - Custom systemd service (NOT services.coturn) — secrets loaded at runtime
#   from /etc/secrets/coturn.env; config written to /run/coturn/turnserver.conf
#   at each service start so secrets never appear in the Nix store.
# - No reverse proxy — coturn uses raw UDP/TCP ports directly (3478 + relay range)
# - No database, no Redis
#
# Network: DMZ zone (VMID 341, tappaas1), firewall ports:
#   TCP  22 (SSH), 3478 (TURN/STUN)
#   UDP  3478 (TURN/STUN), 49152-65535 (relay ports)
# Secrets: Auto-generated COTURN_SECRET (64-char hex) on first boot.
#   COTURN_EXTERNAL_IP must be set manually before coturn will relay correctly.
#
# FIRST-BOOT ACTION REQUIRED:
#   Edit /etc/secrets/coturn.env, set COTURN_EXTERNAL_IP=<your public WAN IP>,
#   then run: systemctl restart coturn.service
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  versions = {
    coturnPkg = pkgs.coturn;
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

  networking.hostName = lib.mkDefault "coturn";
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
      3478  # TURN/STUN
    ];
    allowedUDPPorts = [
      3478  # TURN/STUN
    ];
    # Relay port range — required for WebRTC media streams
    allowedUDPPortRanges = [
      { from = 49152; to = 65535; }
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

  users.users.coturn = {
    isSystemUser  = true;
    group         = "coturn";
    description   = "coturn TURN server";
  };
  users.groups.coturn = {};

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
    coturn
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
  # SECRETS AUTO-GENERATION
  # ============================================================================

  # Runs once on first boot to populate /etc/secrets/coturn.env.
  # After generation the operator MUST set COTURN_EXTERNAL_IP and restart coturn.
  systemd.services.coturn-init-secrets = {
    description = "Generate coturn shared secret if missing";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    before      = [ "coturn.service" ];
    unitConfig.ConditionPathExists = "!/etc/secrets/coturn.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "coturn-init-secrets" ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets
        ${pkgs.coreutils}/bin/chmod 700 /etc/secrets

        COTURN_SECRET="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        ${pkgs.coreutils}/bin/install -m 0600 -o root -g root /dev/null /etc/secrets/coturn.env
        printf 'COTURN_SECRET=%s\nCOTURN_EXTERNAL_IP=\n' "$COTURN_SECRET" \
          > /etc/secrets/coturn.env

        echo "================================================"
        echo "coturn secrets generated: /etc/secrets/coturn.env"
        echo ""
        echo "ACTION REQUIRED: Set COTURN_EXTERNAL_IP=<your public WAN IP>"
        echo "in /etc/secrets/coturn.env and restart coturn.service"
        echo ""
        echo "  sudo nano /etc/secrets/coturn.env"
        echo "  sudo systemctl restart coturn.service"
        echo "================================================"
      '';
    };
  };

  # ============================================================================
  # COTURN TURN/STUN SERVER
  # ============================================================================

  # Custom systemd service — does NOT use services.coturn.
  # Reason: services.coturn writes the config at build time and cannot load
  # secrets from /etc/secrets/coturn.env at runtime without embedding them in
  # the Nix store. This service generates /run/coturn/turnserver.conf freshly
  # at each start from the environment file.

  systemd.services.coturn = {
    description = "coturn TURN/STUN relay server";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" "coturn-init-secrets.service" ];
    requires    = [ "coturn-init-secrets.service" ];
    wants       = [ "network-online.target" ];

    serviceConfig = {
      Type            = "simple";
      User            = "coturn";
      Group           = "coturn";
      EnvironmentFile = "/etc/secrets/coturn.env";
      RuntimeDirectory     = "coturn";
      RuntimeDirectoryMode = "0750";
      StateDirectory       = "coturn";
      StateDirectoryMode   = "0750";
      LogsDirectory        = "coturn";
      LogsDirectoryMode    = "0750";

      ExecStartPre = pkgs.writeShellScript "coturn-write-config" ''
        set -euo pipefail

        # Determine local DMZ IP from routing table
        LOCAL_IP=$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null \
          | ${pkgs.gawk}/bin/awk '/src/{print $7; exit}')

        CONFIG_FILE="/run/coturn/turnserver.conf"

        # Base configuration
        cat > "$CONFIG_FILE" <<CONF
listening-port=3478
min-port=49152
max-port=65535
realm=${config.networking.hostName}
use-auth-secret
static-auth-secret=$COTURN_SECRET
no-cli
no-multicast-peers
no-software-attribute
fingerprint
# RFC 1918 + special ranges — deny relay to private/loopback addresses (CRITICAL)
# NOTE: 100.64.0.0/10 (RFC 6598 Shared Address Space) is intentionally NOT blocked —
# mobile carriers use it for 5G CGNAT, so blocking it prevents relay for 5G users.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=240.0.0.0-255.255.255.255
CONF

        # Append external-ip mapping only when the operator has configured it
        if [ -n "$COTURN_EXTERNAL_IP" ]; then
          echo "external-ip=$COTURN_EXTERNAL_IP/$LOCAL_IP" >> "$CONFIG_FILE"
        fi

        ${pkgs.coreutils}/bin/chmod 640 "$CONFIG_FILE"
      '';

      ExecStart = "${versions.coturnPkg}/bin/turnserver -c /run/coturn/turnserver.conf";

      Restart    = "on-failure";
      RestartSec = "5s";

      # Security hardening
      NoNewPrivileges  = true;
      PrivateTmp       = true;
      ProtectSystem    = "strict";
      ReadWritePaths   = [ "/run/coturn" "/var/lib/coturn" "/var/log/coturn" ];
    };
  };

  # ============================================================================
  # BACKUP STRATEGY
  # ============================================================================

  # No database — daily archive of the secrets file only (mode 600)
  systemd.services.coturn-backup-secrets = {
    description = "Daily coturn secrets backup";
    serviceConfig = {
      Type  = "oneshot";
      User  = "root";
      ExecStart = pkgs.writeShellScript "coturn-backup-secrets" ''
        set -euo pipefail

        BACKUP_DIR="/var/backup/coturn"
        TIMESTAMP="$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S)"

        ${pkgs.coreutils}/bin/mkdir -p "$BACKUP_DIR"

        if [ -f /etc/secrets/coturn.env ]; then
          ${pkgs.gnutar}/bin/tar -czf "$BACKUP_DIR/secrets-$TIMESTAMP.tar.gz" \
            -C / etc/secrets/coturn.env
          ${pkgs.coreutils}/bin/chmod 600 "$BACKUP_DIR/secrets-$TIMESTAMP.tar.gz"
        else
          echo "WARNING: /etc/secrets/coturn.env not found, skipping." >&2
        fi
      '';
    };
  };

  systemd.timers.coturn-backup-secrets = {
    description = "Daily coturn secrets backup timer";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
    };
  };

  systemd.services.coturn-cleanup-backups = {
    description = "Monthly cleanup of old coturn backups";
    serviceConfig = {
      Type      = "oneshot";
      User      = "root";
      ExecStart = pkgs.writeShellScript "coturn-cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup/coturn -type f -mtime +30 -delete
      '';
    };
  };

  systemd.timers.coturn-cleanup-backups = {
    description = "Monthly cleanup of old coturn backups";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /var/backup/coturn  0700 root root -"
    "d /etc/secrets        0700 root root -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION — DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
