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
    ./test-fw-webserver.nix
    ./test-fw-subnet-filter.nix
  ];

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = "test-fw-iot";
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

  environment.systemPackages = with pkgs; [ curl jq ];

  tappaas.test = {
    webserverPort = 8080;
    marker = "tappaas-snat-test-iot-ok";
    # Overwritten at install time with the testIot zone CIDR (see test.sh).
    acceptOnlyFrom = "10.4.80.0/24";
  };

  system.stateVersion = "25.05";
}
