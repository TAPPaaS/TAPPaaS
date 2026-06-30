# Copyright (c) 2026 Gridtefy / TAPPaaS
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - deCONZ Zigbee gateway
# ============================================================================
# Product: deCONZ (Dresden Elektronik) — Zigbee 3.0 gateway for ConBee II.
#          Native nixpkgs service (services.deconz). BSD-3 (core open 2024).
#
# Role in the architecture:
# - Standalone Zigbee engine -> decouples Zigbee from Home Assistant (HA not a
#   SPOF; HA consumes via the official `deconz` integration over the websocket).
# - Native Hue-bridge emulation -> SysAP (free@home) controls lights via the
#   Hue-compat API directly; REPLACES HA emulated_hue. No MQTT broker needed.
#
# Network: srvHome zone (VMID 213, tappaas2). Ports: 22 (SSH), 8080 (REST +
#   Hue-compat API + Phoscon UI), 8443 (websocket), UDP 1900 (SSDP discovery).
# Hardware: ConBee II USB attached to the VM by update.sh (qm set -usb0).
# Backups: covered by the module's backup:vm dependency (full-VM PBS).
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

{
  # ── IMPORTS ────────────────────────────────────────────────────────────────
  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ── BOOT ─────────────────────────────────────────────────────────────────--
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # ── CLOUD-INIT ───────────────────────────────────────────────────────────--
  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # ── NETWORKING ───────────────────────────────────────────────────────────--
  networking.hostName = lib.mkDefault "deconz";
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
      8080  # deCONZ REST + Hue-compat API + Phoscon UI
      8443  # deCONZ websocket (HA deconz integration)
    ];
    allowedUDPPorts = [
      1900  # SSDP discovery (SysAP discovers the Hue-emulated bridge)
    ];
  };

  # ── TIME ─────────────────────────────────────────────────────────────────--
  time.timeZone = lib.mkDefault "UTC";

  # ── USERS & SECURITY ─────────────────────────────────────────────────────--
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "dialout" ];  # dialout = serial (ConBee)
  };
  security.sudo.wheelNeedsPassword = false;

  # ── PACKAGES ─────────────────────────────────────────────────────────────--
  environment.systemPackages = with pkgs; [
    vim wget curl htop git jq usbutils
  ];

  # ── NIX SETTINGS ─────────────────────────────────────────────────────────--
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
  nix.optimise = { automatic = true; dates = [ "weekly" ]; };

  # ── ESSENTIAL SERVICES ───────────────────────────────────────────────────--
  services.qemuGuest.enable = true;
  services.openssh = {
    enable = true;
    settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };
  };
  programs.ssh.startAgent = true;

  # ── deCONZ ─────────────────────────────────────────────────────────────────
  # The ConBee II is attached to this VM by update.sh (qm set -usb0 host=1cf1:0030).
  # `device` MUST be a stable by-id path (NOT /dev/ttyACM0 — renumbers on replug).
  # TODO (deploy): confirm the exact by-id path on this VM with:
  #   ls -l /dev/serial/by-id/   (look for ...ConBee_II_<serial>-if00)
  services.deconz = {
    enable = true;
    device = "/dev/serial/by-id/usb-dresden_elektronik_ingenieurtechnik_GmbH_ConBee_II_DE2149039-if00";
    listenAddress = "0.0.0.0";  # bind all interfaces — default is 127.0.0.1 (localhost only),
                                # which makes HA (8080/8443) and SysAP (8080) unable to reach it.
                                # Smoke-test 2026-06-16 caught this: API was up but loopback-only.
    httpPort = 8080;        # REST + Hue-compat API + Phoscon UI
    wsPort = 8443;          # websocket (HA deconz integration)
    openFirewall = false;   # firewall handled explicitly above (also need UDP 1900)
    allowRestartService = true;  # let the OTA/maintenance flow restart deCONZ via API
  };

  # ── SYSTEM STATE VERSION — DO NOT CHANGE after initial install ──────────────
  system.stateVersion = "25.05";
}
