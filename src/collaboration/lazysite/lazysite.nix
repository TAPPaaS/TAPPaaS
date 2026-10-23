# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - lazysite
# ============================================================================
# Self-contained NixOS configuration, applied by update-os.sh on install and
# every update (built on the mothership against the release's nixpkgs).
#
# lazysite (MIT) renders Markdown pages as HTML on their first request and
# keeps the result as a static file beside the page. Here it serves one public
# website whose pages live in a Forgejo repository (forgejo:repo):
#
#   - nginx on :8080 (behind the firewall's Caddy) serves files and hands every
#     page to the lazysite processor, which runs as a FastCGI pool on a socket
#     systemd opens (lazysite.socket) — no CGI, no root in the request path;
#   - only the page renderer is reachable: lazysite's browser manager, its
#     sign-in, WebDAV and the other CGI endpoints are not wired, and the
#     identity headers a front end could pass are always stripped;
#   - lazysite-pull checks the repository every minute with the VM's read-only
#     deploy key and, on a new commit, puts the pages in place and clears the
#     rendered copies, so the next visit renders the new text;
#   - the VM keeps no data of its own: everything is in the repository.
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  version = "0.16.0";
  lazysite = pkgs.stdenvNoCC.mkDerivation {
    pname = "lazysite";
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "OpenDigitalCC";
      repo = "lazysite";
      rev = "v${version}";
      hash = "sha256-C23aso4kZEnEBksIRctK5D1vB2FlDfdCHYCby88i+28=";
    };
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/lazysite
      cp -r . $out/share/lazysite
    '';
  };
  perlEnv = pkgs.perl.withPackages (p: with p; [
    TextMultiMarkdown TemplateToolkit LWP LWPProtocolHttps FCGI FCGIProcManager
  ]);

  state = "/var/lib/lazysite";
  docroot = "${state}/site";
  # lazysite's engine tree (its config, layouts, logs) beside the docroot rather
  # than inside it: never reachable as a URL, whatever the front end does.
  engine = "${state}/site-lazysite";
  socket = "/run/lazysite/site.sock";

  # The firewall's IPv6 address in this zone, where Caddy's requests come from
  # over IPv6 (update-os.sh ships the module's config as /etc/nixos/lazysite.json).
  moduleCfg = if builtins.pathExists ./lazysite.json
              then builtins.fromJSON (builtins.readFile ./lazysite.json)
              else {};
  proxySourceV6 = moduleCfg.proxySourceV6 or "";

  # The identity and payment headers lazysite would trust from a front end:
  # always empty here, so no visitor can claim to be signed in.
  stripTrust = ''
    fastcgi_param HTTP_X_REMOTE_USER      "";
    fastcgi_param HTTP_X_REMOTE_GROUPS    "";
    fastcgi_param HTTP_X_REMOTE_NAME      "";
    fastcgi_param HTTP_X_REMOTE_EMAIL     "";
    fastcgi_param HTTP_X_PAYMENT_VERIFIED "";
    fastcgi_param HTTP_X_PAYMENT_PAYER    "";
  '';
  toEngine = "try_files /dev/null @lazysite;";

  # Bring the repository's latest commit into the docroot. Runs as lazysite,
  # with the deploy key and Forgejo's host key as systemd credentials.
  pull = pkgs.writeShellScript "lazysite-pull" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.openssh pkgs.rsync pkgs.coreutils pkgs.findutils pkgs.gnused ]}
    if [ -z "''${REPO_SSH_URL:-}" ]; then
      echo "lazysite-pull: no repository yet (/etc/secrets/forgejo-repo.env is written by forgejo:repo)"
      exit 0
    fi
    branch="''${REPO_BRANCH:-main}"
    export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$CREDENTIALS_DIRECTORY/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15"
    repo=${state}/repo
    remote="$(git ls-remote "$REPO_SSH_URL" "refs/heads/$branch" | cut -f1)"
    [ -n "$remote" ] || { echo "lazysite-pull: $REPO_SSH_URL has no branch $branch yet"; exit 0; }
    if [ "$remote" = "$(cat ${state}/deployed 2>/dev/null)" ] && [ -d ${docroot} ]; then
      exit 0
    fi
    if [ ! -d "$repo/.git" ]; then
      rm -rf "$repo"
      git clone --quiet --depth 1 --branch "$branch" "$REPO_SSH_URL" "$repo"
    else
      git -C "$repo" remote set-url origin "$REPO_SSH_URL"
      git -C "$repo" fetch --quiet --depth 1 origin "$branch"
      git -C "$repo" reset --quiet --hard FETCH_HEAD
      git -C "$repo" clean -qfdx
    fi
    install -d -m 0750 ${docroot} ${engine}
    # The pages, without the repository's own files and the engine tree. --delete
    # also removes every rendered copy (an .html no commit has), which is what
    # makes the next visit render the new text.
    rsync -a --delete --exclude=/.git/ --exclude=/.forgejo/ --exclude=/lazysite/ "$repo/" ${docroot}/
    # The site's own lazysite settings and layouts, when the repository has them
    # (lazysite/ at its root); what lazysite writes there itself is kept.
    if [ -d "$repo/lazysite" ]; then
      rsync -a --delete --filter='P /logs/' --filter='P /cache/' --filter='P /auth/' --filter='P /forms/' \
        --filter='P /.install-state.json' "$repo/lazysite/" ${engine}/
    fi
    find /var/cache/lazysite -mindepth 1 -delete 2>/dev/null || true
    echo "$remote" > ${state}/deployed
    echo "lazysite-pull: deployed $(git -C "$repo" log -1 --format='%h %s')"
  '';
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324).
    /etc/nixos/tappaas-common.nix
  ];

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "lazysite";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 8080 ];
  };

  # -- SSH: keys only ----------------------------------------------------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  environment.systemPackages = with pkgs; [ git jq curl ];

  users.groups.lazysite = { };
  users.users.lazysite = {
    isSystemUser = true;
    group = "lazysite";
    home = state;
  };
  # nginx reads the docroot through the group.
  users.users.nginx.extraGroups = [ "lazysite" ];

  systemd.tmpfiles.rules = [
    "d ${state}  0750 lazysite lazysite -"
    "d ${docroot} 0750 lazysite lazysite -"
    "d ${engine} 0750 lazysite lazysite -"
  ];

  # -- The lazysite processor, a FastCGI pool --------------------------------
  # systemd binds the socket and hands it over as fd 0, which the processor
  # takes as a FastCGI listen socket (its pool mode).
  systemd.sockets.lazysite = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = socket;
      SocketUser = "lazysite";
      SocketGroup = "nginx";
      SocketMode = "0660";
      Accept = false;
    };
  };
  systemd.services.lazysite = {
    description = "lazysite page renderer (FastCGI)";
    requires = [ "lazysite.socket" ];
    after = [ "lazysite.socket" ];
    environment = {
      DOCUMENT_ROOT = docroot;
      LAZYSITE_CACHE_DIR = "/var/cache/lazysite";
      LAZYSITE_FCGI_WORKERS = "2";
      LAZYSITE_FCGI_MAX_REQUESTS = "500";
    };
    restartTriggers = [ lazysite perlEnv ];
    serviceConfig = {
      ExecStart = "${perlEnv}/bin/perl ${lazysite}/share/lazysite/lazysite-processor.pl";
      User = "lazysite";
      Group = "lazysite";
      StandardInput = "socket";
      StandardOutput = "journal";
      StandardError = "journal";
      Restart = "always";
      RestartSec = 2;
      CacheDirectory = "lazysite";
      # Writes only the rendered pages and its engine tree.
      ProtectSystem = "strict";
      ReadWritePaths = [ docroot engine ];
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      SystemCallFilter = [ "@system-service" ];
    };
  };

  # -- Content from the Forgejo repository ------------------------------------
  systemd.services.lazysite-pull = {
    description = "Bring the website's latest commit from Forgejo";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "/etc/secrets/forgejo-repo.key";
    serviceConfig = {
      Type = "oneshot";
      User = "lazysite";
      Group = "lazysite";
      EnvironmentFile = "-/etc/secrets/forgejo-repo.env";
      LoadCredential = [
        "key:/etc/secrets/forgejo-repo.key"
        "known_hosts:/etc/secrets/forgejo-repo.known_hosts"
      ];
      ExecStart = pull;
      CacheDirectory = "lazysite";
      ProtectSystem = "strict";
      ReadWritePaths = [ state ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
  systemd.timers.lazysite-pull = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "30s"; OnUnitActiveSec = "60s"; AccuracySec = "5s"; };
  };
  # A new or changed repository (forgejo:repo writes these) is pulled at once.
  systemd.paths.lazysite-repo = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = [ "/etc/secrets/forgejo-repo.env" "/etc/secrets/forgejo-repo.key" ];
      Unit = "lazysite-pull.service";
    };
  };

  # -- nginx -------------------------------------------------------------------
  # Caddy's addresses in this zone, where every published request comes from:
  # nginx then gives lazysite the visitor's address (from X-Forwarded-For, which
  # Caddy sets), so its rate limit counts visitors, not the firewall.
  systemd.services.lazysite-realip = {
    description = "nginx: trust X-Forwarded-For from the firewall";
    before = [ "nginx.service" ];
    requiredBy = [ "nginx.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      install -d -m 0755 /run/lazysite-nginx
      gw4="$(${pkgs.iproute2}/bin/ip -4 route show default | ${pkgs.gawk}/bin/awk '{print $3; exit}')"
      {
        [ -n "$gw4" ] && echo "set_real_ip_from $gw4;"
        ${lib.optionalString (proxySourceV6 != "") ''echo "set_real_ip_from ${proxySourceV6};"''}
        echo "real_ip_header X-Forwarded-For;"
      } > /run/lazysite-nginx/realip.conf
    '';
  };

  services.nginx = {
    enable = true;
    # The realip include is written at boot (above), so it is not there to check
    # when the configuration is built.
    validateConfigFile = false;
    recommendedGzipSettings = true;
    serverTokens = false;
    appendHttpConfig = ''
      include /run/lazysite-nginx/realip.conf;
      # lazysite reads the requested path from REDIRECT_URL (what Apache's
      # FallbackResource sets), without the query string.
      map $request_uri $lazysite_request_path {
          ~^(?<path>[^?]*) $path;
      }
    '';
    virtualHosts.lazysite = {
      default = true;
      listen = [ { addr = "0.0.0.0"; port = 8080; } { addr = "[::]"; port = 8080; } ];
      root = docroot;
      extraConfig = ''
        # index.html is lazysite's rendered home page: "/" goes to the
        # processor, which serves it.
        index index.htm;
        client_max_body_size 1m;
      '';
      locations = {
        # lazysite's own instance check.
        "^~ /.well-known/lazysite-instance.json".extraConfig = toEngine;
        # Hidden files (a stray .git, .env) and anything named like the engine
        # tree are never files to serve.
        "~ /\\.".extraConfig = "return 404;";
        "^~ /lazysite/".extraConfig = "return 404;";
        # What lazysite does not run here: its manager, sign-in, WebDAV and every
        # CGI endpoint.
        "^~ /cgi-bin/".extraConfig = "return 404;";
        "^~ /manager".extraConfig = "return 404;";
        "~ ^/dav(/|$)".extraConfig = "return 404;";
        # Page sources go to the processor, which renders /about.md as /about and
        # never hands a source out; the list is lazysite's own (%STATIC_DENY).
        "~* \\.(?:md|url|brief|bak|swp|swo|orig|old|tmp|conf|ini|env|pem|key|pl|pm|cgi|fcgi|phtml|php|php3|php4|php5|phps|phar|htaccess|htpasswd)$".extraConfig = toEngine;
        # The per-site registries, always from the processor.
        "= /sitemap.xml".extraConfig = toEngine;
        "= /llms.txt".extraConfig = toEngine;
        "= /robots.txt".extraConfig = toEngine;
        "= /feed.rss".extraConfig = toEngine;
        "= /feed.atom".extraConfig = toEngine;
        # Files are served as they are; a URL that is no file is a page.
        "/".extraConfig = "try_files $uri @lazysite;";
        "@lazysite".extraConfig = ''
          include ${config.services.nginx.package}/conf/fastcgi_params;
          ${stripTrust}
          fastcgi_param REDIRECT_URL $lazysite_request_path;
          fastcgi_param DOCUMENT_ROOT ${docroot};
          fastcgi_pass unix:${socket};
        '';
      };
    };
  };
  systemd.services.nginx = {
    after = [ "lazysite.socket" ];
    wants = [ "lazysite.socket" ];
  };

  system.stateVersion = "25.05";
}
