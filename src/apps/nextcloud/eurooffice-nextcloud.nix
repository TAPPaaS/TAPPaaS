# TAPPaaS — Euro-Office Nextcloud connector
# App ID: eurooffice | Requires: Nextcloud ≥ 33
# Source: https://github.com/Euro-Office/eurooffice-nextcloud
#
# UPDATING to a newer version: run ./update-eurooffice-app.sh
# Hashes to refresh:
#   src.hash        nix-prefetch-git (fetchSubmodules = false)
#   phpJwt.hash     nix-prefetch-url --unpack <github-archive-of-new-rev>
#   npmDepsHash     prefetch-npm-deps <src-path>/npm-shrinkwrap.json
#   composerClassLoader / composerInstalledVersions only change when nixpkgs
#     bumps phpPackages.composer (currently 2.9.7 in nixpkgs 25.11)
{ lib, stdenv, fetchgit, fetchurl, fetchNpmDeps, buildNpmPackage, nodejs_20 }:

let
  version = "10.0.0";

  src = fetchgit {
    url = "https://github.com/Euro-Office/eurooffice-nextcloud";
    rev = "v${version}";
    # fetchSubmodules causes submodule init to trigger git-lfs smudge on the
    # parent repo, which empties all files tracked by LFS. Fetch without
    # submodules so the main PHP/XML source files are present.
    hash = "sha256-bhVlONWKB6KTd4gBpNnaJhmpV1MX4AG3SCj8o6XGOVc=";
    fetchSubmodules = false;
  };

  # prefetch-npm-deps 0.1.0 truncates downloads at ~4 MB. typescript@5.4.5
  # (5.8 MB) lands in the cache truncated; npm detects corruption at install
  # time and fails. We build a patched npm-deps that replaces the bad entry.
  correctTypescript = fetchurl {
    url = "https://registry.npmjs.org/typescript/-/typescript-5.4.5.tgz";
    hash = "sha256-FU+udxafBBVaxS1SGsWauwfJvinqN0RzKtv58Uq7JEA=";
  };

  fixedNpmDeps = let
    brokenDeps = fetchNpmDeps {
      name = "eurooffice-nextcloud-js-${version}-npm-deps";
      inherit src;
      nodejs = nodejs_20;
      hash = "sha256-xgqwQSekV8nVrx34WHP1GpATWbJIPNxdBv4ZDTLx67k=";
    };
    # npm cacache path = hex(sha512(tgz)) — split bd/c2/rest per cacache layout
    tsCachePath = "_cacache/content-v2/sha512/bd/c2/3852946083cd68211505c11d164881cab75d6727b48056560d22ef90a6a7b25cffa0a50272fd9e3e174686c5213832ac23c97bd6fd3ce090b031d80187c1";
  in stdenv.mkDerivation {
    name = "eurooffice-nextcloud-js-${version}-npm-deps-fixed";
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      cp -r --no-preserve=mode ${brokenDeps} $out
      cp ${correctTypescript} "$out/${tsCachePath}"
      runHook postInstall
    '';
  };

  # Build Vite JS assets (9 entry points → js/)
  jsBuild = buildNpmPackage {
    pname = "eurooffice-nextcloud-js";
    inherit version src;
    nodejs = nodejs_20;
    npmDeps = fixedNpmDeps;
    # npmDepsHash is unused when npmDeps is provided directly
    npmDepsHash = "sha256-xgqwQSekV8nVrx34WHP1GpATWbJIPNxdBv4ZDTLx67k=";
    dontNpmInstall = true;
    buildPhase = "npm run build";
    # @nextcloud/vite-config outputs bundles to js/ — expose that as $out
    installPhase = "cp -r js $out";
  };

  # assets/document-formats is a git submodule (ONLYOFFICE/document-formats).
  # fetchgit with fetchSubmodules=false leaves the directory empty; fetch separately.
  # Commit 7d7576a matches onlyoffice-nextcloud v10.0.0 (all v9.x docserver tags point here).
  documentFormats = builtins.fetchTarball {
    url = "https://github.com/ONLYOFFICE/document-formats/archive/7d7576a3fe2337c30f4c9b40fae70a69dc68ba08.tar.gz";
    sha256 = "01x4f8916lrwnhajx7nlg57l2nklq023v9ky3ihhwvf6wdbs348y";
  };

  # assets/document-templates is a git submodule (ONLYOFFICE/document-templates).
  # Also left empty by fetchSubmodules=false; must be fetched separately.
  # Commit 54f35867 matches onlyoffice-nextcloud v10.0.0.
  # Contains default/new.docx (and .pdf/.pptx/.xlsx) served by the /empty endpoint
  # that euro-office uses during its health-check conversion round-trip.
  documentTemplates = builtins.fetchTarball {
    url = "https://github.com/ONLYOFFICE/document-templates/archive/54f35867b40126d9ccfc71b05335c6d552016e01.tar.gz";
    sha256 = "1r4m3xbx39n3b2nz4rfnzx83p255k0kzczk1bbll24963hndk6jn";
  };

  # firebase/php-jwt v6.11.1 — pinned via composer.lock
  # Uses builtins.fetchTarball (Nix daemon HTTP) to bypass the nixpkgs 25.11
  # fetchurl curl bug (curl binary missing from nativeBuildInputs).
  phpJwt = builtins.fetchTarball {
    url = "https://github.com/firebase/php-jwt/archive/d1e91ecf8c598d073d0995afa8cd5c75c6e19e66.tar.gz";
    sha256 = "1nl7c2ypqv0c2j06f5yy1js1ghivdspgspmq52b7ms8kwwqps97r";
  };

  # Composer 2.9.7 runtime files (matches nixpkgs 25.11 phpPackages.composer.version)
  composerClassLoader = fetchurl {
    url = "https://raw.githubusercontent.com/composer/composer/2.9.7/src/Composer/Autoload/ClassLoader.php";
    hash = "sha256-1LIxPlYu35QoOOwxbZg8GjRZymfaPlZY6GEgCws2k8I=";
  };
  composerInstalledVersions = fetchurl {
    url = "https://raw.githubusercontent.com/composer/composer/2.9.7/src/Composer/InstalledVersions.php";
    hash = "sha256-HkUlGYMB0e0fh6w98qhVWm8Tn43zCnA9C3daYZY8luQ=";
  };

  # Hand-generated composer autoloader for the single-package (firebase/php-jwt)
  # vendor layout. Class-name suffix "a55a7e42" is arbitrary but stable across builds.
  vendorAutoload = builtins.toFile "autoload.php" ''
    <?php
    require_once __DIR__ . '/composer/autoload_real.php';
    return ComposerAutoloaderInita55a7e42::getLoader();
  '';

  vendorAutoloadReal = builtins.toFile "autoload_real.php" ''
    <?php
    class ComposerAutoloaderInita55a7e42
    {
        private static $loader;
        public static function loadClassLoader($class)
        {
            if ('Composer\Autoload\ClassLoader' === $class) {
                require __DIR__ . '/ClassLoader.php';
            }
        }
        public static function getLoader()
        {
            if (null !== self::$loader) {
                return self::$loader;
            }
            require __DIR__ . '/platform_check.php';
            spl_autoload_register(['ComposerAutoloaderInita55a7e42', 'loadClassLoader'], true, true);
            self::$loader = $loader = new \Composer\Autoload\ClassLoader(\dirname(__DIR__));
            spl_autoload_unregister(['ComposerAutoloaderInita55a7e42', 'loadClassLoader']);
            require __DIR__ . '/autoload_static.php';
            call_user_func(\Composer\Autoload\ComposerStaticInita55a7e42::getInitializer($loader));
            $loader->register(true);
            return $loader;
        }
    }
  '';

  vendorAutoloadStatic = builtins.toFile "autoload_static.php" ''
    <?php
    namespace Composer\Autoload;
    class ComposerStaticInita55a7e42
    {
        public static $prefixLengthsPsr4 = array(
            'F' => array('Firebase\\JWT\\' => 13),
        );
        public static $prefixDirsPsr4 = array(
            'Firebase\\JWT\\' => array(0 => __DIR__ . '/..' . '/firebase/php-jwt/src'),
        );
        public static $classMap = array(
            'Composer\\InstalledVersions' => __DIR__ . '/InstalledVersions.php',
        );
        public static function getInitializer(ClassLoader $loader)
        {
            return \Closure::bind(function () use ($loader) {
                $loader->prefixLengthsPsr4 = ComposerStaticInita55a7e42::$prefixLengthsPsr4;
                $loader->prefixDirsPsr4 = ComposerStaticInita55a7e42::$prefixDirsPsr4;
                $loader->classMap = ComposerStaticInita55a7e42::$classMap;
            }, null, ClassLoader::class);
        }
    }
  '';

  vendorAutoloadPsr4 = builtins.toFile "autoload_psr4.php" ''
    <?php
    $vendorDir = dirname(__DIR__);
    $baseDir = dirname($vendorDir);
    return array('Firebase\\JWT\\' => array($vendorDir . '/firebase/php-jwt/src'));
  '';

  vendorAutoloadNamespaces = builtins.toFile "autoload_namespaces.php" ''
    <?php
    $vendorDir = dirname(__DIR__);
    $baseDir = dirname($vendorDir);
    return array();
  '';

  vendorAutoloadClassmap = builtins.toFile "autoload_classmap.php" ''
    <?php
    $vendorDir = dirname(__DIR__);
    $baseDir = dirname($vendorDir);
    return array();
  '';

  vendorPlatformCheck = builtins.toFile "platform_check.php" ''
    <?php
    $issues = array();
    if (!(PHP_VERSION_ID >= 80000)) {
        $issues[] = 'Your Composer dependencies require a PHP version ">= 8.0.0". You are running '
            . PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '.' . PHP_RELEASE_VERSION . '.';
    }
    if ($issues) {
        $nl = strpos(PHP_SAPI, 'cli') === 0 ? PHP_EOL : '<br />';
        echo 'Composer detected issues in your platform:' . $nl . implode($nl, $issues) . $nl;
        trigger_error('Composer detected issues in your platform: ' . implode(' ', $issues), E_USER_ERROR);
    }
  '';

  vendorInstalledJson = builtins.toFile "installed.json" ''
    {
        "packages": [{
            "name": "firebase/php-jwt",
            "version": "v6.11.1",
            "version_normalized": "6.11.1.0",
            "source": {
                "type": "git",
                "url": "https://github.com/firebase/php-jwt.git",
                "reference": "d1e91ecf8c598d073d0995afa8cd5c75c6e19e66"
            },
            "dist": {
                "type": "zip",
                "url": "https://api.github.com/repos/firebase/php-jwt/zipball/d1e91ecf8c598d073d0995afa8cd5c75c6e19e66",
                "reference": "d1e91ecf8c598d073d0995afa8cd5c75c6e19e66",
                "shasum": ""
            },
            "require": {"php": "^8.0"},
            "type": "library",
            "autoload": {"psr-4": {"Firebase\\JWT\\": "src"}},
            "license": ["BSD-3-Clause"],
            "description": "A simple library to encode and decode JSON Web Tokens (JWT) in PHP.",
            "install-path": "../firebase/php-jwt"
        }],
        "dev": false,
        "dev-package-names": []
    }
  '';

  vendorInstalledPhp = builtins.toFile "installed.php" ''
    <?php return array(
        'root' => array(
            'name' => 'onlyoffice/onlyoffice-nextcloud',
            'pretty_version' => 'dev-main',
            'version' => 'dev-main',
            'reference' => NULL,
            'type' => 'project',
            'install_path' => __DIR__ . '/../../',
            'aliases' => array(),
            'dev' => false,
        ),
        'versions' => array(
            'firebase/php-jwt' => array(
                'pretty_version' => 'v6.11.1',
                'version' => '6.11.1.0',
                'reference' => 'd1e91ecf8c598d073d0995afa8cd5c75c6e19e66',
                'type' => 'library',
                'install_path' => __DIR__ . '/../firebase/php-jwt',
                'aliases' => array(),
                'dev_requirement' => false,
            ),
            'onlyoffice/onlyoffice-nextcloud' => array(
                'pretty_version' => 'dev-main',
                'version' => 'dev-main',
                'reference' => NULL,
                'type' => 'project',
                'install_path' => __DIR__ . '/../../',
                'aliases' => array(),
                'dev_requirement' => false,
            ),
        ),
    );
  '';

  # PHP vendor directory assembled without running composer.
  # composer segfaults on this host (SIGSEGV/SIGBUS across PHP 8.2 and 8.4).
  phpVendor = stdenv.mkDerivation {
    name = "eurooffice-nextcloud-vendor-${version}";
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/firebase/php-jwt $out/composer

      cp -r ${phpJwt}/src           $out/firebase/php-jwt/src
      cp    ${phpJwt}/composer.json $out/firebase/php-jwt/composer.json
      cp    ${phpJwt}/LICENSE       $out/firebase/php-jwt/LICENSE

      cp ${composerClassLoader}       $out/composer/ClassLoader.php
      cp ${composerInstalledVersions} $out/composer/InstalledVersions.php

      cp ${vendorAutoload}           $out/autoload.php
      cp ${vendorAutoloadReal}       $out/composer/autoload_real.php
      cp ${vendorAutoloadStatic}     $out/composer/autoload_static.php
      cp ${vendorAutoloadPsr4}       $out/composer/autoload_psr4.php
      cp ${vendorAutoloadNamespaces} $out/composer/autoload_namespaces.php
      cp ${vendorAutoloadClassmap}   $out/composer/autoload_classmap.php
      cp ${vendorPlatformCheck}      $out/composer/platform_check.php
      cp ${vendorInstalledJson}      $out/composer/installed.json
      cp ${vendorInstalledPhp}       $out/composer/installed.php

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
    cp -r "${phpVendor}" "$out/vendor"
    # Verify critical submodule files are present (catches empty-directory build bugs)
    test -f "$out/assets/document-templates/default/new.docx" || \
      (echo "ERROR: document-templates/default/new.docx missing — submodule not populated" >&2; exit 1)
    runHook postInstall
  '';

  meta = {
    description = "Euro-Office connector for Nextcloud — edit documents with Euro-Office DocumentServer";
    homepage = "https://github.com/Euro-Office/eurooffice-nextcloud";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
  };
}
