# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# ============================================================================
# TAPPaaS - LiteLLM AI proxy
# ============================================================================
# Version: 1.98.0
# Date: 2026-08-31
# Author: @ErikDaniel007 (TAPPaaS)
# Product: LiteLLM proxy with PostgreSQL + Redis backend
#
# Architecture:
# - PostgreSQL 17 (model configs + usage tracking)
# - Redis 7 (response caching + AOF persistence)
# - LiteLLM container (unified API gateway)
#
# Network: Self-managed DHCP, firewall ports 22 (SSH) + 4000 (LiteLLM API)
# Secrets: Auto-generated master key on first boot
# Backups: Daily PostgreSQL/Redis/config backups, 30-day retention
#
# Changelog v0.9.1 (2026-02-13):
# - Fixed Redis backup (was using --rdb replication tool instead of SAVE)
# - Added filesystem dependency to secrets generation (boot safety)
# - Removed broken WAL archiving (daily pg_dump already provides recovery)
#
# Changelog v1.85.0 (2026-05-20):
# - Upgraded LiteLLM 1.81.14 → 1.85.0; switched registry GHCR → Docker Hub
# - Upgraded PostgreSQL 15 → 17 (fresh DB, no migration needed)
# - Added Redis AOF persistence (appendonly + appendfsync everysec)
#
# Changelog v1.98.0 (2026-08-31):
# - Upgraded LiteLLM 1.85.0 → 1.98.0 (no PostgreSQL change; already on 17).
#   Upstream's only flagged breaking change is Langfuse metadata now sourced
#   from StandardLoggingPayload — no Langfuse callback is configured here.
# - Pinned default_internal_user_params.user_role to internal_user; the upstream
#   default (internal_user_viewer) cannot create even its own keys.
# - Access is now gated in Authentik, not here: identity.adminOnly binds only the
#   litellm-admins group, so the 5-seat SSO cap is spent on admins rather than on
#   whoever opens the UI first. Devs reach models via OpenWebUI or a virtual key,
#   neither of which consumes a seat.
# - GENERIC_SCOPE now derives from identity.scopes instead of being hardcoded.
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning - change versions here only
  versions = {
    litellm     = "v1.98.0";
    postgresPkg = pkgs.postgresql_17;
    redisPkg    = pkgs.redis;
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
  boot.growPartition = lib.mkDefault true;  # Auto-expand root partition on resize

  # ============================================================================
  # CLOUD-INIT
  # ============================================================================
  
  services.cloud-init = {
    enable = true;
    network.enable = false;  # We handle networking ourselves with NetworkManager
  };

  # ============================================================================
  # NETWORKING
  # ============================================================================
  
  networking.hostName = let
    cfg = if builtins.pathExists ./litellm.json
          then builtins.fromJSON (builtins.readFile ./litellm.json)
          else {};
  in lib.mkDefault (cfg.vmname or "litellm");
  networking.networkmanager.enable = true;
  # Match ethernet by type, not interface name (ens18/eth0/enp0s18 varies)
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };
  
  # Prevent systemd-networkd conflicts with NetworkManager
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  # Serial console for VM debugging (bypass KVM console)
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      22    # SSH
      4000  # LiteLLM API
    ];
    # Stateful firewall: outbound connections auto-allowed (e.g. to external Langfuse)
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
    postgresql  # psql CLI for debugging
  ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================
  
  nix.settings.trusted-users = [ "root" "@wheel" ];  # Allow remote deployments
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Automatic garbage collection - 30 day retention (dev-friendly)
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
  
  services.qemuGuest.enable = true;  # Proxmox/QEMU integration
  
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  
  programs.ssh.startAgent = true;

  # ============================================================================
  # DATABASE - PostgreSQL 17
  # ============================================================================
  
  services.postgresql = {
    enable = true;
    package = versions.postgresPkg;
    ensureDatabases = [ "litellm" ];
    ensureUsers = [
      { name = "litellm"; ensureDBOwnership = true; }
    ];
    
    # Passwordless local access (LiteLLM container via host network)
    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
    
    # Tuning for 2-4GB RAM VM
    settings = {
      max_connections = 100;
      shared_buffers = "1GB";
      effective_cache_size = "2GB";
      maintenance_work_mem = "256MB";
      work_mem = "16MB";

      # Performance tuning
      checkpoint_completion_target = 0.9;
      wal_buffers = "16MB";
      default_statistics_target = 100;
      random_page_cost = 1.1;  # SSD
      effective_io_concurrency = 200;

      # WAL archiving disabled - daily pg_dump backups provide sufficient recovery
      # (Previous WAL archive command was broken due to missing full paths)
      wal_level = "replica";
      archive_mode = "off";
    };
  };

  # ============================================================================
  # CACHING - Redis 7
  # ============================================================================
  
  services.redis.servers."litellm" = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";  # Localhost only
    settings = {
      maxmemory = "512mb";
      maxmemory-policy = "allkeys-lru";
      maxclients = 10000;
      timeout = 300;
      tcp-keepalive = 60;
      appendonly = "yes";
      appendfsync = "everysec";
    };
    save = [
      [900 1]      # Save after 900s if ≥1 key changed
      [300 10]     # Save after 300s if ≥10 keys changed
      [60 10000]   # Save after 60s if ≥10000 keys changed
    ];
  };

  # ============================================================================
  # CONTAINER RUNTIME
  # ============================================================================
  
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # LITELLM CONFIGURATION
  # ============================================================================
  
  # LiteLLM config file - mounted read-only into container
  environment.etc."litellm/config.yaml" = {
    text = ''
      general_settings:
        master_key: os.environ/LITELLM_MASTER_KEY
        database_url: "postgresql://litellm@localhost:5432/litellm"
        database_connection_pool_limit: 25
        database_connection_timeout: 60
        proxy_batch_write_at: 60
        disable_spend_logs: false
        
        # Public endpoints - no authentication
        public_routes:
          - "/health"
          - "/health/liveliness"
          - "/health/readiness"

      router_settings:
        redis_host: "localhost"
        redis_port: 6379
        routing_strategy: "simple-shuffle"

      litellm_settings:
        cache: true
        cache_type: "redis"
        cache_params:
          type: "redis"
          host: "localhost"
          port: 6379
          max_connections: 100
        load_models_from_db: true
        # Upstream seats new SSO arrivals as internal_user_viewer, which cannot
        # create even its own keys. internal_user can create and revoke its own
        # keys and see its own spend; registering models stays proxy_admin.
        default_internal_user_params:
          user_role: "internal_user"
        set_verbose: true
        json_logs: true
        request_timeout: 300
        max_retries: 3
        log_raw_request_response: false
    '';
    mode = "0644";
  };

  # Secrets template - bootstrap secret only; provider keys go via UI/API → DB
  environment.etc."secrets/litellm-template.env" = {
    text = ''
      LITELLM_MASTER_KEY=sk-your_master_key_here
    '';
    mode = "0600";
  };

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================
  
  systemd.services.generate-litellm-secrets = {
    description = "Generate LiteLLM secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];  # Ensure /etc is mounted before writing secrets
    before = [ "podman-litellm.service" ];

    # Only run if secrets file doesn't exist
    unitConfig.ConditionPathExists = "!/etc/secrets/litellm.env";
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-litellm-secrets" ''
        # Generate secure random master key
        MASTER_KEY="sk-$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        
        # Create secrets directory
        mkdir -p /etc/secrets
        
        # Write secrets file — bootstrap secret only; provider keys go via UI/API
        cat > /etc/secrets/litellm.env <<EOF
LITELLM_MASTER_KEY=$MASTER_KEY
EOF
        chmod 600 /etc/secrets/litellm.env
        
        # Display master key for admin to save
        echo "================================================"
        echo "LITELLM MASTER KEY (save this!):"
        echo "$MASTER_KEY"
        echo "================================================"
        echo "Saved to: /etc/secrets/litellm.env"
        echo "View anytime: sudo cat /etc/secrets/litellm.env"
      '';
    };
  };

  # ============================================================================
  # LITELLM CONTAINER
  # ============================================================================
  
  virtualisation.oci-containers.containers.litellm = {
    image = "docker.io/litellm/litellm:${versions.litellm}";
    volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
    environment = {
      STORE_MODEL_IN_DB = "True";
    };
    environmentFiles = [ "/etc/secrets/litellm.env" "/etc/secrets/litellm-integrations.env" ];
    extraOptions = [ 
      "--network=host"           # Access localhost PostgreSQL/Redis
      "--log-driver=journald"    # Logs to systemd journal
    ];
    cmd = [ 
      "--config" "/app/config.yaml" 
      "--port" "4000" 
      "--host" "0.0.0.0" 
      "--num_workers" "4"  
    ];
  };

  # Ensure LiteLLM starts after dependencies are ready
  systemd.services.podman-litellm = {
    after = [ "postgresql.service" "redis-litellm.service" "litellm-integrations.service" ];
    requires = [ "postgresql.service" "redis-litellm.service" "litellm-integrations.service" ];
  };

  # ============================================================================
  # PROVIDER INTEGRATIONS — Authentik SSO (#503)
  # ============================================================================
  #
  # identity:identity writes OIDC_CLIENT_ID/SECRET/DISCOVERY_URI to
  # /etc/secrets/litellm-oidc.env. LiteLLM does not read those names, and does
  # not consume a discovery document — it wants the three endpoints separately as
  # GENERIC_*. This translates one into the other and writes the env-file the
  # container loads.
  #
  # The endpoints are READ FROM the discovery document rather than assembled by
  # string surgery on the issuer URL, so a change in Authentik's URL layout does
  # not silently produce endpoints that 404.
  #
  # Runs before the container (podman fails on a missing --env-file, so the file
  # is created unconditionally, even empty) and is the identity.configureService
  # that identity:identity restarts after writing new OIDC secrets.
  # GENERIC_SCOPE derives from identity.scopes rather than being hardcoded:
  # identity:identity attaches one provider property mapping per scope name it
  # finds there, so hardcoding a different list here silently requests scopes
  # that yield no claim, or omits ones that were mapped. One list, both sides.
  systemd.services.litellm-integrations = let
    modCfg = if builtins.pathExists ./litellm.json
             then builtins.fromJSON (builtins.readFile ./litellm.json)
             else {};
    oidcScopes = lib.concatStringsSep " "
      (modCfg.identity.scopes or [ "openid" "email" "profile" ]);
  in {
    description = "Translate provider secrets into LiteLLM settings";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "litellm-integrations" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.systemd}/bin:$PATH"
        OUT=/etc/secrets/litellm-integrations.env
        OIDC=/etc/secrets/litellm-oidc.env
        # update.sh owns this file (owner identity + public URL); keeping the
        # public URL out of the OIDC file avoids depending on identity:identity
        # preserving foreign keys when it rewrites its own.
        OWNER=/etc/secrets/litellm-owner.env

        mkdir -p /etc/secrets
        readvar() { [ -f "$1" ] && grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

        NEW=""
        add() { NEW="$NEW$1"$'\n'; }

        CID="$(readvar "$OIDC" OIDC_CLIENT_ID)"
        CSE="$(readvar "$OIDC" OIDC_CLIENT_SECRET)"
        DIS="$(readvar "$OIDC" OIDC_DISCOVERY_URI)"
        PUB="$(readvar "$OWNER" LITELLM_PUBLIC_URL)"

        if [ -n "$CID" ] && [ -n "$CSE" ] && [ -n "$DIS" ]; then
          DOC="$(curl -fsS --max-time 20 "$DIS" 2>/dev/null || true)"
          AUTH_EP="$(printf '%s' "$DOC" | jq -r '.authorization_endpoint // empty' 2>/dev/null)"
          TOK_EP="$(printf '%s' "$DOC" | jq -r '.token_endpoint // empty' 2>/dev/null)"
          INFO_EP="$(printf '%s' "$DOC" | jq -r '.userinfo_endpoint // empty' 2>/dev/null)"
          if [ -n "$AUTH_EP" ] && [ -n "$TOK_EP" ] && [ -n "$INFO_EP" ]; then
            add "GENERIC_CLIENT_ID=$CID"
            add "GENERIC_CLIENT_SECRET=$CSE"
            add "GENERIC_AUTHORIZATION_ENDPOINT=$AUTH_EP"
            add "GENERIC_TOKEN_ENDPOINT=$TOK_EP"
            add "GENERIC_USERINFO_ENDPOINT=$INFO_EP"
            add "GENERIC_SCOPE=${oidcScopes}"
            # LiteLLM builds its SSO redirect_uri from PROXY_BASE_URL; without it
            # the callback points at localhost and Authentik rejects the redirect.
            [ -n "$PUB" ] && add "PROXY_BASE_URL=$PUB"
          else
            echo "litellm-integrations: discovery document unreadable at $DIS — SSO left unconfigured" >&2
          fi
        fi

        # See openwebui: empty content and a missing file compare equal, so
        # existence must be its own condition or podman fails to start.
        OLD="$(cat "$OUT" 2>/dev/null || true)"
        if [ ! -f "$OUT" ] || [ "$OLD" != "$NEW" ]; then
          T="$(mktemp /etc/secrets/.litellm-int.XXXXXX)"
          printf '%s' "$NEW" > "$T"
          chmod 600 "$T"
          mv -f "$T" "$OUT"
          echo "litellm-integrations: settings updated"
          if systemctl is-active --quiet podman-litellm.service; then
            systemctl restart podman-litellm.service || true
          fi
        else
          echo "litellm-integrations: no change"
        fi
      '';
    };
  };


  # ============================================================================
  # vLLM MODEL REGISTRATION (#503)
  # ============================================================================
  #
  # config.yaml carries NO model_list — LiteLLM is configured with
  # load_models_from_db, so models live in the database and were previously added
  # by hand through the UI. A fresh deploy therefore served ZERO models: the
  # vllm-amd:inference dependency was declared and the firewall pinhole opened,
  # but nothing ever registered the backend, and every consumer (OpenWebUI) got
  # an empty model list while all checks reported converged.
  #
  # vllm-amd:inference now writes /etc/secrets/vllm-inference.env (endpoint,
  # served model id, key). This registers that backend through LiteLLM's own API
  # if it is not already present — never a direct DB insert, so it stays correct
  # across LiteLLM schema changes.
  #
  # Idempotent: it checks /model/info first and does nothing when the model is
  # already registered, so a reconcile does not create duplicates.
  systemd.services.litellm-register-vllm = {
    description = "Register the vLLM backend as a LiteLLM model";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman-litellm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "litellm-register-vllm" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"
        SRC=/etc/secrets/vllm-inference.env

        readvar() { [ -f "$1" ] && grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

        BASE="$(readvar "$SRC" VLLM_BASE_URL)"
        MODEL="$(readvar "$SRC" VLLM_MODEL_ID)"
        KEY="$(readvar "$SRC" VLLM_API_KEY)"
        if [ -z "$BASE" ] || [ -z "$MODEL" ]; then
          echo "register-vllm: no vLLM endpoint recorded yet — skipping"
          exit 0
        fi
        # LiteLLM requires an explicit api_key on every DB model (a check
        # test-service.sh enforces). vLLM here is unauthenticated, so send the
        # literal placeholder rather than leaving the field unset.
        [ -n "$KEY" ] || KEY="none"

        MK="$(grep -m1 '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-)"
        [ -n "$MK" ] || { echo "register-vllm: no master key yet — skipping"; exit 0; }

        # Wait for the proxy to answer before asking it anything.
        i=0
        while [ "$i" -lt 60 ]; do
          curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:4000/health/readiness && break
          i=$((i + 1)); sleep 5
        done

        # Register the key as a NAMED CREDENTIAL and have the model reference it,
        # rather than embedding api_key in litellm_params. Two reasons:
        #   * it is this module's documented pattern (scripts/litellm-credentials.sh),
        #     so rotation is a one-touch operation that every referencing model picks up
        #   * /model/info does NOT return api_key (it is stored encrypted and reported
        #     as null), so an embedded key is invisible to verification —
        #     services/models/test-service.sh reads it as "no explicit api_key" and
        #     fails, even though the key is present in the database.
        CRED="vllm-amd"
        if ! curl -fsS -o /dev/null --max-time 20 -H "Authorization: Bearer $MK" \
               "http://127.0.0.1:4000/credentials/by_name/$CRED" 2>/dev/null; then
          curl -fsS --max-time 20 -X POST http://127.0.0.1:4000/credentials \
            -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg n "$CRED" --arg k "$KEY" \
                  '{credential_name:$n, credential_values:{api_key:$k}, credential_info:{custom_llm_provider:"openai"}}')" \
            >/dev/null 2>&1 \
            && echo "register-vllm: created credential '$CRED'" \
            || echo "register-vllm: could not create credential '$CRED'" >&2
        fi

        EXISTING="$(curl -fsS --max-time 20 -H "Authorization: Bearer $MK" \
                      http://127.0.0.1:4000/model/info 2>/dev/null \
                    | jq -r --arg m "$MODEL" '[.data[]? | select(.model_name == $m)] | length' 2>/dev/null)"
        if [ "''${EXISTING:-0}" != "0" ]; then
          echo "register-vllm: model '$MODEL' already registered — nothing to do"
          exit 0
        fi

        if curl -fsS --max-time 30 -X POST http://127.0.0.1:4000/model/new \
             -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
             -d "$(jq -nc --arg m "$MODEL" --arg b "$BASE" --arg c "$CRED" \
                   '{model_name: $m, litellm_params: {model: ("openai/" + $m), api_base: $b, litellm_credential_name: $c}}')" \
             >/dev/null
        then
          echo "register-vllm: registered '$MODEL' -> $BASE (credential '$CRED')"
        else
          echo "register-vllm: failed to register '$MODEL' — will retry on next converge" >&2
        fi
      '';
    };
  };

  # ============================================================================
  # ADMIN = ENVIRONMENT OWNER (#503)
  # ============================================================================
  #
  # LiteLLM's admin UI authenticates via SSO once GENERIC_* is configured, but any
  # SSO user lands as a plain internal user. This promotes the environment owner
  # to proxy_admin so the person who owns the environment owns the LiteLLM admin
  # UI, rather than whoever signs in first.
  #
  # The email is pushed by update.sh, which resolves it on the TAPPaaS side:
  #   environment.ownerOrg -> org.owner -> user.primaryEmail
  #
  # Idempotent: existing users are updated in place rather than duplicated.
  # ----------------------------------------
  # SSO group -> LiteLLM role mapping
  # ----------------------------------------
  #
  # Makes membership of the `litellm-admins` Authentik group actually MEAN
  # admin inside LiteLLM. Without this the group only controls whether you may
  # log in (that gate is the Authentik policy binding); once through, everyone
  # lands on default_internal_user_params.user_role — internal_user — and a
  # real admin has to be promoted by hand, one account at a time.
  #
  # This cannot live in config.yaml: LiteLLM stores SSO role_mappings in the
  # DATABASE (SSOConfigRepository), and proxy_server.py explicitly pops
  # "role_mappings" out of file-based settings. The supported surface is
  # PATCH /update/sso_settings, so it is applied here on every boot — which
  # also means a restored/rebuilt VM re-establishes it rather than silently
  # losing admin mapping into undeclared DB state.
  #
  # Requires "groups" in identity.scopes (litellm.json) — group_claim reads the
  # groups claim from the SSO token. Idempotent: writes the same document each
  # time. default_role keeps non-admins as internal_user, which can create and
  # revoke its own keys but cannot administer the proxy.
  # ----------------------------------------
  # Ollama pull, exposed through LiteLLM
  # ----------------------------------------
  #
  # LiteLLM is a router, not a model host: it holds no weights and has no
  # native "pull". Getting a new model therefore needed SSH to the Ollama LXC,
  # which the dev fleet has no reason (or access) to have.
  #
  # A configurable pass-through endpoint closes that gap: LiteLLM forwards
  # /ollama/api/pull straight to Ollama's own pull API, so a developer can add
  # a model with the same virtual key they already use for chat, over the same
  # host, with the request counted against the same auth. auth defaults to
  # true, so the route is NOT open — an unauthenticated call gets 401.
  #
  # Note this only fetches the weights. The model still needs a LiteLLM route
  # (POST /model/new) before it is visible to OpenWebUI; pull-model.sh in the
  # ollama-nvidia module does both halves in one command.
  systemd.services.litellm-ollama-passthrough = {
    description = "Expose Ollama's pull API through LiteLLM";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman-litellm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "litellm-ollama-passthrough" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"

        MK="$(grep -m1 '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-)"
        [ -n "$MK" ] || { echo "ollama-passthrough: no master key yet — skipping"; exit 0; }

        i=0
        while [ "$i" -lt 60 ]; do
          curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:4000/health/readiness && break
          i=$((i + 1)); sleep 5
        done

        TARGET="http://ollama-nvidia.srvWork.internal:11434/api/pull"
        if curl -fsS --max-time 20 -X POST http://127.0.0.1:4000/config/pass_through_endpoint \
             -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
             -d "$(jq -nc --arg t "$TARGET" '{path:"/ollama/api/pull", target:$t, headers:{}}')" \
             >/dev/null 2>&1
        then
          echo "ollama-passthrough: /ollama/api/pull -> $TARGET"
        else
          # Already present is the common case on a reconcile, and is not an error.
          echo "ollama-passthrough: endpoint already present or could not be created"
        fi
      '';
    };
  };

  systemd.services.litellm-sso-role-mappings = {
    description = "Map the litellm-admins SSO group to the LiteLLM proxy_admin role";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman-litellm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "litellm-sso-role-mappings" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"

        MK="$(grep -m1 '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-)"
        [ -n "$MK" ] || { echo "sso-role-mappings: no master key yet — skipping"; exit 0; }

        i=0
        while [ "$i" -lt 60 ]; do
          curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:4000/health/readiness && break
          i=$((i + 1)); sleep 5
        done

        BODY="$(jq -nc '{
          role_mappings: {
            provider: "generic",
            group_claim: "groups",
            default_role: "internal_user",
            roles: { proxy_admin: ["litellm-admins"] }
          }
        }')"

        curl -fsS --max-time 20 -X PATCH http://127.0.0.1:4000/update/sso_settings \
          -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
          -d "$BODY" >/dev/null \
          && echo "sso-role-mappings: litellm-admins -> proxy_admin applied" \
          || echo "sso-role-mappings: could not apply role mappings" >&2
      '';
    };
  };

  systemd.services.litellm-seed-admin = {
    description = "Make the environment owner a LiteLLM proxy admin";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman-litellm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "litellm-seed-admin" ''
        set -uo pipefail
        PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"
        OWNER=/etc/secrets/litellm-owner.env

        EMAIL="$(grep -m1 '^LITELLM_OWNER_EMAIL=' "$OWNER" 2>/dev/null | cut -d= -f2-)"
        if [ -z "$EMAIL" ]; then
          echo "seed-admin: no owner email recorded yet — skipping"
          exit 0
        fi

        MK="$(grep -m1 '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env | cut -d= -f2-)"
        [ -n "$MK" ] || { echo "seed-admin: no master key yet — skipping"; exit 0; }

        i=0
        while [ "$i" -lt 60 ]; do
          curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:4000/health/readiness && break
          i=$((i + 1)); sleep 5
        done

        FOUND="$(curl -fsS --max-time 20 -H "Authorization: Bearer $MK" \
                   "http://127.0.0.1:4000/user/info?user_id=$EMAIL" 2>/dev/null \
                 | jq -r '.user_id // empty' 2>/dev/null)"

        if [ -n "$FOUND" ]; then
          curl -fsS --max-time 20 -X POST http://127.0.0.1:4000/user/update \
            -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg e "$EMAIL" '{user_id: $e, user_role: "proxy_admin"}')" >/dev/null \
            && echo "seed-admin: $EMAIL confirmed as proxy_admin" \
            || echo "seed-admin: could not update $EMAIL" >&2
        else
          curl -fsS --max-time 20 -X POST http://127.0.0.1:4000/user/new \
            -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg e "$EMAIL" '{user_id: $e, user_email: $e, user_role: "proxy_admin", auto_create_key: false}')" >/dev/null \
            && echo "seed-admin: created $EMAIL as proxy_admin" \
            || echo "seed-admin: could not create $EMAIL — will retry on next converge" >&2
        fi
      '';
    };
  };

  # ============================================================================
  # BACKUP STRATEGY - 3 layers
  # ============================================================================
  
  # Layer 1: PostgreSQL dumps (daily 02:00)
  services.postgresqlBackup = {
    enable = true;
    databases = [ "litellm" ];
    startAt = "*-*-* 02:00:00";
    location = "/var/backup/postgresql";
    compression = "gzip";
  };

  # Layer 2: Redis RDB snapshots (daily 02:30)
  systemd.services.redis-backup = {
    description = "Redis backup service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "redis-backup" ''
        # Trigger synchronous save to disk
        ${versions.redisPkg}/bin/redis-cli SAVE

        # Copy snapshot with timestamp
        ${pkgs.coreutils}/bin/cp /var/lib/redis-litellm/dump.rdb \
          /var/backup/redis/dump-$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S).rdb
      '';
      User = "redis-litellm";
      Group = "redis-litellm";
    };
  };

  systemd.timers.redis-backup = {
    description = "Daily Redis backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;  # Run missed backups on boot
    };
  };

  # Layer 3: Config + secrets backup (daily 02:45)
  systemd.services.litellm-env-backup = {
    description = "Backup LiteLLM environment files";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/litellm-env";
      ExecStart = pkgs.writeShellScript "litellm-env-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/litellm-env/litellm-env-$(date +%F).tar.gz \
          -C / etc/secrets etc/litellm 2>/dev/null || true
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.litellm-env-backup = {
    description = "Daily LiteLLM environment file backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:45:00";
      Persistent = true;
    };
  };

  # Cleanup old backups (monthly) - prevent disk fill
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
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================
  
  systemd.tmpfiles.rules = [
    "d /var/backup/postgresql 0700 postgres postgres -"
    "d /var/backup/redis 0755 redis-litellm redis-litellm -"
    "d /var/backup/litellm-env 0755 root root -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # See: https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion
  # ============================================================================
  
  system.stateVersion = "25.05";
}