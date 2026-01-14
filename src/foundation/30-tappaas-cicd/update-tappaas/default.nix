{
  pkgs ? import <nixpkgs> { },
}:

let
  update-tappaas = pkgs.python3Packages.buildPythonPackage {
    pname = "update-tappaas";
    version = "0.1.0";
    pyproject = true;

    src = ./src;

    build-system = [ pkgs.python3Packages.setuptools ];

    pythonImportsCheck = [ "update_tappaas" ];

    meta = {
      description = "TAPPaaS update utility";
      license = pkgs.lib.licenses.mit;
    };
  };

in
{
  shell = pkgs.mkShell {
    packages = [
      (pkgs.python3.withPackages (ps: [
        update-tappaas
      ]))
    ];

    shellHook = ''
      echo "TAPPaaS Update Utility Development Shell"
      echo ""
      echo "Usage:"
      echo "  update-tappaas"
      echo ""
    '';
  };

  inherit update-tappaas;

  default = pkgs.python3.withPackages (ps: [
    update-tappaas
  ]);
}
