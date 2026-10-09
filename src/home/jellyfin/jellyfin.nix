# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Jellyfin Media Server
# ============================================================================
# Self-contained NixOS configuration -- used directly as nixos-config by
# update-os.sh during install and subsequent nixos-rebuild switch calls.
#
# Storage: the media library is NOT in this VM. /media is the subdir jellyfin
# of the share "media" (storage:nfs, ADR-029 v0.8), mounted by name as
# nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin — the site's server
# declares the share, jellyfin.json the mount, and the service writes it into
# /etc/nixos/tappaas-nfs.nix, which the baseline imports. Until a server
# declares "media" the mount is pending and /media is a directory on this VM's
# own disk; when the share arrives the service migrates its content in
# (rebootOk in jellyfin.json is the consent). The VM
# stays small (OS + Jellyfin's own data on tanka1); the library has its own
# lifecycle and survives the VM.
#
# Library folders under /media (created by update.sh, on the share or locally —
# on the share every write is squashed to its owner, so tmpfiles could not
# chown them to jellyfin anyway):
#   Movies/  TV/  Music/  Photos/  Audiobooks/
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  # -- SSO-Auth plugin (OIDC "Sign in with Authentik", #806) ------------------
  # 9p4/jellyfin-plugin-sso, pinned: upstream is archived, 4.0.0.4 is its last
  # release and targets Jellyfin 10.11. A store path of its own, so the closure
  # (and the security scan) names it. Hash = the release's published sha256.
  ssoPluginVersion = "4.0.0.4";
  ssoPlugin = pkgs.runCommand "jellyfin-plugin-sso-${ssoPluginVersion}" {
    nativeBuildInputs = [ pkgs.unzip ];
    src = pkgs.fetchurl {
      url  = "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${ssoPluginVersion}/sso-authentication_${ssoPluginVersion}.zip";
      hash = "sha256-wJ8WujEFmkNN3X+BHk+WCNS0xFFMyApb8cozvuYeEQc=";
    };
  } ''
    mkdir -p $out
    unzip -q $src -d $out
  '';

  # Writes the "authentik" provider into the plugin's config and the login
  # button into Jellyfin's branding, keeping everything else in both files
  # (the plugin records its account links in the same file). Prints "changed"
  # when it wrote anything. Run with Jellyfin stopped: both files are rewritten
  # by Jellyfin from memory when it saves them.
  ssoConfigure = pkgs.writeText "jellyfin-sso-configure.py" ''
    import os, sys
    import xml.etree.ElementTree as ET

    plugin_xml, branding_xml = sys.argv[1], sys.argv[2]
    PROVIDER = "authentik"
    discovery = os.environ["OIDC_DISCOVERY_URI"]
    suffix = ".well-known/openid-configuration"
    endpoint = discovery[: -len(suffix)] if discovery.endswith(suffix) else discovery

    # OidConfig fields, in the plugin's declaration order (XmlSerializer).
    # Lists are string[]; None leaves the field out (null). Access is decided by
    # Authentik (the app's group binding), so Roles stays empty; "admin" in the
    # groups claim (members of jellyfin-admins) makes a Jellyfin administrator.
    FIELDS = [
        ("OidEndpoint", endpoint),
        ("OidClientId", os.environ["OIDC_CLIENT_ID"]),
        ("OidSecret", os.environ["OIDC_CLIENT_SECRET"]),
        ("Enabled", "true"),
        ("EnableAuthorization", "true"),
        ("EnableAllFolders", "true"),
        ("EnabledFolders", []),
        ("AdminRoles", ["admin"]),
        ("Roles", []),
        ("EnableFolderRoles", "false"),
        ("EnableLiveTvRoles", "false"),
        ("EnableLiveTv", "false"),
        ("EnableLiveTvManagement", "false"),
        ("LiveTvRoles", []),
        ("LiveTvManagementRoles", []),
        ("FolderRoleMapping", []),
        ("RoleClaim", "groups"),
        ("OidScopes", ["email", "groups"]),
        # Caddy terminates TLS; the plugin builds its redirect URI from the
        # (preserved) Host and this scheme.
        ("SchemeOverride", "https"),
        ("NewPath", "true"),
        ("DefaultUsernameClaim", "preferred_username"),
        ("DisableHttps", "false"),
        ("DisablePushedAuthorization", "false"),
        ("DoNotValidateEndpoints", "false"),
        ("DoNotValidateIssuerName", "false"),
        ("DoNotLoadProfile", "false"),
    ]
    XSI = "http://www.w3.org/2001/XMLSchema-instance"
    ET.register_namespace("xsi", XSI)
    ET.register_namespace("xsd", "http://www.w3.org/2001/XMLSchema")

    def load(path, root_tag):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            tree = ET.parse(path)
            return tree, ET.tostring(tree.getroot())
        return ET.ElementTree(ET.Element(root_tag)), b""

    def child(parent, tag):
        el = parent.find(tag)
        if el is None:
            el = ET.SubElement(parent, tag)
        return el

    # -- plugin config -------------------------------------------------------
    # Only the fields above are set, in place: whatever else the plugin keeps
    # in the entry -- CanonicalLinks (its account links), nil fields -- stays,
    # so a re-run with nothing new writes nothing and restarts nothing.
    tree, before = load(plugin_xml, "PluginConfiguration")
    root = tree.getroot()
    child(root, "SamlConfigs")
    oids = child(root, "OidConfigs")
    cfg = None
    for it in oids.findall("item"):
        if (it.findtext("key/string") or "") == PROVIDER:
            cfg = child(child(it, "value"), "OidConfig")
            break
    if cfg is None:
        item = ET.SubElement(oids, "item")
        ET.SubElement(ET.SubElement(item, "key"), "string").text = PROVIDER
        cfg = ET.SubElement(ET.SubElement(item, "value"), "OidConfig")
    for name, value in FIELDS:
        el = cfg.find(name)
        if isinstance(value, list):
            have = None if el is None else [s.text or "" for s in el.findall("string")]
            if have == value and (el is None or len(el) == len(value)):
                continue
            if el is None:
                el = ET.SubElement(cfg, name)
            el.attrib.clear()
            for c in list(el):
                el.remove(c)
            for v in value:
                ET.SubElement(el, "string").text = v
        else:
            if el is not None and el.text == value and not el.attrib:
                continue
            if el is None:
                el = ET.SubElement(cfg, name)
            el.attrib.clear()
            el.text = value
    if cfg.find("CanonicalLinks") is None:
        ET.SubElement(cfg, "CanonicalLinks")
    changed = ET.tostring(root) != before
    if changed:
        os.makedirs(os.path.dirname(plugin_xml), exist_ok=True)
        tree.write(plugin_xml, encoding="utf-8", xml_declaration=True)

    # -- login button --------------------------------------------------------
    BUTTON = ('<form action="/sso/OID/start/' + PROVIDER + '">'
              '<button class="raised block emby-button button-submit">'
              "Sign in with Authentik</button></form>")
    CSS = ".disclaimerContainer { display: block; }"
    btree, bbefore = load(branding_xml, "BrandingOptions")
    broot = btree.getroot()
    child(broot, "LoginDisclaimer").text = BUTTON
    css = child(broot, "CustomCss")
    if CSS not in (css.text or ""):
        css.text = ((css.text or "").rstrip() + "\n" + CSS).strip()
    if broot.find("SplashscreenEnabled") is None:
        ET.SubElement(broot, "SplashscreenEnabled").text = "false"
    if ET.tostring(broot) != bbefore:
        btree.write(branding_xml, encoding="utf-8", xml_declaration=True)
        changed = True

    print("changed" if changed else "unchanged")
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
  # This file states only what jellyfin adds or changes.

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "jellyfin";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 8096 8920 ];
  };

  # -- SSH: keys only (the baseline's defaults allow passwords) ----------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  # -- Packages --------------------------------------------------------------
  # vim, wget, curl, htop and git come from the baseline.
  # NFS client support comes with the mount (tappaas-nfs.nix).
  environment.systemPackages = with pkgs; [ jq ];

  # -- Jellyfin media server -------------------------------------------------
  services.jellyfin = {
    enable    = true;
    openFirewall = true;
    dataDir   = "/var/lib/jellyfin";
    cacheDir  = "/var/cache/jellyfin";
  };

  # -- SSO-Auth plugin + "Sign in with Authentik" (identity:identity, #806) ----
  # The published name is gated by Authentik forward-auth (#805); this plugin
  # turns the second login into one click with the same Authentik session.
  # Jellyfin rewrites a plugin's meta.json, so the plugin is COPIED from the
  # store into its directory (a symlink would be read-only), and only when the
  # store path changed. Older copies are removed so one version loads.
  systemd.services.jellyfin.preStart = ''
    plugins=${config.services.jellyfin.dataDir}/plugins
    target="$plugins/SSO-Auth_${ssoPluginVersion}"
    mkdir -p "$plugins"
    for old in "$plugins"/SSO-Auth_*; do
      [ -e "$old" ] && [ "$old" != "$target" ] && rm -rf "$old"
    done
    if [ "$(cat "$target/.tappaas-src" 2>/dev/null)" != "${ssoPlugin}" ]; then
      rm -rf "$target"
      cp -r ${ssoPlugin} "$target"
      chmod -R u+w "$target"
      echo "${ssoPlugin}" > "$target/.tappaas-src"
    fi
  '';

  # identity:identity writes OIDC_CLIENT_ID / _SECRET / _DISCOVERY_URI into
  # /etc/secrets/jellyfin.env and restarts this unit. It writes them into the
  # plugin's and the branding's XML -- no Jellyfin admin password or API key is
  # needed -- and restarts Jellyfin only when something changed.
  systemd.services.jellyfin-configure-oidc = {
    description = "Configure Authentik sign-in (SSO-Auth plugin) in Jellyfin";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "jellyfin.service" ];
    unitConfig.ConditionPathExists = [ "/etc/secrets/jellyfin.env" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/etc/secrets/jellyfin.env";
    };
    path = [ pkgs.python3 pkgs.systemd pkgs.coreutils ];
    script = ''
      set -euo pipefail
      data=${config.services.jellyfin.dataDir}
      plugin_xml="$data/plugins/configurations/SSO-Auth.xml"
      branding_xml="${config.services.jellyfin.configDir}/branding.xml"
      # Jellyfin saves both files from memory: write them while it is stopped,
      # then start it. A dry run on copies first -- nothing to write, nothing
      # stopped.
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      cp "$plugin_xml" "$tmp/plugin.xml" 2>/dev/null || true
      cp "$branding_xml" "$tmp/branding.xml" 2>/dev/null || true
      if [ "$(python3 ${ssoConfigure} "$tmp/plugin.xml" "$tmp/branding.xml")" = unchanged ]; then
        echo "jellyfin-configure-oidc: provider 'authentik' and login button already in place"
        exit 0
      fi
      was_active=0
      systemctl is-active --quiet jellyfin.service && was_active=1
      systemctl stop jellyfin.service
      python3 ${ssoConfigure} "$plugin_xml" "$branding_xml" >/dev/null
      chown jellyfin:jellyfin "$plugin_xml" "$branding_xml"
      chmod 600 "$plugin_xml" "$branding_xml"
      echo "jellyfin-configure-oidc: provider 'authentik' and login button written"
      [ "$was_active" -eq 1 ] && systemctl start jellyfin.service || true
    '';
  };

  # -- VAAPI hardware transcoding --------------------------------------------
  hardware.graphics.enable = true;
  users.users.jellyfin.extraGroups = [ "render" "video" ];

  system.stateVersion = "25.05";
}
