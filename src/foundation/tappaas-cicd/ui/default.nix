# console — the TAPPaaS console (ADR-034): backend and front end in one package.
#
# The backend is built like a manager, by the shared TS builder
# (lib/nix/ts-manager.nix): tsc, no npm dependencies, a bin/console node
# wrapper. The front end (web/: Vite, React, React Flow) is an npm build with
# its dependencies pinned by web/package-lock.json; after changing them, refresh
# npmDepsHash: nix-shell -p prefetch-npm-deps --run "prefetch-npm-deps web/package-lock.json".
# The built front end lands in $out/web/dist, where the backend looks for it.
# Build + link: install.sh (nix build ..#console, flake-pinned).
{
  pkgs ? import <nixpkgs> { },
}:
let
  backend = import ../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "console";
    componentRel = "ui";
    description = "TAPPaaS console backend (ADR-034)";
  };

  web = pkgs.buildNpmPackage {
    pname = "console-web";
    version = "0.1.0";
    src = pkgs.lib.cleanSourceWith {
      src = ./web;
      filter = path: _type: !(builtins.elem (baseNameOf (toString path)) [ "node_modules" "dist" ]);
    };
    npmDepsHash = "sha256-AVYt0aWEGMp9ec2VOxfiP2iV7eBeszagCVfz7VoABHk=";
    nodejs = pkgs.nodejs_22;
    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';
  };

  console = backend.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      mkdir -p "$out/web"
      cp -r ${web} "$out/web/dist"
      # The declared verbs of the bash controllers (manifest.ts), beside lib/.
      cp -r ui/manifest "$out/manifest"
    '';
  });
in
{
  inherit console web;
  default = console;
}
