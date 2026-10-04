# Standalone Caddy-public test webserver (Option B, ADR-005 #316).
#
# A small NixOS HTTP server returning a marker string on port 8080. Deliberately
# SELF-CONTAINED — no cross-directory `imports` — so update-os.sh copies it to the
# VM cleanly (avoids the parent-import nix-build failure; investigation log in git
# history: network/ISSUES/deep-test-trunk-and-nixbuild.md). Used by
# firewall/test-caddy-public.sh. See also TEST.md's fixture guidance.

{ config, lib, pkgs, modulesPath, system, ... }:

let
  webserverPort = 8080;
  marker = "tappaas-caddy-public-ok";
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-caddy-web";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # Open the webserver port on the VM-local firewall (OPNsense pinholes are
  # handled by network:rules from the module's ingress declaration).
  networking.firewall.allowedTCPPorts = [ webserverPort ];

  environment.etc."tappaas-test-www/index.html".text = "${marker}\n";

  systemd.services.tappaas-caddy-web = {
    description = "TAPPaaS Caddy-public test webserver (port ${toString webserverPort})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString webserverPort} --directory /etc/tappaas-test-www --bind 0.0.0.0";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      ReadOnlyPaths = [ "/etc/tappaas-test-www" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  system.stateVersion = "25.05";
}
