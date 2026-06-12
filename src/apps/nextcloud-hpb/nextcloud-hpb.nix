# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - nextcloud-hpb
# ============================================================================
# Version: 0.1.0
# Date: 2026-05-14
# Author: @AndreasJe (TAPPaaS)
# Product: nextcloud-spreed-signaling (Talk High-Performance Backend)
#
# Architecture:
# - services.nextcloud-spreed-signaling (Go 2.1.1, from nixpkgs)
# - NATS loopback (in-process — no external NATS needed for single node)
# - Listens on 0.0.0.0:8080; Caddy on OPNsense proxies wss:// to this port
# - Secrets auto-generated in /var/lib/nextcloud-hpb/secrets/ on first boot
# - coturn TURN secret written by install.sh after VM creation
#
# Network: srv zone (VMID 342, tappaas2), proxyDomain: see nextcloud-hpb.json
# Firewall: TCP 22 (SSH) + 8080 (HPB WebSocket, proxied by Caddy)
#
# Nextcloud integration:
#   install.sh writes HPB_SECRET to /etc/secrets/hpb.env on the Nextcloud VM.
#   The nextcloud-configure-hpb.service in nextcloud.nix picks it up on next boot.
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # coturnHost and nextcloudUrl are runtime values — written into
  # /etc/secrets/coturn.env and /etc/secrets/nextcloud-hpb.env by
  # the respective module install.sh scripts. Read as env vars below.
  secretsDir = "/var/lib/nextcloud-hpb/secrets";
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

  networking.hostName = lib.mkDefault "nextcloud-hpb";
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
      8080  # HPB WebSocket (proxied by Caddy on OPNsense)
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
  #
  # Runs once on first boot to create all signing/encryption secrets for the
  # signaling server. The TURN relay secret is NOT generated here — it is
  # written by install.sh after reading it from the coturn VM, ensuring both
  # sides share the same HMAC secret.

  systemd.tmpfiles.rules = [
    "d ${secretsDir} 0700 nextcloud-spreed-signaling nextcloud-spreed-signaling -"
    "d /etc/secrets  0700 root root -"
  ];

  systemd.services.hpb-init-secrets = {
    description = "Generate nextcloud-hpb secrets if missing";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
    before      = [ "nextcloud-spreed-signaling.service" ];
    unitConfig.ConditionPathExists = "!${secretsDir}/hpb-secret";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "hpb-init-secrets" ''
        set -euo pipefail

        DIR="${secretsDir}"

        # Session keys — used to sign and encrypt WebSocket session cookies
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/session-hashkey"   # 64-char hex = 32 bytes
        ${pkgs.openssl}/bin/openssl rand -hex 16 > "$DIR/session-blockkey"  # 32-char hex = 16 bytes

        # Internal client secret — used by internal services contacting the signaling server
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/internalsecret"

        # Shared secret between this HPB and the Nextcloud backend
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/hpb-secret"

        # TURN API key — protects the TURN credential REST endpoint (for MCU use)
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/turn-apikey"

        # TURN relay secret — placeholder until install.sh writes the real coturn secret.
        # The signaling server starts with this placeholder; install.sh overwrites it
        # with the actual COTURN_SECRET and restarts the service.
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/turn-secret"

        ${pkgs.coreutils}/bin/chown -R nextcloud-spreed-signaling:nextcloud-spreed-signaling "$DIR"
        ${pkgs.coreutils}/bin/chmod 400 "$DIR"/*

        echo "HPB secrets generated at ${secretsDir}"
      '';
    };
  };

  # ============================================================================
  # NEXTCLOUD SPREED SIGNALING SERVER
  # ============================================================================

  services.nextcloud-spreed-signaling = {
    enable = true;

    settings = {
      # Listen on all interfaces so Caddy (on OPNsense) can proxy to this VM
      http.listen = "0.0.0.0:8080";

      # In-process NATS — no external NATS server needed for a single HPB node
      # Switch to nats://localhost:4222 when adding a second HPB node
      nats.url = [ "nats://loopback" ];

      sessions = {
        hashkeyFile  = "${secretsDir}/session-hashkey";
        blockkeyFile = "${secretsDir}/session-blockkey";
      };

      clients.internalsecretFile = "${secretsDir}/internalsecret";

      turn = {
        # TURN servers: coturn hostname derived from install.sh at deploy time.
        # install.sh overwrites this config via nixos-rebuild with the actual host.
        # Default points to co-deployed coturn in same TAPPaaS cluster.
        servers = [
          "turn:coturn.dmz.internal:3478?transport=udp"
          "turn:coturn.dmz.internal:3478?transport=tcp"
        ];
        apikeyFile = "${secretsDir}/turn-apikey";
        # install.sh writes the real COTURN_SECRET here; placeholder generated on first boot
        secretFile = "${secretsDir}/turn-secret";
      };
    };

    backends.nextcloud = {
      # Nextcloud URL: install.sh sets the actual URL via nixos-rebuild.
      # Default: internal hostname of co-deployed nextcloud in same zone.
      urls      = [ "https://nextcloud.srv_work.internal" ];
      secretFile = "${secretsDir}/hpb-secret";
    };
  };

  # Ensure secrets exist before the signaling service starts
  systemd.services.nextcloud-spreed-signaling = {
    after    = [ "hpb-init-secrets.service" ];
    requires = [ "hpb-init-secrets.service" ];
  };

  # ============================================================================
  # SYSTEM STATE VERSION — DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
