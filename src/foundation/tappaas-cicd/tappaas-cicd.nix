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
  # Import authentik-controller package (Authentik runtime controller; ADR-007 S2b-1)
  identityController = import ./controller/authentik-controller { inherit pkgs; };
in
{
  imports =
    [
      /etc/nixos/hardware-configuration.nix
      # The TAPPaaS NixOS baseline every VM shares (#324), read from this
      # checkout — the flake's own source — rather than shipped like a guest's:
      # ssh, cloud-init, the tappaas user, nix settings, zram/oomd, the NIC and
      # hostname fixes, the file-backup trigger (#626). It also imports the
      # site's own time and locale (#408, #472), /etc/nixos/tappaas-site.nix,
      # which tappaas-self-rebuild.sh writes just before this rebuild — only
      # when it exists, because a bootstrap builds this system before
      # config/site.json does. This file states only what the mothership adds.
      ../templates/tappaas-common.nix
    ]
    # When the mothership captures its own config/ (#691). Optional for the same
    # reason: it is written by backup:filesystem, which runs after a bootstrap.
    ++ lib.optional (builtins.pathExists /etc/nixos/tappaas-backup.nix)
      /etc/nixos/tappaas-backup.nix;

  # Store garbage (#813): the mothership builds every guest's system and each
  # preview fetches pins; one busy day filled its 63G between weekly GCs (99%,
  # 2026-10-10, the boundary's deep test). Collect when space runs low, and
  # daily, keeping a week of generations (baseline: weekly, 30d — mkDefault).
  nix.settings.min-free = 5 * 1024 * 1024 * 1024;
  nix.settings.max-free = 15 * 1024 * 1024 * 1024;
  nix.gc.dates = "daily";
  nix.gc.options = "--delete-older-than 7d";

  # Network
  networking.hostName = lib.mkDefault "tappaas-cicd"; # Define your hostname.

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
  # arrives through /etc/nixos/tappaas-site.nix, which the baseline imports.

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
    # This unit runs the switch that may change this unit. Without this, the
    # switch stops the running helper (SIGTERM, the rebuild reported failed)
    # and then starts it again, which collides with the switch's own transient
    # unit — hrossen 2026-10-06, when #770 added the ExecStartPre below. The
    # system was switched each time; only the report and the unit state lied.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      # Runs as root: no User=, and deliberately none of update-tappaas's
      # sandboxing — nixos-rebuild must write /nix, /boot, /etc and
      # /run/current-system.
      WorkingDirectory = "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd";
      # --impure is required only because tappaas-cicd.nix imports the
      # machine-specific /etc/nixos/hardware-configuration.nix; nixpkgs itself
      # stays pinned by flake.lock.
      # The generated fragments this build imports (site time/locale, journal
      # client — #770), written first as update-tappaas's path does. "-": a
      # failure keeps the fragments already there rather than block the rebuild.
      ExecStartPre = "-/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/tappaas-render-fragments.sh";
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

  # SSH: the baseline allows root and password login for the bare template
  # only; the mothership turns both off. Key-only: don't offer
  # keyboard-interactive/PAM either, so key-only doesn't hinge on the sshd PAM
  # stack staying deny-only.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
    # A satellite's sshPort relays logins from its tunnel end (ADR-010 §4.4.2):
    # one source address for every client, so penalties would lock the operator
    # out for others' failures. The satellite limits who reaches it instead.
    PerSourcePenaltyExemptList = "10.255.0.0/32";
  };

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
    unitConfig.OnFailure = [ "update-tappaas-failure.service" "tappaas-security-scan.service" "tappaas-switch-read.service" ];
    # ADR-011 §9: every sweep is followed by a security scan of what it left
    # running — after a failed sweep too, when the site runs something unplanned.
    # The scan skips itself unless this run wrote a sweep result (--if-new-sweep),
    # so the hourly no-op runs cost one stat.
    # #860: and by a read of the switches, so the switch-ports gate judges the
    # ports as they are, not as somebody last read them.
    unitConfig.OnSuccess = [ "tappaas-security-scan.service" "tappaas-switch-read.service" ];
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
      # Exit 3: the sweep completed, but app modules failed. Not a broken run,
      # so not a unit failure — and not silent either: ExecStopPost mails and
      # records it, as OnFailure does for a broken one. Exit 0 after a failure
      # notice: the RESOLVED (#883; it sends nothing unless one is open and a
      # clean sweep has run since). ($$: the variable is bash's to read, not
      # systemd's to expand.)
      SuccessExitStatus = [ 3 ];
      ExecStopPost = "-/run/current-system/sw/bin/bash -l -c 'case \"$$EXIT_STATUS\" in 3) exec notify-update-failure.sh --degraded ;; 0) exec notify-update-failure.sh --resolved ;; esac'";
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
      # /var/lib/tappaas: the open condition (alerts-open) and the support
      # bundle the notice carries (support/, #883).
      ReadWritePaths = [ "/home/tappaas/config" "/var/lib/tappaas" ];
    };
  };

  # ----------------------------------------
  # Alerts from the logs (#126)
  # ----------------------------------------
  # The logging module's Grafana evaluates LogQL rules over every host's logs
  # (quorum lost, HA fencing, a host gone silent, disk, backup, OOM, a new root
  # key) and posts what fires to this receiver, which mails it through
  # site-notify.sh — the same path as a failed sweep (#651). Stateless: Grafana
  # groups and repeats. The token authenticates Grafana; logging/update.sh
  # copies it to the logging VM. TCP 9095 is open below; the logging VM and the
  # mothership share mgmt, so no firewall rule is involved, and the token is
  # what decides.
  systemd.services.tappaas-alert-token = {
    description = "Generate the token Grafana's alert webhook presents (#126)";
    wantedBy = [ "multi-user.target" ];
    before = [ "tappaas-alert-receiver.service" ];
    unitConfig.ConditionPathExists = "!/etc/secrets/tappaas-alert-token";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tappaas-alert-token" ''
        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets
        ${pkgs.openssl}/bin/openssl rand -hex 32 \
          | ${pkgs.coreutils}/bin/install -m 0600 -o tappaas -g users /dev/stdin /etc/secrets/tappaas-alert-token
      '';
    };
  };

  systemd.services.tappaas-alert-receiver = {
    description = "Receive Grafana alert webhooks and mail them to the site owner (#126)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "tappaas-alert-token.service" ];
    wants = [ "network-online.target" ];
    requires = [ "tappaas-alert-token.service" ];
    serviceConfig = {
      User = "tappaas";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/tappaas-alert-receiver.py}";
      Restart = "on-failure";
      RestartSec = 5;
      # site-notify.sh needs ssh and jq, as the failure notice does (above).
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      ProtectSystem = "strict";
      # config/ for the breadcrumb, /var/lib/tappaas for the heartbeat file.
      ReadWritePaths = [ "/home/tappaas/config" "/var/lib/tappaas" ];
    };
  };

  # ----------------------------------------
  # The console (ADR-034): the site's web UI
  # ----------------------------------------
  # ~/bin/console is built by the control-plane refresh (ui/install.sh, like the
  # managers), which runs after this system is first built — so a path unit
  # starts the service the moment the bin appears, and a fresh install ends with
  # the console up. It listens on the mothership's mgmt address and loopback,
  # TCP 9097, and accepts the firewall (Caddy and the Authentik gate) and
  # loopback only; before identity exists, mgmt and the admin VPN with the setup
  # token bootstrap.sh wrote (D10). It reads the site through the managers and,
  # from P2, changes it only by running their verbs as jobs (the operator's own
  # verbs, as tappaas, in this unit's sandbox): what they write is listed below.
  systemd.paths.tappaas-console = {
    description = "Start the TAPPaaS console once its bin is built (ADR-034)";
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathExists = "/home/tappaas/bin/console";
  };

  systemd.services.tappaas-console = {
    description = "TAPPaaS console — the site's web UI (ADR-034)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "/home/tappaas/bin/console";
    serviceConfig = {
      User = "tappaas";
      ExecStart = "/home/tappaas/bin/console serve";
      # "always", not "on-failure": the console exits 0 on purpose to take up a
      # new build. ui/install.sh does not restart it while a job runs (the
      # relink is reached from `module update tappaas-cicd`, itself a job — a
      # restart would kill it); it leaves restart-pending in the state
      # directory and the console exits the moment its runner is idle. A
      # `systemctl stop` is not an exit and is not restarted.
      Restart = "always";
      RestartSec = 10;
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      ProtectSystem = "strict";
      # The console's own files: Activity (jobs.jsonl) and the health document
      # it hands to `network-manager topology`.
      StateDirectory = "tappaas/console";
      ReadWritePaths = [
        # The verbs the console runs write all over the operator's home, as they
        # do from a shell: config/ (every manager's records), the repository
        # clones (`repository add/sync/hold` make and pull ~/<name>, ~/TAPPaaS),
        # the credential files the Setup wizard writes where the scripts read
        # them (~/.acme-dns-credentials.txt, ~/.unifi-os-credentials.txt,
        # ~/.wlan-secrets.txt, created on a fresh install, so no per-file entry
        # can name them in advance), ~/.ssh/known_hosts (a re-provisioned node's
        # host key), ~/logs, and nix's ~/.cache and ~/.tappaas-gcroots for the
        # builds `module add/update` run. Read-only below: what would let a
        # compromised console log in elsewhere (the SSH keys and the
        # controllers' credentials), or plant code in the next login shell or
        # git run. ~/bin stays writable, with this reason: `site-manager
        # repository sync` and `module update tappaas-cicd` relink it from
        # inside a console job (refresh-control-plane.sh), and running those
        # two verbs outside the sandbox (tappaas-unit-run) would put the
        # heaviest verbs the console runs outside it altogether — a bigger
        # change than this list, kept as a follow-up.
        "/home/tappaas"
        # /tmp itself, not a private one: `site-manager node add` stages
        # the netboot files in /tmp/tappaas-serve and serves them from a
        # transient unit, which sees the real /tmp; the bash controllers make
        # their scratch directories there too.
        "/tmp"
        # `node add` runs `sudo node-provisioner`, which writes the PXE
        # asset tree as root (still inside this unit's sandbox); sudo records
        # its timestamp under /run/sudo. "-": absent until first used.
        "-/var/lib/tappaas-pxe"
        "-/run/sudo"
        # `backup-manager key export --usb` records which keys the stick now
        # holds (usb-copy.json, beside the escrow, tappaas's): without it the
        # write succeeds but the backup-keys gate keeps asking for a stick.
        "-/etc/secrets/backup-fs"
      ];
      ReadOnlyPaths = [
        "-/home/tappaas/.ssh/authorized_keys"
        "-/home/tappaas/.bashrc"
        "-/home/tappaas/.profile"
        "-/home/tappaas/.bash_profile"
        "-/home/tappaas/.gitconfig"
        "-/home/tappaas/.config/git"
        # The verbs READ these (ssh to the nodes and the firewall, OPNsense's
        # API credentials); only install-platform.sh and cicd-key.sh write
        # them, neither from a job. Not listed, because a job writes them:
        # ~/.authentik-credentials.txt (ensure-authentik-creds.sh re-fetches
        # the token inside `identity` and every accessControl install) and
        # ~/.loki-admin-password (lib/log-shipping.sh creates it on first use,
        # from `logging update` and update-os.sh). "-": absent until the
        # install step that creates it.
        "-/home/tappaas/.ssh/config"
        "-/home/tappaas/.ssh/id_ed25519"
        "-/home/tappaas/.ssh/id_ed25519.pub"
        "-/home/tappaas/.ssh/id_rsa"
        "-/home/tappaas/.ssh/id_rsa.pub"
        "-/home/tappaas/.ssh/tappaas-fw"
        "-/home/tappaas/.ssh/tappaas-fw.pub"
        "-/home/tappaas/.opnsense-credentials.txt"
      ];
    };
  };

  # The alerting watches itself (#126): Grafana's Heartbeat rule reaches the
  # receiver hourly while logs flow and rules run; this timer — here, not on the
  # logging VM it watches — mails when that stops for two hours, so a dead
  # logging VM, Grafana, Loki or token cannot leave the site silently unwatched.
  systemd.services.tappaas-alert-watchdog = {
    description = "Mail when the log alerting has stopped reporting (#126)";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = "/home/tappaas/bin/tappaas-alert-watchdog.sh";
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ "/home/tappaas/config" "/var/lib/tappaas" ];
    };
  };

  systemd.timers.tappaas-alert-watchdog = {
    description = "Check the log alerting's heartbeat every 15 minutes (#126)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30min";
      OnUnitActiveSec = "15min";
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

  # #860: read the switches after every sweep (OnSuccess/OnFailure of
  # update-tappaas above), never by a timer of its own. `switch-manager
  # interrogate --no-park` reads every controller and auto switch — it never
  # parks and never applies — then the switch-ports gate runs over what was read,
  # and the owner is mailed when it has a finding it did not have the last time.
  # Like the sweep's own steps it runs in the operator's login shell (#767): the
  # read logs in to the switch controller and validate reaches the nodes. A
  # separate unit, so a switch that cannot be read never marks a sweep failed.
  systemd.services.tappaas-switch-read = {
    description = "TAPPaaS switch read — the switches as they are, after a sweep (#860)";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = "/run/current-system/sw/bin/bash -l -c 'tappaas-switch-read.sh --if-new-sweep --notify'";
      TimeoutStartSec = "15min";
    };
  };

  # ADR-017 D2: the timer is no longer declared here. update-tappaas-schedule
  # renders it from site.json .updateSchedule into /run at boot, after every
  # self-rebuild and on every schedule change (Persistent=false, D1).
  systemd.services.update-tappaas-schedule = {
    description = "Render update-tappaas.timer from site.json (ADR-017 D2)";
    wantedBy = [ "timers.target" ];
    # A fresh mothership has neither yet: bootstrap.sh's first switch runs before
    # install.sh writes config/ and links ~/bin. Skipped then (a condition is no
    # failure, so the switch succeeds); install.sh starts it once both exist.
    unitConfig.ConditionPathExists = [ "/home/tappaas/config/site.json" "/home/tappaas/bin/update-tappaas-schedule.sh" ];
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
  # The trigger, tappaas-fs-backup.service/.timer, is the baseline's (#626): the
  # same unit every guest has, inert until backup:filesystem deploys the runner
  # (ConditionPathExists), and timed by the generated tappaas-backup.nix (#691).
  # It runs as root because the capture set includes /etc/secrets, whose escrow
  # of every module's encryption key is root-only.

  # check-firewall-cert — the firewall API's certificate changed? (#310)
  # Every controller call skips certificate verification (self-signed, for
  # another name), so a rotation — or something answering as the firewall —
  # is otherwise invisible. Logs a line on a change; logging mails it
  # (FirewallCertChanged). The record is config/firewall-cert.json.
  systemd.services.check-firewall-cert = {
    description = "TAPPaaS: has the firewall API certificate changed";
    serviceConfig = {
      Type = "oneshot";
      User = "tappaas";
      ExecStart = "/home/tappaas/bin/check-firewall-cert.sh";
      Environment = [
        ("PATH=/home/tappaas/bin:/run/wrappers/bin:/home/tappaas/.nix-profile/bin"
          + ":/etc/profiles/per-user/tappaas/bin:/nix/var/nix/profiles/default/bin"
          + ":/run/current-system/sw/bin")
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/home/tappaas/config" ];
      PrivateTmp = true;
    };
  };
  systemd.timers.check-firewall-cert = {
    description = "Hourly trigger for check-firewall-cert";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "60s";
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

  # The mothership's journal goes to logging through the baseline's journal
  # client (#770): tappaas-self-rebuild.sh writes /etc/nixos/tappaas-logging.nix
  # from lib/log-shipping.sh — the same pipeline as every NixOS VM. Units that
  # handle OPNsense credentials are dropped there (tappaas-cicd.json
  # config."logging:logs".dropUnits) and secret patterns scrubbed before a line
  # leaves this host.

  systemd.tmpfiles.rules = [
    # check-ha-health.sh records when each HA service entered a transitional
    # state, so it can alert on duration rather than on the state alone (#146).
    "d /var/lib/tappaas 0750 tappaas users -"
    # config/: most units name it in ReadWritePaths, and a missing directory
    # fails their namespace setup — on a fresh mothership the first switch runs
    # before install.sh writes anything there (lab2 bootstrap, 2026-10-27).
    "d /home/tappaas/config 0755 tappaas users -"
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

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Add any missing dynamic libraries for unpackaged programs
    # here, NOT in environment.systemPackages
  ];

  # System packages
  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [
        tmux        # persistent sessions for long-running ops over SSH
        jq
        gh          # GitHub CLI
        tea         # Forgejo CLI for the Codeberg issue tracker
        dig
        shellcheck   # bash script linting for module *.sh validation (#265)
        # OPNsense controller tools (opnsense-controller, opnsense-firewall, zone-manager, dns-manager)
        opnsenseController.default
        # Authentik controller tools (authentik-controller; its old names authentik-manager and
        # identity-controller are aliases for one release, ADR-035 P2)
        identityController.default
        # TFTP server for node-provisioner's PXE trap (runs tftp-only via
        # systemd-run when provisioning is enabled; node-provisioning.md N3)
        dnsmasq
        # node-provisioner prepare builds the installer stick image with it
        xorriso
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
  networking.firewall.allowedTCPPorts = [
    8090  # node-provisioner (above)
    9095  # tappaas-alert-receiver: Grafana's alert webhook (#126)
    9097  # tappaas-console (ADR-034): the console filters its peers itself
  ];
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
