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
  # Option 2 (issue #302/#309): leave the hostname UNSET in the template so the
  # per-clone hostname is owned by cloud-init's local-hostname (Proxmox injects
  # it via `qm set --name <vmname>`) instead of being baked to "tappaas-nixos".
  # On its own this is not enough — cloud-init applies the name in its network
  # stage, after NetworkManager's first DHCP, so the first lease is briefly "*";
  # the tappaas-dhcp-hostname service below re-acquires DHCP once the name is set.
  # The net effect (verified on the live cluster) is that the VM self-registers
  # in DNS under <vmname> within ~40s of first boot, with NO dependency on the
  # cicd pipeline or on the consumer's nixos-rebuild overlay applying. Consumer
  # overlays still set networking.hostName = "<vmname>" for the final state.
  networking.hostName = lib.mkDefault ""; # was "tappaas-nixos" — see Option 2 investigation
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Option 2 (issue #302/#309): make the DHCP lease carry the correct per-clone
  # name autonomously, independent of the cicd install pipeline AND of whether
  # the consumer's nixos-rebuild overlay ever applies.
  #
  # Why this is needed: the per-VM hostname is delivered by Proxmox via cloud-init
  # USER-DATA, which cloud-init only processes in its network stage — so it lands
  # AFTER NetworkManager has already sent its first DHCP request. With hostName
  # left unset (above), that first request carries no name → dnsmasq records a "*"
  # lease that does not resolve. cloud-init then sets the correct hostname, but a
  # NetworkManager renew/reapply does NOT update an existing lease's name (verified
  # on the live cluster) — only a full re-acquire does.
  #
  # This oneshot runs right AFTER cloud-init.service (by which point the hostname
  # is correct) and bounces the ethernet connection, forcing a fresh DHCP DISCOVER
  # that carries the right name. Result: the VM self-registers in DNS at first
  # boot under <vmname>, with no dependency on update-os.sh or nixos-rebuild.
  systemd.services.tappaas-dhcp-hostname = {
    description = "Re-acquire DHCP so the lease carries the cloud-init hostname (TAPPaaS Option 2)";
    after = [ "cloud-init.service" "NetworkManager.service" ];
    requires = [ "cloud-init.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Two things are required on this NetworkManager version (both verified on the
    # live cluster):
    #   1. Set ipv4.dhcp-hostname EXPLICITLY on the ethernet profile(s). With the
    #      template hostName unset the *static* hostname is empty, and NM sends the
    #      static (not the live) hostname — so without this the lease is "*".
    #   2. Re-acquire with a full device disconnect/connect. `device reapply` /
    #      connection renew do NOT refresh an existing lease's name.
    script = ''
      hn=$(cat /proc/sys/kernel/hostname 2>/dev/null || true)
      case "$hn" in ""|localhost|"(none)")
        echo "TAPPaaS: hostname not set ('$hn') — skipping DHCP re-acquire"; exit 0 ;;
      esac
      # Set the DHCP hostname on every ethernet profile so NM advertises it.
      ${pkgs.networkmanager}/bin/nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep ethernet | ${pkgs.coreutils}/bin/cut -d: -f1 \
        | while IFS= read -r c; do
            ${pkgs.networkmanager}/bin/nmcli connection modify "$c" ipv4.dhcp-hostname "$hn" 2>/dev/null || true
          done
      # Full re-acquire on the ethernet device → fresh DHCP DISCOVER carrying $hn.
      dev=$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep ethernet | ${pkgs.coreutils}/bin/cut -d: -f1 \
              | ${pkgs.coreutils}/bin/head -1)
      [ -z "$dev" ] && dev=eth0
      echo "TAPPaaS: re-acquiring DHCP on '$dev' so the lease carries hostname '$hn'"
      ${pkgs.networkmanager}/bin/nmcli device disconnect "$dev" 2>/dev/null || true
      ${pkgs.coreutils}/bin/sleep 1
      ${pkgs.networkmanager}/bin/nmcli device connect "$dev" 2>/dev/null || true
    '';
  };

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
