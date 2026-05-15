# Test webserver overlay for firewall test VMs (test-fw-a, test-fw-b).
#
# Imported by both test-fw-a.nix and test-fw-b.nix to provide a minimal
# HTTP server returning a marker string. The port is parameterised via the
# `tappaas.test.webserverPort` option so the same module works for both VMs.
#
# This file is consumed by firewall/test.sh --deep and ships as part of the
# firewall foundation module (not the production-app set).

{ config, lib, pkgs, ... }:

let
  cfg = config.tappaas.test;
in
{
  options.tappaas.test = {
    webserverPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the test webserver listens on.";
    };
    marker = lib.mkOption {
      type = lib.types.str;
      default = "tappaas-firewall-test-ok";
      description = "String served on /; test.sh greps for this exact value to confirm reachability.";
    };
  };

  config = {
    # Open the configured port on the VM-local firewall (not OPNsense) so the
    # webserver is reachable from other zones once OPNsense rules permit it.
    networking.firewall.allowedTCPPorts = [ cfg.webserverPort ];

    # Static document root containing the marker string.
    environment.etc."tappaas-test-www/index.html".text = ''
      ${cfg.marker}
    '';

    systemd.services.tappaas-test-webserver = {
      description = "TAPPaaS firewall test webserver (port ${toString cfg.webserverPort})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString cfg.webserverPort} --directory /etc/tappaas-test-www --bind 0.0.0.0";
        Restart = "on-failure";
        RestartSec = "5s";
        DynamicUser = true;
        ReadOnlyPaths = [ "/etc/tappaas-test-www" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };
  };
}
