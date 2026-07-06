# network-manager — TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies, ambient lib/ts/src/env.d.ts) + a
# bin/network-manager node wrapper. The one extra step: ship the distributed
# zones.json template next to the compiled main.js so `init` can resolve it
# via __dirname (see src/zones.ts defaultTemplateFile). Build + symlink:
#   nix-build -A default default.nix
#   ln -sf "$PWD/result/bin/network-manager" /home/tappaas/bin/network-manager
{
  pkgs ? import <nixpkgs> { },
}:
let
  network-manager =
    (import ../../lib/nix/ts-manager.nix {
      inherit pkgs;
      name = "network-manager";
      componentRel = "manager/network-manager";
      description = "TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008)";
    }).overrideAttrs
      (_old: {
        # Ship the distributed zones.json template next to main.js so
        # `zones-init` can resolve it via __dirname (the bin's real dir).
        postInstall = ''
          cp manager/network-manager/zones.json "$out/lib/manager/network-manager/src/zones.json"
        '';
      });
in
{
  inherit network-manager;
  default = network-manager;
}
