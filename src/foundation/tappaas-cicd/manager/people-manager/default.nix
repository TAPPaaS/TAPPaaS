# people-manager — TAPPaaS People → Authentik reconcile manager (ADR-007 P1, S2b-3).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/people-manager node wrapper. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/people-manager" /home/tappaas/bin/people-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  people-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "people-manager";
    componentRel = "manager/people-manager";
    description = "TAPPaaS People → Authentik reconcile manager (ADR-007 P1, S2b-3)";
  };
in
{
  inherit people-manager;
  default = people-manager;
}
