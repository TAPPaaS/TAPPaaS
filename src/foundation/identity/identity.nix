# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Authentik Identity Provider
# ============================================================================
# Version: 1.0.0
# Date: 2026-02-17
# Author: @ErikDaniel007 (TAPPaaS)
# Product: Authentik IdP with PostgreSQL + Redis backend
#
# Architecture:
# - PostgreSQL 16 (user/group/policy storage)
# - Redis (caching, sessions, task queue) — only until Authentik 2025.10, which
#   no longer uses it; the walk to the target version is ak-step.nix (#748)
# - Authentik Server container (web UI + API, ports 9000/9443)
# - Authentik Worker container (background tasks, LDAP sync, email)
#
# Network: zone "srv" (VLAN 210, 10.2.10.0/24)
# Firewall: ports 22 (SSH) + 9000 (HTTP) + 9443 (HTTPS)
# Secrets: Auto-generated AUTHENTIK_SECRET_KEY on first boot
# Backups: the whole VM, by the platform's Proxmox Backup job (backup:vm)
#
# Changelog v1.0.0 (2026-02-17):
# - Removed VaultWarden (moved to separate module in src/security/vaultwarden/)
# - Full Authentik setup with server + worker containers
# - PostgreSQL 16 with ensureDatabases/ensureUsers
# - Redis for caching/sessions/task queue
# - Auto-generated secrets on first boot
# - Daily backup timers with 30-day retention
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning - change versions here only
  versions = {
    postgresPkg = pkgs.postgresql_16;
  };

  # Authentik moves ONE step per build along its release lines (#748): it
  # refuses to skip a line and cannot go back. Each line's latest patch, oldest
  # first; the last is this release's target. A new release appends a line.
  # ak.version is what this build runs; ak-step.nix says why.
  # 2025.2 stops at .3, not its latest .4: ghcr's 2025.2.4 tag is an arm64-only
  # manifest (every other tag here is multi-arch), so an x86 guest pulled an
  # image it cannot execute (#748, 2026-10-03). Each tag below was checked.
  ak = import ./ak-step.nix {
    # 2026.5 and later need the worker's own listeners moved off the server's
    # ports (akWorkerEnv below); without that 2026.5.7 answered every request
    # with an empty page on hrossen (#748, 2026-10-03).
    lines = [ "2025.2.3" "2025.4.4" "2025.6.4" "2025.8.6" "2025.10.4"
              "2025.12.6" "2026.2.7" "2026.5.7" "2026.8.3" ];
  };

  # Settings, as opposed to secrets: declared here, so a change reaches every
  # guest at its next update. (They used to live in /etc/secrets/authentik.env,
  # which is written once at first boot — a change there reached new installs only.)
  akEnv = {
    AUTHENTIK_POSTGRESQL__HOST = "localhost";
    AUTHENTIK_POSTGRESQL__PORT = "5432";
    AUTHENTIK_POSTGRESQL__USER = "authentik";
    AUTHENTIK_POSTGRESQL__NAME = "authentik";
    AUTHENTIK_LOG_LEVEL = "info";
    AUTHENTIK_DISABLE_STARTUP_ANALYTICS = "true";
  } // lib.optionalAttrs ak.redis {
    # Redis is not used from 2025.10 on
    AUTHENTIK_REDIS__HOST = "localhost";
    AUTHENTIK_REDIS__PORT = "6379";
  };

  # The worker binds Authentik's listen addresses too — from 2026.5 a Rust
  # health server whose fallback answers EVERY path with an empty 200. With
  # --network=host both containers share the guest's ports, and when the worker
  # wins :9000 the server only warns and every login, OIDC and API request gets
  # an empty page (#748: 2026.5.7 on hrossen; upstream's compose gives each
  # container its own network and never meets it). The worker's listeners go to
  # loopback ports of their own; harmless on the versions before.
  akWorkerEnv = akEnv // {
    AUTHENTIK_LISTEN__HTTP = "127.0.0.1:9001";
    AUTHENTIK_LISTEN__HTTPS = "127.0.0.1:9444";
    AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9301";
  };

  # From 2025.12 files are served from /data, and Authentik manages uploads (a
  # brand logo, an application icon) only when /data itself is a mount point.
  # /data/media is a symlink to /media inside the image, so mounting there put
  # the volume on /media and left uploads refused ("No file management backend
  # configured"). Mount /data, as upstream's compose does; media is data/media.
  akMedia = if ak.dataMount
    then "/var/lib/authentik/data:/data"
    else "/var/lib/authentik/media:/media";
  akAfter = [ "postgresql.service" "generate-authentik-secrets.service" "authentik-env-secrets-only.service" ]
    ++ lib.optional ak.redis "redis-authentik.service"
    ++ lib.optional ak.dataMount "authentik-data-dir.service";
  akRequires = [ "postgresql.service" ] ++ lib.optional ak.redis "redis-authentik.service"
    ++ lib.optional ak.dataMount "authentik-data-dir.service";
in
{
  # ============================================================================
  # IMPORTS
  # ============================================================================

  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324): ssh, cloud-init, the
    # tappaas user, nix settings, zram/oomd, the NIC and hostname fixes, and the
    # site's own time and locale (it imports tappaas-site.nix). update-os.sh ships
    # it before every rebuild; this file states only what the module adds.
    /etc/nixos/tappaas-common.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    # Always present: update-os.sh ships an empty one, and backup:filesystem
    # overwrites it with the real trigger.
    /etc/nixos/tappaas-backup.nix
  ];

  # ============================================================================
  # NETWORKING
  # ============================================================================

  networking.hostName = lib.mkDefault "identity";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      9000  # Authentik HTTP
      9443  # Authentik HTTPS
    ];
  };

  # ============================================================================
  # TIME ZONE
  # ============================================================================

  # No time zone here: it is the site's fact, not the module's (#472). It
  # arrives through /etc/nixos/tappaas-site.nix, which the baseline imports.

  # ============================================================================
  # SYSTEM PACKAGES
  # ============================================================================

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ lsof jq openssl postgresql ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # ============================================================================
  # ESSENTIAL SERVICES
  # ============================================================================

  # The baseline allows root and password login for the bare template only;
  # every module turns both off.
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # ============================================================================
  # DATABASE - PostgreSQL 16
  # ============================================================================

  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "authentik" ];
    ensureUsers = [
      { name = "authentik"; ensureDBOwnership = true; }
    ];

    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';

    settings = {
      max_connections = 100;
      shared_buffers = "1GB";
      effective_cache_size = "2GB";
      maintenance_work_mem = "256MB";
      work_mem = "16MB";
      checkpoint_completion_target = 0.9;
      wal_buffers = "16MB";
      default_statistics_target = 100;
      random_page_cost = 1.1;
      effective_io_concurrency = 200;
      wal_level = "replica";
      archive_mode = "off";
    };
  };

  # ============================================================================
  # CACHING & SESSIONS - Redis 7
  # ============================================================================

  services.redis.servers."authentik" = {
    enable = ak.redis;
    port = 6379;
    bind = "127.0.0.1";
    settings = {
      maxmemory = "512mb";
      maxmemory-policy = "allkeys-lru";
      maxclients = 10000;
      timeout = 300;
      tcp-keepalive = 60;
    };
    save = [
      [900 1]
      [300 10]
      [60 10000]
    ];
  };

  # ============================================================================
  # CONTAINER RUNTIME
  # ============================================================================

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.generate-authentik-secrets = {
    description = "Generate Authentik secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "podman-authentik-server.service" "podman-authentik-worker.service" ];

    unitConfig.ConditionPathExists = "!/etc/secrets/authentik.env";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-authentik-secrets" ''
        SECRET_KEY="$(${pkgs.openssl}/bin/openssl rand -base64 60 | tr -d '\n')"
        # AUTHENTIK_BOOTSTRAP_TOKEN binds an API token to akadmin on first
        # boot (issue #45) — TAPPaaS reads it back from /etc/secrets/authentik.env
        # to drive every Authentik admin-API call (proxy app / outpost / etc.).
        # Without it the cicd has no programmatic way to talk to Authentik.
        BOOTSTRAP_TOKEN="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        # AUTHENTIK_BOOTSTRAP_PASSWORD lets a human log in as akadmin too —
        # used for the UI walk-through during E2E setup; rotateable later.
        BOOTSTRAP_PASSWORD="$(${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\n')"

        mkdir -p /etc/secrets

        cat > /etc/secrets/authentik.env <<EOF
AUTHENTIK_SECRET_KEY=$SECRET_KEY
AUTHENTIK_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN
AUTHENTIK_BOOTSTRAP_PASSWORD=$BOOTSTRAP_PASSWORD
AUTHENTIK_BOOTSTRAP_EMAIL=admin@localhost
EOF
        chmod 600 /etc/secrets/authentik.env

        echo "================================================"
        echo "AUTHENTIK SECRETS generated and saved to:"
        echo "/etc/secrets/authentik.env"
        echo "  AUTHENTIK_SECRET_KEY (server signing key)"
        echo "  AUTHENTIK_BOOTSTRAP_TOKEN (admin API token for TAPPaaS — #45)"
        echo "  AUTHENTIK_BOOTSTRAP_PASSWORD (akadmin web-UI password)"
        echo "================================================"
      '';
    };
  };

  environment.etc."secrets/authentik-template.env" = {
    text = ''
      # Secrets only: the settings are declared in identity.nix (akEnv).
      AUTHENTIK_SECRET_KEY=your_secret_key_here
      AUTHENTIK_BOOTSTRAP_TOKEN=your_api_token_here
      AUTHENTIK_BOOTSTRAP_PASSWORD=your_akadmin_password_here
      AUTHENTIK_BOOTSTRAP_EMAIL=admin@localhost
      # Optional SMTP configuration:
      # AUTHENTIK_EMAIL__HOST=smtp.example.com
      # AUTHENTIK_EMAIL__PORT=587
      # AUTHENTIK_EMAIL__USERNAME=authentik@example.com
      # AUTHENTIK_EMAIL__PASSWORD=
      # AUTHENTIK_EMAIL__USE_TLS=true
      # AUTHENTIK_EMAIL__USE_SSL=false
      # AUTHENTIK_EMAIL__FROM=authentik@example.com
    '';
    mode = "0600";
  };

  # ============================================================================
  # AUTHENTIK SERVER CONTAINER (Web UI + API)
  # ============================================================================

  virtualisation.oci-containers.containers.authentik-server = {
    image = "ghcr.io/goauthentik/server:${ak.version}";
    volumes = [
      akMedia
      "/var/lib/authentik/templates:/templates"
    ];
    environment = akEnv;
    environmentFiles = [ "/etc/secrets/authentik.env" ];
    extraOptions = [
      "--network=host"
      "--log-driver=journald"
    ];
    cmd = [ "server" ];
  };

  systemd.services.podman-authentik-server = {
    after = akAfter;
    requires = akRequires;
  };

  # ============================================================================
  # AUTHENTIK WORKER CONTAINER (Background tasks)
  # ============================================================================

  virtualisation.oci-containers.containers.authentik-worker = {
    image = "ghcr.io/goauthentik/server:${ak.version}";
    volumes = [
      akMedia
      "/var/lib/authentik/templates:/templates"
      "/var/lib/authentik/certs:/certs"
    ];
    environment = akWorkerEnv;
    environmentFiles = [ "/etc/secrets/authentik.env" ];
    extraOptions = [
      "--network=host"
      "--log-driver=journald"
      # The worker drains its dramatiq queue on SIGTERM: 16-32 s measured on
      # hrossen, past podman's 10 s default, so every stop ended in SIGKILL
      # (exit 137, unit failed — #786). Below the unit's 2 min TimeoutStopSec.
      "--stop-timeout=90"
    ];
    cmd = [ "worker" ];
  };

  systemd.services.podman-authentik-worker = {
    after = akAfter;
    requires = akRequires;
  };

  # ── The upgrade walk (#748) ───────────────────────────────────────────────
  # The env file holds secrets only. A guest installed before this change has
  # its settings in it too — Redis among them, which would outlive 2025.10 —
  # so they are stripped before the containers start. Idempotent, every boot.
  systemd.services.authentik-env-secrets-only = {
    description = "Keep only secrets in /etc/secrets/authentik.env";
    wantedBy = [ "multi-user.target" ];
    after = [ "generate-authentik-secrets.service" ];
    before = [ "podman-authentik-server.service" "podman-authentik-worker.service" ];
    unitConfig.ConditionPathExists = "/etc/secrets/authentik.env";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      f=/etc/secrets/authentik.env
      t="$(mktemp /etc/secrets/.authentik.env.XXXXXX)"
      ${pkgs.gnugrep}/bin/grep -E '^AUTHENTIK_(SECRET_KEY|BOOTSTRAP_(TOKEN|PASSWORD|EMAIL))=' "$f" > "$t" || true
      # Rewrite only when something was stripped: a file that is already
      # secrets-only stays untouched (same inode, mtime, no log line).
      if ${pkgs.gnugrep}/bin/grep -q '^AUTHENTIK_SECRET_KEY=' "$t" && ! ${pkgs.diffutils}/bin/cmp -s "$f" "$t"; then
        chmod 600 "$t"; mv -f "$t" "$f"; echo "authentik.env: settings removed, secrets kept"
      else
        rm -f "$t"
      fi
    '';
  };

  # What this guest runs, written only once the new version is up — the server
  # running THIS build's image and answering ready, its migrations done. The
  # next build reads it (ak-step.nix) to take the next step; a hop that never
  # comes up leaves the old version recorded, so the next update retries it.
  systemd.services.authentik-version-record = {
    description = "Record the Authentik version this guest runs (${ak.version})";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman-authentik-server.service" "podman-authentik-worker.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "45min"; };
    path = [ pkgs.podman pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
    script = ''
      want="ghcr.io/goauthentik/server:${ak.version}"
      since="$(date '+%Y-%m-%d %H:%M:%S')"
      restarts0="$(systemctl show -p NRestarts --value podman-authentik-server.service 2>/dev/null || echo 0)"
      for _ in $(seq 1 520); do
        # A server that cannot start will not start by waiting: say so now, not
        # after 45 minutes of a switch that looks hung (#748: an arm64 image).
        if systemctl is-failed --quiet podman-authentik-server.service; then
          echo "authentik ${ak.version}: the server failed to start — see journalctl -u podman-authentik-server" >&2
          exit 1
        fi
        # The unit restarts a dying container, so it never reads as failed: a
        # refused version restarted it for 45 minutes with SSO down (#797). Its
        # own refusal, or a server that keeps restarting, ends the wait now.
        if journalctl -u podman-authentik-server --since "$since" -o cat 2>/dev/null \
             | grep -q -m1 'version skips are not allowed'; then
          echo "authentik ${ak.version}: Authentik refuses this version (a release line skipped) — see journalctl -u podman-authentik-server" >&2
          exit 1
        fi
        if [ "$(( $(systemctl show -p NRestarts --value podman-authentik-server.service 2>/dev/null || echo 0) - restarts0 ))" -ge 3 ]; then
          echo "authentik ${ak.version}: the server restarted 3 times while starting — see journalctl -u podman-authentik-server" >&2
          exit 1
        fi
        img="$(podman inspect authentik-server --format '{{.ImageName}}' 2>/dev/null || true)"
        if [ "$img" = "$want" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:9000/-/health/ready/)" = 200 ]; then
          printf '%s\n' "${ak.version}" > /var/lib/authentik/tappaas-version
          echo "authentik ${ak.version} is up — recorded"
          exit 0
        fi
        sleep 5
      done
      echo "authentik ${ak.version} did not come up — the version stays as it was" >&2
      exit 1
    '';
  };

  # A step into 2025.12 fails its migration when two groups share a name; this
  # finds that first and writes it where the next build reads it (ak-step.nix),
  # so the step is refused before anything changes. Hourly, and at boot.
  systemd.services.authentik-step-precheck = {
    description = "Find what would fail the next Authentik migration";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = { Type = "oneshot"; User = "postgres"; };
    path = [ versions.postgresPkg pkgs.coreutils ];
    script = ''
      dup="$(psql -d authentik -tAc "select string_agg(name, ', ') from (select name from authentik_core_group group by name having count(*) > 1) d" 2>/dev/null || true)"
      f=/var/lib/authentik/tappaas-step-blocked
      if [ -n "$dup" ]; then
        printf 'duplicate group names (%s) — rename them; Authentik 2025.12 makes group names unique\n' "$dup" > "$f"
      else
        : > "$f"   # empty = nothing blocks (postgres owns the file, not the directory)
      fi
    '';
  };
  systemd.timers.authentik-step-precheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "1h"; };
  };

  # The /data mount (above) holds media under data/media. A guest that ran with
  # the old /var/lib/authentik/media gets its files moved across once, before
  # either container starts.
  systemd.services.authentik-data-dir = lib.mkIf ak.dataMount {
    description = "Move Authentik's media under /var/lib/authentik/data";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      old=/var/lib/authentik/media new=/var/lib/authentik/data/media
      ${pkgs.coreutils}/bin/install -d -o 1000 -g 1000 -m 0755 /var/lib/authentik/data "$new"
      if [ -d "$old" ] && [ ! -L "$old" ]; then
        ${pkgs.coreutils}/bin/cp -a "$old/." "$new/"
        ${pkgs.coreutils}/bin/rm -rf "$old"
        echo "moved $old to $new"
      fi
    '';
  };

  # Backup is the platform's: backup:vm puts the whole VM in the site's Proxmox
  # Backup job (ADR-012), database, secrets and media together, and a restore is
  # a VM restore (backup/RESTORE.md). The in-VM dumps, Redis snapshots and env
  # tar this module carried until 2026-10 were read by nothing (#754).

  # ============================================================================
  # LOG SHIPPING - journal -> Loki on the logging VM (#770)
  # ============================================================================

  # Authentik's events -- logins, failed logins, OAuth rejections, token and
  # admin changes -- are the site's audit trail. They ship through the
  # baseline's journal client (identity.json integratesWith logging:logs;
  # update-os.sh writes /etc/nixos/tappaas-logging.nix). The units that read or
  # write Authentik's secrets are dropped there (config."logging:logs".dropUnits).
  # Authentik logs JSON lines: query with `| json` in Grafana.

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    # The in-VM backups are gone (#754); their directories go with them.
    "R /var/backup/postgresql - - - -"
    "R /var/backup/redis - - - -"
    "R /var/backup/authentik-env - - - -"
    "d /var/lib/authentik 0755 root root -"
    # the precheck (User = postgres) writes its finding here
    "f /var/lib/authentik/tappaas-step-blocked 0644 postgres postgres -"
  ] ++ (if ak.dataMount then [
    "d /var/lib/authentik/data 0755 1000 1000 -"
  ] else [
    "d /var/lib/authentik/media 0755 1000 1000 -"
  ]) ++ [
    "d /var/lib/authentik/templates 0755 1000 1000 -"
    "d /var/lib/authentik/certs 0755 1000 1000 -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
