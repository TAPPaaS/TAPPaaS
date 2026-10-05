# ----------------------------------------
# Author: Erik, Lars (Tappaas)
# Purpose:
#     Starting point for a TAPPaaS module's NixOS configuration. Copy it to
#     <module>.nix and add what the module runs.
#
#     Everything every TAPPaaS VM has — ssh, cloud-init, the tappaas user,
#     nix settings, NetworkManager, zram/oomd, the site's time and locale — is
#     the baseline, templates/tappaas-common.nix, imported below. Do not restate
#     it here: a copy drifts, and a copy with another value fails the build
#     (#324). scripts/nixos-baseline-eval.sh checks a module against it.
#
#     Help is available in the configuration.nix(5) man page, on
#     https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
#
# ----------------------------------------

{ config, lib, pkgs, modulesPath, system, ... }:

{
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

  networking.hostName = lib.mkDefault "test-nfsconsumer"; # Define your hostname.

  # No time zone here: it is the site's fact, not the module's (#472). It
  # arrives through /etc/nixos/tappaas-site.nix, which the baseline imports.

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # Firewall: explicit, as every TAPPaaS module declares it (canon C7, #390).
  # SSH is the one port every guest needs; a module adds its own service ports
  # here (allowedTCPPorts / allowedUDPPorts are lists, so they merge). Who may
  # reach those ports is the site's decision, made by network:rules.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # Packages beyond the baseline's (vim, wget, curl, htop, git), if any:
  # The deep suite's writer: holds a file open under the first mount, so a
  # migration must stop it (stopUnits) and the open-files guard has something to
  # catch when it is not stopped (ADR-029 D14).
  systemd.services.nfs-deep-writer = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.bash}/bin/bash -c 'mkdir -p /srv/deep/a; exec 3>>/srv/deep/a/writer.log; while sleep 5; do date >&3; done'";
  };

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05";

}
