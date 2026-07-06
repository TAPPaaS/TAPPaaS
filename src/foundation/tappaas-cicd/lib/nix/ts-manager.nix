# ts-manager.nix — the ONE derivation builder for TAPPaaS TypeScript managers
# (ADR-007 post-implementation refactor, Phase 3). A manager's default.nix is a
# thin import:
#
#   { pkgs ? import <nixpkgs> { } }:
#   let drv = import ../../lib/nix/ts-manager.nix {
#     inherit pkgs;
#     name = "site-manager";
#     componentRel = "manager/site-manager";
#     description = "TAPPaaS Site manager (ADR-007 P2)";
#   };
#   in { default = drv; }
#
# Builds with `tsc` (no npm dependencies; ambient lib/ts/src/env.d.ts) against
# a source tree containing ONLY lib/ts/ + the component dir — so a lib/ts
# change rebuilds every manager (wanted), while unrelated tree changes do not.
# Because tsconfig rootDir is the cicd root, emit mirrors the tree:
# $out/lib/<componentRel>/src/main.js is the wrapped entry point.
{
  pkgs,
  name,
  componentRel, # e.g. "manager/site-manager" (relative to tappaas-cicd/)
  version ? "0.1.0",
  description ? "TAPPaaS ${name}",
  entry ? "src/main.js", # entry point inside the component's dist tree
}:
let
  cicd = ../..; # lib/nix/ -> tappaas-cicd/
  cicdStr = toString cicd;

  # Admit a path iff it is an ancestor or a descendant of one of the wanted
  # roots (lib/ts + the component), excluding build artifacts.
  wanted = [
    "lib/ts"
    componentRel
  ];
  isWanted =
    rel:
    pkgs.lib.any (
      w: pkgs.lib.hasPrefix "${w}/" "${rel}/" || pkgs.lib.hasPrefix "${rel}/" "${w}/"
    ) wanted;

  src = pkgs.lib.cleanSourceWith {
    src = cicd;
    filter =
      path: _type:
      let
        rel = pkgs.lib.removePrefix "${cicdStr}/" (toString path);
        b = baseNameOf (toString path);
      in
      b != "result" && b != "dist" && b != "dist-test" && b != "node_modules" && isWanted rel;
  };

  drv = pkgs.stdenv.mkDerivation {
    pname = name;
    inherit version src;

    nativeBuildInputs = [
      pkgs.nodejs_22
      pkgs.typescript
      pkgs.makeWrapper
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      cd ${componentRel}
      tsc -p tsconfig.json
      cd - >/dev/null
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib"
      cp -r ${componentRel}/dist/* "$out/lib/"
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/${name}" \
        --add-flags "$out/lib/${componentRel}/${entry}"
      runHook postInstall
    '';

    meta = {
      inherit description;
      license = pkgs.lib.licenses.mit;
    };
  };
in
drv
