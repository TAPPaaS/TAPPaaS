# rollback-test fixture VM — minimal NixOS config (#307).
# Throwaway VM used by test-rollback.sh to verify update-module.sh snapshot
# rollback. Only requirement beyond a bootable system: the QEMU guest agent,
# which the fixture scripts use (qm guest exec) to read/write the health sentinel.

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

  networking.hostName = "rollback-test";
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

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  services.qemuGuest.enable = true;
  boot.growPartition = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    vim wget curl htop git jq
  ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  system.stateVersion = "25.05";
}
