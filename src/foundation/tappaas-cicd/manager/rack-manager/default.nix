# rack-manager — where the site's hardware sits: owns config/racks.json (the
# racks, the mounts, the cables nothing can see) and reads the faceplate catalog.
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies) + a bin/rack-manager node wrapper. The
# catalog (faceplates/) is copied beside the compiled sources, where
# rack-manager looks for it.
#   nix-build -A default default.nix
{
  pkgs ? import <nixpkgs> { },
}:
let
  built = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "rack-manager";
    componentRel = "manager/rack-manager";
    description = "Where the site's hardware sits — racks, mounts and cables in config/racks.json";
  };
  rack-manager = built.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cp -r manager/rack-manager/faceplates "$out/lib/manager/rack-manager/faceplates"
    '';
  });
in
{
  inherit rack-manager;
  default = rack-manager;
}
