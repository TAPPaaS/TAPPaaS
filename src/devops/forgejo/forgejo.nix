# ----------------------------------------
# TAPPaaS Community Module
# Name:    Forgejo — self-hosted Git service (Gitea fork)
# Type:    NixOS VM
# Zone:    srvWork
# Version: 16.0.5
# Date:    2026-06-01
# Author:  @ErikDaniel007
# License: MIT (Forgejo upstream)
# ----------------------------------------

{ config, pkgs, lib, ... }:

let
  versions = {
    forgejo    = "16.0.5";
    forgejoApp = pkgs.forgejo;  # resolved from nixpkgs — pin overrideAttrs if needed
  };

  # The site's own values (#282), not ours to guess: update-os.sh deploys the
  # module's config beside this file as /etc/nixos/forgejo.json, with the name
  # the proxy publishes it under and whether that name has a public record
  # (#715) — the immich/vaultwarden idiom. ROOT_URL is what Forgejo builds every
  # link and its OAuth callback from, so it must be the public https URL.
  moduleCfg   = if builtins.pathExists ./forgejo.json
                then builtins.fromJSON (builtins.readFile ./forgejo.json)
                else {};
  proxyCfg    = (moduleCfg.config or {})."network:proxy" or {};
  proxyDomain = proxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  published   = proxyDomain != "" && (moduleCfg.proxyPublished or true);
  internalHost = "${moduleCfg.vmname or "forgejo"}.${moduleCfg.zone0 or "srvWork"}.internal";
  rootUrl     = if published then "https://${proxyDomain}/" else "http://${internalHost}:3000/";

  fcfg = config.services.forgejo;
  # The forgejo CLI as the service runs it: its user, work path and app.ini.
  forgejoCli = pkgs.writeShellScriptBin "forgejo-admin" ''
    exec ${pkgs.util-linux}/bin/runuser -u ${fcfg.user} -- \
      ${fcfg.package}/bin/forgejo --work-path ${fcfg.stateDir} \
        --custom-path ${fcfg.customDir} --config ${fcfg.customDir}/conf/app.ini "$@"
  '';
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324), shipped by update-os.sh
    # before every rebuild; it imports the site's time and locale.
    /etc/nixos/tappaas-common.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    # Always present: update-os.sh ships an empty one, and backup:filesystem
    # overwrites it with the real trigger.
    /etc/nixos/tappaas-backup.nix
  ];

  # Everything a TAPPaaS VM has in common -- boot, cloud-init, NetworkManager,
  # the tappaas user and sudo, ssh, qemu-guest, serial console, zram/oomd, nix
  # settings and gc, the site's time zone -- comes from the baseline (#324).
  # This file states only what forgejo adds or changes.

  system.stateVersion = "25.05";

  # === Networking ===
  networking.hostName = lib.mkDefault "forgejo";

  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [ 22 3000 ];
  };

  # === SSH: keys only (the baseline's defaults allow passwords) ===
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # === Forgejo service ===
  services.forgejo = {
    enable   = true;
    package  = versions.forgejoApp;

    settings = {
      DEFAULT = {
        APP_NAME = lib.mkDefault "Forgejo";
      };

      server = {
        HTTP_PORT        = lib.mkDefault 3000;
        SSH_PORT         = lib.mkDefault 22;
        START_SSH_SERVER = lib.mkDefault false;  # Use system OpenSSH
        # From the site (#282): the public https URL when published, else the
        # internal address. SSH clones use the internal name (port 22 is not
        # proxied).
        ROOT_URL         = rootUrl;
        DOMAIN           = if published then proxyDomain else internalHost;
        SSH_DOMAIN       = internalHost;
      };

      database = {
        # SQLite is the default backend — sufficient for single-team use.
        # Switch to postgres if concurrent load exceeds 50 users:
        #   DB_TYPE  = "postgres";
        #   HOST     = "127.0.0.1:5432";
        #   NAME     = "forgejo";
        #   USER     = "forgejo";
        DB_TYPE = lib.mkDefault "sqlite3";
        PATH    = lib.mkDefault "/var/lib/forgejo/data/forgejo.db";
      };

      repository = {
        ROOT = lib.mkDefault "/var/lib/forgejo/repositories";
      };

      # Accounts come from the site's Authentik (#282): no local sign-up page;
      # a first SSO login creates the account. While the name is unpublished
      # there is no SSO, and registration is closed altogether. The NixOS module
      # sets INSTALL_LOCK and generates SECRET_KEY / INTERNAL_TOKEN itself (no
      # web installer); install.sh creates the local break-glass admin.
      service = {
        DEFAULT_ORG_VISIBILITY           = lib.mkDefault "private";
        DISABLE_REGISTRATION             = !published;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
        SHOW_REGISTRATION_BUTTON         = false;
      };

      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        # Authentik's preferred_username arrives as the OIDC nickname.
        USERNAME                 = "nickname";
        # The IdP is the site's own Authentik with verified e-mail: an SSO login
        # attaches to the local account with the same e-mail without a prompt.
        ACCOUNT_LINKING          = "auto";
        UPDATE_AVATAR            = false;
      };

      # OpenID 2.0 (the pre-OIDC protocol) sign-in: off, Authentik is the IdP.
      openid = {
        ENABLE_OPENID_SIGNIN = false;
        ENABLE_OPENID_SIGNUP = false;
      };

      mailer = {
        ENABLED = lib.mkDefault false;  # Configure in INSTALL.md §Post-install
      };

      log = {
        MODE  = lib.mkDefault "file";
        LEVEL = lib.mkDefault "Info";
      };

      webhook = {
        ALLOWED_HOST_LIST = lib.mkDefault "loopback,private";
      };
    };
  };

  # === SSO: the Authentik login source (#282) ===
  #
  # identity:identity registers an OIDC application for this module and writes
  # its client to /etc/secrets/forgejo.env (OIDC_CLIENT_ID / _SECRET /
  # _DISCOVERY_URI), then restarts this unit — the module's
  # identity.configureService. It keeps ONE Forgejo login source named
  # "authentik" in step with that client (add-oauth, else update-oauth). The
  # groups claim carries "admin" for members of Authentik's forgejo-admins
  # (identity.adminGroupClaim), and Forgejo makes those users site admins.
  # No client (unpublished, or identity removed): the source is deleted, so the
  # login page offers no button that cannot work.
  systemd.services.forgejo-configure-oidc = {
    description = "Configure the Authentik login source in Forgejo";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "forgejo.service" ];
    requires    = [ "forgejo.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "-/etc/secrets/forgejo.env";
    };
    path = [ forgejoCli pkgs.curl pkgs.gawk pkgs.coreutils ];
    script = ''
      set -euo pipefail
      ready=0
      for _ in $(seq 1 60); do
        if curl -sf --max-time 5 http://127.0.0.1:3000/api/healthz >/dev/null; then ready=1; break; fi
        sleep 2
      done
      [ "$ready" -eq 1 ] || { echo "forgejo-configure-oidc: forgejo never became healthy" >&2; exit 1; }

      ID="$(forgejo-admin admin auth list 2>/dev/null | awk 'NR>1 && $2=="authentik" {print $1; exit}')"
      if [ -z "''${OIDC_CLIENT_ID:-}" ] || [ -z "''${OIDC_CLIENT_SECRET:-}" ] || [ -z "''${OIDC_DISCOVERY_URI:-}" ]; then
        if [ -n "$ID" ]; then
          forgejo-admin admin auth delete --id "$ID"
          echo "forgejo-configure-oidc: no OIDC client — removed the authentik login source"
        else
          echo "forgejo-configure-oidc: no OIDC client — SSO off"
        fi
        exit 0
      fi

      ARGS=(--name authentik --provider openidConnect
            --key "$OIDC_CLIENT_ID" --secret "$OIDC_CLIENT_SECRET"
            --auto-discover-url "$OIDC_DISCOVERY_URI"
            --scopes openid --scopes email --scopes profile --scopes groups
            --group-claim-name groups --admin-group admin
            --skip-local-2fa)
      if [ -z "$ID" ]; then
        forgejo-admin admin auth add-oauth "''${ARGS[@]}"
        echo "forgejo-configure-oidc: authentik login source added"
      else
        forgejo-admin admin auth update-oauth --id "$ID" "''${ARGS[@]}"
        echo "forgejo-configure-oidc: authentik login source $ID updated"
      fi
    '';
  };

  # === Data directories ===
  # Owned by the user Forgejo runs as. These said git:git, a user this VM never
  # had: tmpfiles skipped both lines and every nightly backup failed with
  # 217/USER (found on hrossen 2026-10-06, #282's live test).
  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo/repositories 0750 ${fcfg.user} ${fcfg.group} -"
    "d /var/backup/forgejo            0700 ${fcfg.user} ${fcfg.group} -"
  ];

  # === Backup: daily dump of repositories + SQLite ===
  systemd.services.forgejo-backup = {
    description = "Forgejo daily backup";
    after       = [ "forgejo.service" ];
    serviceConfig = {
      Type    = "oneshot";
      User    = fcfg.user;
      ExecStart = pkgs.writeShellScript "forgejo-backup" ''
        set -euo pipefail
        DEST=/var/backup/forgejo/forgejo-$(date +%F)
        mkdir -p "$DEST"
        # Repositories (bare git)
        ${pkgs.rsync}/bin/rsync -a /var/lib/forgejo/repositories/ "$DEST/repositories/"
        # SQLite DB — pause Forgejo write-ahead log with PRAGMA
        ${pkgs.sqlite}/bin/sqlite3 /var/lib/forgejo/data/forgejo.db \
          "VACUUM INTO '$DEST/forgejo.db.bak';"
        echo "Backup complete: $DEST"
      '';
    };
  };
  systemd.timers.forgejo-backup = {
    description         = "Daily Forgejo backup at 03:00";
    wantedBy            = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 03:00:00";
    timerConfig.Persistent = true;
  };

  # === Backup rotation (30 days) ===
  systemd.services.forgejo-cleanup = {
    description = "Remove Forgejo backups older than 30 days";
    serviceConfig = {
      Type    = "oneshot";
      User    = "root";
      ExecStart = pkgs.writeShellScript "forgejo-cleanup" ''
        ${pkgs.findutils}/bin/find /var/backup/forgejo -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
      '';
    };
  };
  systemd.timers.forgejo-cleanup = {
    description         = "Monthly Forgejo backup cleanup";
    wantedBy            = [ "timers.target" ];
    timerConfig.OnCalendar = "monthly";
    timerConfig.Persistent = true;
  };

  # === System packages ===
  # vim, wget, curl, htop and git come from the baseline.
  environment.systemPackages = with pkgs; [ rsync sqlite forgejoCli ];
}
