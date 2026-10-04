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
# - NixOS native services.immich (server + optional machine-learning)
# - PostgreSQL + VectorChord: fully managed by the immich module
#   (unix-socket peer auth -- no DB password, no secrets plumbing)
# - Redis (named instance "immich"): managed by the immich module, unix socket
# - Machine learning (smart search, face recognition) on localhost:3003;
#   toggled via "machineLearning" in immich.json (marker block below)
# - Caddy on the OPNsense firewall terminates TLS; VM serves plain HTTP :2283
# - OIDC (Authentik) wired automatically: identity:identity + immich-configure-oidc
#
# Storage architecture (three layers; Layer 1 is selected by the
# "mediaStorage" mode in immich.json -- see INSTALL.md -> Media Storage):
#   Layer 1 -- Block device:  Proxmox virtual disk (allocate) or an attached
#                             USB/iSCSI disk (attached), presented as
#                             /dev/disk/by-label/immich-data; or a NAS
#                             share mounted directly (share).
#   Layer 2 -- Filesystem:   ext4, created by install-service.sh (allocate)
#                             or setup-media-disk.sh (attached).
#   Layer 3 -- Immich mediaLocation = /var/lib/immich (the mount point).
#              Immich manages its own layout there: upload/, library/,
#              thumbs/, encoded-video/, profile/, backups/ (nightly built-in
#              pg_dumpall dumps land in backups/ -> covered by the data disk
#              and PBS snapshots).
#
# Backups: PBS snapshots both disks (backup:vm dependency); additionally a
# daily PostgreSQL dump at 02:30 with 30-day retention (belt and braces).
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # -- Boot ------------------------------------------------------------------
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # -- Cloud-init ------------------------------------------------------------
  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "immich";
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = {
      id = "tappaas-ethernet";
      type = "ethernet";
      autoconnect = "true";
      autoconnect-priority = "100";
    };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  # Single source of truth for open ports (services.immich.openFirewall is
  # deliberately left off so editing this list is sufficient).
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 2283 ];
  };

  # -- Time zone -------------------------------------------------------------
  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # -- Users & sudo ----------------------------------------------------------
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # -- SSH -------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  programs.ssh.startAgent = true;

  # -- Essential services ----------------------------------------------------
  services.qemuGuest.enable = true;

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  # -- OOM resilience --------------------------------------------------------
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableUserSlices = true;
  };
  systemd.slices."user-".sliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "80%";
    MemoryHigh = "90%";
    MemoryMax = "95%";
  };

  # -- Nix settings ----------------------------------------------------------
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # -- Packages --------------------------------------------------------------
  # postgresql: psql CLI for debugging; the immich package brings the
  # immich-admin CLI (lockout recovery: immich-admin enable-password-login).
  environment.systemPackages = with pkgs; [
    vim wget curl htop git jq openssl postgresql
    config.services.immich.package
  ];

  # -- Immich photo/video server ----------------------------------------------
  services.immich = {
    enable = true;
    host = "0.0.0.0";        # module default "localhost" is unreachable by Caddy
    port = 2283;
    mediaLocation = "/var/lib/immich";  # = data-disk mount point (see below)

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

    # BEGIN ml-config (managed by update.sh from "machineLearning" in immich.json)
    machine-learning.enable = true;
    # END ml-config

    # null keeps the entire system config editable in the admin UI (OIDC,
    # storage template, quotas, ...). A declared settings attrset would make
    # the UI read-only AND put the OIDC client secret in the world-readable
    # nix store unless the _secret indirection is used. See INSTALL.md.
    settings = null;

    environment = {
      IMMICH_LOG_LEVEL = "log";
      # Caddy runs on the OPNsense firewall which holds the gateway IP of
      # every TAPPaaS zone (10.x.y.1) -- same rationale as nextcloud.
      IMMICH_TRUSTED_PROXIES = "10.0.0.0/8";
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

    # Activated only once identity:identity has written the secrets file.
    unitConfig.ConditionPathExists = "/etc/secrets/immich.env";

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
        # oauth.mobileRedirectUri must point at here. IMMICH_PUBLIC_URL (this
        # module's own public URL) is co-managed into /etc/secrets/immich.env
        # by update.sh, since identity:identity's env file only carries the
        # OIDC_* keys otherwise -- it may not have run yet on a very first
        # boot, so degrade to web-only OAuth rather than fail the whole call.
        MOBILE_OVERRIDE="false"
        MOBILE_URI=""
        if [ -n "''${IMMICH_PUBLIC_URL:-}" ]; then
          MOBILE_OVERRIDE="true"
          MOBILE_URI="''${IMMICH_PUBLIC_URL}/api/oauth/mobile-redirect"
        else
          echo "immich-configure-oidc: IMMICH_PUBLIC_URL not set yet -- configuring web OAuth only (mobile override applies once update.sh has written it, next run)" >&2
        fi

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
  systemd.services.immich-machine-learning = lib.mkIf config.services.immich.machine-learning.enable {
    serviceConfig = {
      MemoryHigh = "4G";
      MemoryMax  = "5G";
    };
  };

  # -- Data disk mount ---------------------------------------------------------
  # Identified by label so the mount survives disk reordering between reboots.
  # nofail: VM boots normally even before the disk is attached (install order).
  # The block between the media-mount markers is managed by update.sh: with
  # mediaStorage=share in immich.json it is replaced by the declared
  # NFS/CIFS mount at deploy time (edits inside the markers are overwritten
  # in that mode).
  # BEGIN media-mount (managed by update.sh)
  fileSystems."/var/lib/immich" = {
    device  = "/dev/disk/by-label/immich-data";
    fsType  = "ext4";
    options = [ "nofail" "noatime" "x-systemd.automount" "x-systemd.device-timeout=10" ];
  };
  # END media-mount

  # Fail fast instead of silently writing photos to the OS disk if the data
  # disk is absent (diagnostic signature: immich-server restart loop).
  systemd.services.immich-server.unitConfig.RequiresMountsFor = [ "/var/lib/immich" ];

  # -- Backup strategy ---------------------------------------------------------
  # PBS (backup:vm) snapshots both disks. Immich also writes its own nightly
  # pg_dumpall into /var/lib/immich/backups. This dump is belt and braces:
  # a plain-SQL copy on the OS disk, restorable without Immich itself.
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
  systemd.tmpfiles.rules = [
    "d /var/backup/immich             0700 root     root     -"
    "d /var/backup/immich/postgresql  0700 postgres postgres -"
  ];

  system.stateVersion = "25.05";
}
