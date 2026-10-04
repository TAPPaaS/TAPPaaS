# Firewall test VM A — webserver in test_allow_a zone.
#
# Imports the test-fw-webserver overlay (shared with test-fw-b) and pins the
# port to 8080 to match test-fw-a.json's ports[] declaration.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
    ./test-fw-webserver.nix
  ];

  networking.hostName = "test-fw-a";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

  tappaas.test = {
    webserverPort = 8080;
    marker = "tappaas-firewall-test-a-ok";
  };

  system.stateVersion = "25.05";
}
