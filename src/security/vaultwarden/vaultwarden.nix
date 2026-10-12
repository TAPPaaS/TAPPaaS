# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - VaultWarden Password Manager
# ============================================================================
# Version: 1.0.0
# Date: 2026-02-17
# Author: @ErikDaniel007 (TAPPaaS)
# Product: VaultWarden (Bitwarden-compatible) password manager
#
# Architecture:
# - Native NixOS services.vaultwarden (lightweight, no container)
# - SQLite backend (default, sufficient for SMB/home use)
# - Environment file for secrets (ADMIN_TOKEN, SMTP); DOMAIN comes from
#   vaultwarden-site-url. No SSO: the vault keeps its own accounts
#
# Network: DMZ zone (VLAN 610, 10.6.0.0/24)
# Firewall: ports 22 (SSH) + 8222 (VaultWarden HTTP)
# Secrets: Auto-generated ADMIN_TOKEN on first boot
# Backups: Daily vault data backup, 30-day retention
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning - change versions here only
  versions = {
    vaultwardenPkg = pkgs.vaultwarden;
  };

  # The site's own values (#769), not ours to guess: update-os.sh deploys the
  # module's config beside this file as /etc/nixos/vaultwarden.json, with the
  # name the proxy publishes it under and whether that name has a public record
  # (#715) — the logging.nix idiom. Unpublished, there is no https URL, so
  # DOMAIN is the honest internal address.
  moduleCfg   = if builtins.pathExists ./vaultwarden.json
                then builtins.fromJSON (builtins.readFile ./vaultwarden.json)
                else {};
  proxyCfg    = (moduleCfg.config or {})."network:proxy" or {};
  proxyDomain = proxyCfg.proxyDomain or (moduleCfg.proxyDomain or "");
  published   = proxyDomain != "" && (moduleCfg.proxyPublished or true);
  port        = 8222;
  domain      = if published then "https://${proxyDomain}"
                else "http://${moduleCfg.vmname or "vaultwarden"}.${moduleCfg.zone0 or "dmz"}.internal:${toString port}";
  siteEnv     = "/etc/secrets/vaultwarden-site.env";
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

  networking.hostName = let
    cfg = if builtins.pathExists ./vaultwarden.json
          then builtins.fromJSON (builtins.readFile ./vaultwarden.json)
          else {};
  in lib.mkDefault (cfg.vmname or "vaultwarden");

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      8222  # VaultWarden HTTP API
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
  environment.systemPackages = with pkgs; [ jq openssl ];

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
  # VAULTWARDEN PASSWORD MANAGER
  # ============================================================================

  services.vaultwarden = {
    enable = true;
    package = versions.vaultwardenPkg;
    backupDir = "/var/backup/vaultwarden";

    # ADMIN_TOKEN and SMTP: generated on first boot (generate-vaultwarden-secrets
    # below). DOMAIN: vaultwarden-site-url. Later files win, so its DOMAIN
    # replaces the placeholder older installs wrote into the first.
    environmentFile = [ "/var/lib/vaultwarden/vaultwarden.env" siteEnv ];

    config = {
      SIGNUPS_ALLOWED = false;

      # Listen on every address, both families — Caddy reaches it over IPv6
      # where the zone has it (ADR-030 D9)
      ROCKET_ADDRESS = "::";
      ROCKET_PORT = port;
      ROCKET_LOG = "critical";

      # DOMAIN, ADMIN_TOKEN and SMTP_* are set via environmentFile
    };
  };

  # ============================================================================
  # SITE URL — no SSO
  # ============================================================================
  #
  # Vaultwarden is deliberately NOT behind the site's single sign-on: the
  # password vault must not open with — or stop opening without — the identity
  # provider, so it keeps its own accounts and master passwords. #769 had wired
  # identity:identity's OIDC client into SSO_*; that is withdrawn (0.6.0).
  #
  # This unit writes the one site value Vaultwarden needs, DOMAIN (https on the
  # published name, else the internal address), and pins SSO_ENABLED=false so
  # nothing an older install wrote can turn it back on. The file is loaded after
  # vaultwarden.env, whose placeholder DOMAIN older installs still carry, and is
  # always written: Vaultwarden's EnvironmentFile list does not tolerate a missing
  # one. The OIDC client identity:identity left in /etc/secrets/vaultwarden.env
  # is removed — its Authentik application is gone with the dependency.
  systemd.services.vaultwarden-site-url = {
    description = "Write Vaultwarden's site URL";
    wantedBy = [ "multi-user.target" ];
    before = [ "vaultwarden.service" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -uo pipefail
      PATH="${pkgs.coreutils}/bin:${pkgs.systemd}/bin:$PATH"
      OUT=${siteEnv}
      mkdir -p /etc/secrets
      rm -f /etc/secrets/vaultwarden.env /etc/secrets/vaultwarden-sso.env

      NEW="DOMAIN=${domain}"$'\n'"SSO_ENABLED=false"$'\n'
      OLD="$(cat "$OUT" 2>/dev/null || true)"
      if [ ! -f "$OUT" ] || [ "$OLD"$'\n' != "$NEW" ]; then
        T="$(mktemp /etc/secrets/.vaultwarden-site.XXXXXX)"
        printf '%s' "$NEW" > "$T"
        chmod 600 "$T"
        mv -f "$T" "$OUT"
        echo "vaultwarden-site-url: DOMAIN=${domain} — updated"
        # --no-block: vaultwarden is ordered after this unit.
        systemctl try-restart --no-block vaultwarden.service || true
      else
        echo "vaultwarden-site-url: DOMAIN=${domain} — no change"
      fi
    '';
  };

  systemd.services.vaultwarden = {
    wants = [ "vaultwarden-site-url.service" "vaultwarden-smtp-unset-empty.service" ];
    after = [ "vaultwarden-site-url.service" "vaultwarden-smtp-unset-empty.service" ];
  };

  # ============================================================================
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.generate-vaultwarden-secrets = {
    description = "Generate VaultWarden secrets if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "vaultwarden.service" ];

    unitConfig.ConditionPathExists = "!/var/lib/vaultwarden/vaultwarden.env";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-vaultwarden-secrets" ''
        ADMIN_TOKEN="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        ${pkgs.coreutils}/bin/mkdir -p /var/lib/vaultwarden
        ${pkgs.coreutils}/bin/chown vaultwarden:vaultwarden /var/lib/vaultwarden

        cat > /var/lib/vaultwarden/vaultwarden.env <<EOF
# VaultWarden secrets - auto-generated on first boot
# Edit the SMTP settings for your deployment. DOMAIN is not set here: it is
# the site's, written by vaultwarden-site-url.
ADMIN_TOKEN=$ADMIN_TOKEN

# SMTP configuration - uncomment and fill in for your mail server.
# Leave SMTP_HOST commented while there is none: an empty value still turns
# mail on, and every mail-sending action then fails.
# See: https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration
# SMTP_HOST=smtp.example.com
# SMTP_PORT=587
# SMTP_SECURITY=starttls
# SMTP_FROM=vaultwarden@example.com
# SMTP_FROM_NAME=TAPPaaS VaultWarden
# SMTP_USERNAME=
# SMTP_PASSWORD=
EOF
        ${pkgs.coreutils}/bin/chmod 600 /var/lib/vaultwarden/vaultwarden.env
        ${pkgs.coreutils}/bin/chown vaultwarden:vaultwarden /var/lib/vaultwarden/vaultwarden.env

        echo "================================================"
        echo "VAULTWARDEN ADMIN TOKEN generated and saved to:"
        echo "/var/lib/vaultwarden/vaultwarden.env"
        echo "To view: sudo cat /var/lib/vaultwarden/vaultwarden.env"
        echo "================================================"
      '';
    };
  };

  # Installs before this fix wrote `SMTP_HOST=` (empty). Vaultwarden reads an
  # empty value as a host, so mail is on: account creation and new-device mail
  # fail with "failed to lookup address information" (hrossen, 2026-10-06).
  # Comment the SMTP block out while SMTP_HOST is empty; a real host is kept.
  systemd.services.vaultwarden-smtp-unset-empty = {
    description = "Disable VaultWarden mail while SMTP_HOST is empty";
    wantedBy = [ "multi-user.target" ];
    after = [ "generate-vaultwarden-secrets.service" ];
    before = [ "vaultwarden.service" ];
    unitConfig.ConditionPathExists = "/var/lib/vaultwarden/vaultwarden.env";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ENV=/var/lib/vaultwarden/vaultwarden.env
      if ${pkgs.gnugrep}/bin/grep -qE '^SMTP_HOST=[[:space:]]*$' "$ENV"; then
        ${pkgs.gnused}/bin/sed -i 's/^SMTP_/# SMTP_/' "$ENV"
        echo "vaultwarden-smtp-unset-empty: SMTP_HOST was empty — SMTP block commented out"
      fi
    '';
  };

  # ============================================================================
  # BACKUP STRATEGY
  # ============================================================================

  # The built-in services.vaultwarden.backupDir enables the upstream backup
  # service which copies the SQLite database to /var/backup/vaultwarden daily.
  #
  # It also runs at boot, and on a fresh VM that is before vaultwarden has
  # written anything: its `cp /var/lib/vaultwarden/!(db.*)` matches nothing and
  # fails, so the first activation fails and the install rolls back (hrossen,
  # 2026-10-04). Nothing to back up yet is not a failure: wait for the database.
  # No ordering added: upstream already starts vaultwarden after this backup,
  # and `after = vaultwarden` closed a cycle systemd broke by dropping the job.
  systemd.services.backup-vaultwarden.unitConfig.ConditionPathExists =
    "/var/lib/vaultwarden/db.sqlite3";

  # Daily backup archive of vault data + environment (03:00)
  systemd.services.vaultwarden-backup-archive = {
    description = "Archive VaultWarden backup data";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "vaultwarden-backup-archive" ''
        TIMESTAMP=$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S)
        ARCHIVE_DIR="/var/backup/vaultwarden-archives"
        ${pkgs.coreutils}/bin/mkdir -p "$ARCHIVE_DIR"

        ${pkgs.gnutar}/bin/tar -czf "$ARCHIVE_DIR/vaultwarden-backup-$TIMESTAMP.tar.gz" \
          -C / \
          var/backup/vaultwarden \
          var/lib/vaultwarden/vaultwarden.env \
          2>/dev/null || true

        ${pkgs.coreutils}/bin/chmod 600 "$ARCHIVE_DIR/vaultwarden-backup-$TIMESTAMP.tar.gz"
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.vaultwarden-backup-archive = {
    description = "Daily VaultWarden backup archive timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  # Cleanup old backups - 30 day retention
  systemd.services.cleanup-backups = {
    description = "Cleanup old VaultWarden backups";
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
    "d /var/backup/vaultwarden 0700 vaultwarden vaultwarden -"
    "d /var/backup/vaultwarden-archives 0700 root root -"
    "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -"
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
