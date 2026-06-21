# switch-controller — TAPPaaS managed-switch controller (TypeScript pilot, ADR-007 S-TS).
#
# Builds the TypeScript sources with `tsc` (no npm dependencies) and exposes a
# `bin/switch-controller` wrapper that runs the compiled entry through Node —
# mirroring how opnsense-controller exposes its Python CLIs. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/switch-controller" /home/tappaas/bin/switch-controller
{
  pkgs ? import <nixpkgs> { },
}:
let
  # Keep build inputs out of the source copy so rebuilds are deterministic.
  src = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      let
        b = baseNameOf (toString path);
      in
      b != "result" && b != "dist" && b != "node_modules";
  };

  switch-controller = pkgs.stdenv.mkDerivation {
    pname = "switch-controller";
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
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/switch-controller" \
        --add-flags "$out/lib/main.js" \
        --set-default SWITCH_CONTROLLER_DIR \
          /home/tappaas/TAPPaaS/src/foundation/firewall/scripts/switch-controller
      runHook postInstall
    '';

    meta = {
      description = "TAPPaaS switch controller (TypeScript pilot, ADR-007 S-TS)";
      license = pkgs.lib.licenses.mit;
    };
  };
in
{
  inherit switch-controller;
  default = switch-controller;
}
