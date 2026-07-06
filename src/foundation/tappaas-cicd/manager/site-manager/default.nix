# site-manager — TAPPaaS Site manager (ADR-007 P2, #3 all-managers-to-TS).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/site-manager node wrapper. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/site-manager" /home/tappaas/bin/site-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  site-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "site-manager";
    componentRel = "manager/site-manager";
    description = "TAPPaaS Site manager (ADR-007 P2, #3 all-managers-to-TS)";
  };
in
{
  inherit site-manager;
  default = site-manager;
}
