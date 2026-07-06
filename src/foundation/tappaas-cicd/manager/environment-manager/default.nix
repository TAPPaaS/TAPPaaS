# environment-manager — TAPPaaS Environment manager (ADR-007 P3, #3 port).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/environment-manager node wrapper. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/environment-manager" /home/tappaas/bin/environment-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  environment-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "environment-manager";
    componentRel = "manager/environment-manager";
    description = "TAPPaaS Environment manager (ADR-007 P3, #3) — TypeScript first-pass port";
  };
in
{
  inherit environment-manager;
  default = environment-manager;
}
