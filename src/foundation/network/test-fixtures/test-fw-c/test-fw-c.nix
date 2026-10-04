# Firewall test VM C — webserver in the test-pinhole zone.
#
# Listens on 9091 and serves a distinct marker so the auto-pinhole (#173) live
# test can tell reaching test-fw-c apart from a stray hit on test-fw-a.
#
# SELF-CONTAINED (no cross-directory import). test-fw-c lives in its own subdir,
# and update-os.sh only copies same-directory sibling .nix files to the VM — a
# parent-relative `../test-fw-webserver.nix` import resolved to a non-existent
# /etc/test-fw-webserver.nix and broke nixos-rebuild (historical defect 2 —
# investigation log in git history: network/ISSUES/deep-test-trunk-and-nixbuild.md).
# The webserver is inlined here. See also TEST.md's fixture guidance.

{ config, lib, pkgs, modulesPath, system, ... }:

let
  webserverPort = 9091;
  marker = "tappaas-firewall-test-c-ok";
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "test-fw-c";

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

  # Inlined test webserver (was the shared test-fw-webserver.nix overlay).
  networking.firewall.allowedTCPPorts = [ webserverPort ];
  environment.etc."tappaas-test-www/index.html".text = "${marker}\n";

  systemd.services.tappaas-test-webserver = {
    description = "TAPPaaS firewall test webserver (port ${toString webserverPort})";
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
