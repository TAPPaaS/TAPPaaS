# Identity forward-auth test webserver — identity/test.sh --deep.
#
# A small NixOS HTTP server returning a marker on port 8080. SELF-CONTAINED (no
# cross-directory imports) so update-os.sh copies it to the VM cleanly. With
# identity:accessControl wired, Authentik gates the public URL: an unauthenticated
# request is redirected to the Authentik login and NEVER sees this marker — that
# difference is what the deep test asserts.

{ config, lib, pkgs, modulesPath, system, ... }:

let
  webserverPort = 8080;
  marker = "tappaas-idfa-ok";
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-idfa";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  networking.firewall.allowedTCPPorts = [ webserverPort ];
  environment.etc."tappaas-test-www/index.html".text = "${marker}\n";

  systemd.services.tappaas-idfa-web = {
    description = "TAPPaaS identity forward-auth test webserver (port ${toString webserverPort})";
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
