# cmdb-controller — the CMDB service (ADR-040 D2) and its CLI, cmdb.
#
# Built like the managers, by the shared TS builder (lib/nix/ts-manager.nix):
# tsc, no npm dependencies, a bin/cmdb-controller node wrapper (the service:
# `cmdb-controller serve`, run by cmdb.service in tappaas-cicd.nix). Beside it:
# bin/cmdb, the verb surface (src/cli.ts), and the metamodel and schema files
# the service loads at start, next to lib/ where main.js finds them.
# Build + link: install.sh (nix build ..#cmdb-controller, flake-pinned).
{
  pkgs ? import <nixpkgs> { },
}:
let
  base = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "cmdb-controller";
    kind = "controller";
    description = "TAPPaaS cmdb-controller (ADR-040)";
  };

  cmdb-controller = base.overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.makeWrapper ];
    postInstall = (old.postInstall or "") + ''
      cp -r controller/cmdb-controller/metamodel "$out/metamodel"
      cp -r controller/cmdb-controller/schema "$out/schema"
      # The client calls the API with curl (lib/ts/src/cmdb.ts).
      makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/cmdb" \
        --add-flags "$out/lib/controller/cmdb-controller/src/cli.js" \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.curl ]}
    '';
  });
in
{
  inherit cmdb-controller;
  default = cmdb-controller;
}
