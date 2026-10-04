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
# - services.nextcloud-spreed-signaling (Go, from nixpkgs) + in-process NATS
# - Janus as the signaling server's MCU: one uplink per participant instead of
#   the N-1 mesh that caps a Talk video call at ~5-6 people
# - Signaling on 0.0.0.0:8080 (Caddy proxies wss://); Janus's WebSocket API is
#   loopback-only, its media on UDP 20000-20999
#
# turnHost (coturn:turn) and nextcloudPublicUrl (nextcloud:fileservice) are read
# from the companion JSON that update-os.sh ships; neither is authored here.
#
# Network: the NEXTCLOUD zone (co-located; see INSTALL.md).
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  secretsDir = "/var/lib/nextcloud-hpb/secrets";

  moduleCfg = if builtins.pathExists ./nextcloud-hpb.json
              then builtins.fromJSON (builtins.readFile ./nextcloud-hpb.json)
              else {};

  turnHost           = moduleCfg.turnHost or "";
  turnHostInternal   = moduleCfg.turnHostInternal or "";
  nextcloudPublicUrl = moduleCfg.nextcloudPublicUrl or "";

  # Janus is server-side and inside the network, so it always uses the internal
  # endpoint. Browsers are given both and let ICE choose: under a wildcard
  # split-horizon the public name answers with the reverse proxy internally.
  turnInternalEff = if turnHostInternal != "" then turnHostInternal else "coturn.dmz.internal:3478";
  turnHostName    = lib.head (lib.splitString ":" turnInternalEff);
  turnHostPort    = lib.last (lib.splitString ":" turnInternalEff);

  turnServers = lib.warnIf (turnHost == "")
    "nextcloud-hpb.nix: ./nextcloud-hpb.json carries no turnHost (coturn:turn stamps it) — clients outside the network get no relay"
    (lib.concatMap (h: [ "turn:${h}?transport=udp" "turn:${h}?transport=tcp" ])
      (lib.unique (lib.filter (s: s != "") [ turnHost turnInternalEff ])));

  backendUrls = lib.warnIf (nextcloudPublicUrl == "")
    "nextcloud-hpb.nix: ./nextcloud-hpb.json carries no nextcloudPublicUrl (nextcloud:fileservice stamps it) — the backend allow-list is a placeholder and Talk WILL reject this HPB with invalid_backend; rebuild through update-os.sh after the provider services have run"
    [ (if nextcloudPublicUrl != "" then nextcloudPublicUrl else "https://nextcloud.invalid") ];

  janusPkg     = pkgs.janus-gateway;
  janusWsPort  = 8188;
  # ~500 concurrent media legs; widen with the firewall rule for bigger meetings.
  janusRtpFrom = 20000;
  janusRtpTo   = 20999;
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

  networking.hostName = lib.mkDefault (moduleCfg.vmname or "nextcloud-hpb");

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      8080  # HPB WebSocket (proxied by Caddy on OPNsense)
    ];
    # Janus media. Clients that cannot reach this zone directly relay via coturn.
    allowedUDPPortRanges = [
      { from = janusRtpFrom; to = janusRtpTo; }
    ];
  };

  # ============================================================================
  # TIME ZONE
  # ============================================================================

  # No time zone here: it is the site's fact, not the module's (#472). It
  # arrives through /etc/nixos/tappaas-site.nix, which the baseline imports.

  # ============================================================================
  # USERS & SECURITY
  # ============================================================================

  users.users.janus = {
    isSystemUser = true;
    group        = "janus";
    description  = "Janus WebRTC gateway";
  };
  users.groups.janus = {};

  # ============================================================================
  # SYSTEM PACKAGES
  # ============================================================================

  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ jq ];

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
  # No NixOS module exists, so (like coturn) a custom unit renders the config at
  # start from runtime secrets — nothing secret reaches the Nix store. Full
  # trickle ICE, not ice-lite: Janus is behind NAT and needs its own TURN relay
  # candidates, which it fetches from the signaling server's REST endpoint.

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
        turn_rest_api = "http://127.0.0.1:8080/turn/credentials"  # /turn is a 404
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

      # Talk learns of the SFU from the signaling hello; nothing to configure
      # on the Nextcloud side.
      mcu = {
        type = "janus";
        url  = "ws://127.0.0.1:${toString janusWsPort}";
      };

      turn = {
        servers = turnServers;
        apikeyFile = "${secretsDir}/turn-apikey";
        # install.sh/update.sh write the real COTURN_SECRET here.
        secretFile = "${secretsDir}/turn-secret";
      };
    };

    backends.nextcloud = {
      # Talk validates against exactly this URL; an internal name is rejected
      # with invalid_backend.
      urls       = backendUrls;
      secretFile = "${secretsDir}/hpb-secret";
    };
  };

  # A signaling server without its MCU still serves and reconnects, so `wants`.
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
