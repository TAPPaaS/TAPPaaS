# storage-manager — TAPPaaS storage control plane (ADR-029 v0.9): owns
# config/shares.json and changes it one share at a time.
#
# Thin wrapper over the shared TS-manager builder (lib/nix/ts-manager.nix):
# tsc build (no npm dependencies) + a bin/storage-manager node wrapper.
#   nix-build -A default default.nix
{
  pkgs ? import <nixpkgs> { },
}:
let
  storage-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "storage-manager";
    componentRel = "manager/storage-manager";
    description = "TAPPaaS storage control plane — NFS shares in config/shares.json (ADR-029)";
  };
in
{
  inherit storage-manager;
  default = storage-manager;
}
