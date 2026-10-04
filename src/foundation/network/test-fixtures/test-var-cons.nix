# Variant E2E test CONSUMER — minimal self-contained NixOS VM. It exists only to
# exercise variant dependency resolution (dependsOn test-var-prov:svc); no
# webserver/proxy needed.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [ /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-var-cons";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  system.stateVersion = "25.05";
}
