# people-manager — TAPPaaS People → Authentik reconcile manager (ADR-007 P1, S2b-3).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies, ambient
# src/env.d.ts) and exposes a `bin/people-manager` wrapper that runs the
# compiled entry through Node — mirroring the S-TS switch-controller pilot and
# how opnsense-controller exposes its Python CLIs. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/people-manager" /home/tappaas/bin/people-manager
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

  people-manager = pkgs.stdenv.mkDerivation {
    pname = "people-manager";
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
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/people-manager" \
        --add-flags "$out/lib/main.js"
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS People → Authentik reconcile manager (ADR-007 P1, S2b-3)";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit people-manager;
  default = people-manager;
}
