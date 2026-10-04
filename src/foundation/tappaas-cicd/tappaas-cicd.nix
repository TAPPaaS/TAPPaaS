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
    ]
    # The site's own time and locale (#408, #472). The mothership is IN the site,
    # so it reads the same generated fragment every other guest does — written by
    # tappaas-self-rebuild.sh just before this rebuild. Optional, because a
    # bootstrap builds this system before config/site.json exists.
    ++ lib.optional (builtins.pathExists /etc/nixos/tappaas-site.nix)
      /etc/nixos/tappaas-site.nix
    # When the mothership captures its own config/ (#691). Optional for the same
    # reason: it is written by backup:filesystem, which runs after a bootstrap.
    ++ lib.optional (builtins.pathExists /etc/nixos/tappaas-backup.nix)
      /etc/nixos/tappaas-backup.nix;

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
  # No time zone here: it is the site's fact, not the mothership's (#472). It
  # arrives through /etc/nixos/tappaas-site.nix, imported above.

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
  # (History — since #767 update-tappaas.service has no NoNewPrivileges and runs
  # its root steps through `sudo -n`; this helper remains for the module update.)
  # update-tappaas.service ran as tappaas under NoNewPrivileges=true. The
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
  # resolved from the module config. This was the INTERIM fix for #471. Since
  # ADR-017 D3 the rebuild runs in update-tappaas.service's ExecStartPre; this
  # unit stays only for the first activation (ADR-017 Bootstrap: the old unit
  # still rebuilds through it) and goes with the legacy path in update-tappaas.
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

  # The rule that let tappaas start tappaas-rebuild@ was scoped to the interim
  # rebuild path; ADR-017 D3 moved the rebuild into update-tappaas.service and
  # the fallback that still uses the helper (Bootstrap) is covered by the wheel
  # rule below (#515).
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    // Grant wheel polkit authority over systemd unit management, matching the
    // NOPASSWD sudo trust it already holds (security.sudo.wheelNeedsPassword =
    // false). Without this, `systemctl restart/stop/enable ...` as a wheel user
    // (tappaas) hits an auth_admin prompt for a password that cannot exist —
    // the account is key-only (no hashedPassword), so no input ever succeeds.
    // Not an escalation: wheel is already root via sudo on this host; this only
    // makes the same authority reachable over D-Bus/polkit. YES (not
    // allow_active) because SSH sessions are often classified inactive on a
    // single-admin, key-only host. manage-unit-files covers enable/disable/
    // mask, which are a separate action id from manage-units. (#515)
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.systemd1.manage-units" ||
           action.id == "org.freedesktop.systemd1.manage-unit-files") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';

  # Essential Services
  services.openssh = {
        enable = true;
        settings = {
                PasswordAuthentication = false;
                # Key-only: don't offer keyboard-interactive/PAM either, so key-only
                # doesn't hinge on the sshd PAM stack staying deny-only.
                KbdInteractiveAuthentication = false;
                PermitRootLogin = "no";
        };
  };
  programs.ssh.startAgent = true;

  # ----------------------------------------
  # update-tappaas — the update sweep (cron was retired in issue #150)
  # ----------------------------------------
  # Started by update-tappaas.timer, which update-tappaas-schedule renders from
  # site.json .updateSchedule (ADR-017 D1/D2), or by `site-manager update` (D4).
  # Output flows through Python's logging module with systemd-priority
  # prefixes, so journald (and Alloy → Loki) tag entries with the right
  # severity.
  systemd.services.update-tappaas = {
    description = "TAPPaaS scheduler — update foundation and app modules";
    # #506: a failed sweep must stay visible without reading the journal.
    # main.py writes config/last-update-result.json on every real sweep, but a
    # hard crash exits before that — and the hourly no-op run then clobbers this
    # unit's Result back to success. OnFailure fires on ANY non-zero exit and
    # leaves a durable breadcrumb the operator/monitoring can see.
    unitConfig.OnFailure = [ "update-tappaas-failure.service" "tappaas-security-scan.service" ];
    # ADR-011 §9: every sweep is followed by a security scan of what it left
    # running — after a failed sweep too, when the site runs something unplanned.
    # The scan skips itself unless this run wrote a sweep result (--if-new-sweep),
    # so the hourly no-op runs cost one stat.
    unitConfig.OnSuccess = [ "tappaas-security-scan.service" ];
    # The rebuild in ExecStartPre changes this very unit; a restart on switch
    # would kill the run that is doing the switch (ADR-017 Open).
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      # #767 (ADR-017 D3, amended 2026-10-04): each step runs in the OPERATOR'S
      # CONSOLE CONTEXT, because that is the context every change is tested in.
      # Three times code that worked from the tappaas console failed only here —
      # root's runuser child got root's PATH (#713); sudo cannot run under
      # NoNewPrivileges (#742); the `+` root step had HOME=/home/tappaas and
      # libgit2 refused the checkout that `sudo` had made trusted by hand (#719) —
      # each found by a failed sweep, not a test. So:
      #   * tappaas steps run in a LOGIN SHELL: the operator's PATH and profile,
      #     not a list kept in step with them by hand;
      #   * root steps run through `sudo -n`, as the operator would run them
      #     (root's HOME, SUDO_UID set; tappaas has passwordless sudo, line ~130);
      #   * no sandbox. NoNewPrivileges only ever protected this VM's own root:
      #     the tappaas user whose code the sweep runs already holds the root SSH
      #     key to every node, the backup-key escrow, ~/bin and the checkouts.
      # What alignment cannot remove (no TTY, a timer start, no SSH agent) is
      # tested in this context with tappaas-unit-run (scripts/).
      #
      # The steps (ADR-017 D3): repair ownership (#533; `-`: a failed repair
      # must not block the sweep); prepare (pull + relink + builds); rebuild
      # (nixos-rebuild switch — fatal on failure); then the sweep.
      ExecStartPre = [
        "-/run/wrappers/bin/sudo -n /home/tappaas/bin/tappaas-repair-ownership.sh"
        "/run/current-system/sw/bin/bash -l -c tappaas-self-prepare.sh"
        "/run/wrappers/bin/sudo -n /home/tappaas/bin/tappaas-self-rebuild.sh"
      ];
      ExecStart = "/run/current-system/sw/bin/bash -l -c update-tappaas";
      # Per-run state (the claimed request, the prepared/rebuilt markers);
      # removed when the unit stops, so nothing leaks into the next run. The root
      # steps find it at /run/update-tappaas (sudo resets RUNTIME_DIRECTORY).
      RuntimeDirectory = "update-tappaas";
      # The login shell sets PATH from the operator's profile; this is only the
      # floor for anything that runs before it (and for the self-check, which
      # reads this unit's PATH, #713).
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
    };
  };

  # #506: OnFailure handler for update-tappaas.service. Appends a timestamped
  # line to config/update-tappaas.failures and logs to the journal, so a failed
  # (or crashed) sweep leaves a durable signal that the next hourly no-op run
  # cannot erase. The authoritative detail is config/last-update-result.json.
  # #651: then mails site.json `email` through a Proxmox node's mailer
  # (scripts/notify-update-failure.sh; ADR-007e v1.3). If no node takes the
  # mail this unit fails too, so a lost notice is visible in `systemctl --failed`.
  systemd.services.update-tappaas-failure = {
    description = "Surface a failed update-tappaas sweep (OnFailure handler, #506, #651)";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = pkgs.writeShellScript "update-tappaas-failure" ''
        printf '%s update-tappaas.service FAILED — see config/last-update-result.json (journalctl -u update-tappaas for detail)\n' \
          "$(${pkgs.coreutils}/bin/date -Is)" >> /home/tappaas/config/update-tappaas.failures
        echo "update-tappaas sweep FAILED — see /home/tappaas/config/last-update-result.json" >&2
        exec /home/tappaas/bin/notify-update-failure.sh
      '';
      # The notice needs ssh and jq, like the sweep (see update-tappaas above).
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ "/home/tappaas/config" ];
    };
  };

  # ADR-011 §9: the security scan — started by update-tappaas (OnSuccess and
  # OnFailure above), never by a timer of its own. Inventories every target
  # read-only and matches it against its layer's CVE source; writes
  # config/sbom/{site.cdx.json,cve-status.json} and mails the owner only when a
  # fixable CVE or a failed scan is NEW. A separate unit, so a scan problem never
  # marks a sweep failed. Its scanner databases (~4.4 GB, ~/.cache/{grype,trivy})
  # live on the root disk; the scan refuses to download them without room.
  systemd.services.tappaas-security-scan = {
    description = "TAPPaaS security scan — SBOM and CVE status after a sweep (ADR-011)";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = "/home/tappaas/bin/health-manager scan security --if-new-sweep --notify";
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
        # The mothership's nixpkgs is the estate pin (ADR-028 D1): the CPE
        # vendors it declares hold for every guest built from it.
        "TAPPAAS_NIXPKGS=${pkgs.path}"
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ "/home/tappaas/config" "/home/tappaas/.cache" ];
      PrivateTmp = true;
      NoNewPrivileges = true;
      # A slow registry must not hold the unit for ever; the scan's own
      # timeouts are shorter.
      TimeoutStartSec = "2h";
    };
  };

  # ADR-017 D2: the timer is no longer declared here. update-tappaas-schedule
  # renders it from site.json .updateSchedule into /run at boot, after every
  # self-rebuild and on every schedule change (Persistent=false, D1).
  systemd.services.update-tappaas-schedule = {
    description = "Render update-tappaas.timer from site.json (ADR-017 D2)";
    wantedBy = [ "timers.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/home/tappaas/bin/update-tappaas-schedule.sh";
      # It also consumes the #744 resume marker, which lives in config/ because
      # /run is cleared by the very reboot the marker has to survive.
      # NixOS's default service PATH has no bash, so the script's
      # `#!/usr/bin/env bash` fails without this (exit 127, T3 2026-09-15).
      # Root-only directories: never the operator's ~/bin.
      Environment = [ "PATH=/run/wrappers/bin:/run/current-system/sw/bin" ];
      # It only writes the rendered timer; everything else stays read-only.
      ProtectSystem = "strict";
      ReadWritePaths = [ "/run/systemd/system" "/home/tappaas/config" ];
      PrivateTmp = true;
      NoNewPrivileges = true;
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

  # ----------------------------------------
  # config/ file backup (ADR-012 §3.1 / #545)
  # ----------------------------------------
  # The mothership's config/ IS the cluster's source of truth — the declared
  # state every module is rebuilt from. A whole-VM backup covers it too, but a
  # file capture restores in seconds into a running system and, unlike a VM
  # snapshot, can be restored onto a DIFFERENT mothership during a rebuild.
  # That is the case that matters: full-site DR restores config/ before there
  # is a VM to restore into.
  #
  # The runner and its manifest are deployed by backup:filesystem's
  # install-service.sh; this unit is only the trigger. ConditionPathExists keeps
  # it inert until then, so a mothership whose backup is still a shim does not
  # log a failure every day.
  #
  # This duplicates templates/tappaas-common.nix verbatim, because this config
  # does not source the common baseline — remove it once #324 makes it do so.
  # The trigger cannot live with the runner it triggers: /etc/systemd/system is
  # a read-only store symlink on NixOS, so backup:filesystem has no way to
  # deliver a unit imperatively and every guest must declare this one (#626).
  systemd.services.tappaas-fs-backup = {
    description = "TAPPaaS file-level backup of the mothership's config/ (ADR-012 §3.1)";
    unitConfig.ConditionPathExists = "/home/tappaas/bin/tappaas-fs-backup.sh";
    serviceConfig = {
      Type = "oneshot";
      # Runs as ROOT, not tappaas (#626). Its declared capture set includes
      # /etc/secrets, and the escrow dir inside it is root-only 0600 — as it
      # must be, it holds every module's encryption key. Run as tappaas the
      # capture simply skipped those keys, and proxmox-backup-client exits 0
      # after logging "access denied", so every run reported a complete backup
      # of a path it had not fully read. A backup agent is privileged by nature.
      ExecStart = "/home/tappaas/bin/tappaas-fs-backup.sh";
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      # It reads /etc/secrets (its own write-no-delete login + encryption key)
      # and the paths it captures; it writes nothing locally.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };

  systemd.timers.tappaas-fs-backup = {
    description = "Daily trigger for the mothership's config/ file backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Ahead of the 21:00 VM job, so a night's capture and snapshot describe
      # the same state rather than straddling a change.
      # A fallback: the generated tappaas-backup.nix carries the real window (#691).
      OnCalendar = lib.mkDefault "20:30";
      RandomizedDelaySec = "5min";
      Persistent = true;          # catch up after downtime
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
  # Alloy client → ship the mothership's journal to logging
  # ----------------------------------------
  # Lets you query update-tappaas / update-module.sh output in Grafana via the
  # Loki datasource. Safe-if-target-missing: Alloy buffers locally and retries.
  #
  # Grafana Alloy replaced Promtail here because 26.05 removed both the promtail
  # NixOS module AND the package — promtail reached end of life (#721). Alloy
  # embeds promtail's own pipeline, so every stage below means exactly what it
  # meant before; the translation was made by `alloy convert --source-format=promtail`
  # from the config this host was actually running, not rewritten by hand.
  #
  # SECURITY: this VM runs opnsense-controller and setup-caddy.sh, which handle
  # OPNsense API credentials. The stages below DROP journal entries from
  # credential-handling units and SCRUB common secret patterns from everything
  # else BEFORE the line leaves this host.
  services.alloy = {
    enable = true;
    extraFlags = [
      # Alloy's own HTTP server: metrics and the component UI. Localhost only —
      # this must not be reachable across mgmt. (Alloy already defaults to
      # 127.0.0.1, unlike promtail; stated here so it cannot drift.)
      "--server.http.listen-addr=127.0.0.1:9080"
      # Do not report the enabled component set to Grafana. A TAPPaaS site
      # tells no one what it runs.
      "--disable-reporting"
    ];
  };

  # Written to /etc rather than the store so `alloy` can reload it in place;
  # the module watches every alloy/*.alloy file and reloads on switch.
  environment.etc."alloy/config.alloy".text = ''
    loki.process "journal" {
      forward_to = [loki.write.default.receiver]

      // 1. Drop journal entries from units that handle credentials.
      stage.match {
        selector = "{unit=~\"opnsense-controller.*|setup-caddy.*|generate-.*-secrets.*\"}"
        action   = "drop"
      }

      // 2. Belt-and-braces: scrub common secret assignments anywhere else.
      //
      // Only the CAPTURE GROUPS are replaced, and `replace` is used literally —
      // there is no $1 expansion (#724). So each expression captures the SECRET
      // and leaves the key outside the group: the key stays readable and only
      // the value is destroyed.
      //
      // These deliberately over-match: "password: permission denied" loses the
      // word "permission", because demanding the value hug the separator would
      // miss the very common `token: abc123`. Redacting a word that was not a
      // secret costs readability; missing one that was costs the secret.
      stage.replace {
        expression = "(?i)\\b(?:token|secret|password|passwd|api[_-]?key)\\s*[:=]\\s*(\\S+)"
        replace    = "***REDACTED***"
      }

      // 3. Scrub HTTP basic-auth in curl-like lines: -u "user:pass"
      stage.replace {
        expression = "-u[[:space:]]+[\"']?([^\"' ]+:[^\"' ]+)[\"']?"
        replace    = "***REDACTED***"
      }

      // 4. Scrub Authorization headers
      stage.replace {
        expression = "Authorization:[[:space:]]+(?:Basic|Bearer)[[:space:]]+(\\S+)"
        replace    = "***REDACTED***"
      }
    }

    discovery.relabel "journal" {
      targets = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "severity"
      }
    }

    loki.source.journal "journal" {
      max_age       = "12h0m0s"
      relabel_rules = discovery.relabel.journal.rules
      forward_to    = [loki.process.journal.receiver]
      labels        = {
        host = "tappaas-cicd",
        job  = "systemd-journal",
      }
    }

    loki.write "default" {
      endpoint {
        url = "http://logging.mgmt.internal:3100/loki/api/v1/push"
      }
    }
  '';

  systemd.tmpfiles.rules = [
    # check-ha-health.sh records when each HA service entered a transitional
    # state, so it can alert on duration rather than on the state alone (#146).
    "d /var/lib/tappaas 0750 tappaas users -"
    # The security scan's scanner databases (ADR-011): the unit's ReadWritePaths
    # names this directory, and a missing one fails the unit's namespace setup.
    "d /home/tappaas/.cache 0700 tappaas users -"
    # The backup-key escrow (ADR-012 §2.5.1) belongs to tappaas, so the sweep
    # can write it without sudo — which its NoNewPrivileges forbids. Z hands the
    # keys a root-era escrow already holds to tappaas as well; their 0600 stays.
    "d /etc/secrets 0755 root root -"
    "d /etc/secrets/backup-fs 0700 tappaas users -"
    "Z /etc/secrets/backup-fs - tappaas users -"
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
        tea         # Forgejo CLI for the Codeberg issue tracker
        dig
        shellcheck   # bash script linting for module *.sh validation (#265)
        # OPNsense controller tools (opnsense-controller, opnsense-firewall, zone-manager, dns-manager)
        opnsenseController.default
        # Identity controller tools (authentik-manager, identity-controller; ADR-007 S2b-1)
        identityController.default
        # TFTP server for node-provisioner's PXE trap (runs tftp-only via
        # systemd-run when provisioning is enabled; node-provisioning.md N3)
        dnsmasq
        # The mothership captures its own config/ as a backup:filesystem
        # (ADR-012 §3.1 / #545): only the guest can read its own files, so the
        # client belongs INSIDE it.
        proxmox-backup-client
        # The security scan's scanners (ADR-011 §4): grype matches Nix closures
        # by CPE, trivy matches Debian hosts and container images.
        grype
        trivy
        # No secret is committed here, nor released (#378): the pre-commit hook
        # below, and the release train's scan at every boundary.
        gitleaks
  ];

  # Every repository on the mothership — the managed clones, a module under
  # development, the release record tappaas-train commits — runs this hook
  # before a commit: gitleaks on what is staged, with the repository's own
  # .gitleaks.toml when it has one. Local and immediate: nothing is scanned on
  # Codeberg (operator, 2026-10-03: the scan that enforces is the release gate).
  # core.hooksPath replaces a clone's .git/hooks, so a repository's own
  # pre-commit hook is run after it rather than lost.
  programs.git = {
    enable = true;
    config.core.hooksPath = "/etc/tappaas/git-hooks";
  };
  environment.etc."tappaas/git-hooks/pre-commit" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      # TAPPaaS: no secret is committed on the mothership (#378).
      top="$(git rev-parse --show-toplevel)" || exit 1
      if command -v gitleaks >/dev/null 2>&1; then
        cfg=""; [ -f "$top/.gitleaks.toml" ] && cfg="--config=$top/.gitleaks.toml"
        # shellcheck disable=SC2086
        if ! gitleaks git --pre-commit --staged --redact --no-banner $cfg "$top"; then
          echo "pre-commit: gitleaks found a secret in what is staged — commit refused." >&2
          echo "  A false positive goes in .gitleaks.toml; a real one is rotated, never committed." >&2
          exit 1
        fi
      fi
      # The repository's own hook, from its git directory: NOT `--git-path
      # hooks/…`, which follows core.hooksPath back to this file — a hook that
      # execs itself, forever (found testing it, 2026-10-03).
      own="$(git rev-parse --git-common-dir)/hooks/pre-commit"
      if [ -x "$own" ] && [ "$(readlink -f "$own")" != "$(readlink -f "$0")" ]; then
        exec "$own" "$@"
      fi
      exit 0
    '';
  };

  # `health-manager scan security` from a shell resolves CPE vendors against
  # the same nixpkgs the unit does.
  environment.variables.TAPPAAS_NIXPKGS = "${pkgs.path}";

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
