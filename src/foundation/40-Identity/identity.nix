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
    [ 
      /etc/nixos/hardware-configuration.nix
    ];

  services.cloud-init = {
        enable = true;
        network.enable = false; # We handle networking ourselves with DHCP
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Network
  networking.hostName = lib.mkDefault "tappaas-nixos"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # Users
  users.users.tappaas = {
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" ];
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

  nix.settings.trusted-users = [ "root" "@wheel" ]; # Allow remote updates
  nix.settings.experimental-features = [ "nix-command" "flakes" ]; # Enable flakes
  nixpkgs.config.allowUnfree = true; # Allow unfree packages


  # start tty0 on serial console
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ]; # to start at boot
    serviceConfig.Restart = "always"; # restart when session is closed
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

# TODO: the following service definitions are templates only, they need to be adopted/customized for tappaas use

# password manager vaultwarden
services.vaultwarden = {
    enable = true;
    backupDir = "/var/local/vaultwarden/backup";
    # in order to avoid having  ADMIN_TOKEN in the nix store it can be also set with the help of an environment file
    # be aware that this file must be created by hand (or via secrets management like sops)
    environmentFile = "/var/lib/vaultwarden/vaultwarden.env";
    config = {
        # Refer to https://github.com/dani-garcia/vaultwarden/blob/main/.env.template
        DOMAIN = "https://bitwarden.example.com";
        SIGNUPS_ALLOWED = false;

        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        ROCKET_LOG = "critical";

        # This example assumes a mailserver running on localhost,
        # thus without transport encryption.
        # If you use an external mail server, follow:
        #   https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration
        SMTP_HOST = "127.0.0.1";
        SMTP_PORT = 25;
        SMTP_SSL = false;

        SMTP_FROM = "admin@bitwarden.example.com";
        SMTP_FROM_NAME = "example.com Bitwarden server";
    };
};

  # Identity Management - Authentik
  #  services.authentik = {
  #    enable = true;
      # The environmentFile needs to be on the target host!
      # Best use something like sops-nix or agenix to manage it
 #     environmentFile = "/run/secrets/authentik/authentik-env";
 #     settings = {
 #       email = {
 #         host = "smtp.example.com";
 #         port = 587;
 #         username = "authentik@example.com";
 #         use_tls = true;
 #         use_ssl = false;
 #         from = "authentik@example.com";
 #       };
 #       disable_startup_analytics = true;
 #       avatars = "initials";
 #     };
 #   };



  # Firewall configuration
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