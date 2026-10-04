# Source-NAT test VM — the subnet-filtering "device" in the testIot zone.
#
# Stands in for the Alfen NG5 charger of #239: a webserver that answers only
# callers inside its own /24 and drops everyone else. The deep test proves it
# unreachable from the default environment's zone, applies network:snat, and
# proves it reachable — with nothing on this VM changed between the two.
#
# acceptOnlyFrom is written by network/test.sh at install time from the
# testIot zone's own `ip` in zones.json, so the CIDR is never duplicated here.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
    ./test-fw-webserver.nix
    ./test-fw-subnet-filter.nix
  ];

  networking.hostName = "test-fw-iot";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

  tappaas.test = {
    webserverPort = 8080;
    marker = "tappaas-snat-test-iot-ok";
    # Overwritten at install time with the testIot zone CIDR (see test.sh).
    acceptOnlyFrom = "10.4.80.0/24";
  };

  system.stateVersion = "25.05";
}
