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
    # The TAPPaaS NixOS baseline every VM shares (#324), shipped by update-os.sh
    # before every rebuild; it imports the site's time and locale.
    /etc/nixos/tappaas-common.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    # Always present: update-os.sh ships an empty one, and backup:filesystem
    # overwrites it with the real trigger.
    /etc/nixos/tappaas-backup.nix
  ];

  # Everything a TAPPaaS VM has in common -- boot, cloud-init, NetworkManager,
  # the tappaas user and sudo, ssh, qemu-guest, serial console, zram/oomd, nix
  # settings and gc, the site's time zone -- comes from the baseline (#324).
  # This file states only what jellyfin adds or changes.

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "jellyfin";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 2049 8096 8920 ];
    allowedUDPPorts = [ 2049 ];
  };

  # -- SSH: keys only (the baseline's defaults allow passwords) ----------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Packages --------------------------------------------------------------
  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq nfs-utils ];

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
