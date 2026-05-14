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

let
  # Import opnsense-controller package
  opnsenseController = import ./opnsense-controller { inherit pkgs; };
in
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
  networking.hostName = lib.mkDefault "tappaas-cicd"; # Define your hostname.
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

  # Enable cron for scheduled tasks
  services.cron.enable = true;

  # ----------------------------------------
  # Promtail client → ship the mothership's journal to logging
  # ----------------------------------------
  # Lets you query update-tappaas / update-module.sh output in Grafana via the
  # Loki datasource. Safe-if-target-missing: Promtail buffers locally and retries.
  #
  # SECURITY: this VM runs opnsense-controller and setup-caddy.sh, which handle
  # OPNsense API credentials. The pipeline_stages below DROP journal entries
  # from credential-handling units and SCRUB common secret patterns from
  # everything else BEFORE the line leaves this host.
  services.promtail = {
    enable = true;
    configuration = {
      server = {
        # bind to localhost — Promtail metrics must not leak across mgmt
        http_listen_address = "127.0.0.1";
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };
      positions.filename = "/var/lib/promtail/positions.yaml";
      clients = [{
        url = "http://logging.mgmt.internal:3100/loki/api/v1/push";
      }];
      scrape_configs = [{
        job_name = "journal";
        journal = {
          max_age = "12h";
          labels = {
            job = "systemd-journal";
            host = "tappaas-cicd";
          };
        };
        relabel_configs = [
          { source_labels = [ "__journal__systemd_unit" ]; target_label = "unit"; }
          { source_labels = [ "__journal_priority_keyword" ]; target_label = "severity"; }
        ];
        pipeline_stages = [
          # 1. Drop journal entries from units that handle credentials.
          {
            match = {
              selector = ''{unit=~"opnsense-controller.*|setup-caddy.*|generate-.*-secrets.*"}'';
              action = "drop";
            };
          }
          # 2. Belt-and-braces: scrub common secret assignments anywhere else.
          {
            replace = {
              expression = ''(?i)\b(token|secret|password|passwd|api[_-]?key)\s*[:=]\s*\S+'';
              replace = "$1=***REDACTED***";
            };
          }
          # 3. Scrub HTTP basic-auth in curl-like lines: -u "user:pass"
          {
            replace = {
              expression = ''(-u[[:space:]]+["']?)[^"' ]+:[^"' ]+(["']?)'';
              replace = "$1***REDACTED***$2";
            };
          }
          # 4. Scrub Authorization headers
          {
            replace = {
              expression = ''(Authorization:[[:space:]]+(Basic|Bearer)[[:space:]]+)\S+'';
              replace = "$1***REDACTED***";
            };
          }
        ];
      }];
    };
  };

  # Promtail's hardened unit declares ReadWritePaths=/var/lib/promtail; that
  # dir must exist for the systemd mount-namespacing step to succeed.
  systemd.tmpfiles.rules = [
    "d /var/lib/promtail 0750 promtail promtail -"
  ];

  nix.settings.trusted-users = [ "root" "@wheel" ]; # Allow remote updates
  nix.settings.experimental-features = [ "nix-command" "flakes" ]; # Enable flakes
  nixpkgs.config.allowUnfree = true; # Allow unfree packages


  # start tty0 on serial console
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ]; # to start at boot
    serviceConfig.Restart = "always"; # restart when session is closed
  };

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Add any missing dynamic libraries for unpackaged programs
    # here, NOT in environment.systemPackages
  ];

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
        jq
        git
        dig
        # OPNsense controller tools (opnsense-controller, opnsense-firewall, zone-manager, dns-manager)
        opnsenseController.default
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
  system.stateVersion = "25.05";

}
