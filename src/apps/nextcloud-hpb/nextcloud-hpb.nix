# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - nextcloud-hpb
# ============================================================================
# Version: 0.3.0
# Date: 2026-09-21
# Author: @AndreasJe (TAPPaaS)
# Product: nextcloud-spreed-signaling (Talk High-Performance Backend)
#          + Janus WebRTC gateway (the SFU that makes group calls scale)
#
# Architecture:
# - services.nextcloud-spreed-signaling (Go, from nixpkgs), NATS loopback
#   (in-process — no external NATS needed for a single node)
# - Janus (janus-gateway, nixpkgs) as the signaling server's MCU: every
#   participant sends ONE stream to Janus, which fans it out. Without it Talk
#   runs group calls as a full mesh (N-1 uplinks per client), which caps a
#   video call at roughly 5-6 participants.
# - Signaling listens on 0.0.0.0:8080; Caddy on OPNsense proxies wss:// to it.
#   Janus's WebSocket API is loopback-only (127.0.0.1:8188); its media ports
#   (UDP 20000-20999) are open on the VM firewall.
# - Secrets auto-generated in /var/lib/nextcloud-hpb/secrets/ on first boot;
#   the coturn TURN secret is synced there by install.sh/update.sh.
#
# Facts from PROVIDERS, read from the companion JSON (./nextcloud-hpb.json,
# shipped to /etc/nixos by update-os.sh on every rebuild):
#   turnHost           — stamped by coturn:turn        (<publicDomain>:3478)
#   nextcloudPublicUrl — stamped by nextcloud:fileservice (https://<proxyDomain>)
# Neither is authored in this module; both are re-derived on every converge.
# This replaces the earlier `sed` of the deployed .nix followed by an
# out-of-band `nixos-rebuild` (which bypassed the platform's nixpkgs pin).
#
# Network: the NEXTCLOUD zone (co-located; see INSTALL.md), proxyDomain: see
# nextcloud-hpb.json. Firewall: TCP 22 (SSH), TCP 8080 (signaling, via Caddy),
# UDP 20000-20999 (Janus media).
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  secretsDir = "/var/lib/nextcloud-hpb/secrets";

  # ── Companion JSON: the deployed config, as update-os.sh ships it ──────────
  moduleCfg = if builtins.pathExists ./nextcloud-hpb.json
              then builtins.fromJSON (builtins.readFile ./nextcloud-hpb.json)
              else {};

  # Provider-stamped facts (see header). Missing means "rebuilt outside the
  # pipeline, or before the providers ran" — say so at evaluation time rather
  # than shipping a backend Talk rejects with invalid_backend.
  turnHost           = moduleCfg.turnHost or "";
  nextcloudPublicUrl = moduleCfg.nextcloudPublicUrl or "";

  turnHostEff  = if turnHost != "" then turnHost else "coturn.dmz.internal:3478";
  turnHostName = lib.head (lib.splitString ":" turnHostEff);
  turnHostPort = lib.last (lib.splitString ":" turnHostEff);

  turnServers = lib.warnIf (turnHost == "")
    "nextcloud-hpb.nix: ./nextcloud-hpb.json carries no turnHost (coturn:turn stamps it) — advertising the internal coturn name, which external Talk clients cannot resolve"
    [
      "turn:${turnHostEff}?transport=udp"
      "turn:${turnHostEff}?transport=tcp"
    ];

  backendUrls = lib.warnIf (nextcloudPublicUrl == "")
    "nextcloud-hpb.nix: ./nextcloud-hpb.json carries no nextcloudPublicUrl (nextcloud:fileservice stamps it) — the backend allow-list is a placeholder and Talk WILL reject this HPB with invalid_backend; rebuild through update-os.sh after the provider services have run"
    [ (if nextcloudPublicUrl != "" then nextcloudPublicUrl else "https://nextcloud.invalid") ];

  # ── Janus ──────────────────────────────────────────────────────────────────
  janusPkg     = pkgs.janus-gateway;   # built with --enable-turn-rest-api in nixpkgs
  janusWsPort  = 8188;
  # 1000 UDP ports ≈ 500 concurrent media legs — comfortably a 30-participant
  # video call. Widen (and the firewall rule with it) for bigger single meetings.
  janusRtpFrom = 20000;
  janusRtpTo   = 20999;
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

  networking.hostName = lib.mkDefault (moduleCfg.vmname or "nextcloud-hpb");
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
      22    # SSH
      8080  # HPB WebSocket (proxied by Caddy on OPNsense)
    ];
    # Janus media. Clients in a zone that reaches this one send RTP here
    # directly; everyone else (other client zones, the internet) reaches Janus
    # through coturn, whose relay candidates Janus obtains via the TURN REST API.
    allowedUDPPortRanges = [
      { from = janusRtpFrom; to = janusRtpTo; }
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

  users.users.janus = {
    isSystemUser = true;
    group        = "janus";
    description  = "Janus WebRTC gateway";
  };
  users.groups.janus = {};

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
  # SECRETS AUTO-GENERATION
  # ============================================================================
  #
  # Runs once on first boot to create all signing/encryption secrets for the
  # signaling server. The TURN relay secret is NOT generated here — it is
  # written by install.sh/update.sh from the management plane, ensuring both
  # sides share the same HMAC secret.

  systemd.tmpfiles.rules = [
    "d ${secretsDir} 0700 nextcloud-spreed-signaling nextcloud-spreed-signaling -"
    "d /etc/secrets  0700 root root -"
  ];

  systemd.services.hpb-init-secrets = {
    description = "Generate nextcloud-hpb secrets if missing";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
    before      = [ "nextcloud-spreed-signaling.service" "janus.service" ];
    unitConfig.ConditionPathExists = "!${secretsDir}/hpb-secret";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "hpb-init-secrets" ''
        set -euo pipefail

        DIR="${secretsDir}"

        # Session keys — used to sign and encrypt WebSocket session cookies
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/session-hashkey"   # 64-char hex = 32 bytes
        ${pkgs.openssl}/bin/openssl rand -hex 16 > "$DIR/session-blockkey"  # 32-char hex = 16 bytes

        # Internal client secret — used by internal services contacting the signaling server
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/internalsecret"

        # Shared secret between this HPB and the Nextcloud backend
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/hpb-secret"

        # TURN API key — protects the TURN credential REST endpoint Janus calls
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/turn-apikey"

        # Janus admin API secret (the admin transport is disabled; kept so the
        # core has a secret should it ever be enabled for diagnostics)
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/janus-admin"

        # TURN relay secret — placeholder until install.sh writes the real coturn secret.
        # The signaling server starts with this placeholder; install.sh overwrites it
        # with the actual COTURN_SECRET and restarts the service.
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$DIR/turn-secret"

        ${pkgs.coreutils}/bin/chown -R nextcloud-spreed-signaling:nextcloud-spreed-signaling "$DIR"
        ${pkgs.coreutils}/bin/chmod 400 "$DIR"/*

        echo "HPB secrets generated at ${secretsDir}"
      '';
    };
  };

  # ============================================================================
  # JANUS — the SFU behind the signaling server
  # ============================================================================
  #
  # No NixOS module exists for Janus, so — like coturn — a custom unit renders
  # the config at start from runtime secrets into /run/janus, and nothing
  # secret lands in the Nix store. Rendering runs as root (the "+" prefix): the
  # TURN REST API key is 0400 and owned by the signaling user.
  #
  # ICE: full trickle, NOT ice-lite. Janus sits behind the site's NAT; it needs
  # TURN relay candidates of its own for participants it cannot reach directly
  # (other client zones, the internet), and an ice-lite agent never uses TURN.
  # The credentials come from the signaling server's TURN REST endpoint, so
  # Janus and the browsers share coturn's HMAC secret without a copy here.

  systemd.services.janus = {
    description = "Janus WebRTC gateway (SFU for Nextcloud Talk)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" "hpb-init-secrets.service" ];
    wants       = [ "network-online.target" ];
    requires    = [ "hpb-init-secrets.service" ];

    serviceConfig = {
      Type                 = "simple";
      User                 = "janus";
      Group                = "janus";
      RuntimeDirectory     = "janus";
      RuntimeDirectoryMode = "0750";

      ExecStartPre = "+" + pkgs.writeShellScript "janus-write-config" ''
        set -euo pipefail
        CONF=/run/janus
        SECRETS=${secretsDir}

        # An HPB installed before this file existed has no janus-admin: make one.
        if [ ! -s "$SECRETS/janus-admin" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "$SECRETS/janus-admin"
          ${pkgs.coreutils}/bin/chown nextcloud-spreed-signaling:nextcloud-spreed-signaling "$SECRETS/janus-admin"
          ${pkgs.coreutils}/bin/chmod 400 "$SECRETS/janus-admin"
        fi
        TURN_APIKEY="$(${pkgs.coreutils}/bin/cat "$SECRETS/turn-apikey")"
        ADMIN_SECRET="$(${pkgs.coreutils}/bin/cat "$SECRETS/janus-admin")"

        ${pkgs.coreutils}/bin/cat > "$CONF/janus.jcfg" <<JCFG
general: {
        configs_folder = "/run/janus"
        plugins_folder = "${janusPkg}/lib/janus/plugins"
        transports_folder = "${janusPkg}/lib/janus/transports"
        events_folder = "${janusPkg}/lib/janus/events"
        loggers_folder = "${janusPkg}/lib/janus/loggers"
        log_to_stdout = true
        debug_level = 4
        admin_secret = "$ADMIN_SECRET"
}
certificates: {
}
media: {
        rtp_port_range = "${toString janusRtpFrom}-${toString janusRtpTo}"
}
nat: {
        full_trickle = true
        ignore_mdns = true
        turn_server = "${turnHostName}"
        turn_port = ${turnHostPort}
        turn_type = "udp"
        turn_rest_api = "http://127.0.0.1:8080/turn"
        turn_rest_api_key = "$TURN_APIKEY"
        turn_rest_api_method = "GET"
}
plugins: {
        disable = "libjanus_audiobridge.so,libjanus_echotest.so,libjanus_recordplay.so,libjanus_sip.so,libjanus_nosip.so,libjanus_streaming.so,libjanus_textroom.so,libjanus_videocall.so,libjanus_voicemail.so,libjanus_duktape.so,libjanus_lua.so"
}
transports: {
        disable = "libjanus_http.so,libjanus_pfunix.so,libjanus_mqtt.so,libjanus_rabbitmq.so,libjanus_nanomsg.so"
}
events: {
        broadcast = false
}
JCFG

        # WebSocket API for the signaling server only — loopback, no TLS needed,
        # admin API off entirely.
        ${pkgs.coreutils}/bin/cat > "$CONF/janus.transport.websockets.jcfg" <<JCFG
general: {
        json = "indented"
        ws = true
        ws_port = ${toString janusWsPort}
        ws_ip = "127.0.0.1"
        wss = false
}
admin: {
        admin_ws = false
        admin_wss = false
}
JCFG

        # The only plugin nextcloud-spreed-signaling drives. No static rooms:
        # the signaling server creates one per Talk call.
        ${pkgs.coreutils}/bin/cat > "$CONF/janus.plugin.videoroom.jcfg" <<JCFG
general: {
}
JCFG

        ${pkgs.coreutils}/bin/chown root:janus "$CONF"/*.jcfg
        ${pkgs.coreutils}/bin/chmod 640 "$CONF"/*.jcfg
      '';

      ExecStart = "${janusPkg}/bin/janus --configs-folder=/run/janus";

      Restart    = "on-failure";
      RestartSec = "5s";

      # Security hardening — Janus writes nothing but /run/janus (its config)
      # and logs to stdout.
      NoNewPrivileges = true;
      PrivateTmp      = true;
      ProtectSystem   = "strict";
      ProtectHome     = true;
      ReadWritePaths  = [ "/run/janus" ];
    };
  };

  # ============================================================================
  # NEXTCLOUD SPREED SIGNALING SERVER
  # ============================================================================

  services.nextcloud-spreed-signaling = {
    enable = true;

    settings = {
      # Listen on all interfaces so Caddy (on OPNsense) can proxy to this VM
      http.listen = "0.0.0.0:8080";

      # In-process NATS — no external NATS server needed for a single HPB node
      # Switch to nats://localhost:4222 when adding a second HPB node
      nats.url = [ "nats://loopback" ];

      sessions = {
        hashkeyFile  = "${secretsDir}/session-hashkey";
        blockkeyFile = "${secretsDir}/session-blockkey";
      };

      clients.internalsecretFile = "${secretsDir}/internalsecret";

      # The SFU. With an MCU configured every call — 1:1 included — is routed
      # through Janus; Talk learns of it from the signaling hello, nothing to
      # configure on the Nextcloud side.
      mcu = {
        type = "janus";
        url  = "ws://127.0.0.1:${toString janusWsPort}";
      };

      turn = {
        # The name clients (and Janus) use for TURN, stamped by coturn:turn as
        # `turnHost` in the companion JSON — coturn's publicDomain, one name in
        # every horizon (split-horizon DNS answers with the coturn VM inside).
        servers = turnServers;
        apikeyFile = "${secretsDir}/turn-apikey";
        # install.sh/update.sh write the real COTURN_SECRET here; placeholder on first boot
        secretFile = "${secretsDir}/turn-secret";
      };
    };

    backends.nextcloud = {
      # Nextcloud's PUBLIC URL, stamped by nextcloud:fileservice as
      # `nextcloudPublicUrl`. Talk validates against exactly this URL; an
      # internal name is rejected with invalid_backend.
      urls       = backendUrls;
      secretFile = "${secretsDir}/hpb-secret";
    };
  };

  # Secrets before the signaling server; Janus preferably up first, but a
  # signaling server without its MCU still serves (it reconnects), so `wants`.
  systemd.services.nextcloud-spreed-signaling = {
    after    = [ "hpb-init-secrets.service" "janus.service" ];
    requires = [ "hpb-init-secrets.service" ];
    wants    = [ "janus.service" ];
  };

  # ============================================================================
  # SYSTEM STATE VERSION — DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
