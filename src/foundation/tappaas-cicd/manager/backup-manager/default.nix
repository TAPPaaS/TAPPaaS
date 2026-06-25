# backup-manager — TAPPaaS backup-policy cascade manager (ADR-007 verb-alignment #3).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies, ambient
# src/env.d.ts) and exposes a `bin/backup-manager` wrapper that runs the
# compiled entry through Node — mirroring people-manager/default.nix and the
# S-TS switch-controller pilot. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/backup-manager" /home/tappaas/bin/backup-manager
#
# NOTE: not yet wired into install.sh (the .sh entry points stay live for this
# first-pass port — see the ADR-007 #3 handoff).
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

  backup-manager = pkgs.stdenv.mkDerivation {
    pname = "backup-manager";
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
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/backup-manager" \
        --add-flags "$out/lib/main.js"
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS backup-policy cascade manager (ADR-007 verb-alignment #3)";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit backup-manager;
  default = backup-manager;
}
