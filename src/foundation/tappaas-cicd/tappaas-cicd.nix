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
        # Keep this VM's SSH host identity across re-provisioning (#473).
        # cloud-init's cc_ssh module is a PER-INSTANCE module: whenever the
        # NoCloud seed presents an instance-id it has not seen before, it deletes
        # /etc/ssh/ssh_host_* and generates fresh keys. That fired on 2026-08-10
        # and every client with a cached known_hosts entry got a host-key-changed
        # warning. NixOS already generates the host keys (sshd-keygen.service);
        # cloud-init still injects the per-clone authorized user key.
        #
        # This duplicates tappaas-common.nix verbatim, because this config does
        # not source the common baseline — remove it once #324 makes it do so.
        settings = {
          ssh_deletekeys = false;
          ssh_genkeytypes = [ ];
        };
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Network
  networking.hostName = lib.mkDefault "tappaas-cicd"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Declare who owns the NIC (#446). Enabling NetworkManager above is not enough:
  # without a profile it left the interface "connected (externally)", carrying the
  # address cloud-init brought up once at first boot with nothing renewing it. The
  # kernel valid_lft (~24h) then expired silently and the mothership went dark for
  # ~50 minutes, with no trace in any log. cloud-init writes
  # /etc/systemd/network/10-cloud-init-eth0.network (DHCP=ipv4), but
  # systemd-networkd is not installed here, so that file is inert — force the unit
  # off rather than leave two half-owners of the same interface on disk.
  #
  # Matching by type, not name: Proxmox virtio NICs come up as eth0 or ens18
  # depending on how the udev/cloud-init rename race lands on a given boot.
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };

  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

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

  # ----------------------------------------
  # tappaas-rebuild@ — privileged helper for the mothership's own rebuild
  # ----------------------------------------
  # update-tappaas.service runs as tappaas under NoNewPrivileges=true. The
  # kernel's no_new_privs latch is inherited by every descendant and cannot be
  # cleared, so setuid binaries stop conferring privilege and the `sudo
  # nixos-rebuild` in this module's update.sh aborts before doing anything:
  #
  #   sudo: The "no new privileges" flag is set, which prevents sudo from
  #   running as root.
  #
  # That made the tappaas-cicd module fail on EVERY scheduled run (2026-08-04,
  # 08-11, 08-17, 08-18) while succeeding on every manual one — a login shell
  # carries no such latch — so the repair reflex (`update-tappaas --force`) was
  # precisely the path that could not reproduce the fault.
  #
  # The rebuild therefore moves into this root unit, which update.sh triggers
  # over D-Bus. polkit authorises on the CALLER'S UID rather than via setuid, so
  # NoNewPrivileges does not block it — verified on the reference cluster: a
  # `systemctl start` issued from inside the hardened sandbox and from a plain
  # shell produce a byte-identical polkit response.
  #
  # %i is the cicd VM name, so the flake attribute stays exactly what update.sh
  # resolved from the module config. This is the INTERIM fix for #471; ADR-017
  # replaces it with an `ExecStartPre=+` line on update-tappaas.service and
  # removes this unit and its polkit rule.
  systemd.services."tappaas-rebuild@" = {
    description = "TAPPaaS mothership NixOS rebuild for %i (privileged helper)";
    serviceConfig = {
      Type = "oneshot";
      # Runs as root: no User=, and deliberately none of update-tappaas's
      # sandboxing — nixos-rebuild must write /nix, /boot, /etc and
      # /run/current-system.
      WorkingDirectory = "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd";
      # --impure is required only because tappaas-cicd.nix imports the
      # machine-specific /etc/nixos/hardware-configuration.nix; nixpkgs itself
      # stays pinned by flake.lock.
      ExecStart = "/run/current-system/sw/bin/nixos-rebuild switch --flake .#%i --impure";
      # nixos-rebuild shells out to nix, git and systemd tooling.
      Environment = [
        ("PATH=/run/wrappers/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
        # Root-owned HOME holding the safe.directory grant above; nix also puts
        # its eval cache under it, which is why it must be writable.
        "HOME=/var/lib/tappaas-rebuild"
      ];
      # A rebuild of a large closure can outrun the default 90s.
      TimeoutStartSec = "60min";
    };
  };

  # nixos-rebuild resolves `.#<vm>` to the git flake at /home/tappaas/TAPPaaS,
  # and nix refuses to open a repository owned by another user. Interactively
  # this never bites: `sudo` exports SUDO_UID=1000, and libgit2 (which nix uses)
  # treats a repo owned by the sudo-invoking user as trusted. A systemd unit has
  # no SUDO_UID, so the same rebuild fails with
  #
  #   error: opening Git repository "/home/tappaas/TAPPaaS": repository path
  #   '/home/tappaas/TAPPaaS' is not owned by current user
  #
  # The repo is therefore declared trusted through git's safe.directory. Measured
  # on this host, nix's libgit2 honours that ONLY from $HOME/.gitconfig — both
  # GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM are ignored, so `programs.git.config`
  # (which writes /etc/gitconfig) does not reach it. The helper unit is given a
  # root-owned HOME carrying exactly that one setting.
  #
  # NOTE for ADR-017: D3 runs the rebuild from `ExecStartPre=+`, also as root and
  # also without SUDO_UID, so this stays necessary once the helper unit retires.
  #
  # `path:` would sidestep the ownership check, but a path flake copies the
  # directory verbatim while a git flake sees only tracked files — that changes
  # which files are part of the build, so it is not a drop-in substitute.
  environment.etc."tappaas-rebuild-gitconfig".text = ''
    [safe]
    	directory = /home/tappaas/TAPPaaS
  '';

  # Let tappaas start (only) the rebuild helper without an interactive agent.
  # Scoped to the unit prefix and to the start verb: this grants the operator
  # nothing it did not already have through passwordless sudo, it only makes it
  # reachable from a NoNewPrivileges context.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "tappaas" &&
          action.lookup("verb") == "start") {
        var unit = action.lookup("unit");
        if (unit && unit.indexOf("tappaas-rebuild@") == 0) {
          return polkit.Result.YES;
        }
      }
    });
  '';

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
    # #506: a failed sweep must stay visible without reading the journal.
    # main.py writes config/last-update-result.json on every real sweep, but a
    # hard crash exits before that — and the hourly no-op run then clobbers this
    # unit's Result back to success. OnFailure fires on ANY non-zero exit and
    # leaves a durable breadcrumb the operator/monitoring can see.
    unitConfig.OnFailure = "update-tappaas-failure.service";
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

  # #506: OnFailure handler for update-tappaas.service. Appends a timestamped
  # line to config/update-tappaas.failures and logs to the journal, so a failed
  # (or crashed) sweep leaves a durable signal that the next hourly no-op run
  # cannot erase. The authoritative detail is config/last-update-result.json.
  systemd.services.update-tappaas-failure = {
    description = "Surface a failed update-tappaas sweep (OnFailure handler, #506)";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = pkgs.writeShellScript "update-tappaas-failure" ''
        printf '%s update-tappaas.service FAILED — see config/last-update-result.json (journalctl -u update-tappaas for detail)\n' \
          "$(${pkgs.coreutils}/bin/date -Is)" >> /home/tappaas/config/update-tappaas.failures
        echo "update-tappaas sweep FAILED — see /home/tappaas/config/last-update-result.json" >&2
      '';
      ProtectSystem = "strict";
      ReadWritePaths = [ "/home/tappaas/config" ];
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

  # ----------------------------------------
  # check-ha-health — systemd timer (issue #146)
  # ----------------------------------------
  # A failed HA failback leaves the CRM retrying a migration every ~10s
  # indefinitely, freezing the guest filesystem on every attempt. Nothing
  # surfaced that for 27 hours, so poll for services stuck in a transitional
  # state. --repair runs the cloud-init orphan sweep, which is the known cause
  # (issue #146 / https://bugzilla.proxmox.com/show_bug.cgi?id=7608).
  #
  # Runs as tappaas: the check SSHes to the nodes with the operator key, the
  # same way reboot-node.sh and the other cluster tooling do.
  systemd.services.check-ha-health = {
    description = "TAPPaaS HA health check — detect wedged HA services";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = "/home/tappaas/bin/check-ha-health.sh --quiet --repair";
      # rc 2 = a wedged service was found and reported; that is a successful
      # detection, not a unit failure, so don't spam systemd with failed units.
      SuccessExitStatus = [ 0 2 ];
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/tappaas" ];
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };

  systemd.timers.check-ha-health = {
    description = "Periodic trigger for check-ha-health";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";          # let the cluster settle after a reboot
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
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
    # check-ha-health.sh records when each HA service entered a transitional
    # state, so it can alert on duration rather than on the state alone (#146).
    "d /var/lib/tappaas 0750 tappaas users -"
    # HOME for tappaas-rebuild@: root-owned, writable (nix caches there), and
    # carrying only the safe.directory grant that lets root open the operator's
    # git checkout. See the comment on environment.etc."tappaas-rebuild-gitconfig".
    "d /var/lib/tappaas-rebuild 0700 root root -"
    "L+ /var/lib/tappaas-rebuild/.gitconfig - - - - /etc/tappaas-rebuild-gitconfig"
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
        # TFTP server for node-provisioner's PXE trap (runs tftp-only via
        # systemd-run when provisioning is enabled; node-provisioning.md N3)
        dnsmasq
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

  # node-provisioner PXE trap (node-provisioning.md N3): TFTP for ipxe.efi +
  # the HTTP answer/asset server. The VM sits on the mgmt plane only, and the
  # services are OFF by default (TTL-limited transient units) — the ports are
  # open, the listeners are the interlock.
  networking.firewall.allowedTCPPorts = [ 8090 ];
  networking.firewall.allowedUDPPorts = [ 69 ];

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
