# health-manager — TAPPaaS cluster/VM/disk health manager (ADR-007 #3).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/health-manager node wrapper. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/health-manager" /home/tappaas/bin/health-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  health-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "health-manager";
    componentRel = "manager/health-manager";
    description = "TAPPaaS cluster/VM/disk health manager (ADR-007 #3)";
  };
in
{
  inherit health-manager;
  default = health-manager;
}
