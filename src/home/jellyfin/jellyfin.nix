# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Jellyfin Media Server
# ============================================================================
# Self-contained NixOS configuration -- used directly as nixos-config by
# update-os.sh during install and subsequent nixos-rebuild switch calls.
#
# Storage architecture (three layers; Layer 1 is selected by the
# "mediaStorage" mode in jellyfin.json — see INSTALL.md → Media Storage):
#   Layer 1 -- Block device:  Proxmox virtual disk (allocate) or an attached
#                             USB/iSCSI disk (attached), presented as
#                             /dev/disk/by-label/jellyfin-media; or a NAS
#                             share mounted directly (share).
#   Layer 2 -- Filesystem:   ext4, created by install-service.sh (allocate)
#                             or setup-media-disk.sh (attached).
#   Layer 3 -- NFS export:   /media exported to srvHome zone so file-service
#                             modules can mount it via jellyfin:storage
#                             (allocate/attached modes only).
#
# Media folder layout under /media:
#   Movies/           Jellyfin library type Movies
#   TV/               Jellyfin library type Shows
#   Music/            Jellyfin library type Music
#   Photos/           Jellyfin library type Photos
#   Audiobooks/       Jellyfin library type Books/Audiobooks
#   downloads/
#     complete/       file-service modules write here (writable via NFS)
#     incomplete/     in-progress downloads (not exported)
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # -- Boot ------------------------------------------------------------------
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # -- Cloud-init ------------------------------------------------------------
  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "jellyfin";
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = {
      id = "tappaas-ethernet";
      type = "ethernet";
      autoconnect = "true";
      autoconnect-priority = "100";
    };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 2049 8096 8920 ];
    allowedUDPPorts = [ 2049 ];
  };

  # -- Time zone -------------------------------------------------------------
  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # -- Users & sudo ----------------------------------------------------------
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # -- SSH -------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  programs.ssh.startAgent = true;

  # -- Essential services ----------------------------------------------------
  services.qemuGuest.enable = true;

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  # -- OOM resilience --------------------------------------------------------
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableUserSlices = true;
  };
  systemd.slices."user-".sliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "80%";
    MemoryHigh = "90%";
    MemoryMax = "95%";
  };

  # -- Nix settings ----------------------------------------------------------
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # -- Packages --------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    vim wget curl htop git jq nfs-utils
  ];

  # -- Jellyfin media server -------------------------------------------------
  services.jellyfin = {
    enable    = true;
    openFirewall = true;
    dataDir   = "/var/lib/jellyfin";
    cacheDir  = "/var/cache/jellyfin";
  };

  # -- Media disk mount ------------------------------------------------------
  # Identified by label so the mount survives disk reordering between reboots.
  # nofail: VM boots normally even before the disk is attached (install order).
  # The block between the media-mount markers is managed by update.sh: with
  # mediaStorage=share in jellyfin.json it is replaced by the declared
  # NFS/CIFS mount at deploy time (edits inside the markers are overwritten
  # in that mode).
  # BEGIN media-mount (managed by update.sh)
  fileSystems."/media" = {
    device  = "/dev/disk/by-label/jellyfin-media";
    fsType  = "ext4";
    options = [ "nofail" "noatime" "x-systemd.automount" "x-systemd.device-timeout=10" ];
  };
  # END media-mount

  # -- Content folder layout -------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /media/Movies               0755 jellyfin jellyfin -"
    "d /media/TV                   0755 jellyfin jellyfin -"
    "d /media/Music                0755 jellyfin jellyfin -"
    "d /media/Photos               0755 jellyfin jellyfin -"
    "d /media/Audiobooks           0755 jellyfin jellyfin -"
    "d /media/downloads            0775 jellyfin jellyfin -"
    "d /media/downloads/complete   0775 jellyfin jellyfin -"
    "d /media/downloads/incomplete 0770 jellyfin jellyfin -"
  ];

  # -- NFS export (provides storage to dependent modules) --------------------
  # anonuid/anongid=993: NFS clients write as the Jellyfin user/group.
  services.nfs.server = {
    enable  = true;
    exports = ''
      /media  10.2.10.0/24(rw,sync,no_subtree_check,all_squash,anonuid=993,anongid=993)
    '';
  };

  # -- VAAPI hardware transcoding --------------------------------------------
  hardware.graphics.enable = true;
  users.users.jellyfin.extraGroups = [ "render" "video" ];

  system.stateVersion = "25.05";
}
