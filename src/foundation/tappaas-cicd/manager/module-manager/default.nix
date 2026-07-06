# module-manager — TAPPaaS module lifecycle manager (ADR-007 #3 verb alignment).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/module-manager node wrapper. Build + symlink:
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
  module-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "module-manager";
    componentRel = "manager/module-manager";
    description = "TAPPaaS module lifecycle manager (ADR-007 #3 verb alignment)";
  };
in
{
  inherit module-manager;
  default = module-manager;
}
