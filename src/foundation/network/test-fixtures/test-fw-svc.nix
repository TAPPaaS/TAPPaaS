# Source-NAT test VM — the CLIENT, in the default environment's zone.
#
# Deliberately not the mothership. mgmt reaches everywhere by design, so a test
# driven from there would prove nothing about a *client* zone reaching an IoT
# device — and the zone whose traffic ADR-016 masquerades is the environment's
# own service zone, not the control plane.
#
# Its zone0 is written at install time from site.json's defaultEnvironment, so
# this fixture carries no site-specific zone name.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-fw-svc";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # curl is the probe; the test greps its exit code to tell a timeout (device
  # dropped us) from a refusal (nothing listening) from success.

  system.stateVersion = "25.05";
}
