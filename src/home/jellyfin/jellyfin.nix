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
# Storage: the media library is NOT in this VM. /media is the subdir jellyfin
# of the share "media" (pvehost:nfs, ADR-029 v0.8), mounted by name as
# nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin — the site's server
# declares the share, jellyfin.json the mount, and the service writes it into
# /etc/nixos/tappaas-nfs.nix, which the baseline imports. Until a server
# declares "media" the mount is pending and /media is a directory on this VM's
# own disk; when the share arrives the service migrates its content in
# (rebootOk in jellyfin.json is the consent). The VM
# stays small (OS + Jellyfin's own data on tanka1); the library has its own
# lifecycle and survives the VM.
#
# Library folders under /media (created by update.sh, on the share or locally —
# on the share every write is squashed to its owner, so tmpfiles could not
# chown them to jellyfin anyway):
#   Movies/  TV/  Music/  Photos/  Audiobooks/
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
    allowedTCPPorts = [ 22 8096 8920 ];
  };

  # -- SSH: keys only (the baseline's defaults allow passwords) ----------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Packages --------------------------------------------------------------
  # vim, wget, curl, htop and git come from the baseline.
  # NFS client support comes with the mount (tappaas-nfs.nix).
  environment.systemPackages = with pkgs; [ jq ];

  # -- Jellyfin media server -------------------------------------------------
  services.jellyfin = {
    enable    = true;
    openFirewall = true;
    dataDir   = "/var/lib/jellyfin";
    cacheDir  = "/var/cache/jellyfin";
  };

  # -- VAAPI hardware transcoding --------------------------------------------
  hardware.graphics.enable = true;
  users.users.jellyfin.extraGroups = [ "render" "video" ];

  system.stateVersion = "25.05";
}
