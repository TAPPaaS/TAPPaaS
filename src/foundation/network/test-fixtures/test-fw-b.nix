# Firewall test VM B — client/server in test_allow_b zone.
#
# Imports the test-fw-webserver overlay (shared with test-fw-a) and pins the
# port to 9090 to match test-fw-b.json's ports[] declaration.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
    ./test-fw-webserver.nix
  ];

  networking.hostName = "test-fw-b";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

  tappaas.test = {
    webserverPort = 9090;
    marker = "tappaas-firewall-test-b-ok";
  };

  system.stateVersion = "25.05";
}
