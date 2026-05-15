# Firewall test VM B — client/server in test2 zone.
#
# Imports the test-fw-webserver overlay (shared with test-fw-a) and pins the
# port to 9090 to match test-fw-b.json's ports[] declaration.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    ./test-fw-webserver.nix
  ];

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = "test-fw-b";
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
    webserverPort = 9090;
    marker = "tappaas-firewall-test-b-ok";
  };

  system.stateVersion = "25.05";
}
