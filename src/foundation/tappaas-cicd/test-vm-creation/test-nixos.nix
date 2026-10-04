# Test NixOS VM - mgmt zone on tappaas1
# This is a minimal test configuration for validating NixOS clone creation

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-nixos";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

  system.stateVersion = "25.05";
}
