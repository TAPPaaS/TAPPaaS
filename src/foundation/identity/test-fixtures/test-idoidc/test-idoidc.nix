# Identity OIDC test webserver — identity/test.sh --deep.
#
# A small NixOS HTTP server (port 8080) that, unlike the forward-auth fixture, is
# NOT gated — Caddy proxies straight through, so the marker IS reachable. The
# identity:identity install-service writes /etc/secrets/test-idoidc.env
# (OIDC_CLIENT_ID/SECRET/DISCOVERY_URI) and restarts the configure unit below
# (named per the <base>-configure-oidc.service convention so no module-JSON
# declaration is needed). That unit validates the delivered OIDC env — proving
# the env reached the VM AND the OIDC provider is live + reachable — and writes a
# marker the deep test inspects. SELF-CONTAINED (no cross-dir imports).

{ config, lib, pkgs, modulesPath, system, ... }:

let
  webserverPort = 8080;
  marker = "tappaas-idoidc-ok";
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = "test-idoidc";
  networking.networkmanager.enable = true;

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  programs.ssh.startAgent = true;

  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  services.qemuGuest.enable = true;
  boot.growPartition = lib.mkDefault true;

  networking.firewall.allowedTCPPorts = [ webserverPort ];
  environment.etc."tappaas-test-www/index.html".text = "${marker}\n";

  systemd.services.tappaas-idoidc-web = {
    description = "TAPPaaS identity OIDC test webserver (port ${toString webserverPort})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString webserverPort} --directory /etc/tappaas-test-www --bind 0.0.0.0";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      ReadOnlyPaths = [ "/etc/tappaas-test-www" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  # Validate the OIDC env the identity:identity install-service delivers. Gated on
  # the env file existing (so it's a no-op until install-service writes it and
  # restarts this unit — exercising the configureService-restart path). Writes
  # /var/lib/test-idoidc/oidc-verified with the client_id and whether the OIDC
  # discovery document is reachable+valid from the VM.
  systemd.services.test-idoidc-configure-oidc = {
    description = "Validate delivered OIDC env (identity:identity test)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "/etc/secrets/test-idoidc.env";
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/test-idoidc.env";
      ExecStart = pkgs.writeShellScript "test-idoidc-verify-oidc" ''
        set -uo pipefail
        out=/var/lib/test-idoidc
        mkdir -p "$out"
        {
          echo "client_id=''${OIDC_CLIENT_ID:-}"
          echo "discovery_uri=''${OIDC_DISCOVERY_URI:-}"
          if ${pkgs.curl}/bin/curl -fsS --max-time 15 "''${OIDC_DISCOVERY_URI:-}" -o /tmp/oidc-disc.json 2>/dev/null \
             && ${pkgs.jq}/bin/jq -e .issuer /tmp/oidc-disc.json >/dev/null 2>&1; then
            echo "discovery_reachable=yes"
            echo "issuer=$(${pkgs.jq}/bin/jq -r .issuer /tmp/oidc-disc.json)"
          else
            echo "discovery_reachable=no"
          fi
        } > "$out/oidc-verified"
      '';
    };
  };

  system.stateVersion = "25.05";
}
