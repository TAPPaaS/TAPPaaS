# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# ----------------------------------------
# TAPPaaS
# Name: Open webui
# Type: APP
# Version: 0.10.2
# Date: 2026-07-02
# Author: @ErikDaniel007 (Tappaas)
# Products: openwebui, postgres, redis
#
# Changelog v0.10.2 (2026-07-02):
# - Upgraded OpenWebUI 0.9.6 → 0.10.2
# - Upstream 0.10.x includes a database schema migration and a
#   tool-calling-mode default change (Legacy → Native) — validate via
#   test-variant deploy before any production rollout; upstream changelog
#   content could not be independently verified from this session, treat
#   as unconfirmed until re-checked against a live source at deploy time.
# - No PostgreSQL major-version change required (already on postgresql_17)
#
# Changelog v0.9.6 (2026-06-02):
# - Upgraded OpenWebUI 0.9.5 → 0.9.6
# - Fixed registry inconsistency: ExecStartPre now uses docker.io (was ghcr.io)
# - Fixed backup: exclude cache/ (embedding models are regeneratable, not user data)
#
# Changelog v0.9.5 (2026-05-20):
# - Upgraded OpenWebUI 0.8.10 → 0.9.5; registry GHCR → Docker Hub
# - Upgraded PostgreSQL 15 → 17
# - Added Redis AOF persistence (appendonly + appendfsync everysec)
# - Auto-generate secrets on first boot (no more placeholder values)
# - Added 7-day backup rotation per backup job
# ----------------------------------------

{ config, pkgs, lib, ... }:

let
  # ----------------------------------------
  # Version pinning
  # Change versions in one place only
  # ----------------------------------------
  versions = {
    openwebui   = "0.10.2";              # OpenWebUI container version (Docker Hub, no v-prefix)
    postgresPkg = pkgs.postgresql_17;   # PostgreSQL version
    redisPkg    = pkgs.redis;           # Redis version
  };
in
{
  # ----------------------------------------
  # Imports
  # ----------------------------------------
  imports = [ /etc/nixos/hardware-configuration.nix ];

  # ----------------------------------------
  # Bootloader
  # ----------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ----------------------------------------
  # Kernel parameters
  # ----------------------------------------
  boot.kernelParams = [ "systemd.unified_cgroup_hierarchy=1" ];

  # ----------------------------------------
  # System Identity
  # ----------------------------------------
  system.stateVersion = "25.05";

  # ----------------------------------------
  # Network Configuration
  # ----------------------------------------
  networking.hostName = let
    cfg = if builtins.pathExists ./openwebui.json
          then builtins.fromJSON (builtins.readFile ./openwebui.json)
          else {};
  in lib.mkDefault (cfg.vmname or "openwebui");

  networking = {
    networkmanager.enable = true;
    # Match ethernet by type, not interface name (ens18/eth0/enp0s18 varies)
    networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
      connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
      ipv4 = { method = "auto"; };
      ipv6 = { method = "auto"; addr-gen-mode = "default"; };
    };
  };

  networking.firewall = { enable = true; allowedTCPPorts = [ 22 8080 ]; };

  # Disable systemd-networkd (conflicts with NetworkManager)
  systemd.network.enable = lib.mkForce false;               # Avoid conflict
  systemd.network.wait-online.enable = lib.mkForce false;   # Fast boot

  # ----------------------------------------
  # Timezone
  # ----------------------------------------
  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # ----------------------------------------
  # Users
  # ----------------------------------------
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
  };

  users.users.svc_openwebui_admin = {
    isSystemUser = true;
    group = "svc_openwebui";
    home = "/var/lib/openwebui";
    createHome = true;
    uid = 1001;
  };

  users.groups.svc_openwebui.gid = 1001;

  # Redis user (needed for backup service)
  users.users.redis = {
    isSystemUser = true;
    createHome = false;
    group = "redis";
  };
  users.groups.redis.gid = 1010;

  # ----------------------------------------
  # Core system services
  # ----------------------------------------
  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.cloud-init = {
    enable = true;
    network.enable = false; # modified - should stay false!
  };

  # ----------------------------------------
  # PostgreSQL service
  # ----------------------------------------
  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "openwebui" ];
    ensureUsers = [
      { name = "openwebui"; ensureDBOwnership = true; }
    ];
    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
    settings = {
      max_connections = 100;
      shared_buffers = "256MB";
    };
  };

  # ----------------------------------------
  # Redis service
  # ----------------------------------------
  services.redis.servers.openwebui = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
    settings = {
      appendonly = "yes";
      appendfsync = "everysec";
    };
    save = [
      [900 1]
      [300 10]
      [60 10000]
    ];
  };

  # ----------------------------------------
  # Podman container runtime
  # ----------------------------------------
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ----------------------------------------
  # OpenWebUI container wrapper
  # ----------------------------------------
  systemd.services.openwebui-wrapper = let
    startScript = pkgs.writeShellScript "openwebui-start" ''
      exec ${pkgs.podman}/bin/podman run \
        --name openwebui \
        --network=host \
        --log-driver=journald \
        --env-file=/etc/secrets/openwebui.env \
        --env-file=/etc/secrets/openwebui-integrations.env \
        -v /var/lib/openwebui/data:/app/backend/data \
        -v /var/lib/openwebui/models:/app/backend/data/models \
        docker.io/openwebui/open-webui:${versions.openwebui}
    '';
  in {
    description = "OpenWebUI via Podman wrapper";
    after = [ "network.target" "openwebui-integrations.service" ];
    requires = [ "openwebui-integrations.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${startScript}";
      ExecStop = "${pkgs.podman}/bin/podman stop openwebui";
      ExecStartPre = pkgs.writeShellScript "openwebui-prestart" ''
        IMAGE="docker.io/openwebui/open-webui:${versions.openwebui}"
        if ! ${pkgs.podman}/bin/podman image exists "$IMAGE"; then
          echo "Image $IMAGE not found locally, pulling..."
          ${pkgs.podman}/bin/podman pull "$IMAGE"
        else
          echo "Image $IMAGE already present locally, skipping pull."
        fi
        ${pkgs.podman}/bin/podman rm -f openwebui || true
      '';
      TimeoutStartSec = 600;
      Restart = "always";
      RestartSec = 10;
      Delegate = true;
      NoNewPrivileges = true;
      ProtectSystem = "full";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [
        "/var/lib/openwebui"
        "/sys/fs/cgroup"
        "/sys/fs/cgroup/machine.slice"
      ];
    };
  };

  # ----------------------------------------
  # Secrets — auto-generated on first boot, never overwritten by NixOS
  # ----------------------------------------
  systemd.services.generate-openwebui-secrets = {
    description = "Generate OpenWebUI secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "openwebui-wrapper.service" ];
    unitConfig.ConditionPathExists = "!/etc/secrets/openwebui.env";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-openwebui-secrets" ''
        SECRET_KEY="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        mkdir -p /etc/secrets
        cat > /etc/secrets/openwebui.env <<EOF
DATABASE_URL=postgresql://openwebui@127.0.0.1:5432/openwebui
WEBUI_SECRET_KEY=$SECRET_KEY
WEBUI_AUTH=True
WEBUI_NAME=TAPPaaS Open WebUI
DATA_DIR=/app/backend/data
OPENWEBUI_PORT=8080
ENABLE_WEBSOCKET_SUPPORT=true
WEBSOCKET_MANAGER=redis
WEBSOCKET_REDIS_URL=redis://127.0.0.1:6379/1
REDIS_KEY_PREFIX=openwebui
EOF
        chmod 600 /etc/secrets/openwebui.env
        echo "OpenWebUI secrets generated."
      '';
    };
  };


  # ----------------------------------------
  # Provider integrations — LiteLLM + Authentik OIDC
  # ----------------------------------------
  #
  # Both providers already deliver their secrets to this VM, but under THEIR
  # variable names, and OpenWebUI reads neither:
  #   litellm:models    -> /etc/secrets/litellm-svckey.env  (LITELLM_API_KEY, LITELLM_BASE_URL)
  #   identity:identity -> /etc/secrets/openwebui-oidc.env  (OIDC_CLIENT_ID/SECRET/DISCOVERY_URI)
  #
  # Before this, litellm:models wired a virtual key and then told the operator to
  # "configure OpenWebUI admin -> Settings -> Connections" BY HAND, and there was
  # no OIDC at all. This service translates both into the names OpenWebUI expects
  # and writes a single env-file the container loads.
  #
  # It runs BEFORE the wrapper (podman needs every --env-file to exist, so the
  # file is always created, even empty), and is the `identity.configureService`
  # that identity:identity restarts after writing new OIDC secrets — so a
  # credential rotation regenerates this file and restarts the container.
  # The restart is guarded on content actually changing, so a reconcile that
  # changes nothing does not bounce the service.
  systemd.services.openwebui-integrations = {
    description = "Translate provider secrets into OpenWebUI settings";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openwebui-integrations" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.systemd}/bin:$PATH"
        OUT=/etc/secrets/openwebui-integrations.env
        LITELLM=/etc/secrets/litellm-svckey.env
        OIDC=/etc/secrets/openwebui-oidc.env
        OWNER=/etc/secrets/openwebui-owner.env

        mkdir -p /etc/secrets

        # Read a KEY=value from a file without sourcing it (values may contain
        # characters that would be re-interpreted by the shell).
        readvar() { [ -f "$1" ] && grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

        NEW=""
        add() { NEW="$NEW$1"$'\n'; }

        # ── LiteLLM: the OpenAI-compatible endpoint OpenWebUI talks to ──
        LK="$(readvar "$LITELLM" LITELLM_API_KEY)"
        LB="$(readvar "$LITELLM" LITELLM_BASE_URL)"
        if [ -n "$LK" ] && [ -n "$LB" ]; then
          add "OPENAI_API_KEY=$LK"
          add "OPENAI_API_BASE_URL=$LB"
          add "ENABLE_OPENAI_API=true"
        fi

        # ── Authentik OIDC ──
        CID="$(readvar "$OIDC" OIDC_CLIENT_ID)"
        CSE="$(readvar "$OIDC" OIDC_CLIENT_SECRET)"
        DIS="$(readvar "$OIDC" OIDC_DISCOVERY_URI)"
        if [ -n "$CID" ] && [ -n "$CSE" ] && [ -n "$DIS" ]; then
          add "ENABLE_OAUTH_SIGNUP=true"
          # Merge by email so the pre-seeded owner account (see
          # openwebui-seed-admin) is adopted by the owner's first SSO login
          # instead of a second, non-admin account being created alongside it.
          add "OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true"
          add "OAUTH_CLIENT_ID=$CID"
          add "OAUTH_CLIENT_SECRET=$CSE"
          add "OPENID_PROVIDER_URL=$DIS"
          add "OAUTH_PROVIDER_NAME=TAPPaaS"
          add "OAUTH_SCOPES=openid email profile"
        fi

        # Owner email is informational for the container; the seeding service
        # below is what actually uses it.
        OE="$(readvar "$OWNER" OPENWEBUI_OWNER_EMAIL)"
        [ -n "$OE" ] && add "OPENWEBUI_OWNER_EMAIL=$OE"

        # The file must EXIST unconditionally: podman --env-file fails hard on a
        # missing file, so an instance with no provider secrets yet (first boot,
        # before litellm:models/identity:identity have run) must still get an
        # empty one. Comparing content alone is not enough — empty content and a
        # missing file compare equal, which is what broke the first install.
        OLD="$(cat "$OUT" 2>/dev/null || true)"
        if [ ! -f "$OUT" ] || [ "$OLD" != "$NEW" ]; then
          T="$(mktemp /etc/secrets/.owui-int.XXXXXX)"
          printf '%s' "$NEW" > "$T"
          chmod 600 "$T"
          mv -f "$T" "$OUT"
          echo "openwebui-integrations: settings updated"
          # Only bounce the container when it is already running: at boot the
          # wrapper has not started yet and requires this unit, so restarting it
          # here would deadlock.
          if systemctl is-active --quiet openwebui-wrapper.service; then
            systemctl restart openwebui-wrapper.service || true
          fi
        else
          echo "openwebui-integrations: no change"
        fi
      '';
    };
  };


  # ----------------------------------------
  # Seed the admin account as the environment owner
  # ----------------------------------------
  #
  # OpenWebUI makes the FIRST account to sign up an admin; every later account
  # gets DEFAULT_USER_ROLE. Left alone that means whoever happens to log in first
  # owns the instance — on a fresh deploy, quite possibly not the environment
  # owner. This seeds the owner's account before anyone can log in, so the admin
  # is deterministic.
  #
  # The email is pushed by update.sh, which resolves it on the TAPPaaS side:
  #   environment.ownerOrg -> org.owner -> user.primaryEmail
  #
  # Signup goes through OpenWebUI's OWN API rather than direct DB inserts, so it
  # stays correct across schema changes between versions. The password is random
  # and deliberately discarded: the owner signs in via SSO, and
  # OAUTH_MERGE_ACCOUNTS_BY_EMAIL adopts this account on first login.
  #
  # Runs once — it does nothing as soon as any account exists, so it can never
  # take an instance over from real users.
  systemd.services.openwebui-seed-admin = {
    description = "Seed the OpenWebUI admin account as the environment owner";
    wantedBy = [ "multi-user.target" ];
    after = [ "openwebui-wrapper.service" "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openwebui-seed-admin" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.util-linux}/bin:${versions.postgresPkg}/bin:$PATH"
        OWNER=/etc/secrets/openwebui-owner.env

        EMAIL="$(grep -m1 '^OPENWEBUI_OWNER_EMAIL=' "$OWNER" 2>/dev/null | cut -d= -f2-)"
        NAME="$(grep -m1 '^OPENWEBUI_OWNER_NAME=' "$OWNER" 2>/dev/null | cut -d= -f2-)"
        if [ -z "$EMAIL" ]; then
          echo "seed-admin: no owner email recorded yet — skipping"
          exit 0
        fi
        [ -n "$NAME" ] || NAME="$EMAIL"

        # Already have accounts? Then the instance is in use; never interfere.
        COUNT="$(runuser -u postgres -- psql -d openwebui -tAc 'SELECT COUNT(*) FROM auth' 2>/dev/null | tr -d '[:space:]')"
        if [ -z "$COUNT" ]; then
          echo "seed-admin: database not ready — skipping (will retry on next converge)"
          exit 0
        fi
        if [ "$COUNT" != "0" ]; then
          echo "seed-admin: $COUNT account(s) already exist — nothing to do"
          exit 0
        fi

        # Wait for the API to answer; the container may still be starting.
        i=0
        while [ "$i" -lt 60 ]; do
          curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/health && break
          i=$((i + 1)); sleep 5
        done

        PW="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        if curl -fsS --max-time 20 -X POST http://127.0.0.1:8080/api/v1/auths/signup \
             -H 'Content-Type: application/json' \
             -d "{\"name\":\"$NAME\",\"email\":\"$EMAIL\",\"password\":\"$PW\"}" >/dev/null
        then
          echo "seed-admin: created $EMAIL as the first account (admin)"
        else
          echo "seed-admin: signup failed for $EMAIL — will retry on next converge" >&2
        fi
        unset PW
      '';
    };
  };


  # ----------------------------------------
  # Reconcile OpenWebUI's PERSISTED OpenAI connection
  # ----------------------------------------
  #
  # OPENAI_API_BASE_URL / OPENAI_API_KEY are only applied as INITIAL DEFAULTS.
  # OpenWebUI persists them into its `config` table on first start, and from then
  # on the DATABASE wins — changing the env afterwards has no effect at all.
  #
  # That is not a corner case: on a fresh deploy the container starts before
  # litellm:models has provisioned the virtual key, so OpenWebUI persists its
  # built-in defaults (api.openai.com with an empty key). Every later converge
  # then wrote the correct env, restarted the container, reported success — and
  # the UI still showed no models, because the DB still pointed at OpenAI.
  #
  # So the connection has to be reconciled where it actually lives. The config
  # table is a simple key/value store; api_base_urls and api_keys are parallel
  # arrays indexed together. Idempotent: it compares first and only writes (and
  # only restarts the container) when the stored value actually differs.
  systemd.services.openwebui-apply-connection = {
    description = "Point OpenWebUI's stored OpenAI connection at the provider";
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" "openwebui-wrapper.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openwebui-apply-connection" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.util-linux}/bin:${pkgs.systemd}/bin:${versions.postgresPkg}/bin:$PATH"
        SRC=/etc/secrets/openwebui-integrations.env

        readvar() { [ -f "$1" ] && grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
        BASE="$(readvar "$SRC" OPENAI_API_BASE_URL)"
        KEY="$(readvar "$SRC" OPENAI_API_KEY)"
        if [ -z "$BASE" ] || [ -z "$KEY" ]; then
          echo "apply-connection: no provider endpoint recorded yet — skipping"
          exit 0
        fi

        q() { runuser -u postgres -- psql -d openwebui -tAc "$1" 2>/dev/null; }

        # Nothing to reconcile until OpenWebUI has created its config table.
        HAVE="$(q "SELECT to_regclass('public.config')")"
        [ -n "$HAVE" ] || { echo "apply-connection: config table not present yet — skipping"; exit 0; }

        CUR_B="$(q "SELECT value::text FROM config WHERE key = 'openai.api_base_urls'")"
        CUR_K="$(q "SELECT value::text FROM config WHERE key = 'openai.api_keys'")"

        if [ "$CUR_B" = "[\"$BASE\"]" ] && [ "$CUR_K" = "[\"$KEY\"]" ]; then
          echo "apply-connection: stored connection already correct"
          exit 0
        fi

        runuser -u postgres -- psql -d openwebui -v ON_ERROR_STOP=1 \
          -c "INSERT INTO config (key, value, updated_at) VALUES ('openai.api_base_urls', to_json(ARRAY['$BASE']::text[]), extract(epoch from now())::bigint) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at" \
          -c "INSERT INTO config (key, value, updated_at) VALUES ('openai.api_keys', to_json(ARRAY['$KEY']::text[]), extract(epoch from now())::bigint) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at" \
          -c "INSERT INTO config (key, value, updated_at) VALUES ('openai.enable', 'true'::json, extract(epoch from now())::bigint) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at" \
          >/dev/null 2>&1 \
          && echo "apply-connection: stored connection now points at $BASE" \
          || { echo "apply-connection: failed to update stored connection" >&2; exit 0; }

        # The running container caches the connection; restart so it re-reads.
        if systemctl is-active --quiet openwebui-wrapper.service; then
          systemctl restart openwebui-wrapper.service || true
        fi
      '';
    };
  };

  # Template only — actual secrets are auto-generated above
  environment.etc."secrets/openwebui-template.env".text = ''
    DATABASE_URL=postgresql://openwebui@127.0.0.1:5432/openwebui
    WEBUI_SECRET_KEY=<auto-generated on first boot>
    WEBUI_AUTH=True
    WEBUI_NAME=TAPPaaS Open WebUI
    DATA_DIR=/app/backend/data
    OPENWEBUI_PORT=8080
    ENABLE_WEBSOCKET_SUPPORT=true
    WEBSOCKET_MANAGER=redis
    WEBSOCKET_REDIS_URL=redis://127.0.0.1:6379/1
    REDIS_KEY_PREFIX=openwebui
  '';

  # ----------------------------------------
  # Data directories
  # ----------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/openwebui 0750 svc_openwebui_admin svc_openwebui -"
    "d /var/lib/openwebui/data 0750 svc_openwebui_admin svc_openwebui -"
    "d /var/lib/openwebui/models 0750 svc_openwebui_admin svc_openwebui -"
    "d /var/backup/postgresql 0700 postgres postgres -"
    "d /var/backup/redis 0700 redis redis -"
    "d /var/backup/openwebui-data 0700 root root -"
    "d /var/backup/openwebui-env 0700 root root -"
    "f /etc/openwebui/start.sh 0755 root root -"
  ];

  # ----------------------------------------
  # Backup Services - PostgreSQL
  # ----------------------------------------
  systemd.services.postgresqlBackup = {
    description = "PostgreSQL backup service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "pg-backup" ''
        ${versions.postgresPkg}/bin/pg_dump -U openwebui openwebui | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/openwebui-pg-$(date +%F).sql.gz
        ${pkgs.findutils}/bin/find /var/backup/postgresql -name "*.sql.gz" -mtime +7 -delete
      '';
      User = "postgres";
    };
  };

  systemd.timers.postgresqlBackup = {
    description = "Daily PostgreSQL backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:00:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - Redis
  # ----------------------------------------
  systemd.services.redis-backup = {
    description = "Redis backup service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "redis-backup" ''
        ${versions.redisPkg}/bin/redis-cli --rdb /var/backup/redis/openwebui-redis-$(date +%F).rdb
        ${pkgs.findutils}/bin/find /var/backup/redis -name "*.rdb" -mtime +7 -delete
      '';
      User = "redis";
      Group = "redis";
    };
  };

  systemd.timers.redis-backup = {
    description = "Daily Redis backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:30:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - OpenWebUI container data
  # ----------------------------------------
  systemd.services.openwebui-container-backup = {
    description = "Backup OpenWebUI container data";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/openwebui-data";
      ExecStart = pkgs.writeShellScript "openwebui-data-backup" ''
        ${pkgs.gnutar}/bin/tar -cf - \
          --exclude='./cache' \
          -C /var/lib/openwebui/data \
          . \
          | ${pkgs.gzip}/bin/gzip > /var/backup/openwebui-data/openwebui-data-$(date +%F).tar.gz
        ${pkgs.findutils}/bin/find /var/backup/openwebui-data -name "*.tar.gz" -mtime +7 -delete
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.openwebui-container-backup = {
    description = "Daily OpenWebUI container data backup";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:45:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - Environment files
  # ----------------------------------------
  systemd.services.openwebui-env-backup = {
    description = "Backup OpenWebUI environment files";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/openwebui-env";
      ExecStart = pkgs.writeShellScript "openwebui-env-backup" ''
        ${pkgs.gnutar}/bin/tar -cf - \
          -C / etc/secrets \
          | ${pkgs.gzip}/bin/gzip > /var/backup/openwebui-env/openwebui-env-$(date +%F).tar.gz
        ${pkgs.findutils}/bin/find /var/backup/openwebui-env -name "*.tar.gz" -mtime +7 -delete
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.openwebui-env-backup = {
    description = "Daily OpenWebUI environment file backup";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 02:50:00";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # Backup Services - Cleanup old backups
  # ----------------------------------------
  systemd.services.cleanup-backups = {
    description = "Cleanup old backups";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup -type f -mtime +30 -delete
      '';
      User = "root";
    };
  };

  systemd.timers.cleanup-backups = {
    description = "Monthly cleanup of old backups";
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "monthly";
    timerConfig.Persistent = true;
  };

  # ----------------------------------------
  # System packages
  # ----------------------------------------
  environment.systemPackages = with pkgs; [
    vim wget curl htop git podman openssl postgresql redis crun
  ];

  # ----------------------------------------
  # Security settings
  # ----------------------------------------
  security.sudo.wheelNeedsPassword = false;

  # ----------------------------------------
  # Nix CLI and garbage collection
  # ----------------------------------------
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "daily"; options = "--delete-older-than 7d"; };
  nix.optimise = { automatic = true; dates = [ "weekly" ]; };

  # ----------------------------------------
  # System update configuration
  # ----------------------------------------
  system.autoUpgrade = { enable = false; dates = "weekly"; allowReboot = false; };
}