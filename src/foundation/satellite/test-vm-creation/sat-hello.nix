# ----------------------------------------
# sat-hello — disposable ADR-010 test VM.
#
# Minimal nginx serving a plaintext OK page on :80, so network:proxy can bind
# the wildcard cert and publish sat-hello.<env>.tapaas.org through the satellite.
# Kept as close as possible to the TAPPaaS NixOS baseline (00-Template/template.nix)
# — including zramSwap + systemd-oomd (issue #323) so nixos-rebuild does not OOM
# on a small VM — with only an nginx service added. Safe to delete.
# ----------------------------------------

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports =
    [
      /etc/nixos/hardware-configuration.nix
      # The TAPPaaS NixOS baseline every VM shares (#324).
      /etc/nixos/tappaas-common.nix
    ];

  # Network
  networking.hostName = lib.mkDefault "sat-hello";

  # Essential Services
  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # ── The actual test payload: a trivial web server on :80 ────────────────
  services.nginx = {
    enable = true;
    virtualHosts."sat-hello" = {
      default = true;
      locations."/" = {
        extraConfig = ''
          default_type text/plain;
          return 200 "sat-hello OK — ADR-010 satellite HTTPS path works\n";
        '';
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ 80 ];

  system.stateVersion = "25.05";
}
