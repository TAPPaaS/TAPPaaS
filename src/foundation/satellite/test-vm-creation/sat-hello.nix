# ----------------------------------------
# sat-hello — disposable ADR-010 test VM.
#
# Minimal nginx serving a plaintext OK page on :80, so network:proxy can bind
# the wildcard cert and publish sat-hello.<env>.tapaas.org through the satellite.
# Kept as close as possible to the TAPPaaS NixOS baseline (00-Template/template.nix)
# — including zramSwap + systemd-oomd (issue #323) so nixos-rebuild does not OOM
# on a small VM — with only an nginx service added. Safe to delete.
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
  networking.hostName = lib.mkDefault "sat-hello";
  networking.networkmanager.enable = true;

  # Ensure consistent interface naming across cloned VMs (see template.nix).
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

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # Users
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };
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

  # ── OOM resilience (issue #323) — keep the baseline so nixos-rebuild has swap ──
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableUserSlices = true;
  };
  systemd.slices."user-".sliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "80%";
    MemoryHigh = "90%";
    MemoryMax = "95%";
  };

  # ── The actual test payload: a trivial web server on :80 ────────────────
  services.nginx = {
    enable = true;
    virtualHosts."sat-hello" = {
      default = true;
      locations."/" = {
        extraConfig = ''
          default_type text/plain;
          return 200 "sat-hello OK — ADR-010 satellite HTTPS path works\n";
        '';
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ 80 ];

  environment.systemPackages = with pkgs; [ vim curl htop ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  system.stateVersion = "25.05";
}
