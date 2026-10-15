# TAPPaaS — Euro-Office Nextcloud connector
# App ID: eurooffice | Requires: Nextcloud ≥ 33
# Source: https://github.com/Euro-Office/eurooffice-nextcloud
#
# UPDATING to a newer version: run ./update-eurooffice-app.sh
# Hashes to refresh:
#   src.hash        nix-prefetch-git (fetchSubmodules = false)
#   phpJwt sha256   nix-prefetch-url --unpack <github-archive-of-new-rev>
#   npmDepsHash     prefetch-npm-deps <src-path>/npm-shrinkwrap.json
#   documentFormats / documentTemplates: the submodule commits of the new tag
#
# PHP-JWT: since v11.0.6 upstream scopes php-jwt with mozart (upstream PR #213):
#   the app imports OCA\Eurooffice\Vendor\Firebase\JWT, found in
#   lib/Vendor/Firebase/JWT through the app's own PSR-4 mapping. We do the same
#   without composer (it segfaults on our hosts): copy php-jwt's src there and
#   rewrite its namespace. No vendor/ directory or composer autoloader is shipped.
#
# NODE: pinned to nodejs_22, which builds on both nixos-25.11 and nixos-26.05.
#   It was nodejs_20 until 26.05 marked that end-of-life and refused to evaluate
#   it, which stopped the estate's release move dead (the connector is the only
#   thing in the tree that pinned a Node). Do not "fix" a future refusal with
#   nixpkgs.config.permittedInsecurePackages: that ships a runtime with known
#   vulnerabilities to every site running Nextcloud, to avoid a version bump.
{ lib, stdenv, fetchgit, fetchurl, fetchNpmDeps, buildNpmPackage, nodejs_22 }:

let
  version = "11.0.6";

  src = fetchgit {
    url = "https://github.com/Euro-Office/eurooffice-nextcloud";
    rev = "v${version}";
    # fetchSubmodules causes submodule init to trigger git-lfs smudge on the
    # parent repo, which empties all files tracked by LFS. Fetch without
    # submodules so the main PHP/XML source files are present.
    hash = "sha256-pALbXwYyulyo6imr57AiPci5mIeZA5xdYI0/1BJI4jQ=";
    fetchSubmodules = false;
  };

  # Build Vite JS assets (9 entry points → js/)
  jsBuild = buildNpmPackage {
    pname = "eurooffice-nextcloud-js";
    inherit version src;
    nodejs = nodejs_22;
    npmDepsHash = "sha256-49bL+Nls0p3p74nUYH7MX3BZ5HBexER+wQmgwAWC94g=";
    dontNpmInstall = true;
    buildPhase = "npm run build";
    # @nextcloud/vite-config outputs bundles to js/ — expose that as $out
    installPhase = "cp -r js $out";
  };

  # assets/document-formats is a git submodule (Euro-Office/document-formats,
  # an ONLYOFFICE repo up to v11.0.5). fetchgit with fetchSubmodules=false
  # leaves the directory empty; fetch separately. Commit 46995828 is the
  # submodule pin in v11.0.6.
  documentFormats = builtins.fetchTarball {
    url = "https://github.com/Euro-Office/document-formats/archive/46995828084d4460112efec579499809f418ca6e.tar.gz";
    sha256 = "1pfsszzlasgxv31a5iqsijdn9m3hjb0c08dh09sv54a2wsqi3hf9";
  };

  # assets/document-templates is a git submodule (Euro-Office/document-templates,
  # an ONLYOFFICE repo up to v11.0.5). Also left empty by fetchSubmodules=false.
  # Commit d697ab3d is the submodule pin in v11.0.6.
  # Contains new/default/new.docx (and .pdf/.pptx/.xlsx; was default/ before the
  # Euro-Office fork, the app reads new/ since v11.0.6) served by the /empty endpoint
  # that euro-office uses during its health-check conversion round-trip.
  documentTemplates = builtins.fetchTarball {
    url = "https://github.com/Euro-Office/document-templates/archive/d697ab3d75dbec104e4a99f47852398752cb2ace.tar.gz";
    sha256 = "0499b4jrrk2hsjfsbjswkzff6kcyg69j4nq4mm4h837wmwqbx7gv";
  };

  # firebase/php-jwt v7.2.1 — the commit in v11.0.6's composer.lock (^7.0).
  # Uses builtins.fetchTarball (Nix daemon HTTP) to bypass the nixpkgs 25.11
  # fetchurl curl bug (curl binary missing from nativeBuildInputs).
  phpJwt = builtins.fetchTarball {
    url = "https://github.com/firebase/php-jwt/archive/0501f5729b9e2448516674aff07c7d1727869b8e.tar.gz";
    sha256 = "147x7z476ni2i5yxyvs2hk5hza5gb3pz838ahl8jrygipkrm0kdz";
  };

  # php-jwt scoped the way upstream's mozart step does it: src/ files under
  # Firebase/JWT with the namespace rewritten to OCA\Eurooffice\Vendor\Firebase\JWT.
  phpJwtScoped = stdenv.mkDerivation {
    name = "eurooffice-nextcloud-php-jwt-scoped-${version}";
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/Firebase/JWT
      cp ${phpJwt}/src/*.php $out/Firebase/JWT/
      cp ${phpJwt}/LICENSE   $out/Firebase/JWT/LICENSE
      sed -i 's/\bFirebase\\JWT/OCA\\Eurooffice\\Vendor\\Firebase\\JWT/g' $out/Firebase/JWT/*.php
      grep -q '^namespace OCA\\Eurooffice\\Vendor\\Firebase\\JWT;' $out/Firebase/JWT/JWT.php
      if grep -rq '^namespace Firebase\\JWT' $out/Firebase/JWT; then exit 1; fi
      runHook postInstall
    '';
  };

in
stdenv.mkDerivation {
  pname = "nextcloud-app-eurooffice";
  inherit version src;

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    for d in appinfo assets css img l10n lib licenses screenshots templates; do
      [ -d "$d" ] && cp -r "$d" "$out/$d"
    done
    # Populate the document-formats and document-templates submodules that fetchgit left empty
    cp -r "${documentFormats}"/. "$out/assets/document-formats/"
    cp -r "${documentTemplates}"/. "$out/assets/document-templates/"
    cp -r "${jsBuild}" "$out/js"
    mkdir -p "$out/lib/Vendor"
    cp -r "${phpJwtScoped}"/Firebase "$out/lib/Vendor/Firebase"
    # Verify critical submodule files are present (catches empty-directory build bugs)
    test -f "$out/assets/document-templates/new/default/new.docx" || \
      (echo "ERROR: document-templates/new/default/new.docx missing — submodule not populated" >&2; exit 1)
    test -f "$out/assets/document-formats/onlyoffice-docs-formats.json" || \
      (echo "ERROR: document-formats/onlyoffice-docs-formats.json missing — submodule not populated" >&2; exit 1)
    runHook postInstall
  '';

  meta = {
    description = "Euro-Office connector for Nextcloud — edit documents with Euro-Office DocumentServer";
    homepage = "https://github.com/Euro-Office/eurooffice-nextcloud";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
  };
}
