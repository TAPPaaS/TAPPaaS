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
# Product: Grafana Loki + Alloy + Grafana
#
# Architecture:
# - Loki single-binary mode (log store, filesystem-backed, 30-day retention)
# - Grafana (web UI, port 3000, behind Caddy)
# - Alloy (local journal scrape + 2 syslog receivers: 1514 OPNsense, 1515 Proxmox)
#
# Ingest paths:
# - Other TAPPaaS VMs run Alloy clients that push to this VM:3101 (push-only,
#   loki.source.api; logging:logs, #770) — 3100 (Loki, query too) is mgmt-only
# - OPNsense forwards RFC 5424 syslog over TCP to this VM:1514 (source=opnsense)
# - Proxmox nodes' rsyslog forwards to this VM:1515 (source=proxmox)
#
# Secrets: Grafana admin password auto-generated on first boot
#   -> /etc/secrets/grafana-admin-password (shown in journal once)
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  lokiPort          = 3100;    # nginx: Loki's API behind the admin credential (#165 §1)
  pushPort          = 3101;    # nginx: push only, a credential per VM (#770, #165 §1)
  lokiInternal      = 3102;    # Loki itself, localhost only
  pushInternal      = 3103;    # Alloy's push receiver, localhost only
  grafanaPort       = 3000;
  syslogOpnsensePort = 1514;   # OPNsense → Alloy (source=opnsense)
  syslogProxmoxPort  = 1515;   # Proxmox nodes → Alloy (source=proxmox)
  alloyHttp         = 9080;
  retentionHours    = "720h";  # 30 days

  # The site's own values, not ours to guess: update-os.sh deploys the module's
  # config beside this file as /etc/nixos/logging.json, so proxyDomain is
  # available declaratively (same idiom as nextcloud.nix, #508). A site that has
  # not published Grafana has no public URL and no OIDC redirect can exist, so
  # everything below is conditional on it.
  moduleCfg    = if builtins.pathExists ./logging.json
                 then builtins.fromJSON (builtins.readFile ./logging.json)
                 else {};
  proxyCfg     = (moduleCfg.config or {})."network:proxy" or {};
  proxyDomain  = proxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  # A name is not the same as a published route (#715). update-os.sh writes
  # proxyPublished = false when the name has no public DNS record: no
  # certificate, nothing served, so an https root URL, a secure-only cookie and
  # an SSO redirect there leave Grafana with no working login at all (seen on
  # hrossen, 2026-09-23). Absent, the name alone decides, as before.
  published    = proxyDomain != "" && (moduleCfg.proxyPublished or true);

  # Grafana substitutes $__file{path} into any setting, which is how the admin
  # password already reaches it. The OIDC values arrive the same way, because
  # they are only known once identity:identity has registered the application —
  # long after this file is built.
  oidcSecret   = name: "$__file{/etc/secrets/logging-oidc-${name}}";

  # ── Alert rules over the logs (#126) ─────────────────────────────────────
  # Every host already logs here and nothing read it: on 2026-09-06 a cluster
  # reset itself 13 times in 70 minutes and no one was told. Since ADR-039 the
  # rules live with the modules whose events they are (<module>-alerts.json:
  # pvehost, cluster, network, backup, logging's own), put into Grafana through
  # its API by the mothership (tappaas-alert-rules.py, re-applied by this
  # module's update). Only the Heartbeat is built here: it must exist before any
  # module has applied anything, so the watchdog has its signal.
  # Each rule is a LogQL count per host; anything above zero fires, and Grafana posts it to
  # the mothership's tappaas-alert-receiver, which mails it through
  # site-notify.sh (#651). `kind` tells the receiver what a resolve means:
  #   event  something happened; it "resolves" only as its window moves on, so
  #          that is not mailed
  #   state  something is so; its resolve is news, and is mailed
  # `query` is the log query to paste into Explore; the mail carries it.
  # `headline`, when given, is how the mail's subject names the rule
  # ("ALERT: Out of Memory Kill on tappaas3" rather than "ALERT: OomKill on …").
  # `bundle`: the receiver attaches a support bundle (#883) — the cluster's
  # state and the site's anonymized configuration — when the rule fires.
  alertRule = { uid, title, kind, expr, window, summary, query, headline ? null, bundle ? false,
                execErrState ? "KeepLast" }: {
    inherit uid title;
    condition = "C";
    data = [
      { refId = "A"; datasourceUid = "loki";
        relativeTimeRange = { from = window; to = 0; };
        model = { refId = "A"; expr = expr; queryType = "instant"; editorMode = "code"; }; }
      { refId = "B"; datasourceUid = "__expr__";
        model = { refId = "B"; type = "reduce"; expression = "A"; reducer = "last";
                  datasource = { type = "__expr__"; uid = "__expr__"; }; }; }
      { refId = "C"; datasourceUid = "__expr__";
        model = { refId = "C"; type = "threshold"; expression = "B";
                  conditions = [{ evaluator = { type = "gt"; params = [ 0 ]; }; }];
                  datasource = { type = "__expr__"; uid = "__expr__"; }; }; }
    ];
    # Nothing matched is the healthy case, not missing data. A query that
    # cannot run (Loki or Grafana's own database busy, as during the logging
    # VM's backup) keeps the rule's last state: no mail under the rule's name,
    # and a firing state rule does not resolve. A Loki that stays down stops
    # the Heartbeat, and the mothership's watchdog says so — the one alert for it.
    noDataState = "OK";
    inherit execErrState;
    for = "0s";
    labels = { inherit kind; } // lib.optionalAttrs bundle { bundle = "true"; };
    annotations = { inherit summary query; } // lib.optionalAttrs (headline != null) { inherit headline; };
  };
  alertRules = [
    (alertRule {
      uid = "tappaas-heartbeat"; title = "Heartbeat"; kind = "heartbeat"; window = 300;
      # Fires for as long as logs arrive and rules run; its webhook proves the
      # whole path reaches the mothership. Never mailed: the receiver records
      # it, and tappaas-alert-watchdog there mails when it stops (#126). A query
      # that cannot run is not alive: OK, so the heartbeat stops (#905).
      execErrState = "OK";
      expr = ''sum(count_over_time({host=~".+"}[5m]))'';
      summary = "The log alerting is alive (logs arrive, rules run, the webhook gets through).";
      query = ''{host=~".+"}'';
    })
  ];

  oidcFiles    = [ "client-id" "client-secret" "auth-url" "token-url" "api-url" ];
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

  networking.hostName = lib.mkDefault "logging";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22             # SSH
      grafanaPort    # Grafana web UI (3000) — fronted by Caddy
      lokiPort       # Loki API (3100) via nginx, admin credential — mgmt only
      pushPort       # Push only (3101) via nginx, a credential per VM (#770)
      syslogOpnsensePort     # Syslog ingest (1514) — from OPNsense
      syslogProxmoxPort      # Syslog ingest (1515) — from Proxmox nodes
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
  environment.systemPackages = with pkgs; [ lsof jq openssl grafana-loki ];

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
  # SECRETS — Grafana admin password (generated on first boot)
  # ============================================================================

  systemd.services.generate-grafana-secrets = {
    description = "Generate Grafana's admin password and secret key if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "grafana.service" ];

    # No ConditionPathExists: the unit now owns TWO secrets, and gating the
    # whole unit on the first one would leave a site that already has an admin
    # password without a secret key forever. Each file is generated only if it
    # is absent, inside the script.

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

        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets

        # ── the secret key that encrypts Grafana's own database secrets ──
        # 26.05 removed the built-in default, which was the same string in every
        # NixOS install (#722). There is no supported way to rotate this: a new
        # key makes anything already encrypted under the old one unreadable, so
        # it is written ONCE and then left alone.
        if [ ! -e /etc/secrets/grafana-secret-key ]; then
          ${pkgs.coreutils}/bin/install -m 0600 -o grafana -g grafana \
            /dev/stdin /etc/secrets/grafana-secret-key \
            <<< "$(${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '\n')"
          echo "Grafana secret key generated at /etc/secrets/grafana-secret-key."
          echo "  It encrypts Grafana's database secrets and CANNOT be rotated;"
          echo "  it is covered by this module's backup:vm snapshot."
        fi

        # ── the alert webhook's token (#126) ──
        # The real one is the mothership's, copied here by update.sh. Until it
        # arrives, a placeholder lets Grafana start (its contact point reads the
        # file); the receiver refuses it, which the receiver's journal shows.
        if [ ! -e /etc/secrets/grafana-alert-webhook-token ]; then
          ${pkgs.coreutils}/bin/install -m 0600 -o grafana -g grafana \
            /dev/stdin /etc/secrets/grafana-alert-webhook-token <<< "unconfigured"
        fi

        # ── the admin password ──
        if [ -e /etc/secrets/grafana-admin-password ]; then
          exit 0
        fi

        ADMIN_PASSWORD="$(${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\n')"

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
        # Localhost only (#165 §1): everything from outside goes through nginx,
        # which asks for a credential (lokiPort, pushPort below).
        http_listen_address = "127.0.0.1";
        http_listen_port = lokiInternal;
        # gRPC must listen on 0.0.0.0: Loki's internal querier/scheduler
        # components dial each other via the ring's instance address (the
        # VM's primary interface IP), even in single-binary mode. Binding
        # to 127.0.0.1 causes "connection refused" on every query.
        # The firewall does NOT open 9096; this stays inside the VM.
        grpc_listen_address = "0.0.0.0";
        grpc_listen_port = 9096;
        # warn, not info: at info Loki logs every query and table lookup
        # into its own journal, which it then ingests — ~190k lines a day.
        log_level = "warn";
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
        # boot until chrony corrects it). Accept whatever the shipper sends;
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

  # Survive a slow NIC at boot. Loki's memberlist-kv module resolves its
  # advertise address by scanning [eth0 en0 lo] (common.ring.instance_addr above
  # does NOT cover memberlist), and dies in ~80ms if none carry an address yet.
  # NetworkManager-wait-online can fail while network-online.target is still
  # reported as reached, so `After=network-online.target` is not a guarantee.
  #
  # The stock budget — Restart=always, RestartSec=100ms, 5 starts per 10s — is
  # spent in under a second by a process that fails this fast, after which
  # systemd gives up for good. That is what took Loki down on 2026-08-10 and
  # kept it down for five days: log ingestion stopped, nothing restarted it.
  # Back off and keep retrying instead, so a transient boot race self-heals.
  systemd.services.loki = {
    serviceConfig.RestartSec = "5s";
    unitConfig.StartLimitIntervalSec = 0;   # 0 = no start-rate limit; retry forever
  };

  # ============================================================================
  # ALLOY — local receiver (journal + OPNsense/Proxmox syslog)
  # ============================================================================
  #
  # Grafana Alloy replaced Promtail because 26.05 removed both the promtail
  # NixOS module and the package — promtail reached end of life (#721). Alloy
  # embeds promtail's own pipeline, so every stage here means what it meant
  # before; `alloy convert --source-format=promtail` made the translation from
  # the config this VM was actually running, rather than a hand rewrite.

  services.alloy = {
    enable = true;
    extraFlags = [
      # Alloy's own HTTP server: metrics and the component UI. Localhost only —
      # it must not leak across mgmt. (Alloy defaults to 127.0.0.1, unlike
      # promtail; stated here so it cannot drift.)
      "--server.http.listen-addr=127.0.0.1:${toString alloyHttp}"
      # Do not report the enabled component set to Grafana. A TAPPaaS site
      # tells no one what it runs.
      "--disable-reporting"
    ];
  };

  # Written to /etc rather than the store so alloy can reload it in place; the
  # module watches every alloy/*.alloy file and reloads on switch.
  environment.etc."alloy/config.alloy".text = ''
    // Same hardening as on tappaas-cicd: drop credential-handling units and
    // scrub common secret patterns. Belt-and-braces: the generate-grafana-secrets
    // unit no longer prints the password, but the drop rule means future
    // regressions still won't leak.
    loki.process "journal" {
      forward_to = [loki.write.default.receiver]

      stage.match {
        selector = "{unit=~\"generate-.*-secrets.*\"}"
        action   = "drop"
      }

      // Only the CAPTURE GROUPS are replaced, and `replace` is used literally
      // — there is no $1 expansion (#724). So each expression captures the
      // SECRET and leaves the key outside the group: the key stays readable and
      // only the value is destroyed.
      //
      // These deliberately over-match. "password: permission denied" loses the
      // word "permission", because the alternative — demanding the value hug
      // the separator — would miss the very common `token: abc123`. Redacting a
      // word that was not a secret costs a little readability; missing one that
      // was costs the secret. The file path itself survives either way.
      stage.replace {
        expression = "(?i)\\b(?:token|secret|password|passwd|api[_-]?key)\\s*[:=]\\s*(\\S+)"
        replace    = "***REDACTED***"
      }

      stage.replace {
        expression = "-u[[:space:]]+[\"']?([^\"' ]+:[^\"' ]+)[\"']?"
        replace    = "***REDACTED***"
      }

      stage.replace {
        expression = "Authorization:[[:space:]]+(?:Basic|Bearer)[[:space:]]+(\\S+)"
        replace    = "***REDACTED***"
      }
    }

    discovery.relabel "journal" {
      targets = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "severity"
      }
    }

    // Only the last 30 minutes of journal at startup: avoids dragging in
    // pre-time-sync boot entries whose skewed timestamps Loki treats as
    // out-of-order.
    loki.source.journal "journal" {
      max_age       = "30m0s"
      relabel_rules = discovery.relabel.journal.rules
      forward_to    = [loki.process.journal.receiver]
      labels        = {
        host = "logging",
        job  = "systemd-journal",
      }
    }

    discovery.relabel "syslog_opnsense" {
      targets = []

      // host = the first label of the sender's hostname, which is its
      // instance's vmname (network.internal -> network): what a module's alert
      // rule selects by (ADR-039 D9).
      rule {
        source_labels = ["__syslog_message_hostname"]
        regex         = "([^.]+)(\\..*)?"
        replacement   = "$1"
        target_label  = "host"
      }

      rule {
        source_labels = ["__syslog_message_app_name"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__syslog_message_severity"]
        target_label  = "severity"
      }

      rule {
        source_labels = ["__syslog_message_facility"]
        target_label  = "facility"
      }
    }

    loki.source.syslog "syslog_opnsense" {
      listener {
        address               = "0.0.0.0:${toString syslogOpnsensePort}"
        idle_timeout          = "1m0s"
        label_structured_data = true
        labels                = {
          job    = "syslog",
          source = "opnsense",
        }
      }
      forward_to    = [loki.write.default.receiver]
      relabel_rules = discovery.relabel.syslog_opnsense.rules
    }

    discovery.relabel "syslog_proxmox" {
      targets = []

      rule {
        source_labels = ["__syslog_message_hostname"]
        regex         = "([^.]+)(\\..*)?"
        replacement   = "$1"
        target_label  = "host"
      }

      rule {
        source_labels = ["__syslog_message_app_name"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__syslog_message_severity"]
        target_label  = "severity"
      }

      rule {
        source_labels = ["__syslog_message_facility"]
        target_label  = "facility"
      }
    }

    loki.source.syslog "syslog_proxmox" {
      listener {
        address               = "0.0.0.0:${toString syslogProxmoxPort}"
        idle_timeout          = "1m0s"
        label_structured_data = true
        labels                = {
          job    = "syslog",
          source = "proxmox",
        }
      }
      forward_to    = [loki.write.default.receiver]
      relabel_rules = discovery.relabel.syslog_proxmox.rules
    }

    // Push receiver for every TAPPaaS VM's journal (#770), behind nginx on
    // :${toString pushPort}: nginx checks the VM's own credential and passes its
    // username on as the tenant (X-Scope-OrgID). App zones reach :${toString pushPort}
    // through the logging:logs pinhole (per consumer VM, that port only).
    loki.source.api "push" {
      http {
        listen_address = "127.0.0.1"
        listen_port    = ${toString pushInternal}
      }
      // Keep the time each VM's journal gave the line (#784). The default
      // restamps it on arrival, so a backfill or a reboot's lines all landed
      // on Alloy's start, and a line re-sent after a restart was stored twice.
      use_incoming_timestamp = true
      forward_to = [loki.relabel.pushed_by.receiver]
    }

    // A VM writes as itself and nobody else (#165 §1): `host` is the
    // authenticated username, whatever the line claimed. The tenant label goes
    // after use — Loki here is single-tenant.
    loki.relabel "pushed_by" {
      forward_to = [loki.write.default.receiver]
      rule {
        source_labels = ["__tenant_id__"]
        target_label  = "host"
      }
      rule {
        action = "labeldrop"
        regex  = "__tenant_id__"
      }
    }

    loki.write "default" {
      endpoint {
        url = "http://127.0.0.1:${toString lokiInternal}/loki/api/v1/push"
      }
    }
  '';

  # ============================================================================
  # NGINX — who may push, who may read (#165 §1)
  # ============================================================================
  #
  # Loki and Alloy's receiver listen on localhost only; this is the way in.
  #   :${toString pushPort}  push only. One credential per VM (username = its vmname),
  #          kept on the mothership and synced here as push.htpasswd by
  #          logging:logs. The username becomes the tenant, and Alloy makes it
  #          the line's `host` — a VM cannot write as another.
  #   :${toString lokiPort}  Loki's whole API (query, admin) for the mothership's
  #          tools, behind the admin credential (admin.htpasswd).
  # Grafana and this VM's own Alloy talk to Loki on localhost directly.
  # The password files start empty (tmpfiles below): nginx then refuses everyone
  # until the mothership writes them, rather than failing to start.
  services.nginx = {
    enable = true;
    virtualHosts."loki-push" = {
      listen = [ { addr = "0.0.0.0"; port = pushPort; } ];
      locations."= /loki/api/v1/push" = {
        proxyPass = "http://127.0.0.1:${toString pushInternal}";
        extraConfig = ''
          auth_basic "TAPPaaS log push";
          auth_basic_user_file /etc/loki-auth/push.htpasswd;
          proxy_set_header X-Scope-OrgID $remote_user;
          client_max_body_size 16m;
        '';
      };
      locations."/".return = "404";
    };
    virtualHosts."loki-api" = {
      listen = [ { addr = "0.0.0.0"; port = lokiPort; } ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString lokiInternal}";
        extraConfig = ''
          auth_basic "TAPPaaS log store";
          auth_basic_user_file /etc/loki-auth/admin.htpasswd;
          client_max_body_size 16m;
          proxy_read_timeout 300s;
        '';
      };
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
        # Where the site publishes Grafana, root_url must say so EXPLICITLY:
        # Grafana derives the OAuth redirect_uri from it, and that URI has to
        # match the one identity:identity registered in Authentik character for
        # character. X-Forwarded-* is enough for ordinary links and not enough
        # for this. Unpublished, it stays at Grafana's default as before.
      } // lib.optionalAttrs published {
        root_url = "https://${proxyDomain}/";
      };

      security = {
        admin_user = "admin";
        admin_password = "$__file{/etc/secrets/grafana-admin-password}";
        # 26.05 removed this option's default (#722). It encrypts Grafana's own
        # database secrets and has no supported rotation path, so it is
        # generated once per site beside the admin password rather than shared
        # as a constant every TAPPaaS install would publish.
        secret_key = "$__file{/etc/secrets/grafana-secret-key}";
        # Tied to the same fact, in both directions. On a site that publishes
        # Grafana through Caddy the browser gets HTTPS and the auth cookie must
        # be marked secure — without it the OIDC round trip appears to succeed
        # and bounces straight back to /login. On a site that does not, access
        # is plain http://logging.<zone>.internal:3000 and a secure cookie is
        # never stored at all, which is the same failure from the other side.
        cookie_secure = published;
        cookie_samesite = "lax";
      };

      "auth.anonymous".enabled = false;
      analytics.reporting_enabled = false;
      analytics.check_for_updates = false;
      news.news_feed_enabled = false;

    } // lib.optionalAttrs published {
      # ── Authentik OIDC (ADR-006) ──────────────────────────────────────────
      # Only where Grafana is published: the redirect URI is built from the
      # public domain, so without one there is nothing Authentik could call
      # back to.
      #
      # Every value here is read from a file at RUNTIME rather than written in:
      # the client id and secret because identity:identity mints them, and the
      # three endpoints because they belong to the site's own Authentik, whose
      # domain this file does not know. logging-configure-oidc.service below
      # fills all five in from the discovery document.
      "auth.generic_oauth" = {
        # On only once identity:identity has wired this module (#701): identity
        # is an optional integration, and with no Authentik behind it an
        # auto-login to placeholder URLs would leave Grafana with no login.
        # logging-configure-oidc writes the file: true with credentials, false
        # without; tmpfiles creates it false.
        enabled       = oidcSecret "enabled";
        name          = "Authentik";
        client_id     = oidcSecret "client-id";
        client_secret = oidcSecret "client-secret";
        auth_url      = oidcSecret "auth-url";
        token_url     = oidcSecret "token-url";
        api_url       = oidcSecret "api-url";
        # The groups claim rides on Authentik's own profile scope, so no extra
        # scope mapping is requested (identity's field schema says so, and a
        # scope that does not exist fails provider creation).
        scopes        = "openid email profile";
        use_pkce      = true;
        allow_sign_up = true;
        # The login page goes straight to Authentik, as Nextcloud's does; the
        # local admin still signs in at /login?disableAutoLogin.
        auto_login    = oidcSecret "enabled";
        # logging-admins (created because logging.json sets
        # identity.providesAdminRole) becomes GrafanaAdmin; everyone else who
        # can sign in at all gets Viewer. Day-2 access is granted through
        # Grafana's own permissions rather than by handing out Editor.
        role_attribute_path       = "contains(groups[*], 'logging-admins') && 'GrafanaAdmin' || 'Viewer'";
        allow_assign_grafana_admin = true;
      };
    };

    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        # Grafana finds a provisioned data source by its uid. The one every
        # site already has was created without a fixed uid, so giving it one
        # made Grafana refuse to start ("data source not found", hrossen
        # 2026-10-04). Deleting it by name first — Grafana processes deletes
        # before creates — recreates it with the uid on every start; nothing
        # refers to it by its numeric id.
        deleteDatasources = [{ name = "Loki"; orgId = 1; }];
        datasources = [{
          name = "Loki";
          # A fixed uid: the alert rules below name their data source by it.
          uid = "loki";
          type = "loki";
          access = "proxy";
          url = "http://127.0.0.1:${toString lokiInternal}";
          isDefault = true;
          editable = false;
        }];
      };

      # #126: the heartbeat above, one contact point (the mothership's
      # receiver), and a policy that sends everything there — the modules'
      # rules too (ADR-039) — grouped per rule and host, repeated at most every
      # 4 hours while it lasts (a module rule may set its own repeat).
      alerting = {
        rules.settings = {
          apiVersion = 1;
          groups = [{
            orgId = 1;
            name = "tappaas-logs";
            folder = "TAPPaaS";
            interval = "1m";
            rules = alertRules;
          }];
          # The rules that moved into their modules' <module>-alerts.json
          # (ADR-039 D6). Grafana keeps a file-provisioned rule that leaves the
          # file until it is deleted by name: without this, each would fire
          # beside its module copy and mail twice.
          deleteRules = map (uid: { orgId = 1; inherit uid; }) [
            "tappaas-quorum-lost" "tappaas-ha-fencing" "tappaas-host-silent"
            "tappaas-backup-failed" "tappaas-oom-kill" "tappaas-root-key-changed"
            "tappaas-replication-failed" "tappaas-ha-stuck" "tappaas-firewall-cert"
            "tappaas-lan-leg-down" "tappaas-disk-errors"
          ];
        };
        contactPoints.settings = {
          apiVersion = 1;
          contactPoints = [{
            orgId = 1;
            name = "tappaas-site-notify";
            receivers = [{
              uid = "tappaas-site-notify";
              type = "webhook";
              disableResolveMessage = false;
              settings = {
                url = "http://tappaas-cicd.mgmt.internal:9095/alert";
                httpMethod = "POST";
                authorization_scheme = "Bearer";
                authorization_credentials = "$__file{/etc/secrets/grafana-alert-webhook-token}";
              };
            }];
          }];
        };
        policies.settings = {
          apiVersion = 1;
          policies = [{
            orgId = 1;
            receiver = "tappaas-site-notify";
            group_by = [ "alertname" "host" ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
            routes = [{
              # The heartbeat: every 10 minutes, never grouped with anything
              # else. Repeats leave at the 5-minute group ticks, so a beat can
              # come up to 15 minutes after the last: the watchdog's 35 then
              # rides out one missed beat. The receiver records it; the
              # watchdog mails if it stops.
              receiver = "tappaas-site-notify";
              object_matchers = [ [ "alertname" "=" "Heartbeat" ] ];
              group_by = [ "alertname" ];
              group_wait = "0s";
              group_interval = "5m";
              repeat_interval = "10m";
            }];
          }];
        };
      };
    };
  };

  systemd.services.grafana = {
    after = [ "loki.service" "generate-grafana-secrets.service" ]
            ++ lib.optional published "generate-logging-oidc-placeholder.service";
    requires = [ "generate-grafana-secrets.service" ]
               ++ lib.optional published "generate-logging-oidc-placeholder.service";
    # Grafana reads its secrets as the grafana group, through /etc/secrets —
    # a directory other writers share. One of them re-moding it 0700 (identity's
    # OIDC delivery did, #715) crash-looped Grafana on its admin-password file,
    # and only a rebuild or a reboot re-ran the tmpfiles rule below. So every
    # start re-asserts THIS module's rule for that directory first, as root
    # ("+"): Grafana cannot be locked out of its own secrets by any writer, and a
    # site stuck in that loop recovers the next time the unit starts.
    # mkBefore: ahead of the NixOS module's own grafana-pre-start, so nothing in
    # Grafana's start runs against a directory it cannot enter.
    serviceConfig.ExecStartPre = lib.mkBefore [
      "+${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix=/etc/secrets"
    ];
  };

  # ============================================================================
  # AUTHENTIK OIDC INTEGRATION (ADR-006)
  # ============================================================================
  # identity:identity registers the application, then writes OIDC_CLIENT_ID,
  # OIDC_CLIENT_SECRET and OIDC_DISCOVERY_URI into the secretsEnv path named in
  # logging.json and restarts the configureService named there. Grafana reads
  # each value from its own file, so these units split the env into files and
  # resolve the endpoints from the discovery document.

  # Grafana must be able to START before identity has wired anything: a setting
  # whose $__file target is missing is a hard startup failure, not a disabled
  # login. Placeholders make the first boot survivable; the sign-in button is
  # present and refuses until the real values land.
  systemd.services.generate-logging-oidc-placeholder = lib.mkIf published {
    description = "Create placeholder Grafana OIDC files so Grafana can start unwired";
    wantedBy    = [ "multi-user.target" ];
    # After tmpfiles has made /etc/secrets 0750 root:grafana. Creating the
    # directory here first can win the race and leave it 0700, at which point
    # grafana — a group member, not the owner — cannot traverse it and
    # crash-loops on its own admin-password file (seen live 2026-08-26).
    after       = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
    before      = [ "grafana.service" ];
    unitConfig.ConditionPathExists = "!/etc/secrets/logging-oidc-client-secret";
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-logging-oidc-placeholder" ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets
        for f in ${lib.concatStringsSep " " (map (n: "logging-oidc-${n}") oidcFiles)}; do
          [ -f "/etc/secrets/$f" ] || ${pkgs.coreutils}/bin/install -m 0600 -o grafana -g grafana             /dev/stdin "/etc/secrets/$f" <<< "unconfigured"
        done
      '';
    };
  };

  # Defined unconditionally, unlike the placeholder above. logging.json names
  # this unit as its identity.configureService, and identity:identity checks
  # that the unit it was told to restart is actually there — a contract stated
  # in config cannot be honoured only on some sites. Gating it on `published`
  # made the module FAIL its update on every site that does not publish Grafana
  # ("logging-configure-oidc.service does not exist on logging"). Where there is
  # no public domain the unit runs and says why there is nothing to do.
  systemd.services.logging-configure-oidc = {
    description = "Configure Authentik OIDC login in Grafana";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "generate-logging-oidc-placeholder.service" "network-online.target" ];
    wants       = [ "network-online.target" ];
    # Deliberately NOT before grafana.service: this unit restarts grafana to
    # pick up the new files, and ordering it first deadlocks — systemd holds
    # grafana until this unit exits while this unit waits on that same job.
    # (The identical mistake was made on openwebui, 2026-08-25.)
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "logging-configure-oidc" (
        if !published then ''
        # No proxyDomain: no public name, so no redirect URI, so nothing for
        # Authentik to call back to and no provider in Grafana's settings to
        # configure. Present and honest rather than missing.
        echo "Grafana is not published at this site (no public name, or its name has no public DNS record) — no OIDC login to configure."
        '' else ''
        set -euo pipefail
        # The unit always runs with these defaults. They are overridable only so
        # the branches below can be exercised off the VM (test-grafana-oidc.sh)
        # — the paths are not configuration and nothing else sets them.
        ENV_FILE="''${LOGGING_OIDC_ENV:-/etc/secrets/logging.env}"
        SECRETS_DIR="''${LOGGING_OIDC_SECRETS_DIR:-/etc/secrets}"

        # `|| true`: a key that is absent is an answer, not a crash. Under
        # `set -o pipefail` a bare grep miss kills the script, which made the
        # "OIDC_DISCOVERY_URI missing" diagnostic below unreachable — the unit
        # failed with no output at all.
        readvar() { ${pkgs.gnugrep}/bin/grep "^$1=" "$ENV_FILE" | ${pkgs.coreutils}/bin/cut -d= -f2- || true; }

        # Owned by grafana because Grafana reads these itself. As root — which
        # is how the unit runs — that ownership is applied; the unprivileged
        # branch exists for the test, where no grafana user exists.
        write() {
          if [ "$(${pkgs.coreutils}/bin/id -u)" = 0 ]; then
            ${pkgs.coreutils}/bin/install -m 0600 -o grafana -g grafana /dev/stdin "$SECRETS_DIR/$1" <<< "$2"
          else
            ${pkgs.coreutils}/bin/install -m 0600 /dev/stdin "$SECRETS_DIR/$1" <<< "$2"
          fi
        }

        # The enabled file follows whether there are credentials. Grafana
        # reads it at start, so a change restarts it.
        set_enabled() {
          [ "$(${pkgs.coreutils}/bin/cat "$SECRETS_DIR/logging-oidc-enabled" 2>/dev/null)" = "$1" ] && return 0
          write logging-oidc-enabled "$1"
          ${pkgs.systemd}/bin/systemctl try-restart grafana.service || true
        }

        if ! ${pkgs.gnugrep}/bin/grep -q '^OIDC_CLIENT_ID=' "$ENV_FILE" 2>/dev/null; then
          echo "No Authentik OIDC credentials in $ENV_FILE — identity:identity has not wired this module (or is not installed). Grafana keeps its local login."
          set_enabled false
          exit 0
        fi

        CLIENT_ID="$(readvar OIDC_CLIENT_ID)"
        CLIENT_SECRET="$(readvar OIDC_CLIENT_SECRET)"
        DISCOVERY="$(readvar OIDC_DISCOVERY_URI)"

        if [ -z "''${DISCOVERY:-}" ]; then
          echo "OIDC_DISCOVERY_URI missing from $ENV_FILE — cannot resolve the Authentik endpoints." >&2
          exit 1
        fi

        # The endpoints come from the provider itself. Deriving them by string
        # surgery on the discovery URI would bake in Authentik's current URL
        # layout, which is not ours to assume.
        DOC="$(${pkgs.curl}/bin/curl -fsS --max-time 15 "$DISCOVERY")" || {
          echo "Could not fetch the OIDC discovery document at $DISCOVERY" >&2
          exit 1
        }
        AUTH_URL="$(${pkgs.jq}/bin/jq -r '.authorization_endpoint // empty' <<< "$DOC")"
        TOKEN_URL="$(${pkgs.jq}/bin/jq -r '.token_endpoint // empty' <<< "$DOC")"
        API_URL="$(${pkgs.jq}/bin/jq -r '.userinfo_endpoint // empty' <<< "$DOC")"
        for v in "$AUTH_URL" "$TOKEN_URL" "$API_URL"; do
          [ -n "$v" ] || { echo "The discovery document at $DISCOVERY names no authorization/token/userinfo endpoint." >&2; exit 1; }
        done

        write logging-oidc-client-id     "$CLIENT_ID"
        write logging-oidc-client-secret "$CLIENT_SECRET"
        write logging-oidc-auth-url      "$AUTH_URL"
        write logging-oidc-token-url     "$TOKEN_URL"
        write logging-oidc-api-url       "$API_URL"
        write logging-oidc-enabled       true

        echo "Grafana OIDC login configured against $DISCOVERY"
        ${pkgs.systemd}/bin/systemctl try-restart grafana.service || true
      '');
    };
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /var/lib/loki                   0700 loki     loki     -"
    "d /var/lib/loki/chunks            0700 loki     loki     -"
    "d /var/lib/loki/rules             0700 loki     loki     -"
    "d /var/lib/loki/compactor         0700 loki     loki     -"
    "d /etc/secrets                    0750 root     grafana  -"
    # Grafana's OIDC switch (#701): off until logging-configure-oidc has real
    # credentials from identity:identity. `f` never overwrites an existing file.
    "f /etc/secrets/logging-oidc-enabled 0600 grafana grafana -   false"
    # nginx's password files (#165 §1), written by the mothership. Created
    # empty so nginx starts — and refuses everyone — before the first sync.
    "d /etc/loki-auth                  0750 root     nginx    -"
    "f /etc/loki-auth/push.htpasswd    0640 root     nginx    -"
    "f /etc/loki-auth/admin.htpasswd   0640 root     nginx    -"
    # nginx's own log directory, before anything starts — see logrotate-checkconf.
    "d /var/log/nginx                  0750 nginx    nginx    -"
  ];

  # logrotate-checkconf runs in every switch and checks nginx's rotation rule as
  # the nginx user. On the first switch that brings nginx (2.1 → 2.2) it ran while
  # nginx was still creating /var/log/nginx, got "stat of /var/log/nginx/*.log
  # failed: Permission denied", and failed the switch — logging's update rolled
  # back on makerfloss (2026-10-11). The directory now exists first (tmpfiles
  # above), and the check waits for nginx.
  systemd.services.logrotate-checkconf.after = [ "nginx.service" ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
