# network-manager — TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies, ambient
# src/env.d.ts) and exposes a `bin/network-manager` wrapper that runs the
# compiled entry through Node — mirroring the S-TS switch-controller pilot and
# people-manager. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/network-manager" /home/tappaas/bin/network-manager
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
      b != "result" && b != "dist" && b != "dist-test" && b != "node_modules";
  };

  network-manager = pkgs.stdenv.mkDerivation {
    pname = "network-manager";
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
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/network-manager" \
        --add-flags "$out/lib/main.js"
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008)";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit network-manager;
  default = network-manager;
}
