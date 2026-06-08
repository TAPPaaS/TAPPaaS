# Variant E2E test CONSUMER — minimal self-contained NixOS VM. It exists only to
# exercise variant dependency resolution (dependsOn test-var-prov:svc); no
# webserver/proxy needed.

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports = [ /etc/nixos/hardware-configuration.nix ];

  services.cloud-init = { enable = true; network.enable = false; };
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = "test-var-cons";
  networking.networkmanager.enable = true;
  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  users.users.tappaas = { isNormalUser = true; extraGroups = [ "wheel" "networkmanager" ]; };
  security.sudo.wheelNeedsPassword = false;
  services.openssh = { enable = true; settings = { PasswordAuthentication = false; PermitRootLogin = "no"; }; };
  programs.ssh.startAgent = true;

  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  services.qemuGuest.enable = true;
  boot.growPartition = lib.mkDefault true;

  system.stateVersion = "25.05";
}
