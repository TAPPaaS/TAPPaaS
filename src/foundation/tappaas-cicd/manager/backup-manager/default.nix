# backup-manager — TAPPaaS backup-policy cascade manager (ADR-007 verb-alignment #3).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/backup-manager node wrapper. Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/backup-manager" /home/tappaas/bin/backup-manager
#
# install.sh builds + links this bin; the legacy .sh entry points were retired
# in the ADR-007 post-implementation refactor, Phase 7.4.
{
  pkgs ? import <nixpkgs> { },
}:
let
  backup-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "backup-manager";
    componentRel = "manager/backup-manager";
    description = "TAPPaaS backup-policy cascade manager (ADR-007 verb-alignment #3)";
  };
in
{
  inherit backup-manager;
  default = backup-manager;
}
