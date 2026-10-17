# console — the TAPPaaS console backend (ADR-034).
#
# The backend is built like a manager, by the shared TS builder
# (lib/nix/ts-manager.nix): tsc, no npm dependencies, a bin/console node
# wrapper. Build + link:
#   nix build ..#console          (install.sh does this, flake-pinned)
{
  pkgs ? import <nixpkgs> { },
}:
let
  console = import ../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "console";
    componentRel = "ui";
    description = "TAPPaaS console backend (ADR-034)";
  };
in
{
  inherit console;
  default = console;
}
