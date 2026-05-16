# Firewall test VM C — webserver in test3 zone.
#
# Mirrors test-fw-a but listens on 9091 and serves a different marker so the
# auto-pinhole (#173) live test can distinguish reaching test-fw-c from any
# stray hit on test-fw-a.
#
# The shared webserver overlay lives one directory up; we import it via a
# relative path because copy-update-json.sh keeps the original on-disk layout.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    ../test-fw-webserver.nix
  ];

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = "test-fw-c";
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
    webserverPort = 9091;
    marker = "tappaas-firewall-test-c-ok";
  };

  system.stateVersion = "25.05";
}
