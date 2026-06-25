# environment-manager — TAPPaaS Environment manager (ADR-007 P3, #3 port).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies, ambient
# src/env.d.ts) and exposes a `bin/environment-manager` wrapper that runs the
# compiled entry through Node — mirroring people-manager / the S-TS pilot.
# Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/environment-manager" /home/tappaas/bin/environment-manager
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

  environment-manager = pkgs.stdenv.mkDerivation {
    pname = "environment-manager";
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
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/environment-manager" \
        --add-flags "$out/lib/main.js"
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS Environment manager (ADR-007 P3, #3) — TypeScript first-pass port";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit environment-manager;
  default = environment-manager;
}
