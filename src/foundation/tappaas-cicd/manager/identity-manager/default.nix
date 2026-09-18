# identity-manager — TAPPaaS Identity → Authentik reconcile manager (ADR-007 P1, S2b-3).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/identity-manager node wrapper. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/identity-manager" /home/tappaas/bin/identity-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  identity-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "identity-manager";
    componentRel = "manager/identity-manager";
    description = "TAPPaaS Identity → Authentik reconcile manager (ADR-007 P1, S2b-3)";
  };
in
{
  inherit identity-manager;
  default = identity-manager;
}
