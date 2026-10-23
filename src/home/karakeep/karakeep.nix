# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Karakeep
# ============================================================================
# Self-contained NixOS configuration, applied by update-os.sh on install and
# every update (built on the mothership against the release's nixpkgs).
#
# Karakeep (AGPL-3.0) is a Docker Compose stack of three: the web app with its
# background workers (port 3000), a headless Chromium that fetches each saved
# page for its archive and screenshot, and Meilisearch for full-text search.
#
# What TAPPaaS adds:
#   - images pinned to release tags (src/image-pins.json), never :latest;
#   - secrets generated once on the VM (/var/lib/karakeep/secrets.env);
#   - sign-in with Authentik: identity:identity writes /etc/secrets/karakeep.env,
#     and then Karakeep offers only "Sign in with Authentik" (no local passwords);
#     until then sign-ups are closed;
#   - AI tagging through LiteLLM when the site has the AI stack: litellm:models
#     writes /etc/secrets/litellm-svckey.env;
#   - either file appearing or changing restarts the stack (karakeep-secrets.path).
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  # Pinned images (src/image-pins.json tracks them, #750). Immutable tags.
  karakeepImage = "ghcr.io/karakeep-app/karakeep:0.34.0";
  chromeImage = "ghcr.io/karakeep-app/karakeep-chrome:154.0.8037.57-r1";
  meiliImage = "getmeili/meilisearch:v1.41.0";

  state = "/var/lib/karakeep";

  # The address people reach Karakeep at — its OAuth callback and its links are
  # built from it. update-os.sh ships the module's config beside this file as
  # /etc/nixos/karakeep.json, with the name the proxy publishes it under and
  # whether that name has a public record (the immich idiom). Unpublished, it is
  # the VM's own name.
  moduleCfg = if builtins.pathExists ./karakeep.json
              then builtins.fromJSON (builtins.readFile ./karakeep.json)
              else {};
  proxyCfg = (moduleCfg.config or {})."network:proxy" or {};
  proxyDomain = proxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  published = proxyDomain != "" && (moduleCfg.proxyPublished or true);
  zone0 = moduleCfg.zone0 or "";
  publicUrl = if published then "https://${proxyDomain}"
              else "http://${moduleCfg.vmname or "karakeep"}${lib.optionalString (zone0 != "") ".${zone0}"}.internal:3000";

  compose = pkgs.writeText "karakeep-compose.yml" ''
    name: karakeep
    services:
      web:
        image: ${karakeepImage}
        container_name: karakeep_web
        restart: unless-stopped
        ports:
          - "3000:3000"
        volumes:
          - ${state}/data:/data
        env_file:
          - /run/karakeep/env
        environment:
          - DATA_DIR=/data
          - MEILI_ADDR=http://meilisearch:7700
          - BROWSER_WEB_URL=http://chrome:9222
        depends_on:
          - meilisearch
          - chrome
      chrome:
        image: ${chromeImage}
        container_name: karakeep_chrome
        restart: unless-stopped
        init: true
        command:
          - --disable-gpu
          - --disable-dev-shm-usage
          - --hide-scrollbars
          - --disable-blink-features=AutomationControlled
          - --window-size=1440,900
      meilisearch:
        image: ${meiliImage}
        container_name: karakeep_meilisearch
        restart: unless-stopped
        env_file:
          - /run/karakeep/meili.env
        environment:
          - MEILI_NO_ANALYTICS=true
        volumes:
          - ${state}/meili:/meili_data
  '';

  # Assembles the stack's environment, then brings it to the compose file. Run
  # at every start, so a new sign-in or AI configuration takes effect.
  karakeepUp = pkgs.writeShellScript "karakeep-up" ''
    set -euo pipefail
    install -d -m 0755 ${state} ${state}/data ${state}/meili
    secrets=${state}/secrets.env
    if [ ! -s "$secrets" ]; then
      umask 077
      {
        echo "NEXTAUTH_SECRET=$(${pkgs.openssl}/bin/openssl rand -base64 36)"
        echo "MEILI_MASTER_KEY=$(${pkgs.openssl}/bin/openssl rand -hex 32)"
      } > "$secrets"
    fi
    # A file not written yet (no sign-in, no AI stack) is empty, not an error.
    readvar() { [ -r "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | tail -1; }
    install -d -m 0700 /run/karakeep
    out=/run/karakeep/env.new
    umask 077
    {
      cat "$secrets"
      echo "NEXTAUTH_URL=${publicUrl}"
      # Sign-ins and their redirects only from Karakeep's own address (the
      # default is any origin).
      echo "AUTH_TRUSTED_ORIGINS=${publicUrl}"
      echo "DISABLE_NEW_RELEASE_CHECK=true"
      echo "CRAWLER_STORE_SCREENSHOT=true"

      # Sign in with Authentik (identity:identity). Until it is set up nobody
      # can sign up: Karakeep is published to the internet, and its first
      # account is the administrator. DISABLE_SIGNUPS would also refuse a first
      # Authentik sign-in, so with Authentik only password sign-in is off.
      oidc=/etc/secrets/karakeep.env
      cid="$(readvar "$oidc" OIDC_CLIENT_ID)"; cse="$(readvar "$oidc" OIDC_CLIENT_SECRET)"; dis="$(readvar "$oidc" OIDC_DISCOVERY_URI)"
      if [ -n "$cid" ] && [ -n "$cse" ] && [ -n "$dis" ]; then
        echo "OAUTH_WELLKNOWN_URL=$dis"
        echo "OAUTH_CLIENT_ID=$cid"
        echo "OAUTH_CLIENT_SECRET=$cse"
        echo "OAUTH_PROVIDER_NAME=Authentik"
        echo "OAUTH_SCOPE=openid email profile"
        echo "DISABLE_PASSWORD_AUTH=true"
        echo "OAUTH_AUTO_REDIRECT=true"
      else
        echo "DISABLE_SIGNUPS=true"
      fi

      # AI tagging through LiteLLM (litellm:models). The model is the first one
      # LiteLLM serves; an operator chooses another in ${state}/local.env.
      ai=/etc/secrets/litellm-svckey.env
      key="$(readvar "$ai" LITELLM_API_KEY)"; base="$(readvar "$ai" LITELLM_BASE_URL)"
      if [ -n "$key" ] && [ -n "$base" ]; then
        echo "OPENAI_API_KEY=$key"
        echo "OPENAI_BASE_URL=$base"
        model="$(${pkgs.curl}/bin/curl -sf --max-time 10 -H "Authorization: Bearer $key" "$base/models" \
                 | ${pkgs.jq}/bin/jq -r '.data[0].id // empty' 2>/dev/null || true)"
        if [ -n "$model" ]; then
          echo "INFERENCE_TEXT_MODEL=$model"
          echo "INFERENCE_IMAGE_MODEL=$model"
          echo "INFERENCE_ENABLE_AUTO_TAGGING=true"
        else
          echo "INFERENCE_ENABLE_AUTO_TAGGING=false"
        fi
      else
        echo "INFERENCE_ENABLE_AUTO_TAGGING=false"
      fi

      # The operator's own settings last, so they win (an INFERENCE_TEXT_MODEL,
      # a MAX_ASSET_SIZE_MB, ...). Never written by TAPPaaS.
      if [ -s ${state}/local.env ]; then cat ${state}/local.env; fi
    } > "$out"
    mv "$out" /run/karakeep/env
    # Meilisearch gets its master key and nothing else.
    grep '^MEILI_MASTER_KEY=' "$secrets" > /run/karakeep/meili.env

    # A first boot can reach this before the VM resolves names: wait for DNS,
    # and retry the pull rather than fail the activation on a transient.
    for i in $(seq 1 30); do
      ${pkgs.getent}/bin/getent hosts ghcr.io >/dev/null && break
      sleep 10
    done
    for i in 1 2 3 4 5; do
      ${pkgs.docker-compose}/bin/docker-compose -p karakeep -f ${compose} up -d --remove-orphans && exit 0
      echo "karakeep: up failed (attempt $i of 5), retrying in 30 s" >&2
      sleep 30
    done
    exit 1
  '';
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
    /etc/nixos/tappaas-backup.nix
  ];

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "karakeep";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 3000 ];
  };

  # -- SSH: keys only ----------------------------------------------------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Docker ------------------------------------------------------------------
  virtualisation.docker = {
    enable = true;
    autoPrune = { enable = true; dates = "weekly"; };
  };

  environment.systemPackages = with pkgs; [ jq curl docker-compose ];

  # Readable by update.sh and test.sh (as tappaas, through sudo).
  environment.etc."karakeep/compose.yml".source = compose;

  systemd.services.karakeep = {
    description = "Karakeep (web app, Chromium, Meilisearch)";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker pkgs.coreutils pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = karakeepUp;
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose -p karakeep -f ${compose} down";
      TimeoutStartSec = "15min";
    };
    # A new compose (a pin bump) brings the stack to it on the next switch.
    restartTriggers = [ compose ];
  };

  # Sign-in or AI configuration written by identity:identity or litellm:models:
  # restart the stack so it takes effect. (identity:identity restarts the unit
  # itself too; litellm:models does not.)
  systemd.paths.karakeep-secrets = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = [ "/etc/secrets/karakeep.env" "/etc/secrets/litellm-svckey.env" ];
      Unit = "karakeep-reconfigure.service";
    };
  };
  systemd.services.karakeep-reconfigure = {
    description = "Restart Karakeep for new sign-in or AI configuration";
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.systemd}/bin/systemctl restart karakeep.service"; };
  };

  system.stateVersion = "25.05";
}
