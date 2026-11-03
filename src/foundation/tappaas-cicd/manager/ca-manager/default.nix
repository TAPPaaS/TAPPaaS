# ca-manager — the site's certificate authorities and the certificates they
# issue (ADR-043). Thin wrapper over the shared TS-manager builder, with openssl
# on its PATH: it makes keys and signs with it.
#   nix-build -A default default.nix
{
  pkgs ? import <nixpkgs> { },
}:
let
  ca-manager = import ../../lib/nix/ts-manager.nix {
    inherit pkgs;
    name = "ca-manager";
    componentRel = "manager/ca-manager";
    description = "TAPPaaS site certificates — the internal CA, a CA per local domain tree, and what they issue (ADR-043)";
    runtimeInputs = [ pkgs.openssl ];
  };
in
{
  inherit ca-manager;
  default = ca-manager;
}
