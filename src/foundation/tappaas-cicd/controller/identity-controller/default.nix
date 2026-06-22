{
  pkgs ? import <nixpkgs> { },
}:

let
  # Authentik runtime controller for TAPPaaS.
  # Extracted from opnsense-controller (ADR-007 S2b-1). Pure stdlib + httpx —
  # it talks to the Authentik API directly, so it does NOT depend on the
  # oxl-opnsense-client library.
  identity-controller = pkgs.python3Packages.buildPythonPackage {
    pname = "identity-controller";
    version = "0.1.0";
    pyproject = true;

    src = ./src;

    build-system = [ pkgs.python3Packages.setuptools ];

    dependencies = with pkgs.python3Packages; [
      httpx
    ];

    pythonImportsCheck = [ "identity_controller" ];

    meta = {
      description = "Authentik runtime controller for TAPPaaS";
      license = pkgs.lib.licenses.mit;
    };
  };

in
{
  # Development shell with the package
  shell = pkgs.mkShell {
    packages = [
      (pkgs.python3.withPackages (ps: [
        identity-controller
      ]))
    ];

    shellHook = ''
      echo "Identity Controller Development Shell"
      echo ""
      echo "Usage:"
      echo "  authentik-manager --help"
      echo ""
      echo "Environment variables / credentials:"
      echo "  ~/.authentik-credentials.txt  - url=...  token=..."
      echo ""
    '';
  };

  # The package
  inherit identity-controller;

  # Default: Python environment with the package (provides authentik-manager
  # and identity-controller on bin/)
  default = pkgs.python3.withPackages (ps: [
    identity-controller
  ]);
}
