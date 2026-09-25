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
  # `targetMajor` is the release's Nextcloud; `ncMajor` is what THIS build installs.
  # Majors must be sequential — Nextcloud refuses to skip — so nc-major.nix reads the
  # installed major on the guest and steps at most one per build: an existing 33 site
  # goes 33 → 34 at one update and 34 → 35 at the next, keeping its data; a fresh
  # install goes straight to targetMajor. The eurooffice connector pin lives in
  # eurooffice-nextcloud.nix; the nixpkgs template rev is pinned engine-side
  # (update-os.sh). See UPGRADE.md.
  targetMajor = 35;
  ncStep = import ./nc-major.nix {
    inherit targetMajor;
    available = m: pkgs ? "nextcloud${toString m}";
  };
  ncMajor = ncStep.major;
  # Apps nixpkgs does not package for 35 yet: 35-compatible releases came out after its
  # last app-list refresh. Same app-store source nixpkgs uses; drop each pin once
  # nextcloud35Packages.apps carries it. unpack = true hashes the unpacked tree, so a
  # re-generated codeberg /archive tarball (uppush) cannot break the hash again.
  storeApp = url: hash: patches: pkgs.fetchNextcloudApp { inherit url hash patches; unpack = true; license = "agpl3Plus"; };
  storeApps = {
    news             = storeApp "https://github.com/nextcloud/news/releases/download/29.0.0-beta.1/news.tar.gz"
                                "sha256-ZT0FLb2u0vhuEX8tvUyHq2hW+hVuwW+1sArBiJQKGIw=" [];
    previewgenerator = storeApp "https://github.com/nextcloud-releases/previewgenerator/releases/download/v5.15.0/previewgenerator-v5.15.0.tar.gz"
                                "sha256-jXUX5hDNrZ7qFBQel+8IWAGu6WwMlMcpMf+YX5dKh/g=" [];
    # 2.6.0's first migration types its tables as Doctrine's, but 35 hands out its own
    # wrapper, so enabling it dies with a TypeError (upstream #124, open).
    uppush           = storeApp "https://codeberg.org/NextPush/uppush/archive/2.6.0.tar.gz"
                                "sha256-trpmBCuU4q4GXiSAT8gpP9pAz6q1Rdz/yIIB6Iem2is="
                                [ (pkgs.callPackage ./uppush-nc35-patch.nix {}) ];
    # nixpkgs ships 1.3.3 (<=34) as both the app and the daemon; 1.4.1 supports 35.
    notify_push      = storeApp "https://github.com/nextcloud-releases/notify_push/releases/download/v1.4.1/notify_push-v1.4.1.tar.gz"
                                "sha256-stMKO4B148w/AKF0CjT+OR+JDCiN5SfbTOp4j8K5txw=" [];
  };

  # The notify_push daemon must match its app, so it moves to 1.4.1 with it.
  notifyPushPkg = pkgs.nextcloud-notify_push.overrideAttrs (old: rec {
    version = "1.4.1";
    src = pkgs.fetchFromGitHub {
      owner = "nextcloud";
      repo  = "notify_push";
      tag   = "v${version}";
      hash  = "sha256-lg/gffgfUJHLCL1TOPdYAw7DtRZeGDH+jO9deQSUbEY=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "notify_push-${version}-vendor";
      hash = "sha256-skKOCJBtpvtdc594eOxbvSIl+SucaH0jl1gFv9kfvNA=";
    };
  });

  versions = {
    postgresPkg   = pkgs.postgresql_15;
    nextcloudPkg  = pkgs."nextcloud${toString ncMajor}";
    # The store pins and the uppush patch are for targetMajor; an intermediate step
    # takes nixpkgs' own app set for that major, which carries every app below.
    nextcloudApps = pkgs."nextcloud${toString ncMajor}Packages".apps
                    // lib.optionalAttrs ncStep.onTarget storeApps;
  };

  # ── trusted_domains, derived from the module config (#508) ────────────────
  # Same companion JSON the hostName below reads: update-os.sh deploys it to
  # /etc/nixos/nextcloud.json, and it carries the site's proxyDomain and zone —
  # so the public domain IS available declaratively, which the old comment here
  # assumed it was not.
  moduleCfg = if builtins.pathExists ./nextcloud.json
              then builtins.fromJSON (builtins.readFile ./nextcloud.json)
              else {};
  ncVmName      = moduleCfg.vmname or "nextcloud";
  ncZone0       = moduleCfg.zone0 or "";
  ncProxyCfg    = (moduleCfg.config or {})."network:proxy" or {};
  ncProxyDomain = ncProxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  ncInternalFqdn = if ncZone0 != "" then "${ncVmName}.${ncZone0}.internal" else "";

  # hostName is deliberately NOT listed: the NixOS nextcloud module prepends
  # services.nextcloud.hostName to whatever settings.trusted_domains declares,
  # so including it here yields a duplicate index (observed: nextcloud,
  # nextcloud, <fqdn>, <domain>). Contribute only what the module does not.
  ncTrustedDomains = lib.unique (
    lib.optional (ncInternalFqdn != "") ncInternalFqdn
    ++ lib.optional (ncProxyDomain != "") ncProxyDomain
  );

in
{
  # ============================================================================
  # IMPORTS
  # ============================================================================

  imports = [
    /etc/nixos/hardware-configuration.nix
    # The site's own time, locale and time source (#472, #87), generated from
    # config/site.json and shipped to /etc/nixos by update-os.sh on every update.
    # A VM that has never had one simply keeps the NixOS defaults.
    #
    # NOT tappaas-common.nix: this module still carries its own copy of the
    # baseline (ssh, cloud-init, users, nix settings), so importing the baseline
    # would conflict on every one of them. De-duplicating that is #324.
    /etc/nixos/tappaas-site.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    # Always present: update-os.sh ships an empty one, and backup:filesystem
    # overwrites it with the real trigger.
    /etc/nixos/tappaas-backup.nix
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

  # No time zone here: it is the site's fact, not the module's (#472). It
  # arrives through /etc/nixos/tappaas-site.nix, imported above.

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
  #
  # After postgresql-setup, not merely after postgresql (#715). On NixOS 25.11
  # the ensureDatabases/ensureUsers work moved out of postgresql's postStart into
  # its own postgresql-setup.service, which runs CREATE USER "nextcloud" and then
  # ALTER ROLE "nextcloud" — the same pg_authid row this unit alters. Ordered
  # only after postgresql.service, the two ran concurrently and one lost:
  #   ERROR:  tuple concurrently updated
  # measured on hrossen on 2026-09-20, 09-21 and twice on 09-23. Ordering after
  # setup also means the role exists by the time this runs.
  systemd.services.nextcloud-apply-db-pass = {
    description = "Apply Nextcloud DB password to PostgreSQL";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "postgresql.service" "postgresql-setup.service" "nextcloud-init-secrets.service" ];
    requires    = [ "postgresql-setup.service" ];
    before      = [ "nextcloud-setup.service" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nextcloud-apply-db-pass" ''
        set -euo pipefail
        DB_PASS="$(${pkgs.coreutils}/bin/cat /var/lib/nextcloud/db-pass)"
        # The role is created by postgresql-setup, which this unit is ordered
        # after; the wait stays as a guard, not as the mechanism.
        for i in $(seq 1 10); do
          if ${pkgs.util-linux}/bin/runuser -u postgres -- \
              ${versions.postgresPkg}/bin/psql -tAc \
              "SELECT 1 FROM pg_roles WHERE rolname='nextcloud'" | grep -q 1; then
            break
          fi
          sleep 2
        done
        # ON_ERROR_STOP: without it psql exits 0 on an SQL error, so a failed
        # ALTER ROLE reported success and left the password unapplied.
        ${pkgs.coreutils}/bin/printf "ALTER ROLE nextcloud WITH ENCRYPTED PASSWORD '%s';\n" "$DB_PASS" \
          | ${pkgs.util-linux}/bin/runuser -u postgres -- ${versions.postgresPkg}/bin/psql -v ON_ERROR_STOP=1
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
        previewgenerator end_to_end_encryption
        # Integrations
        integration_openai
      ;
      eurooffice = pkgs.callPackage ./eurooffice-nextcloud.nix {};
      # The notify_push module adds its own (nixpkgs 1.3.3); this one wins.
      notify_push = lib.mkForce versions.nextcloudApps.notify_push;
    };
    extraAppsEnable = true;

    # TLS terminated by Caddy; VM serves plain HTTP
    https = false;

    notify_push.enable  = true;
    # 1.4.1 on targetMajor (35 needs it); nixpkgs' own 1.3.3 (<= 34) on a step.
    notify_push.package = if ncStep.onTarget then notifyPushPkg else pkgs.nextcloud-notify_push;

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

      # JWT leeway for the onlyoffice/euro-office connector, in seconds (#714).
      #
      # The document server signs its request to download a file from Nextcloud
      # with a JWT, and Nextcloud checks that token's `iat` against its OWN
      # clock. The app's default leeway is 0, so a guest whose clock is a few
      # seconds behind the document server's rejects every download:
      #
      #   Download empty with invalid jwt | Cannot handle token with iat
      #   prior to 2026-09-23T06:06:10+0000        (Nextcloud's clock: 06:06:05)
      #
      # and the document server reports "Error while downloading the document
      # file to be converted". That is what failed euro-office on hrossen: after
      # its OS update this VM could not reach its NTP server (timesyncd timed out
      # at 08:04:36, first synchronised at 08:21:46), and for those 17 minutes
      # its clock ran 5-6 s behind. A minute of tolerance covers boot-time skew
      # without touching what the token protects — the signature is still
      # checked in full; leeway only relaxes the time claims. The app provides
      # this knob for exactly this ("in case the system clock is a second off").
      # Where the user ID is the Authentik username (--unique-uid=0: new installs),
      # an Authentik user named like a local account (admin) would sign in AS it.
      # Refuse that ("User conflict") instead of adopting the local user. Harmless
      # on a site that keeps hashed IDs: a hash never names a local account.
      user_oidc = {
        soft_auto_provision = false;
      };

      eurooffice = {
        jwt_leeway = 60;
      };

      # trusted_domains: pinned here, derived from the module config above (#508).
      #
      # It used to be left to nextcloud-occ on the grounds that the public domain
      # was not available declaratively. It is — the companion JSON deployed to
      # /etc/nixos/nextcloud.json carries proxyDomain and zone0, and the hostName
      # a few lines up already reads that same file.
      #
      # Leaving it imperative meant nextcloud-setup.service, which runs on EVERY
      # boot, reset the list to just the hostName:
      #
      #   System config value trusted_domains => 0 set to string nextcloud
      #
      # wiping the public domain and internal FQDN, so every reboot of this VM
      # answered HTTP 400 "Access through untrusted domain" on the site domain
      # until the next update-tappaas run happened to converge it (observed
      # 2026-08-25, twice). Pinning it writes override.config.php, which takes
      # precedence over config.php — so the boot-time reset becomes harmless
      # rather than an outage. That shadowing was the original objection to
      # pinning; it is exactly what makes this correct.
      trusted_domains = ncTrustedDomains;

      # trusted_proxies: Caddy runs on the OPNsense firewall which holds the
      # gateway IP of every TAPPaaS zone (10.x.y.1). Including 10.0.0.0/8
      # covers all zones generically — safe in a private TAPPaaS deployment.
      # With a trusted proxy, Nextcloud reads the Host header directly, so
      # overwritehost is not needed. overwrite.cli.url is: occ and cron have no
      # Host header, and without it Talk signs its HPB backend calls as
      # https://localhost, which the HPB rejects ("Authentication check failed").
      trusted_proxies   = [ "127.0.0.1" "::1" "10.0.0.0/8" ];
      overwriteprotocol = "https";
    } // lib.optionalAttrs (ncProxyDomain != "") {
      "overwrite.cli.url" = "https://${ncProxyDomain}";
    } // {

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
  # Every boot-time occ unit (the six nextcloud-configure-* and the preview
  # backfill) requires nextcloud-setup, not only orders after it (#715): after
  # alone ran them against a failed setup — seven failures masking one cause.
  systemd.services.nextcloud-configure-oidc = {
    description = "Configure Authentik OIDC provider in Nextcloud";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];
    requires    = [ "nextcloud-setup.service" ];

    # Activated only once the operator has populated the secrets file
    unitConfig.ConditionPathExists = "/etc/secrets/nextcloud.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/nextcloud.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-oidc" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.jq}/bin:$PATH"

        # --unique-uid: the user ID is the Authentik username (0: andreas) or a
        # SHA-256 of it (1). Decided ONCE, when the provider is created: changing it
        # later gives every existing user a new, empty account and orphans their
        # files, shares and client accounts. A new provider gets 0; an existing one
        # keeps what it has — user_oidc's default, 1, when it was never set.
        unique_uid=0
        pid=$(nextcloud-occ user_oidc:provider --output=json 2>/dev/null \
          | jq -r '.[]? | select(.identifier == "authentik") | .id' || true)
        if [ -n "$pid" ]; then
          unique_uid=$(nextcloud-occ config:app:get user_oidc "provider-$pid-uniqueUid" 2>/dev/null || true)
          unique_uid=''${unique_uid:-1}
        fi

        nextcloud-occ user_oidc:provider authentik \
          --clientid="$OIDC_CLIENT_ID" \
          --clientsecret="$OIDC_CLIENT_SECRET" \
          --discoveryuri="$OIDC_DISCOVERY_URI" \
          --scope="email profile nextcloud openid groups" \
          --mapping-uid="preferred_username" \
          --unique-uid="$unique_uid" \
          --mapping-display-name="name" \
          --mapping-email="email" \
          --mapping-quota="quota" \
          --mapping-groups="groups" \
          --group-provisioning=1 \
          --group-whitelist-regex="^admin$" \
          --check-bearer=1 \
          --send-id-token-hint=1

        # Authentik is the only login backend, so the login page goes straight to
        # it; a local account still logs in at /login?direct=1.
        nextcloud-occ --no-interaction config:app:set user_oidc allow_multiple_user_backends --value=0 --type=string

        echo "Authentik OIDC provider configured successfully."
      '';
    };
  };

  # Configure the Euro-Office connector — only runs when the secrets file exists.
  # Secrets file (/etc/secrets/onlyoffice.env) is written by this module's nextcloud:fileservice converge (the onlyoffice connector).
  # Format: JWT_SECRET=<hex>
  systemd.services.nextcloud-configure-eurooffice = {
    description = "Configure Euro-Office connector in Nextcloud";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];
    requires    = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/onlyoffice.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/onlyoffice.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-eurooffice" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        # Connector v11 renamed the app onlyoffice -> eurooffice. The old app's code
        # is gone (not in extraApps), but a site that had it still lists it as
        # installed, and Nextcloud reports it as missing on every request. Its
        # settings are rebuilt below under the new ID.
        if nextcloud-occ config:app:get onlyoffice enabled >/dev/null 2>&1; then
          nextcloud-occ app:disable onlyoffice || true
        fi

        nextcloud-occ config:app:set eurooffice DocumentServerUrl         --value="$EURO_OFFICE_URL"
        nextcloud-occ config:app:set eurooffice DocumentServerInternalUrl --value="$EURO_OFFICE_INTERNAL_URL"
        nextcloud-occ config:app:set eurooffice StorageUrl                --value="https://$NEXTCLOUD_PUBLIC_URL/"
        nextcloud-occ config:app:set eurooffice jwt_secret                --value="$JWT_SECRET"
        nextcloud-occ config:app:set eurooffice jwt_header                --value="Authorization"

        echo "Euro-Office connector configured successfully."
      '';
    };
  };

  # Configure SMTP credentials — runs on every boot when /etc/secrets/mail.env exists.
  # Populate /etc/secrets/mail.env (mode 0600, root:root) with:
  #   SMTP_USER=user@example.com
  #   SMTP_PASSWORD=<app password or account password>
  # The local part of SMTP_USER becomes the From address (user@example.com → "user").
  # Mail app: Microsoft 365 sign-in. update.sh delivers the env file (MS_TENANT_ID,
  # MS_CLIENT_ID, MS_CLIENT_SECRET) from the management plane when it exists there.
  # The Mail app encrypts the client secret itself, so it goes through its admin
  # endpoint; occ config:app:set would store it in clear and the app could not read it.
  # notify_push: the daemon keeps reaching Nextcloud internally (the module's default
  # URL, where its trusted-proxy self-test passes; through the reverse proxy the test fails
  # because the proxy replaces X-Forwarded-For). Browsers need the public endpoint instead:
  # the default hands them ws://<hostName>/push/ws, unresolvable and mixed content, so web
  # notifications fell back to slow polling. Setup runs every boot, so this re-applies.
  systemd.services.nextcloud-notify_push_setup.serviceConfig.ExecStartPost =
    lib.mkIf (ncProxyDomain != "")
      "${lib.getExe config.services.nextcloud.occ} --no-interaction config:app:set notify_push base_endpoint --value=https://${ncProxyDomain}/push --type=string";

  systemd.services.nextcloud-configure-mail-microsoft = {
    description = "Configure Microsoft 365 sign-in for the Mail app";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" "phpfpm-nextcloud.service" "nginx.service" ];
    requires    = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/mail-microsoft.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/mail-microsoft.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-mail-microsoft" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"

        # No secret in argv (ps shows argv to every user): jq reads the Microsoft
        # settings from the environment (EnvironmentFile) into a 0600 file that curl
        # sends by name, and the admin password goes to curl on stdin (-K -).
        umask 077
        body=$(mktemp)
        trap 'rm -f "$body"' EXIT
        jq -n '{tenantId: env.MS_TENANT_ID, clientId: env.MS_CLIENT_ID, clientSecret: env.MS_CLIENT_SECRET}' > "$body"
        # OCS-APIRequest: a plain app route; without it Nextcloud wants a CSRF token (412).
        code=$(printf 'user = "admin:%s"\n' "$(cat /var/lib/nextcloud/admin-pass)" \
          | curl -s -o /dev/null -w '%{http_code}' -K - -X POST \
              -H 'Content-Type: application/json' -H 'OCS-APIRequest: true' -H 'Host: ${config.networking.hostName}' \
              --data @"$body" http://127.0.0.1/apps/mail/api/integration/microsoft)
        [ "$code" = 200 ] || { echo "Mail app refused the Microsoft settings (HTTP $code)" >&2; exit 1; }

        stored=$(nextcloud-occ config:app:get mail microsoft_oauth_client_id || true)
        [ "$stored" = "$MS_CLIENT_ID" ] || { echo "client id not stored (got '$stored')" >&2; exit 1; }
        echo "Mail app: Microsoft 365 sign-in configured for tenant $MS_TENANT_ID"
      '';
    };
  };

  systemd.services.nextcloud-configure-mail = {
    description = "Configure Nextcloud SMTP credentials";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];
    requires    = [ "nextcloud-setup.service" ];

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

  # ── Talk: TURN/STUN relay (coturn) ────────────────────────────────────────
  # Written by the `talk` connector (ADR-COM-0002). Its own unit and its own env
  # file, so a coturn-only site gets a relay without an HPB.
  systemd.services.nextcloud-configure-talk-turn = {
    description = "Register the coturn TURN/STUN relay in Nextcloud Talk";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];
    requires    = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/talk.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/talk.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-talk-turn" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        # talk:turn:add appends, so clear first or a re-run stacks duplicates.
        nextcloud-occ config:app:delete spreed turn_servers >/dev/null 2>&1 || true
        nextcloud-occ config:app:delete spreed stun_servers >/dev/null 2>&1 || true
        for s in "''${TURN_SERVER:-}" "''${TURN_SERVER_INTERNAL:-}"; do
          [ -n "$s" ] || continue
          nextcloud-occ talk:stun:add "$s"
          nextcloud-occ talk:turn:add turn "$s" "udp,tcp" --secret="$TURN_SECRET"
        done

        echo "Nextcloud Talk STUN/TURN relay configured: ''${TURN_SERVER:-} ''${TURN_SERVER_INTERNAL:-}"
      '';
    };
  };

  # ── HPB: register Talk signaling backend ─────────────────────────────────
  # Written by the `hpb` connector. Signaling only — the relay is the unit above.
  systemd.services.nextcloud-configure-hpb = {
    description = "Register Nextcloud Talk HPB signaling backend";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "nextcloud-setup.service" ];
    requires    = [ "nextcloud-setup.service" ];

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

        echo "Nextcloud Talk HPB signaling backend configured: wss://$HPB_URL"
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
    requires    = [ "nextcloud-setup.service" ];

    unitConfig.ConditionPathExists = "/etc/secrets/whiteboard.env";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/whiteboard.env";
      ExecStart = pkgs.writeShellScript "nextcloud-configure-whiteboard" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:$PATH"

        # The browser opens the collab socket at this URL, so it must be the public
        # one; Caddy routes its /socket.io/ to the co-located server.
        PUBLIC_URL="${if ncProxyDomain != "" then "https://" + ncProxyDomain else "http://" + config.networking.hostName}"

        # Whiteboard 2.x declares both keys in its config lexicon (string; the
        # secret sensitive). Set untyped, occ declines the change with "Config
        # value were not updated", still exits 0, and the socket runs without a
        # secret: the board shows Offline. --no-interaction makes it never prompt.
        nextcloud-occ --no-interaction config:app:set whiteboard collabBackendUrl \
          --type=string --value="$PUBLIC_URL"

        nextcloud-occ --no-interaction config:app:set whiteboard jwt_secret_key \
          --type=string --sensitive --value="$JWT_SECRET_KEY"

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
    requires    = [ "nextcloud-setup.service" ];

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
