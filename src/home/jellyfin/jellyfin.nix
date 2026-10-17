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
  # Jellyfin 12 comes from nixos-unstable: the pinned release only has 10.11,
  # which gets no more upstream releases and misses fixes that are only in 12
  # (#850). Only the package is taken from it -- it brings its own jellyfin-web
  # and jellyfin-ffmpeg; the service module stays the pinned release's. Drop
  # this once the pinned release carries Jellyfin 12 (NixOS 26.11).
  # Bump: new rev + `nix-prefetch-url --unpack <url>`.
  unstableSrc = builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/55bfb4d7437bd4e09ab7cba58a43bd68eb310044.tar.gz";
    sha256 = "02sljlk6abwqsx32nhjmfbm7hki7nvcsg442ldp0yx9f5qz0c5lc";
  };
  unstable = import unstableSrc { inherit (pkgs.stdenv.hostPlatform) system; };

  # jellyfin-ffmpeg 8.1.3-1 (#807): FFmpeg 8.1.3 fixes the decoder and demuxer
  # flaws open in 8.1.2-5 (VobSub, ADX, TDSC, TY, MACE, DVB subtitles, CFHD,
  # RTP/ASF, the HLS playlist loop). nixpkgs has it (#573402, via staging-next),
  # the nixos-unstable channel not yet: until it does, the pinned package with
  # the new source. jellyfin's own patch series comes from that source
  # (postPatch). Drop this when unstableSrc carries 8.1.3 or later.
  jellyfinFfmpeg = unstable.jellyfin-ffmpeg.overrideAttrs (old: rec {
    version = "8.1.3-1";
    src = unstable.fetchFromGitHub {
      owner = "jellyfin";
      repo  = "jellyfin-ffmpeg";
      tag   = "v${version}";
      hash  = "sha256-sxJyUaB0rqpVzd6OVRC6kPVWyBdgFUzvyqwLCkMKRgM=";
    };
    # The pinned ffmpeg adds an 8.1.2 fix that 8.1.3 already contains (the
    # swscale loongarch underflow); applied again it fails.
    patches = builtins.filter (p: !(unstable.lib.hasInfix "swscale-loongarch-fix-buffer-underflow" (toString p)))
      (old.patches or [ ]);
  });

  # -- SSO-Auth plugin (OIDC "Sign in with Authentik", #806) ------------------
  # K0lin/jellyfin-plugin-sso, the maintained continuation of the archived
  # 9p4 plugin (same plugin id, same configuration). 5.1.x targets Jellyfin
  # 12; it also gives every account it creates or links a random password, so
  # an SSO account cannot be signed into with an empty password. A store path
  # of its own, so the closure (and the security scan) names it. Hash = the
  # release's published sha256.
  ssoPluginVersion = "5.1.1";
  ssoPlugin = pkgs.runCommand "jellyfin-plugin-sso-${ssoPluginVersion}" {
    nativeBuildInputs = [ pkgs.unzip ];
    src = pkgs.fetchurl {
      url  = "https://github.com/K0lin/jellyfin-plugin-sso/releases/download/v${ssoPluginVersion}/sso-authentication_${ssoPluginVersion}.zip";
      hash = "sha256-2xJrR2O9o6N1T6IQMjL8A+8b+SnP7aNfLprznIdSM7E=";
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

    # OidConfig fields, in the plugin's declaration order, by their XML names.
    # The class is [XmlRoot("PluginConfiguration")], so each provider's value
    # is a nested <PluginConfiguration>, and FolderRoleMapping serializes as
    # FolderRoleMappings. Anything else and Jellyfin silently replaces the file
    # with an empty default on load (#806, found live on hrossen).
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
        ("FolderRoleMappings", []),
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
            cfg = child(child(it, "value"), "PluginConfiguration")
            break
    if cfg is None:
        item = ET.SubElement(oids, "item")
        ET.SubElement(ET.SubElement(item, "key"), "string").text = PROVIDER
        cfg = ET.SubElement(ET.SubElement(item, "value"), "PluginConfiguration")
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

  # The module's deployed config, shipped beside this file by update-os.sh as
  # /etc/nixos/jellyfin.json: proxySourceV6 is the firewall's IPv6 address in
  # this zone, where Caddy's requests come from over IPv6 (ADR-030 D9).
  moduleCfg = if builtins.pathExists ./jellyfin.json
              then builtins.fromJSON (builtins.readFile ./jellyfin.json)
              else {};
  proxySourceV6 = moduleCfg.proxySourceV6 or "";

  # network.xml: EnableIPv6 (Jellyfin listens on IPv6 only with it, and Caddy
  # reaches it over IPv6 where the zone has it, ADR-030 D9), and KnownProxies --
  # the firewall's addresses in this zone, where every published request comes
  # from. Jellyfin then takes the client's address from X-Forwarded-For (which
  # Caddy sets from the real connection), so a user's remote-access policy and
  # the login lockout see the client, not the firewall (ADR-032 D3). Sets those
  # two and keeps the rest; a missing file is created with them alone, which
  # Jellyfin reads as its defaults plus these.
  networkSettings = pkgs.writeText "jellyfin-network.py" ''
    import os, sys
    import xml.etree.ElementTree as ET
    path, proxies = sys.argv[1], [a for a in sys.argv[2:] if a]
    tree = ET.parse(path) if os.path.exists(path) else ET.ElementTree(ET.Element("NetworkConfiguration"))
    root = tree.getroot()
    before = ET.tostring(root)
    el = root.find("EnableIPv6")
    if el is None:
        el = ET.SubElement(root, "EnableIPv6")
    el.text = "true"
    kp = root.find("KnownProxies")
    if kp is None:
        kp = ET.SubElement(root, "KnownProxies")
    if [s.text for s in kp.findall("string")] != proxies:
        for c in list(kp):
            kp.remove(c)
        for a in proxies:
            ET.SubElement(kp, "string").text = a
    if ET.tostring(root) != before:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tree.write(path, encoding="utf-8", xml_declaration=True)
  '';

  # The TAPPaaS API key and the policy it keeps (ADR-032 D3). Jellyfin's API
  # keys are rows in its database; one named TAPPaaS is added once (while
  # Jellyfin runs: it looks keys up per request) and kept root-only on the VM.
  # With it, the break-glass account `admin` is kept from signing in from
  # outside the site -- Jellyfin is published without the Authentik gate, and
  # admin's password would otherwise face the internet.
  apiKeyFile = "/var/lib/jellyfin-tappaas/api-key";
  jellyfinPolicy = pkgs.writeShellScript "jellyfin-tappaas-policy" ''
    set -euo pipefail
    db=${config.services.jellyfin.dataDir}/data/jellyfin.db
    # As the jellyfin user: a write as root could leave the database's -wal and
    # -shm files root's, and Jellyfin unable to write its own database.
    sql() { runuser -u jellyfin -- sqlite3 -cmd ".timeout 10000" "$db" "$@"; }
    install -d -m 0700 "$(dirname ${apiKeyFile})"
    key="$(cat ${apiKeyFile} 2>/dev/null || true)"
    if [ -z "$key" ] || [ "$(sql "SELECT count(*) FROM ApiKeys WHERE AccessToken = '$key';")" != 1 ]; then
      key="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      sql "INSERT INTO ApiKeys (DateCreated, DateLastActivity, Name, AccessToken) VALUES (strftime('%Y-%m-%d %H:%M:%f','now'), strftime('%Y-%m-%d %H:%M:%f','now'), 'TAPPaaS', '$key');"
      ( umask 077; printf '%s' "$key" > ${apiKeyFile} )
      echo "jellyfin-tappaas-policy: API key TAPPaaS created"
    fi
    api="http://localhost:8096"
    auth="Authorization: MediaBrowser Token=\"$key\""
    for _ in $(seq 1 60); do curl -sf "$api/health" >/dev/null && break; sleep 2; done
    admin="$(curl -sf -H "$auth" "$api/Users" | jq -c '.[] | select(.Name == "admin")')"
    if [ -z "$admin" ]; then echo "jellyfin-tappaas-policy: no user admin"; exit 0; fi
    if [ "$(jq -r '.Policy.EnableRemoteAccess' <<<"$admin")" = true ]; then
      jq -c '.Policy | .EnableRemoteAccess = false' <<<"$admin" \
        | curl -sf -X POST -H "$auth" -H 'Content-Type: application/json' -d @- \
            "$api/Users/$(jq -r .Id <<<"$admin")/Policy" >/dev/null
      echo "jellyfin-tappaas-policy: admin may no longer sign in from outside the site"
    else
      echo "jellyfin-tappaas-policy: admin signs in from the site only (unchanged)"
    fi
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
  environment.systemPackages = with pkgs; [ jq sqlite ];

  # -- Jellyfin media server -------------------------------------------------
  services.jellyfin = {
    enable    = true;
    package   = unstable.jellyfin.override { jellyfin-ffmpeg = jellyfinFfmpeg; };
    openFirewall = true;
    dataDir   = "/var/lib/jellyfin";
    cacheDir  = "/var/cache/jellyfin";
  };

  # -- SSO-Auth plugin + "Sign in with Authentik" (identity:identity, #806) ----
  # The published name has no Authentik gate in front (ADR-032 D3: Jellyfin's
  # apps must work for friends and family), so this is how a person signs in on
  # the web; an app or a TV signs in with a Quick Connect code approved from
  # such a session. Who may use Jellyfin is the Authentik group bound to its app.
  # Jellyfin rewrites a plugin's meta.json, so the plugin is COPIED from the
  # store into its directory (a symlink would be read-only), and only when the
  # store path changed. Older copies are removed so one version loads.
  systemd.services.jellyfin.preStart = ''
    # Jellyfin 12 makes user names case-insensitive, and its database
    # migration fails on two users whose names differ only in case. Name them
    # here, before Jellyfin starts, instead of a failed migration in its log.
    db=${config.services.jellyfin.dataDir}/data/jellyfin.db
    if [ -s "$db" ]; then
      clash="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "SELECT group_concat(Username, ' / ') FROM Users GROUP BY lower(Username) HAVING count(*) > 1;" 2>/dev/null || true)"
      if [ -n "$clash" ]; then
        echo "jellyfin: user names that differ only in case: $clash -- rename or remove one of each pair, then start Jellyfin again" >&2
        exit 1
      fi
    fi
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
    gw4="$(${pkgs.iproute2}/bin/ip -4 route show default | ${pkgs.gawk}/bin/awk '{print $3; exit}')"
    ${pkgs.python3}/bin/python3 ${networkSettings} ${config.services.jellyfin.configDir}/network.xml "$gw4" "${proxySourceV6}"
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

  systemd.services.jellyfin-tappaas-policy = {
    description = "Jellyfin: the TAPPaaS API key, and admin kept to the site";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "jellyfin.service" ];
    requires    = [ "jellyfin.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.sqlite pkgs.curl pkgs.jq pkgs.coreutils pkgs.util-linux ];
    script = "${jellyfinPolicy}";
  };

  # -- VAAPI hardware transcoding --------------------------------------------
  hardware.graphics.enable = true;
  users.users.jellyfin.extraGroups = [ "render" "video" ];

  system.stateVersion = "25.05";
}
