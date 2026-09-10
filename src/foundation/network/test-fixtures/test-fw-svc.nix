# Source-NAT test VM — the CLIENT, in the default environment's zone.
#
# Deliberately not the mothership. mgmt reaches everywhere by design, so a test
# driven from there would prove nothing about a *client* zone reaching an IoT
# device — and the zone whose traffic ADR-016 masquerades is the environment's
# own service zone, not the control plane.
#
# Its zone0 is written at install time from site.json's defaultEnvironment, so
# this fixture carries no site-specific zone name.

{ config, lib, pkgs, modulesPath, system, ... }:

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

  networking.hostName = "test-fw-svc";
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

  # curl is the probe; the test greps its exit code to tell a timeout (device
  # dropped us) from a refusal (nothing listening) from success.
  environment.systemPackages = with pkgs; [ curl ];

  system.stateVersion = "25.05";
}
