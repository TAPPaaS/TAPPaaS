# Variant E2E test PROVIDER webserver — self-contained (no cross-dir import), so
# update-os.sh copies it to the VM cleanly. Serves a marker on :8080.

{ config, lib, pkgs, modulesPath, system, ... }:

let
  webserverPort = 8080;
  marker = "tappaas-var-prov-ok";
in
{
  imports = [ /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-var-prov";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  networking.firewall.allowedTCPPorts = [ webserverPort ];
  environment.etc."tappaas-test-www/index.html".text = "${marker}\n";

  systemd.services.tappaas-var-prov = {
    description = "TAPPaaS variant-test provider webserver";
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
