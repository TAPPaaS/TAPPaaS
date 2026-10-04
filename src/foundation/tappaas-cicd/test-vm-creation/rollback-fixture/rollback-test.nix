# rollback-test fixture VM — minimal NixOS config (#307).
# Throwaway VM used by test-rollback.sh to verify update-module.sh snapshot
# rollback. Only requirement beyond a bootable system: the QEMU guest agent,
# which the fixture scripts use (qm guest exec) to read/write the health sentinel.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "rollback-test";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

  system.stateVersion = "25.05";
}
