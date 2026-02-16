# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# ----------------------------------------
# TAPPaaS
# Name: UniFi Network Controller
# Type: APP
# Version: 0.9.0 
# Date: 2026-02-09
# Author: @ErikDaniel007 (Tappaas)
# Products: unifi
# ----------------------------------------

{ config, pkgs, lib, ... }:

let
  versions = {
    unifi = "10.0.162";
  };
in
{
  imports = [ /etc/nixos/hardware-configuration.nix ];

  # === Core Boot Config ===
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;  # Auto-resize after PVE disk expansion

  system.stateVersion = "25.05";

  # === Networking ===
  networking = {
    hostName = lib.mkDefault "unifi";
    networkmanager.enable = true;
    # Match ethernet by type, not interface name (ens18/eth0/enp0s18 varies)
    networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
      connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
      ipv4 = { method = "auto"; };
      ipv6 = { method = "auto"; addr-gen-mode = "default"; };
    };
    firewall.allowedTCPPorts = [ 
      22    # SSH
      8080  # Controller HTTP (device communication)
      8443  # Controller HTTPS (admin UI)
      8880  # Guest portal HTTP redirect
      8843  # Guest portal HTTPS
      6789  # Mobile app access
    ];
    firewall.allowedUDPPorts = [ 
      3478   # STUN (device discovery)
      10001  # Device discovery
    ];
  };

  # Disable systemd-networkd (NetworkManager handles networking)
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  # === PVE Integration ===
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";  # Maintain PVE console access
  };

  services.qemuGuest.enable = true;  # VM-host communication
  services.cloud-init = {
    enable = true;
    network.enable = false;  # NetworkManager handles networking
  };

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # === Users & Security ===
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.bash;
  };

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  programs.ssh.startAgent = true;

  # === UniFi Controller Service ===
  services.unifi = {
    enable = true;
    unifiPackage = pkgs.unifi;
    openFirewall = true;  # Redundant with manual firewall config above, kept for clarity
  };

  # === Backup Configuration ===
  systemd.tmpfiles.rules = [
    "d /var/backup/unifi 0700 unifi unifi -"
  ];

  systemd.services.unifi-backup = {
    description = "UniFi controller data backup";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "unifi-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/unifi/unifi-$(date +%F).tar.gz \
          -C /var/lib/unifi data
      '';
      User = "unifi";
    };
  };

  systemd.timers.unifi-backup = {
    description = "Daily UniFi backup at 02:00";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:00:00";
    timerConfig.Persistent = true;  # Run missed backups on boot
  };

  systemd.services.cleanup-backups = {
    description = "Remove backups older than 30 days";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup -type f -mtime +30 -delete
      '';
      User = "root";
    };
  };

  systemd.timers.cleanup-backups = {
    description = "Monthly backup cleanup";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "monthly";
    timerConfig.Persistent = true;
  };

  # === System Packages ===
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    git
  ];

  # === Nix Configuration ===
  nix.settings.trusted-users = [ "root" "@wheel" ];  # Allow remote deploys
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config = {
    allowUnfree = true;  # UniFi controller is unfree software
    permittedInsecurePackages = [
      "mongodb-7.0.25"  # CVE-2025-14847 - TODO: remove when patched upstream
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  system.autoUpgrade = {
    enable = false;  # Manual upgrades recommended for production
    dates = "weekly";
    allowReboot = false;
  };
}