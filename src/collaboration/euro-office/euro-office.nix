# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Euro-Office DocumentServer
# ============================================================================
# Version: 1.0.0
# Date: 2026-05-01
# Author: @AndreasJe (TAPPaaS)
# Product: Euro-Office DocumentServer (collaborative document editing)
#
# Architecture:
# - Single Podman container (ghcr.io/euro-office/documentserver:v9.3.7, pinned in nix)
# - Container bundles Nginx, PostgreSQL, Redis, RabbitMQ, DocService,
#   FileConverter, AdminPanel, and an example app internally
# - Only port 80 (Nginx) is exposed to the host; all other ports are internal
#
# Network: srv zone (VMID 343, tappaas1), firewall ports 22 (SSH) + 80 (HTTP)
# Secrets: Auto-generated JWT_SECRET (64-char hex) on first boot
# Backups: the whole VM, by the platform's Proxmox Backup job (backup:vm)
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

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

  # Read vmname from companion JSON (deployed by update-os.sh to /etc/nixos/euro-office.json).
  networking.hostName = let
    cfg = if builtins.pathExists ./euro-office.json
          then builtins.fromJSON (builtins.readFile ./euro-office.json)
          else {};
  in lib.mkDefault (cfg.vmname or "euro-office");

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22   # SSH
      80   # HTTP — Nginx inside the container handles all routing
      # Do NOT open 8000, 9000, 3000, 5432, 6379, 5672 — all internal to container
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
  # SECRETS AUTO-GENERATION
  # ============================================================================

  systemd.services.euro-office-init-secrets = {
    description = "Generate Euro-Office JWT secret if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];  # Ensure /etc is mounted before writing secrets

    # Only run once — skip if the secrets file already exists
    unitConfig.ConditionPathExists = "!/etc/secrets/euro-office.env";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "euro-office-init-secrets" ''
        # Generate a 64-character hex JWT secret
        JWT_SECRET="$(${pkgs.openssl}/bin/openssl rand -hex 32)"

        # Create secrets directory
        ${pkgs.coreutils}/bin/mkdir -p /etc/secrets

        # Write the secrets env file
        cat > /etc/secrets/euro-office.env <<EOF
JWT_SECRET=$JWT_SECRET
EOF
        ${pkgs.coreutils}/bin/chmod 600 /etc/secrets/euro-office.env

        echo "================================================"
        echo "Euro-Office JWT_SECRET generated and saved to:"
        echo "/etc/secrets/euro-office.env"
        echo "View anytime: sudo cat /etc/secrets/euro-office.env"
        echo "================================================"
      '';
    };
  };

  # ============================================================================
  # CONTAINER RUNTIME
  # ============================================================================

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # EURO-OFFICE CONTAINER
  # ============================================================================

  virtualisation.oci-containers.containers."euro-office" = {
    # Pinned to DocumentServer v9.3.5 (was v9.3.3). v9.3.4 could not generate
    # the presentation themes ("could not use 01_blank.pptx"): V8 crashed on
    # hosts whose CPU reports MPX (upstream #339), fixed in v9.3.5. Known open
    # risk: v9.3.5 binaries can stop with "CPU ISA level is lower than
    # required" on older vCPU models (upstream #415) — keep the VM on
    # cputype host, x86-64-v3 or better (hrossen: v4, clean 2026-10-15).
    # Immutable semver tag — NOT :latest/:nightly.
    # Keep in sync with update.sh; src/image-pins.json tracks both (#750).
    image = "ghcr.io/euro-office/documentserver:v9.3.7";

    environment = {
      ALLOW_PRIVATE_IP_ADDRESS = "true";
      EXAMPLE_ENABLED          = "false";
      ADMINPANEL_ENABLED       = "true";
    };

    # Secrets (JWT_SECRET) loaded from the auto-generated env file
    environmentFiles = [ "/etc/secrets/euro-office.env" ];

    ports = [
      "80:80"  # Host 80 → container Nginx 80
    ];

    volumes = [
      # The document server's data directory. Every euro-office release keeps it
      # at /var/www/euro-office/Data; this was mounted at the OnlyOffice path
      # (/var/www/onlyoffice/Data), so the volume stayed empty and the server's
      # secure_link_secret was regenerated whenever the container was recreated,
      # breaking download links in flight (found 2026-10-04). Documents
      # themselves live in Nextcloud, not here.
      "/var/lib/euro-office/data:/var/www/euro-office/Data"
      # Welcome/example surface, made replaceable so the splash page can be
      # pointed at the Nextcloud that consumes this document server (see
      # euro-office-init-welcome below). Bind-mounted, so rewriting the host
      # file + `nginx -s reload` takes effect without restarting the container
      # and interrupting live editing sessions.
      "/etc/euro-office/ds-example.conf:/etc/nginx/includes/ds-example.conf:ro"
    ];
  };

  # Ensure the container starts only after secrets and the welcome include exist.
  # The include MUST exist before first start: podman would otherwise create a
  # DIRECTORY at the bind-mount source, and nginx would fail to load it.
  systemd.services."podman-euro-office" = {
    requires = [ "euro-office-init-secrets.service" "euro-office-init-welcome.service" ];
    after    = [ "euro-office-init-secrets.service" "euro-office-init-welcome.service" ];
  };

  # ============================================================================
  # WELCOME PAGE INCLUDE
  # ============================================================================
  #
  # The stock image serves a "Docs installed — now integrate me" splash at
  # /welcome/ (and redirects / to it). On a TAPPaaS deployment that page is
  # noise: the document server exists only to serve a Nextcloud, and when the
  # module is published the splash is reachable from the internet.
  #
  # This seeds the include with the stock behaviour, so nothing changes until a
  # consumer wires it. The nextcloud:fileservice provider then rewrites this file
  # to redirect /welcome/ at the Nextcloud it just connected — it is the side
  # that knows the Nextcloud public URL (ADR-COM-0002: the provider owns the
  # wiring, URLs derived from the manifests).
  #
  # Only ds-example.conf is replaced — never ds-docservice.conf, which carries
  # the actual document service routing.
  #
  # Written if ABSENT only, so a wired redirect survives a rebuild.
  systemd.services.euro-office-init-welcome = {
    description = "Seed the Euro-Office welcome nginx include";
    wantedBy = [ "multi-user.target" ];
    after    = [ "local-fs.target" ];

    unitConfig.ConditionPathExists = "!/etc/euro-office/ds-example.conf";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "euro-office-init-welcome" ''
        ${pkgs.coreutils}/bin/mkdir -p /etc/euro-office
        cat > /etc/euro-office/ds-example.conf <<'EOF'
# Seeded by euro-office-init-welcome (stock behaviour: serve the splash page).
# Replaced by nextcloud:fileservice update-service.sh with a redirect to the
# Nextcloud this document server serves. The stock /example/ block is omitted
# deliberately — EXAMPLE_ENABLED=false, so the example app is not running.
location ~ ^(\/welcome\/.*)$ {
  expires 365d;
  alias /var/www/euro-office/documentserver-example$1;
  index docker.html;
}
EOF
        ${pkgs.coreutils}/bin/chmod 644 /etc/euro-office/ds-example.conf
      '';
    };
  };

  # ============================================================================
  # BACKUP
  # ============================================================================
  #
  # The platform's: backup:vm puts the whole VM in the site's Proxmox Backup job,
  # without stopping anything. The data volume holds only the server's
  # secure_link_secret, which it regenerates when missing; documents live in
  # Nextcloud. The nightly stop-tar-start this module ran until 2026-10 took the
  # editor down to copy that one file, and went (#754).

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    # Owned as the image owns its Data directory: user and group `ds` (105:107
    # in the image), setgid. root:root 0700 here would lock the container's
    # `ds` out of its own directory, and `d` re-applies it on every boot.
    "d /var/lib/euro-office/data  2775 105 107 -"
    "R /var/backup/euro-office    - - - -"           # the in-VM backup's leftovers (#754)
  ];

  # ============================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # See: https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion
  # ============================================================================

  system.stateVersion = "25.05";
}
