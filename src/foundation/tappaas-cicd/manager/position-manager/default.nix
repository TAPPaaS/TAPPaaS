# position-manager — where the site's hardware is: owns config/positions.json
# (the rooms and their locations, the racks, the placements, the devices and
# cables nothing can see) and reads the faceplate catalog.
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies) + a bin/position-manager node wrapper. The
# catalog (faceplates/) is copied beside the compiled sources, where
# position-manager looks for it. bin/rack-manager is the old name, an alias
# for one release (ADR-035 P2).
#   nix-build -A default default.nix
{
  pkgs ? import <nixpkgs> { },
}:
let
  built = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "position-manager";
    componentRel = "manager/position-manager";
    description = "Where the site's hardware is — rooms in locations, racks, placements and cables in config/positions.json";
  };
  position-manager = built.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cp -r manager/position-manager/faceplates "$out/lib/manager/position-manager/faceplates"
      ln -s position-manager "$out/bin/rack-manager"
    '';
  });
in
{
  inherit position-manager;
  default = position-manager;
}
