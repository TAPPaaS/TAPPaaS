# ----------------------------------------
# Version: 1.0.0 – tappaas PVE VM Template (common baseline)
# State: Released
# Date: 2025-10-16
# Author: Erik, Lars (Tappaas)
# Purpose:
#     Declarative common baseline NixOS configuration shared by every TAPPaaS
#     pve-nixos VM. It is intentionally hardware-agnostic — it contains NO disk,
#     filesystem or bootloader-device declarations — so it can be consumed by:
#       * a manual install   (tappaas-nixos.nix, which adds hardware-configuration.nix)
#       * a prebuilt image    (flake.nix, where the image format supplies disk/boot)
#
#     Help is available in the configuration.nix(5) man page, on
#     https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
#
# Modules:
#     openssh
#     QEMU
#
# ----------------------------------------

{ config, lib, pkgs, modulesPath, ... }:

{
  services.cloud-init = {
        enable = true;
        network.enable = false; # We handle networking ourselves with DHCP
        # NixOS already generates SSH host keys (sshd-keygen.service). Stop
        # cloud-init's cc_ssh module from ALSO generating them: at first boot the
        # two race, cloud-init wins, and sshd-keygen.service then fails on the
        # pre-existing keys — leaving every fresh clone in systemd "degraded"
        # state. cloud-init still injects the per-clone authorized user key.
        settings = {
          ssh_deletekeys = false;
          ssh_genkeytypes = [ ];
        };
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Root filesystem default. Both real consumers override the device:
  #   * the prebuilt image — the qemu-efi image format labels root "nixos";
  #   * the manual install — hardware-configuration.nix gives the real device.
  # Declaring a default here (low priority) lets the bare config evaluate (e.g.
  # `nix flake check`) without tripping the "no root filesystem" assertion.
  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
  };

  # Initrd disk/console drivers for the Proxmox/QEMU virtual hardware.
  # The MANUAL install path gets these from the installer-generated
  # hardware-configuration.nix; the PREBUILT IMAGE path has no such file, so the
  # initrd would otherwise lack virtio drivers and stage-1 cannot find the root
  # disk (/dev/disk/by-label/nixos times out). Declared here so BOTH paths work;
  # list options merge harmlessly with hardware-configuration.nix.
  boot.initrd.availableKernelModules = [
    "ahci" "xhci_pci" "virtio_pci" "virtio_scsi" "virtio_blk"
    "sd_mod" "sr_mod" "usbhid"
  ];

  # Network
  networking.hostName = lib.mkDefault "tappaas-nixos"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Ensure consistent interface naming across cloned VMs.
  # Proxmox virtio NICs may appear as ens18, eth0, or enp0s18 depending on
  # kernel/udev version. Using ensureProfiles with match-by-type guarantees
  # DHCP works regardless of the actual interface name.
  networking.networkmanager.ensureProfiles.profiles = {
    tappaas-ethernet = {
      connection = {
        id = "tappaas-ethernet";
        type = "ethernet";
        autoconnect = "true";
        autoconnect-priority = "100";
      };
      ipv4 = {
        method = "auto";
      };
      ipv6 = {
        method = "auto";
        addr-gen-mode = "default";
      };
    };
  };

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
  # we allow root ssh access for the template. all derived NixOS installation will have this disabled
  # Reason: need access before tappaas-cicd is configured with public ssh keys
  services.openssh = {
        enable = true;
        settings = {
                PasswordAuthentication = true;
                PermitRootLogin = "yes";
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
  system.stateVersion = "25.11";

}
