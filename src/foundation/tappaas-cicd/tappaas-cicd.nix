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
  opnsenseController = import ./controller/opnsense-controller { inherit pkgs; };
  # Import identity-controller package (Authentik runtime controller; ADR-007 S2b-1)
  identityController = import ./controller/identity-controller { inherit pkgs; };
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

  # DNS-independent control plane (#307). The mothership reaches the firewall and
  # the Proxmox nodes by their mgmt FQDNs to run updates AND to roll a snapshot
  # back when a post-update test fails. But the cluster resolver IS the firewall's
  # Unbound (10.0.0.1) — so if a firewall update breaks Unbound, FQDN resolution
  # dies and the very rollback that must recover it can no longer reach the node.
  # Pin the control-plane FQDNs in /etc/hosts (nsswitch resolves `files` before
  # `dns`) so this path never depends on the firewall's own DNS. IPs follow the
  # fixed TAPPaaS mgmt convention on 10.0.0.0/24: firewall=.1, tappaasN=.(9+N).
  # If a deployment deviates from that convention, update these entries.
  networking.hosts = {
    "10.0.0.1"  = [ "firewall.mgmt.internal" "firewall" ];
    "10.0.0.10" = [ "tappaas1.mgmt.internal" "tappaas1" ];
    "10.0.0.11" = [ "tappaas2.mgmt.internal" "tappaas2" ];
    "10.0.0.12" = [ "tappaas3.mgmt.internal" "tappaas3" ];
    "10.0.0.13" = [ "tappaas4.mgmt.internal" "tappaas4" ];
    "10.0.0.14" = [ "tappaas5.mgmt.internal" "tappaas5" ];
    "10.0.0.15" = [ "tappaas6.mgmt.internal" "tappaas6" ];
    "10.0.0.16" = [ "tappaas7.mgmt.internal" "tappaas7" ];
    "10.0.0.17" = [ "tappaas8.mgmt.internal" "tappaas8" ];
    "10.0.0.18" = [ "tappaas9.mgmt.internal" "tappaas9" ];
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
  services.openssh = {
        enable = true;
        settings = {
                PasswordAuthentication = false;
                PermitRootLogin = "no";
        };
  };
  programs.ssh.startAgent = true;

  # ----------------------------------------
  # update-tappaas — systemd timer (cron was retired in issue #150)
  # ----------------------------------------
  # Fires hourly; the script itself reads `tappaas.updateSchedule` from
  # configuration.json and decides whether to actually do anything. Output
  # flows through Python's logging module with systemd-priority prefixes,
  # so journald (and Promtail → Loki) tag entries with the right severity.
  systemd.services.update-tappaas = {
    description = "TAPPaaS scheduler — update foundation and app modules";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = "/home/tappaas/bin/update-tappaas";
      # Mirror the operator's login PATH. Without this the service runs with
      # NixOS's minimal default service PATH (no bash), so update-module.sh's
      # `#!/usr/bin/env bash` shebang fails with "env: 'bash': No such file or
      # directory" and every module update dies instantly. update-module.sh
      # also needs ssh, jq, git, nixos-rebuild, nix and curl — all on this PATH.
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      # Hardening — update-tappaas only needs to read configs and shell out
      # to /home/tappaas/bin/update-module.sh (which uses ssh).
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/home/tappaas/config" ];
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };

  systemd.timers.update-tappaas = {
    description = "Hourly trigger for update-tappaas";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";        # *-*-* *:00:00
      Persistent = true;            # catch up after downtime / reboots
      RandomizedDelaySec = "5min";  # spread load if multiple things tick on the hour
    };
  };

  # cron was replaced by the systemd timer above (issue #150). Disable it
  # explicitly so a stale crontab entry can never resurrect a dual scheduler.
  services.cron.enable = false;

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

  # ── OOM resilience (issue #323) ────────────────────────────────────────
  # Without swap and oomd configuration, memory exhaustion causes host-wide
  # stalls. zram provides a compressed memory buffer (no disk I/O penalty),
  # and systemd-oomd kills runaway processes before the kernel OOM killer
  # intervenes unpredictably.

  # Compressed in-memory swap — gives oomd time to act before hard OOM
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

  # systemd-oomd: pressure-based OOM handling
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableUserSlices = true;
  };

  # Limit user.slice memory to create backpressure before system exhaustion
  systemd.slices."user-".sliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "80%";
    MemoryHigh = "90%";
    MemoryMax = "95%";
  };

  # System packages
  environment.systemPackages = with pkgs; [
        vim
        wget
        curl
        htop
        tmux        # persistent sessions for long-running ops over SSH
        jq
        git
        gh          # GitHub CLI
        dig
        shellcheck   # bash script linting for module *.sh validation (#265)
        # OPNsense controller tools (opnsense-controller, opnsense-firewall, zone-manager, dns-manager)
        opnsenseController.default
        # Identity controller tools (authentik-manager, identity-controller; ADR-007 S2b-1)
        identityController.default
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
