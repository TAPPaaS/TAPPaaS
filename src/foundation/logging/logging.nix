# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Centralized Logging
# ============================================================================
# Version: 0.1.0
# Date: 2026-05-14
# Author: @larsrossen (TAPPaaS)
# Product: Grafana Loki + Promtail + Grafana
#
# Architecture:
# - Loki single-binary mode (log store, filesystem-backed, 30-day retention)
# - Grafana (web UI, port 3000, behind Caddy)
# - Promtail (local journal scrape + syslog receiver for OPNsense on tcp/1514)
#
# Ingest paths:
# - Other TAPPaaS VMs run Promtail clients that push to this VM:3100
# - OPNsense forwards RFC 5424 syslog over TCP to this VM:1514
#
# Secrets: Grafana admin password auto-generated on first boot
#   -> /etc/secrets/grafana-admin-password (shown in journal once)
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  lokiPort     = 3100;
  grafanaPort  = 3000;
  syslogPort   = 1514;
  promtailHttp = 9080;
  retentionHours = "720h";   # 30 days
in
{
  # ============================================================================
  # IMPORTS
  # ============================================================================

  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ============================================================================
  # BOOT
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

  networking.hostName = lib.mkDefault "logging";
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
      22             # SSH
      grafanaPort    # Grafana web UI (3000) — fronted by Caddy
      lokiPort       # Loki HTTP push/query (3100) — from mgmt zone Promtail clients
      syslogPort     # Syslog ingest (1514) — from OPNsense
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
    lsof
    jq
    openssl
    grafana-loki   # ships `logcli` for ad-hoc queries from the shell
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
  # SECRETS — Grafana admin password (generated on first boot)
  # ============================================================================

  systemd.services.generate-grafana-secrets = {
    description = "Generate Grafana admin password if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "grafana.service" ];

    unitConfig.ConditionPathExists = "!/etc/secrets/grafana-admin-password";

    # The script writes the cleartext password to a one-shot file at
    # /root/grafana-admin-password.initial (mode 0400, root-only) and NEVER
    # echoes it to stdout — so the journal-scrape pipeline never sees it.
    # The admin retrieves it with `sudo cat /root/grafana-admin-password.initial`
    # then deletes the file after first login + UI password change.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Systemd hardening — this unit only needs to write under /etc/secrets and /root
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = false;          # we deliberately write under /root
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ReadWritePaths = [ "/etc/secrets" "/root" ];

      ExecStart = pkgs.writeShellScript "generate-grafana-secrets" ''
        set -euo pipefail

        ADMIN_PASSWORD="$(${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\n')"

        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets
        # Grafana reads the password as the `grafana` user, so the file is owned
        # grafana:grafana with 0600 — group/world cannot read.
        ${pkgs.coreutils}/bin/install -m 0600 -o grafana -g grafana \
          /dev/stdin /etc/secrets/grafana-admin-password <<< "$ADMIN_PASSWORD"

        # Write the password ONCE to a marker file the admin reads then deletes.
        # 0400 root-only — the journal never sees the cleartext.
        ${pkgs.coreutils}/bin/install -m 0400 -o root -g root \
          /dev/stdin /root/grafana-admin-password.initial <<< "$ADMIN_PASSWORD"

        # Clear from local variable
        unset ADMIN_PASSWORD

        echo "================================================"
        echo "Grafana admin password generated."
        echo "  user:           admin"
        echo "  password file:  /etc/secrets/grafana-admin-password (0600 grafana:grafana)"
        echo "  initial value:  /root/grafana-admin-password.initial (0400 root:root)"
        echo ""
        echo "Retrieve with: sudo cat /root/grafana-admin-password.initial"
        echo "After first login + UI password change:"
        echo "  sudo rm /root/grafana-admin-password.initial"
        echo "================================================"
      '';
    };
  };

  # ============================================================================
  # LOKI — log store (single-binary mode, filesystem-backed)
  # ============================================================================

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;

      server = {
        http_listen_address = "0.0.0.0";
        http_listen_port = lokiPort;
        # gRPC must listen on 0.0.0.0: Loki's internal querier/scheduler
        # components dial each other via the ring's instance address (the
        # VM's primary interface IP), even in single-binary mode. Binding
        # to 127.0.0.1 causes "connection refused" on every query.
        # The firewall does NOT open 9096; this stays inside the VM.
        grpc_listen_address = "0.0.0.0";
        grpc_listen_port = 9096;
        log_level = "info";
      };

      common = {
        path_prefix = "/var/lib/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/loki/chunks";
          rules_directory = "/var/lib/loki/rules";
        };
        replication_factor = 1;
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
      };

      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }];

      limits_config = {
        retention_period = retentionHours;
        # Don't reject "old" or "new" samples — on a fresh VM the systemd
        # journal can contain entries from before NTP synced (timestamps
        # appear either in the past or in the future depending on RTC
        # interpretation; Proxmox's `localtime: 1` flag causes a +TZ skew on
        # boot until chrony corrects it). Accept whatever Promtail ships;
        # the real timestamps are still preserved on each entry.
        reject_old_samples = false;
        creation_grace_period = retentionHours;
        ingestion_rate_mb = 8;
        ingestion_burst_size_mb = 16;
        # Allow a generous label cardinality budget for TAPPaaS labels (host/module/unit/zone)
        max_label_names_per_series = 30;
      };

      # Match the ingester chunk window to the retention so backfilled entries
      # from rebooted VMs are accepted.
      ingester = {
        max_chunk_age = retentionHours;
        chunk_idle_period = "1h";
      };

      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        retention_delete_delay = "2h";
        retention_delete_worker_count = 150;
        delete_request_store = "filesystem";
      };

      analytics.reporting_enabled = false;
    };
  };

  # ============================================================================
  # PROMTAIL — local receiver (journal + OPNsense syslog)
  # ============================================================================

  services.promtail = {
    enable = true;
    configuration = {
      server = {
        # bind to localhost — Promtail metrics must not leak across mgmt
        http_listen_address = "127.0.0.1";
        http_listen_port = promtailHttp;
        grpc_listen_port = 0;
      };

      positions.filename = "/var/lib/promtail/positions.yaml";

      clients = [{
        url = "http://127.0.0.1:${toString lokiPort}/loki/api/v1/push";
      }];

      scrape_configs = [
        {
          job_name = "journal";
          journal = {
            # Only pick up the last 30 minutes of journal at promtail startup.
            # Avoids dragging in pre-time-sync boot entries with skewed
            # timestamps that Loki would treat as out-of-order.
            max_age = "30m";
            labels = {
              job = "systemd-journal";
              host = "logging";
            };
          };
          relabel_configs = [
            { source_labels = [ "__journal__systemd_unit" ]; target_label = "unit"; }
            { source_labels = [ "__journal_priority_keyword" ]; target_label = "severity"; }
          ];
          # Same hardening as on tappaas-cicd: drop credential-handling units
          # and scrub common secret patterns. Belt-and-braces: the
          # generate-grafana-secrets unit no longer prints the password, but
          # the drop rule means future regressions still won't leak.
          pipeline_stages = [
            {
              match = {
                selector = ''{unit=~"generate-.*-secrets.*"}'';
                action = "drop";
              };
            }
            {
              replace = {
                expression = ''(?i)\b(token|secret|password|passwd|api[_-]?key)\s*[:=]\s*\S+'';
                replace = "$1=***REDACTED***";
              };
            }
            {
              replace = {
                expression = ''(-u[[:space:]]+["']?)[^"' ]+:[^"' ]+(["']?)'';
                replace = "$1***REDACTED***$2";
              };
            }
            {
              replace = {
                expression = ''(Authorization:[[:space:]]+(Basic|Bearer)[[:space:]]+)\S+'';
                replace = "$1***REDACTED***";
              };
            }
          ];
        }
        {
          job_name = "syslog";
          syslog = {
            listen_address = "0.0.0.0:${toString syslogPort}";
            listen_protocol = "tcp";
            idle_timeout = "60s";
            label_structured_data = true;
            labels = {
              job = "syslog";
              source = "opnsense";
            };
          };
          relabel_configs = [
            { source_labels = [ "__syslog_message_hostname" ];  target_label = "host"; }
            { source_labels = [ "__syslog_message_app_name" ];  target_label = "unit"; }
            { source_labels = [ "__syslog_message_severity" ]; target_label = "severity"; }
            { source_labels = [ "__syslog_message_facility" ]; target_label = "facility"; }
          ];
        }
      ];
    };
  };

  # ============================================================================
  # GRAFANA — web UI
  # ============================================================================

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        # root_url left to Grafana defaults; Caddy passes X-Forwarded-* headers
        # so links resolve to the public proxyDomain. Override here if links break.
      };

      security = {
        admin_user = "admin";
        admin_password = "$__file{/etc/secrets/grafana-admin-password}";
        # cookie_secure = false for v1: this VM is reachable on internal
        # http://logging.mgmt.internal:3000. With cookie_secure=true the
        # browser refuses to persist the auth cookie over plain HTTP, so login
        # appears to succeed then bounces back to /login.
        # v2 (when HTTPS via Caddy + Let's Encrypt is live for every admin
        # access path): set cookie_secure = true and access only through Caddy.
        cookie_secure = false;
        cookie_samesite = "lax";
      };

      "auth.anonymous".enabled = false;
      analytics.reporting_enabled = false;
      analytics.check_for_updates = false;
      news.news_feed_enabled = false;

      # v2: replace with OIDC against Authentik
      # "auth.generic_oauth" = { ... };
    };

    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [{
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://127.0.0.1:${toString lokiPort}";
          isDefault = true;
          editable = false;
        }];
      };
    };
  };

  systemd.services.grafana = {
    after = [ "loki.service" "generate-grafana-secrets.service" ];
    requires = [ "generate-grafana-secrets.service" ];
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /var/lib/loki                   0700 loki     loki     -"
    "d /var/lib/loki/chunks            0700 loki     loki     -"
    "d /var/lib/loki/rules             0700 loki     loki     -"
    "d /var/lib/loki/compactor         0700 loki     loki     -"
    "d /var/lib/promtail               0750 promtail promtail -"
    "d /etc/secrets                    0750 root     grafana  -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
