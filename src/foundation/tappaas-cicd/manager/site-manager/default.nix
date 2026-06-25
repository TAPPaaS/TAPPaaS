# site-manager — TAPPaaS Site manager (ADR-007 P2, #3 all-managers-to-TS).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies, ambient
# src/env.d.ts) and exposes a `bin/site-manager` wrapper that runs the compiled
# entry through Node — mirroring people-manager / network-manager. Build +
# symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/site-manager" /home/tappaas/bin/site-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  # Keep build artifacts out of the source copy so rebuilds are deterministic.
  src = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      let
        b = baseNameOf (toString path);
      in
      b != "result" && b != "dist" && b != "node_modules";
  };

  site-manager = pkgs.stdenv.mkDerivation {
    pname = "site-manager";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [
      pkgs.nodejs_22
      pkgs.typescript
      pkgs.makeWrapper
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      tsc -p tsconfig.json
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib"
      cp -r dist/* "$out/lib/"
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/site-manager" \
        --add-flags "$out/lib/main.js"
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS Site manager (ADR-007 P2, #3 all-managers-to-TS)";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit site-manager;
  default = site-manager;
}
