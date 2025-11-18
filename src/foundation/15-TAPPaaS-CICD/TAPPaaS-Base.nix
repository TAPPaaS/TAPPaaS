# ----------------------------------------
# Version: 1.0.0 – tappaas PVE VM Template
# State: Released
# Date: 2025-10-16
# Author: Erik, Lars (Tappaas)
# Purpose: 
#     Declarative common baseline NIXOS VM Template for all tappaas pve-nixos-vm 
#
#     Edit this configuration file to define what should be installed on
#     your system. Help is available in the configuration.nix(5) man page, on
#     https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
#
# ✅ **Automated provisioning** via cloud-init
# ✅ **Consistent base system** across all clones  
# ✅ **CICD integration** with SSH key authentication
# ✅ **Scalable resources** post-deployment
# ✅ **QEMU integration** for proper Proxmox management
# ✅ **Security hardening** with minimal attack surface
#
# Modules:
#     openssh  
#     QEMU   
#
# ----------------------------------------

{ config, lib, pkgs, modulesPath, system, ... }:

{
  imports =
    [ # Note we are not doing hardware includes
      (modulesPath + "/virtualisation/proxmox-image.nix")
    ];

  proxmox.cloudInit = {
      enable = false;
      defaultStorage="local-zfs";
  };

  # Cloud-init
  # services.cloud-init = {
  #       enable = true;
  #       network.enable = true;
  #
  # };

  # Use the systemd-boot EFI boot loader.
  boot.loader.grub.enable = lib.mkDefault true; # Use the boot drive for GRUB
  boot.loader.grub.devices = [ "nodev" ];

  # Network
  networking.hostName = lib.mkDefault "tappaas-cicd"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # Users
  users.users.tappaas = {
        isNormalUser = true;
  #      password = "tappaas"; # uncomment only for testing ssh connections
        extraGroups = [ "wheel" "networkmanager" ];
        openssh.authorizedKeys.keys = [
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDhNBiriC5vajtn1xvVuVJ9uvyfZ/DOTkCoREDaSWs1UYOhYBhwu4oH3Gqect1dlKO4zfVuOfK0eE5CgwHlc77/aZLLn6LpJeo0raIX3H4G3bKMQxj2O3F3aq54IxzROg+qZ5RD/VXW1havkbOiXOjvJEMc6asUjH33PdQLJyjbOdCjQTKDbPiZ+TNBbkz3jaKJImLhDsYEdubVUJ+MemCRspEXvzuWGFUoQ+cltHvBMeF7oSY6CGkY35dMWRV53J54P1D3/Xj9/R82ZHClXQWsO+IuWlqPEF0ZfJJtwKGqBJ3Ap91nNr3UhAqorYvzjhCAdTj9UvB2RMkNdub6RAIg383ujcMN62gfMqvxS9bQmKHDVPBaFPX0wWBtFkPWazmVG4gIypuwz7fAB2oIRpGCEhyMBrdW006fD/+F1BejjinC3SCje1+NIuRA42fjzna6kSAQGqeXqbvyJGRU0Y0HKi4vjfXp+gjaCQtvdJ7WJXYnbLMH3b7d+8FeOYQBHA5vktLDx1EXnd1EbHfMcZ73e4Hn+HomsZR4XyGTgbKzg5IjBPpIpXFk+4KnEPqei+03XsDhN0nwpngbIT3rJkVPkTgUZ58Fs30ucsvgqM5XI5YeRenys46IUcTqTOFh0faS1KwWV3de18AbZZY95WJpxjpFGxNIax1uuDGepJ9nZQ== root@tappaas1"
        ];
  };

  # Enable passwordless sudo for tappaas
  security.sudo.wheelNeedsPassword = false;

  # Essential Services
  services.openssh = {
        enable = true;
        settings = {
                PasswordAuthentication = false;
                PermitRootLogin = "no";
        };
  };
  programs.ssh.startAgent = true;


  # 
  nix.settings.trusted-users = [ "root" "@wheel" ]; # Allow remote updates
  nix.settings.experimental-features = [ "nix-command" "flakes" ]; # Enable flakes

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  # QEMU Guest Agent
  services.qemuGuest.enable = true;

  # Auto-grow root partition
  boot.growPartition = lib.mkDefault true;

  # System packages
  environment.systemPackages = with pkgs; [
        vim
        wget
        curl
        htop
        git
  ];

  # Enable automatic garbage collection
  nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
  };



  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:


  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05";

}