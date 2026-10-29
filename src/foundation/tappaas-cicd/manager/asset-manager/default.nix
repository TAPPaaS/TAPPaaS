# asset-manager — the site's physical assets and where they are: owns
# config/positions.json (the rooms and their locations, the racks, the
# placements, the assets with their ports and lifecycle, the cables nothing
# can see) and reads the faceplate catalog (ADR-040 D7).
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies) + a bin/asset-manager node wrapper. The
# catalog (faceplates/) is copied beside the compiled sources, where
# asset-manager looks for it. bin/position-manager and bin/rack-manager are its
# old names, aliases for one release (ADR-035 P2).
#   nix-build -A default default.nix
{
  pkgs ? import <nixpkgs> { },
}:
let
  built = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "asset-manager";
    componentRel = "manager/asset-manager";
    description = "The site's physical assets and where they are — rooms, racks, placements, assets with their ports and lifecycle, and cables in config/positions.json";
  };
  asset-manager = built.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cp -r manager/asset-manager/faceplates "$out/lib/manager/asset-manager/faceplates"
      ln -s asset-manager "$out/bin/position-manager"
      ln -s asset-manager "$out/bin/rack-manager"
    '';
  });
in
{
  inherit asset-manager;
  default = asset-manager;
}
