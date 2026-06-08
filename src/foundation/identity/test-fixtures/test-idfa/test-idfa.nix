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
  ];

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = "test-idfa";
  networking.networkmanager.enable = true;

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  programs.ssh.startAgent = true;

  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  services.qemuGuest.enable = true;
  boot.growPartition = lib.mkDefault true;

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
