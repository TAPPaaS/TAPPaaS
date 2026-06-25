# module-manager — TAPPaaS module lifecycle manager (ADR-007 #3 verb alignment).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies, ambient
# src/env.d.ts) and exposes a `bin/module-manager` wrapper that runs the
# compiled entry through Node — mirroring people-manager / network-manager and
# the S-TS switch-controller pilot. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/module-manager" /home/tappaas/bin/module-manager
#
# NOTE: this is a FIRST-PASS port. The CONFIG-layer verbs (list/show/validate)
# are pure TS; the LIFECYCLE verbs (add/modify/delete/reconcile/test/snapshot-vm)
# shell out to the existing *.sh scripts, which stay live until a later retire
# phase. install.sh therefore still links those scripts onto PATH too.
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

  module-manager = pkgs.stdenv.mkDerivation {
    pname = "module-manager";
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
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/module-manager" \
        --add-flags "$out/lib/main.js"
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS module lifecycle manager (ADR-007 #3 verb alignment)";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit module-manager;
  default = module-manager;
}
