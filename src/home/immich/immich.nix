# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Immich Photo & Video Server
# ============================================================================
# Self-contained NixOS configuration -- used directly as nixos-config by
# update-os.sh during install and subsequent nixos-rebuild switch calls.
#
# Architecture:
# - services.immich (server + machine-learning), Immich 3 from
#   nixos-unstable -- see unstableSrc below
# - PostgreSQL + VectorChord: fully managed by the immich module
#   (unix-socket peer auth -- no DB password, no secrets plumbing)
# - Redis (named instance "immich"): managed by the immich module, unix socket
# - Machine learning (smart search, face recognition) on localhost:3003,
#   always on -- it is much of why one runs Immich; the VM is sized for it (8G)
# - Caddy on the OPNsense firewall terminates TLS; VM serves plain HTTP :2283
# - OIDC (Authentik) wired automatically: identity:identity + immich-configure-oidc
#
# Storage: ONE disk. Photos live on the VM's own disk (cluster:vm diskSize,
# on tanka1), in Immich's mediaLocation /var/lib/immich: upload/, library/,
# thumbs/, encoded-video/, profile/, backups/. One disk is what the platform
# can watch and grow -- the disk-threshold check and its auto-grow look at
# `df /` and scsi0 only -- and what cluster:ha replicates. More room = raise
# diskSize (grow-only); boot.growPartition grows the filesystem.
#
# Backups: PBS snapshots the disk (backup:vm dependency); additionally a
# daily PostgreSQL dump at 02:30 with 30-day retention (belt and braces).
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  # Immich 3 comes from nixos-unstable: the pinned release only has Immich 2,
  # which is end of life and marked insecure there (CVE-2026-59258,
  # CVE-2026-82272). Only the immich module and package are taken from it;
  # the rest of the system, PostgreSQL included, stays on the pinned release
  # (both ship VectorChord 1.1.1). Drop this once the pinned release carries
  # Immich 3 (NixOS 26.11). Bump: new rev + `nix-prefetch-url --unpack <url>`.
  unstableSrc = builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/a7868a727837f3c09cee2ce0ca671c76b1589fed.tar.gz";
    sha256 = "0z1daxh826r5d877fa77576ihfq4lzhzwys0ggnppw8bld42s0ia";
  };
  # The site's own public name (#715), not ours to guess: update-os.sh deploys
  # the module's config beside this file as /etc/nixos/immich.json, with the
  # name the proxy publishes it under and whether that name has a public record
  # -- the vaultwarden/logging idiom. The mobile app's OAuth redirect needs that
  # https URL; unpublished, there is none and only web OAuth is configured.
  moduleCfg   = if builtins.pathExists ./immich.json
                then builtins.fromJSON (builtins.readFile ./immich.json)
                else {};
  proxyCfg    = (moduleCfg.config or {})."network:proxy" or {};
  proxyDomain = proxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  published   = proxyDomain != "" && (moduleCfg.proxyPublished or true);
  publicUrl   = if published then "https://${proxyDomain}" else "";
  # The firewall's IPv6 address in this zone: Caddy's source when it reaches
  # Immich over IPv6 (ADR-030 D9). Absent on a site without IPv6.
  proxySourceV6 = moduleCfg.proxySourceV6 or "";

  unstable = import unstableSrc {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # jellyfin-ffmpeg 8.1.3-1 (#807): FFmpeg 8.1.3 fixes the decoder and demuxer
  # flaws open in 8.1.2-5 (VobSub, ADX, TDSC, TY, MACE, DVB subtitles, CFHD,
  # RTP/ASF, the HLS playlist loop). nixpkgs has it (#573402, via staging-next),
  # the nixos-unstable channel not yet: until it does, the pinned package with
  # the new source. jellyfin's own patch series comes from that source
  # (postPatch). Drop this when unstableSrc carries 8.1.3 or later.
  jellyfinFfmpeg = unstable.jellyfin-ffmpeg.overrideAttrs (old: rec {
    version = "8.1.3-1";
    src = unstable.fetchFromGitHub {
      owner = "jellyfin";
      repo  = "jellyfin-ffmpeg";
      tag   = "v${version}";
      hash  = "sha256-sxJyUaB0rqpVzd6OVRC6kPVWyBdgFUzvyqwLCkMKRgM=";
    };
    # The pinned ffmpeg adds an 8.1.2 fix that 8.1.3 already contains (the
    # swscale loongarch underflow); applied again it fails.
    patches = builtins.filter (p: !(unstable.lib.hasInfix "swscale-loongarch-fix-buffer-underflow" (toString p)))
      (old.patches or [ ]);
  });
in
{
  disabledModules = [ "services/web-apps/immich.nix" ];
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324), shipped by update-os.sh
    # before every rebuild; it imports the site's time and locale.
    /etc/nixos/tappaas-common.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    # Always present: update-os.sh ships an empty one, and backup:filesystem
    # overwrites it with the real trigger.
    /etc/nixos/tappaas-backup.nix
    "${unstableSrc}/nixos/modules/services/web-apps/immich.nix"
  ];

  # Everything a TAPPaaS VM has in common -- boot, cloud-init, NetworkManager,
  # the tappaas user and sudo, ssh, qemu-guest, serial console, zram/oomd, nix
  # settings and gc, the site's time zone -- comes from the baseline (#324).
  # This file states only what immich adds or changes.

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "immich";

  # Single source of truth for open ports (services.immich.openFirewall is
  # deliberately left off so editing this list is sufficient).
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 2283 ];
  };

  # -- SSH: keys only (the baseline's defaults allow passwords) ----------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Packages --------------------------------------------------------------
  # vim, wget, curl, htop and git come from the baseline. postgresql: psql CLI
  # for debugging; the immich package brings the immich-admin CLI (lockout
  # recovery: immich-admin enable-password-login).
  environment.systemPackages = with pkgs; [
    jq openssl postgresql
    config.services.immich.package
  ];

  # -- Immich photo/video server ----------------------------------------------
  services.immich = {
    enable = true;
    package = unstable.immich.override { jellyfin-ffmpeg = jellyfinFfmpeg; };   # Immich 3 -- see unstableSrc above
    host = "::";             # every address, both families; "localhost" is unreachable by Caddy
    port = 2283;
    mediaLocation = "/var/lib/immich";  # on the root filesystem (one disk)

    # DB + Redis fully managed by the NixOS module: postgres over a unix
    # socket with peer auth (no password / secretsFile needed), database,
    # user and extensions auto-created; redis instance "immich" on a socket.
    # VectorChord is always on in the pinned nixpkgs: enableVectorChord and
    # enableVectors (pgvecto.rs) are gone, and setting either fails the build.
    database = {
      enable = true;
      createDB = true;
    };
    redis.enable = true;

    machine-learning.enable = true;

    # null keeps the entire system config editable in the admin UI (OIDC,
    # storage template, quotas, ...). A declared settings attrset would make
    # the UI read-only AND put the OIDC client secret in the world-readable
    # nix store unless the _secret indirection is used. See INSTALL.md.
    settings = null;

    environment = {
      IMMICH_LOG_LEVEL = "log";
      # Caddy runs on the OPNsense firewall which holds the gateway IP of
      # every TAPPaaS zone (10.x.y.1) -- same rationale as nextcloud; over IPv6
      # it comes from the firewall's address in this zone (ADR-030 D9).
      IMMICH_TRUSTED_PROXIES = lib.concatStringsSep ","
        ([ "10.0.0.0/8" ] ++ lib.optional (proxySourceV6 != "") proxySourceV6);
    };

    # No GPU passthrough by default; set [ "/dev/dri/renderD128" ] for VAAPI
    # transcoding on a VM with an (i)GPU passed through.
    accelerationDevices = [ ];
  };

  # -- Authentik OIDC (ADR-006, identity:identity) -----------------------------
  # /etc/secrets/immich.env (OIDC_CLIENT_ID/SECRET/DISCOVERY_URI) is written by
  # identity/services/identity/install-service.sh once immich.json declares an
  # `identity` block. Unlike Nextcloud's user_oidc, Immich has no CLI to
  # register a provider -- its OAuth settings live in the system_metadata table,
  # editable only through the admin UI or /api/system-config. Rather than
  # declare services.immich.settings (which would freeze the ENTIRE admin UI
  # read-only just to set OIDC -- see "settings = null" above), this service
  # PUTs only the .oauth section back through that same API, using a
  # narrowly-scoped API key (systemConfig.read/update) minted once by
  # install.sh -- the admin password itself is never written to disk.
  systemd.services.immich-configure-oidc = {
    description = "Configure Authentik OIDC provider in Immich";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "immich-server.service" ];

    # Activated only once identity:identity has written the secrets file AND
    # install.sh has minted the API key. Without the second condition the
    # first nixos-rebuild switch (before the admin exists) failed with exit 4.
    unitConfig.ConditionPathExists = [
      "/etc/secrets/immich.env"
      "/etc/secrets/immich-admin-api-key"
    ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/immich.env";
      ExecStart = pkgs.writeShellScript "immich-configure-oidc" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:$PATH"

        API_KEY_FILE=/etc/secrets/immich-admin-api-key
        if [ ! -f "$API_KEY_FILE" ]; then
          echo "immich-configure-oidc: $API_KEY_FILE missing -- mint one via" \
               "install.sh's admin bootstrap, or manually in the admin UI" \
               "(Account Settings -> API Keys, permissions systemConfig.read" \
               "+ systemConfig.update) and place it there (mode 600)." >&2
          exit 1
        fi
        API_KEY="$(cat "$API_KEY_FILE")"

        BASE_URL=http://127.0.0.1:2283

        # immich-server itself is not a oneshot -- "after" only orders unit
        # start, not readiness (first boot runs DB migrations). Wait for it.
        ready=0
        for _ in $(seq 1 60); do
          if curl -sf --max-time 5 "$BASE_URL/api/server/ping" | grep -q pong; then
            ready=1; break
          fi
          sleep 2
        done
        [ "$ready" -eq 1 ] || { echo "immich-configure-oidc: server never became ready" >&2; exit 1; }

        # Authentik's own issuer includes the trailing slash (its discovery
        # document reports e.g. ".../application/o/immich/") -- Immich's OAuth
        # client validates the issuer string exactly against that, per the
        # OIDC discovery spec, so it must be preserved here. Strip only the
        # ".well-known/..." suffix (no leading slash in the pattern), not
        # "/.well-known/..." -- that extra slash was eating the one that
        # belongs to the issuer itself.
        ISSUER_URL="''${OIDC_DISCOVERY_URI%.well-known/openid-configuration}"

        CURRENT="$(curl -sf -H "x-api-key: $API_KEY" "$BASE_URL/api/system-config")"

        # The mobile app's callback (app.immich:///oauth-callback) is a custom
        # URI scheme -- Immich's own oauth.mobileRedirectUri validator rejects
        # anything that isn't a normal http(s) URL, and it is never registered
        # anywhere directly. Immich ships a built-in route,
        # /api/oauth/mobile-redirect, that forwards to the custom scheme
        # internally; that route is what gets registered with Authentik (via
        # identity.oidcRedirectPaths, a plain https path) and is what
        # oauth.mobileRedirectUri must point at here. The public URL comes from
        # immich.json at build time (publicUrl above), so it is part of this
        # unit: a changed domain changes the unit, and the rebuild re-runs it.
        # Unpublished: web OAuth only.
        PUBLIC_URL="${publicUrl}"
        MOBILE_OVERRIDE="false"
        MOBILE_URI=""
        if [ -n "$PUBLIC_URL" ]; then
          MOBILE_OVERRIDE="true"
          MOBILE_URI="$PUBLIC_URL/api/oauth/mobile-redirect"
        else
          echo "immich-configure-oidc: immich is not published -- configuring web OAuth only (no https URL for the mobile redirect)" >&2
        fi

        # autoLaunch: the login page goes straight to Authentik, as Nextcloud's
        # does -- a user signed in there never sees Immich's own form. The local
        # admin (the account of last resort) still signs in at
        # /auth/login?autoLaunch=0.
        # PUT replaces the whole document -- merge into the current config so
        # storage template/backup/job settings the admin already tuned survive.
        MERGED="$(printf '%s' "$CURRENT" | jq \
          --arg issuer "$ISSUER_URL" \
          --arg cid "$OIDC_CLIENT_ID" \
          --arg csec "$OIDC_CLIENT_SECRET" \
          --argjson mobileOverride "$MOBILE_OVERRIDE" \
          --arg mobileUri "$MOBILE_URI" \
          '.oauth.enabled              = true
           | .oauth.issuerUrl          = $issuer
           | .oauth.clientId           = $cid
           | .oauth.clientSecret       = $csec
           | .oauth.scope              = "openid email profile"
           | .oauth.buttonText         = "Login with Authentik"
           | .oauth.autoRegister       = true
           | .oauth.autoLaunch         = true
           | if $mobileOverride then
               (.oauth.mobileOverrideEnabled = true | .oauth.mobileRedirectUri = $mobileUri)
             else . end')"

        # $MERGED carries the OAuth client secret -- pipe it via stdin (-d @-)
        # rather than as a curl argv, so it doesn't sit in the process list
        # for the call's duration (matches install.sh's existing convention
        # for the admin/login payloads).
        printf '%s' "$MERGED" | curl -sf -X PUT -H "x-api-key: $API_KEY" \
          -H "Content-Type: application/json" -d @- "$BASE_URL/api/system-config" >/dev/null

        echo "Authentik OIDC configured in Immich system-config."
      '';
    };
  };

  # -- PostgreSQL tuning -------------------------------------------------------
  # The immich module provisions the database but leaves memory settings at
  # stock (128MB shared_buffers). Immich is DB-heavy (metadata + vector
  # search) and VectorChord index builds want maintenance_work_mem. Sized for
  # an 8GB VM shared with the ML service; merges with the module's own
  # settings (shared_preload_libraries, search_path).
  services.postgresql.settings = {
    shared_buffers           = "1GB";
    effective_cache_size     = "3GB";
    maintenance_work_mem     = "512MB";
    work_mem                 = "32MB";
    wal_buffers              = "16MB";
    random_page_cost         = 1.1;
    effective_io_concurrency = 200;
  };

  # NOTE: Redis is deliberately left at module defaults. Immich uses it as a
  # BullMQ job queue — capping maxmemory with an eviction policy (nextcloud
  # style) would silently drop jobs. The default noeviction is correct.

  # Throttle ML memory during bulk imports (first phone sync = thousands of
  # jobs) so it cannot starve postgres and immich-server. MemoryHigh throttles
  # before oomd would have to kill.
  systemd.services.immich-machine-learning = {
    serviceConfig = {
      MemoryHigh = "4G";
      MemoryMax  = "5G";
    };
  };

  # -- Backup strategy ---------------------------------------------------------
  # PBS (backup:vm) snapshots the disk. Immich also writes its own nightly
  # pg_dumpall into /var/lib/immich/backups. This dump is belt and braces:
  # a plain-SQL copy, restorable without Immich itself.
  # 02:30, not 02:00: Immich's own built-in nightly dump defaults to ~02:00 —
  # staggering avoids two simultaneous dumps of the same database.
  services.postgresqlBackup = {
    enable      = true;
    databases   = [ "immich" ];
    startAt     = "*-*-* 02:30:00";
    location    = "/var/backup/immich/postgresql";
    compression = "gzip";
  };

  systemd.services.immich-cleanup-backups = {
    description = "Cleanup old Immich DB backups";
    serviceConfig = {
      Type      = "oneshot";
      User      = "root";
      ExecStart = pkgs.writeShellScript "immich-cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup/immich -type f -mtime +30 -delete
      '';
    };
  };

  systemd.timers.immich-cleanup-backups = {
    description = "Monthly cleanup of old Immich DB backups";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # -- Filesystem structure ----------------------------------------------------
  # The parent must be traversable: postgresqlBackup runs as postgres and
  # creates its own 0700 postgres location below it. A 0700 root parent made
  # every dump fail (found in the hrossen live test).
  systemd.tmpfiles.rules = [
    "d /var/backup/immich             0755 root     root     -"
  ];

  system.stateVersion = "25.05";
}
