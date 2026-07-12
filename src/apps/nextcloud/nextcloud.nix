# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Nextcloud
# ============================================================================
# Version: 1.0.0
# Date: 2026-05-04
# Author: @AndreasJe (TAPPaaS)
# Product: Nextcloud (self-hosted file sync, sharing, and collaboration)
#
# Architecture:
# - NixOS native services.nextcloud (PHP-FPM + nginx internal)
# - PostgreSQL (NixOS native) — dedicated nextcloud database and user
# - Redis (NixOS native, named server "nextcloud") — file locking + APCu cache
# - Caddy reverse proxy handles TLS termination; VM listens on port 80
# - Office editing: handled externally by the euro-office module
#
# Network: srv zone (VMID 340, tanka1), firewall ports 22 (SSH) + 80 (HTTP)
# Secrets: Auto-generated admin password + DB password on first boot
# Backups: Daily PostgreSQL dump (02:00) + data dir tar (02:30), 30-day retention
#
# Authentik OIDC (optional):
#   Populate /etc/secrets/nextcloud.env with OIDC_CLIENT_ID, OIDC_CLIENT_SECRET,
#   OIDC_DISCOVERY_URI and the nextcloud-configure-oidc service will activate on
#   the next boot. Emergency bypass: https://<host>/login?direct=1
#
# CRITICAL: Do NOT enable server-side encryption when using OIDC —
#   OIDC cannot supply the cleartext password Nextcloud needs, causing
#   irrevocable data loss. Use LDAP instead if encryption is required.
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # ── Version pins — single source of truth; bump here. ───────────────────────────
  # `ncMajor` drives BOTH the Nextcloud package and its app-set (dynamic attr access),
  # so a major bump is one number. Majors must be sequential — Nextcloud refuses to skip
  # (33 → 34 → 35). The eurooffice connector pin lives in eurooffice-nextcloud.nix; the
  # nixpkgs template rev is pinned engine-side (update-os.sh). See UPGRADE.md.
  ncMajor = 33;
  versions = {
    postgresPkg   = pkgs.postgresql_15;
    nextcloudPkg  = pkgs."nextcloud${toString ncMajor}";
    nextcloudApps = pkgs."nextcloud${toString ncMajor}Packages".apps;
  };

in
{
  # ============================================================================
  # IMPORTS
  # ============================================================================

  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ============================================================================
  # BOOT CONFIGURATION
  # ============================================================================

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # ============================================================================
  # CLOUD-INIT
  # ============================================================================

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # ============================================================================
  # NETWORKING
  # ============================================================================

  # Read vmname from companion JSON (deployed by update-os.sh to /etc/nixos/nextcloud.json)
  # so DHCP registers the actual deployed name (e.g. "nextcloud-test") instead of the
  # hardcoded base name. Falls back to "nextcloud" when the file is absent (fresh install).
  networking.hostName = let
    cfg = if builtins.pathExists ./nextcloud.json
          then builtins.fromJSON (builtins.readFile ./nextcloud.json)
          else {};
  in lib.mkDefault (cfg.vmname or "nextcloud");
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };

  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22   # SSH
      80   # HTTP — Caddy upstream
    ];
  };

  # ============================================================================
  # TIME ZONE
  # ============================================================================

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # ============================================================================
  # USERS & SECURITY
  # ============================================================================

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ============================================================================
  # SYSTEM PACKAGES
  # ============================================================================

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    git
    jq
    openssl
    postgresql  # psql CLI for debugging
  ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================

  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;


  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # ============================================================================
  # ESSENTIAL SERVICES
  # ============================================================================

  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  programs.ssh.startAgent = true;

  # ============================================================================
  # DATABASE — PostgreSQL 15
  # ============================================================================

  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [
      { name = "nextcloud"; ensureDBOwnership = true; }
    ];

    # peer auth for local OS users (postgres + nextcloud match their DB usernames)
    # md5 for the app connecting via TCP loopback with the generated password
    authentication = pkgs.lib.mkOverride 10 ''
      local all  postgres   peer
      local all  nextcloud  peer
      host  all  all        127.0.0.1/32  md5
      host  all  all        ::1/128       md5
    '';

    settings = {
      max_connections          = 100;
      shared_buffers           = "2GB";
      effective_cache_size     = "6GB";
      maintenance_work_mem     = "512MB";
      work_mem                 = "32MB";
      checkpoint_completion_target = 0.9;
      wal_buffers              = "16MB";
      default_statistics_target = 100;
      random_page_cost         = 1.1;
      effective_io_concurrency = 200;
    };
  };

  # ============================================================================
  # CACHING — Redis (named server "nextcloud")
  # ============================================================================

  services.redis.servers."nextcloud" = {
    enable      = true;
    port        = 0;
    unixSocket  = "/run/redis-nextcloud/redis.sock";
    unixSocketPerm = 770;
    settings = {
      maxmemory        = "512mb";
      maxmemory-policy = "allkeys-lru";
      maxclients       = lib.mkForce 1000;
      timeout          = 300;
      tcp-keepalive    = 60;
    };
  };

  users.users.nextcloud = {
    extraGroups = [ "redis-nextcloud" ];
  };

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.nextcloud-init-secrets = {
    description = "Generate Nextcloud admin and DB passwords if missing";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    before      = [ "nextcloud-setup.service" "postgresql.service" ];
    unitConfig.ConditionPathExists = "!/var/lib/nextcloud/admin-pass";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nextcloud-init-secrets" ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/mkdir -p /var/lib/nextcloud
        ${pkgs.coreutils}/bin/chown nextcloud:nextcloud /var/lib/nextcloud
        ${pkgs.coreutils}/bin/chmod 700 /var/lib/nextcloud

        # hex output — no base64 metacharacters that could break SQL or shell
        ADMIN_PASS="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        DB_PASS="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        # Atomic write: printf|install reads from stdin so the file is never
        # briefly empty after permissions are set (avoids TOCTOU window).
        printf '%s' "$ADMIN_PASS" | \
          ${pkgs.coreutils}/bin/install -m 0600 -o nextcloud -g nextcloud \
            /dev/stdin /var/lib/nextcloud/admin-pass
        printf '%s' "$DB_PASS" | \
          ${pkgs.coreutils}/bin/install -m 0600 -o nextcloud -g nextcloud \
            /dev/stdin /var/lib/nextcloud/db-pass

        echo "================================================"
        echo "Nextcloud secrets generated:"
        echo "  Admin pass : /var/lib/nextcloud/admin-pass"
        echo "  DB pass    : /var/lib/nextcloud/db-pass"
        echo "View: sudo cat /var/lib/nextcloud/admin-pass"
        echo "================================================"
      '';
    };
  };

  # Apply DB password to PostgreSQL every boot (idempotent ALTER ROLE)
  systemd.services.nextcloud-apply-db-pass = {
    description = "Apply Nextcloud DB password to PostgreSQL";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "postgresql.service" "nextcloud-init-secrets.service" ];
    before      = [ "nextcloud-setup.service" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nextcloud-apply-db-pass" ''
        set -euo pipefail
        DB_PASS="$(${pkgs.coreutils}/bin/cat /var/lib/nextcloud/db-pass)"
        # Wait for the nextcloud role to exist (ensureUsers runs in postgresql postStart)
        for i in $(seq 1 10); do
          if ${pkgs.util-linux}/bin/runuser -u postgres -- \
              ${versions.postgresPkg}/bin/psql -tAc \
              "SELECT 1 FROM pg_roles WHERE rolname='nextcloud'" | grep -q 1; then
            break
          fi
          sleep 2
        done
        ${pkgs.coreutils}/bin/printf "ALTER ROLE nextcloud WITH ENCRYPTED PASSWORD '%s';\n" "$DB_PASS" \
          | ${pkgs.util-linux}/bin/runuser -u postgres -- ${versions.postgresPkg}/bin/psql
      '';
    };
  };

  # ============================================================================
  # NEXTCLOUD (NixOS native)
  # ============================================================================

  services.nextcloud = {
    enable   = true;
    hostName = config.networking.hostName;
    package  = versions.nextcloudPkg;

    extraApps = {
      inherit (versions.nextcloudApps)
        # Auth
        user_oidc
        # Talk & real-time
        spreed uppush whiteboard
        # Core productivity
        calendar contacts tasks mail deck notes news forms polls
        # Collaboration & knowledge
        collectives tables groupfolders guests
        # Files & admin
        previewgenerator quota_warning end_to_end_encryption
        # Integrations
        integration_openai
      ;
      # eurooffice-nextcloud v10.0.0 still uses app ID "onlyoffice" for backward compat
      onlyoffice = pkgs.callPackage ./eurooffice-nextcloud.nix {};
    };
    extraAppsEnable = true;

    # TLS terminated by Caddy; VM serves plain HTTP
    https = false;

    notify_push.enable = true;

    phpOptions = {
      "memory_limit"                   = lib.mkForce "512M";
      "opcache.interned_strings_buffer" = "16";
    };

    maxUploadSize = "16G";

    database.createLocally = false;

    config = {
      adminuser     = "admin";
      adminpassFile = "/var/lib/nextcloud/admin-pass";

      dbtype    = "pgsql";
      dbname    = "nextcloud";
      dbuser    = "nextcloud";
      dbhost    = "127.0.0.1";
      dbpassFile = "/var/lib/nextcloud/db-pass";
    };

    caching = {
      redis = true;
      apcu  = true;
    };

    settings = {
      redis = {
        host    = "/run/redis-nextcloud/redis.sock";
        port    = 0;
        dbindex = 0;
        timeout = 1.5;
      };

      # Required for Authentik (same srv zone) to be reachable as OIDC provider
      allow_local_remote_servers = true;

      # trusted_domains: deliberately NOT pinned in Nix. The NixOS module auto-adds the hostName;
      # install.sh appends the internal FQDN, the environment/public domain, and localhost via
      # nextcloud-occ. Pinning a list here writes override.config.php, which SHADOWS occ-set values
      # — so the environment/public domain would never become trusted (operator cannot log in via
      # the site domain). TODO: propagate the environment domain declaratively (ADR-007
      # Environment.domain → module), then this can move back to Nix.

      # trusted_proxies: Caddy runs on the OPNsense firewall which holds the
      # gateway IP of every TAPPaaS zone (10.x.y.1). Including 10.0.0.0/8
      # covers all zones generically — safe in a private TAPPaaS deployment.
      # With a trusted proxy, Nextcloud reads the Host header directly, so
      # overwritehost and overwrite.cli.url are not needed here.
      trusted_proxies   = [ "127.0.0.1" "::1" "10.0.0.0/8" ];
      overwriteprotocol = "https";

      # Maintenance window: 01:00 UTC — avoids peak usage hours
      maintenance_window_start = 1;

      # Default phone region for profile phone number validation
      # default_phone_region: not set — operator configures locale per deployment
      # via nextcloud-occ config:system:set default_phone_region --value="NL"

      # Use file log so the logreader app can display logs in the admin panel
      log_type = "file";

      # Unique identifier for this server — silences the admin panel warning
      server_id = config.networking.hostName;

      # SMTP host — encryption/auth/credentials set via nextcloud-configure-mail.service
      # because the NixOS module's type system does not accept "tls" (STARTTLS) here
      mail_smtpmode = "smtp";
      # mail_smtphost and mail_smtpport set via nextcloud-configure-mail.service
      # when /etc/secrets/mail.env is present (operator-supplied SMTP credentials)
    };
  };

  # HSTS header — Caddy terminates TLS but Nextcloud's security check reads headers
  # from the internal nginx response. Add it here so the check passes.
  # /socket.io/ proxied to the co-located whiteboard server (port 3002).
  services.nginx.virtualHosts.${config.networking.hostName} = {
    extraConfig = ''
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    '';
    locations."/socket.io/" = {
      proxyPass    = "http://127.0.0.1:3002";
      proxyWebsockets = true;
      extraConfig  = ''
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  systemd.services.nextcloud-setup = {
    after    = [ "nextcloud-init-secrets.service" "nextcloud-apply-db-pass.service"
                 "redis-nextcloud.service" ];
    requires = [ "postgresql.service" "redis-nextcloud.service" ];
  };

  # ============================================================================
  # AUTHENTIK OIDC INTEGRATION
  # ============================================================================
  #
  # AUTHENTIK SETUP (one-time, in the Authentik Admin UI):
  #   1. Customisation → Property Mappings → Create Scope Mapping:
  #        Name: "Nextcloud Profile"   Scope name: nextcloud
  #        Expression:
  #          return {
  #            "nextcloud_user_id": request.user.username,
  #            "quota":             "5 GB",
  #            "groups":            [g.name for g in request.user.ak_groups.all()],
  #          }
  #
  #   2. Applications → Providers → Create OAuth2/OpenID Connect Provider:
  #        Redirect URI:   https://nextcloud.example.com/apps/user_oidc/code
  #        Subject mode:   Based on the User's UUID
  #        Signing key:    (select existing or create)
  #        Scopes:         email  profile  nextcloud  openid
  #        Back-channel logout URL (optional):
  #          https://nextcloud.example.com/apps/user_oidc/backchannel-logout/authentik
  #
  #   3. Applications → Applications → Create Application:
  #        Attach the provider above. Note the application slug.
  #
  # ON THIS VM — populate the secrets file (mode 0600, root:root):
  #   /etc/secrets/nextcloud.env:
  #     OIDC_CLIENT_ID=<Client ID from Authentik provider>
  #     OIDC_CLIENT_SECRET=<Client Secret from Authentik provider>
  #     OIDC_DISCOVERY_URI=https://identity.example.com/application/o/<slug>/.well-known/openid-configuration
  #
  # The nextcloud-configure-oidc service activates automatically on next boot
  # once the secrets file exists.
  #
  # Emergency bypass (if OIDC breaks): https://nextcloud.example.com/login?direct=1

  # Configure the Authentik OIDC provider — only runs when secrets file exists
  systemd.services.nextcloud-configure-oidc = {
    description = "Configure Authentik OIDC provider in Nextcloud";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];

    # Activated only once the operator has populated the secrets file
    unitConfig.ConditionPathExists = "/etc/secrets/nextcloud.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/nextcloud.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-oidc" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        nextcloud-occ user_oidc:provider authentik \
          --clientid="$OIDC_CLIENT_ID" \
          --clientsecret="$OIDC_CLIENT_SECRET" \
          --discoveryuri="$OIDC_DISCOVERY_URI" \
          --scope="email profile nextcloud openid" \
          --mapping-uid="preferred_username" \
          --mapping-display-name="name" \
          --mapping-email="email" \
          --mapping-quota="quota" \
          --mapping-groups="groups" \
          --check-bearer=1 \
          --send-id-token-hint=1

        echo "Authentik OIDC provider configured successfully."
      '';
    };
  };

  # Configure the Euro-Office connector — only runs when the secrets file exists.
  # Secrets file (/etc/secrets/onlyoffice.env) is written by euro-office install-service.sh.
  # Format: JWT_SECRET=<hex>
  systemd.services.nextcloud-configure-eurooffice = {
    description = "Configure Euro-Office connector in Nextcloud";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/onlyoffice.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/onlyoffice.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-eurooffice" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        nextcloud-occ config:app:set onlyoffice DocumentServerUrl         --value="$EURO_OFFICE_URL"
        nextcloud-occ config:app:set onlyoffice DocumentServerInternalUrl --value="$EURO_OFFICE_INTERNAL_URL"
        nextcloud-occ config:app:set onlyoffice StorageUrl                --value="https://$NEXTCLOUD_PUBLIC_URL/"
        nextcloud-occ config:app:set onlyoffice jwt_secret                --value="$JWT_SECRET"
        nextcloud-occ config:app:set onlyoffice jwt_header                --value="Authorization"

        echo "Euro-Office connector configured successfully."
      '';
    };
  };

  # ============================================================================
  # NEXTCLOUD TALK — coturn TURN/STUN integration
  # ============================================================================
  #
  # SETUP:
  #   1. Deploy the coturn module (VMID 630, DMZ zone).
  #   2. On the coturn VM, confirm /etc/secrets/coturn.env has COTURN_SECRET set
  #      and COTURN_EXTERNAL_IP populated.
  #   3. Copy /etc/secrets/coturn.env from the coturn VM to this VM at the same
  #      path (/etc/secrets/coturn.env, mode 0600, root:root).
  #   4. The nextcloud-configure-talk service activates automatically on next boot.
  #
  # NOTE: COTURN_SECRET in /etc/secrets/coturn.env on THIS VM must match the
  # secret on the coturn VM exactly — both files are copies of the same value.

  # Configure Talk STUN/TURN servers — only runs when coturn secrets file exists
  systemd.services.nextcloud-configure-talk = {
    description = "Configure Nextcloud Talk STUN/TURN servers";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];

    # Activates whenever the coturn secrets file exists (runs on each boot to
    # keep config in sync with the secret — safe because occ set is idempotent)
    unitConfig.ConditionPathExists = "/etc/secrets/coturn.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/coturn.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-talk" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        nextcloud-occ config:app:set spreed stun_servers \
          --value="[\"$COTURN_HOST:3478\"]"

        nextcloud-occ config:app:set spreed turn_servers \
          --value="[{\"server\":\"$COTURN_HOST:3478\",\"secret\":\"$COTURN_SECRET\",\"protocols\":\"udp,tcp\"}]"

        echo "Nextcloud Talk STUN/TURN servers configured successfully."
      '';
    };
  };

  # Configure SMTP credentials — runs on every boot when /etc/secrets/mail.env exists.
  # Populate /etc/secrets/mail.env (mode 0600, root:root) with:
  #   SMTP_USER=user@example.com
  #   SMTP_PASSWORD=<app password or account password>
  # The local part of SMTP_USER becomes the From address (user@example.com → "user").
  systemd.services.nextcloud-configure-mail = {
    description = "Configure Nextcloud SMTP credentials";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/mail.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/mail.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-mail" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        SMTP_FROM_LOCAL="''${SMTP_USER%%@*}"
        SMTP_DOMAIN="''${SMTP_USER##*@}"

        nextcloud-occ config:system:set mail_smtpsecure   --value="tls"
        nextcloud-occ config:system:set mail_smtpauth     --value="1" --type=integer
        nextcloud-occ config:system:set mail_smtpauthtype --value="LOGIN"
        nextcloud-occ config:system:set mail_smtpname     --value="$SMTP_USER"
        nextcloud-occ config:system:set mail_smtppassword --value="$SMTP_PASSWORD"
        nextcloud-occ config:system:set mail_from_address --value="$SMTP_FROM_LOCAL"
        nextcloud-occ config:system:set mail_domain       --value="$SMTP_DOMAIN"

        echo "Nextcloud SMTP credentials configured successfully."
      '';
    };
  };

  # ── HPB: register Talk signaling backend ─────────────────────────────────
  # install.sh writes HPB_SECRET to /etc/secrets/hpb.env and then triggers
  # this service. Runs every boot so secret rotation propagates automatically.
  systemd.services.nextcloud-configure-hpb = {
    description = "Register Nextcloud Talk HPB signaling backend";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/hpb.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/hpb.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-hpb" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        # Signaling (HPB) — use the canonical talk:signaling:add, which writes the
        # structure Talk expects: {"servers":[…],"secret":"…"}. The raw
        # config:app:set produced a bare array WITHOUT the inner "secret" key, so
        # OCA\Talk\Config::getSignalingSecret() returned null and the admin Talk
        # page 500'd (TypeError). Clear first; the add command appends.
        nextcloud-occ config:app:delete spreed signaling_servers >/dev/null 2>&1 || true
        nextcloud-occ config:app:delete spreed signaling_secret  >/dev/null 2>&1 || true
        # Base URL only — Talk appends /api/v1/welcome (check) and /spreed (websocket)
        # itself. Including /spreed here makes the check hit /spreed/api/v1/welcome → 404.
        nextcloud-occ talk:signaling:add "wss://$HPB_URL" "$HPB_SECRET"

        # TURN + STUN (coturn) — only when the consumer plumbed them into hpb.env.
        # Without these, calls with >2 participants have no relay (admin warns).
        if [ -n "''${TURN_SERVER:-}" ] && [ -n "''${TURN_SECRET:-}" ]; then
          nextcloud-occ config:app:delete spreed turn_servers >/dev/null 2>&1 || true
          nextcloud-occ config:app:delete spreed stun_servers >/dev/null 2>&1 || true
          nextcloud-occ talk:stun:add "$TURN_SERVER"
          nextcloud-occ talk:turn:add turn "$TURN_SERVER" "udp,tcp" --secret="$TURN_SECRET"
        fi

        echo "Nextcloud Talk HPB signaling backend configured."
      '';
    };
  };

  # ============================================================================
  # WHITEBOARD — nextcloud-whiteboard-server (co-located)
  # ============================================================================
  #
  # WebSocket backend for the Nextcloud Whiteboard app. Runs on localhost:3002;
  # nginx proxies /socket.io/ so browsers reach it through the existing domain.
  # JWT_SECRET_KEY is auto-generated on first boot and written into both the
  # whiteboard server env file and the Nextcloud app config.

  systemd.services.whiteboard-init-secrets = {
    description = "Generate whiteboard JWT secret if missing";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    before      = [ "nextcloud-whiteboard-server.service" ];
    unitConfig.ConditionPathExists = "!/etc/secrets/whiteboard.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "whiteboard-init-secrets" ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets
        ${pkgs.coreutils}/bin/chmod 700 /etc/secrets

        JWT_SECRET_KEY="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        ${pkgs.coreutils}/bin/install -m 0600 -o root -g root /dev/null /etc/secrets/whiteboard.env
        printf 'JWT_SECRET_KEY=%s\n' "$JWT_SECRET_KEY" > /etc/secrets/whiteboard.env

        echo "Whiteboard JWT secret generated: /etc/secrets/whiteboard.env"
      '';
    };
  };

  services.nextcloud-whiteboard-server = {
    enable   = true;
    settings = {
      NEXTCLOUD_URL    = "http://${config.networking.hostName}";
      STORAGE_STRATEGY = "lru";
      PORT             = "3002";
    };
    secrets = [ "/etc/secrets/whiteboard.env" ];
  };

  # Guarantee the whiteboard server starts only after secrets are available
  systemd.services.nextcloud-whiteboard-server = {
    after    = [ "whiteboard-init-secrets.service" ];
    requires = [ "whiteboard-init-secrets.service" ];
  };

  # Push backend URL and JWT secret into the whiteboard app — idempotent, runs every boot
  systemd.services.nextcloud-configure-whiteboard = {
    description = "Configure Nextcloud Whiteboard backend URL and JWT secret";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" "whiteboard-init-secrets.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/whiteboard.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/whiteboard.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-whiteboard" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        # whiteboard.env provides only JWT_SECRET_KEY — NEXTCLOUD_PUBLIC_URL is not set there.
        # Default to the internal host so activation never fails on `set -u`; the public collab
        # backend URL is refined post-deploy (needs the proxy domain + cert, like the connector).
        PUBLIC_URL="''${NEXTCLOUD_PUBLIC_URL:-http://${config.networking.hostName}}"

        nextcloud-occ config:app:set whiteboard collabBackendUrl \
          --value="$PUBLIC_URL"

        nextcloud-occ config:app:set whiteboard jwt_secret_key \
          --value="$JWT_SECRET_KEY"

        echo "Nextcloud Whiteboard backend configured successfully."
      '';
    };
  };

  # ============================================================================
  # PREVIEW GENERATOR — backfill + recurring pre-generation
  # ============================================================================

  # One-time backfill — generates previews for ALL existing files.
  # CPU-intensive; runs once on first boot and never again (sentinel file guards it).
  systemd.services.nextcloud-preview-backfill = {
    description = "One-time Nextcloud preview backfill for existing files";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];

    # Never re-runs once the sentinel file exists
    unitConfig.ConditionPathExists = "!/var/lib/nextcloud/.preview-backfill-done";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      # Runs as root (like the other configure services); nextcloud-occ switches to the
      # nextcloud user itself via systemd-run. A User=nextcloud service cannot call
      # systemd-run during nixos activation — polkit denies it non-interactively (exit 4).
      ExecStart = pkgs.writeShellScript "nextcloud-preview-backfill" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        echo "Starting one-time preview backfill (CPU-intensive, may take a while)..."
        nextcloud-occ preview:generate-all

        # Mark as done so this service never runs again
        touch /var/lib/nextcloud/.preview-backfill-done
        echo "Preview backfill complete."
      '';
    };
  };

  # Recurring pre-generation — only generates MISSING previews (efficient).
  # Runs daily at 03:00 (after backups at 02:00 and 02:30).
  systemd.services.nextcloud-preview-generate = {
    description = "Nextcloud incremental preview pre-generation";
    serviceConfig = {
      Type  = "oneshot";
      User  = "nextcloud";
      ExecStart = pkgs.writeShellScript "nextcloud-preview-generate" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"
        nextcloud-occ preview:pre-generate
      '';
    };
  };

  systemd.timers.nextcloud-preview-generate = {
    description = "Daily Nextcloud incremental preview pre-generation";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  # ============================================================================
  # BACKUP STRATEGY
  # ============================================================================

  services.postgresqlBackup = {
    enable      = true;
    databases   = [ "nextcloud" ];
    startAt     = "*-*-* 02:00:00";
    location    = "/var/backup/nextcloud/postgresql";
    compression = "gzip";
  };

  systemd.services.nextcloud-data-backup = {
    description = "Nextcloud data directory daily backup";
    serviceConfig = {
      Type  = "oneshot";
      User  = "root";
      ExecStart = pkgs.writeShellScript "nextcloud-data-backup" ''
        set -euo pipefail

        BACKUP_DIR="/var/backup/nextcloud/data"
        TIMESTAMP="$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S)"
        DATA_DIR="/var/lib/nextcloud/data"

        ${pkgs.coreutils}/bin/mkdir -p "$BACKUP_DIR"

        if [ -d "$DATA_DIR" ]; then
          ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
            -cf "$BACKUP_DIR/nextcloud-data-$TIMESTAMP.tar.gz" \
            -C /var/lib/nextcloud data
          ${pkgs.coreutils}/bin/chmod 600 "$BACKUP_DIR/nextcloud-data-$TIMESTAMP.tar.gz"
        else
          echo "WARNING: $DATA_DIR not found, skipping." >&2
        fi
      '';
    };
  };

  systemd.timers.nextcloud-data-backup = {
    description = "Daily Nextcloud data directory backup";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
    };
  };

  systemd.services.nextcloud-cleanup-backups = {
    description = "Cleanup old Nextcloud backups";
    serviceConfig = {
      Type      = "oneshot";
      User      = "root";
      ExecStart = pkgs.writeShellScript "nextcloud-cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup/nextcloud -type f -mtime +30 -delete
      '';
    };
  };

  systemd.timers.nextcloud-cleanup-backups = {
    description = "Monthly cleanup of old Nextcloud backups";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /var/backup/nextcloud             0700 root      root      -"
    "d /var/backup/nextcloud/postgresql  0700 postgres  postgres  -"
    "d /var/backup/nextcloud/data        0700 root      root      -"
    "d /var/lib/nextcloud                0700 nextcloud nextcloud -"
    "d /etc/secrets                      0700 root      root      -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION — DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
