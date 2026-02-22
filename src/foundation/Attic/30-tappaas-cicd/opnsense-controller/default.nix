{
  pkgs ? import <nixpkgs> { },
}:

let
  # OPNsense API client library (not in nixpkgs)
  opnsense-api-client = pkgs.python3Packages.buildPythonPackage rec {
    pname = "oxl-opnsense-client";
    version = "25.7.8";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "O-X-L";
      repo = "opnsense-api-client";
      rev = version;
      hash = "sha256-CucAOsFt83c+SuJUXzSElJpzxqPpgYxR5EJhAuICGGE=";
    };

    postPatch = ''
      echo "${version}" > VERSION
    '';

    build-system = [ pkgs.python3Packages.setuptools ];

    dependencies = with pkgs.python3Packages; [
      httpx
      ansible-core
    ];

    # ansible-core 2.19.x is required but nixpkgs has 2.18.x
    # ansible-core is only used for module-spec validation, not runtime
    pythonRelaxDeps = [ "ansible-core" ];

    pythonImportsCheck = [ "oxl_opnsense_client" ];

    meta = {
      description = "OXL OPNsense API Client";
      homepage = "https://github.com/O-X-L/opnsense-api-client";
      license = pkgs.lib.licenses.gpl3Only;
    };
  };

  # OPNsense controller for TAPPaaS
  opnsense-controller = pkgs.python3Packages.buildPythonPackage {
    pname = "opnsense-controller";
    version = "0.1.0";
    pyproject = true;

    src = ./src;

    build-system = [ pkgs.python3Packages.setuptools ];

    dependencies = [ opnsense-api-client ];

    pythonImportsCheck = [ "opnsense_controller" ];

    meta = {
      description = "OPNsense controller for TAPPaaS using OPNsense API client";
      license = pkgs.lib.licenses.mit;
    };
  };

in
{
  # Development shell with both packages
  shell = pkgs.mkShell {
    packages = [
      (pkgs.python3.withPackages (ps: [
        opnsense-api-client
        opnsense-controller
      ]))
    ];

    shellHook = ''
      echo "OPNsense Controller Development Shell"
      echo ""
      echo "Usage:"
      echo "  python -m opnsense_controller.main --help"
      echo ""
      echo "Environment variables:"
      echo "  OPNSENSE_HOST           - Firewall IP/hostname"
      echo "  OPNSENSE_TOKEN          - API token"
      echo "  OPNSENSE_SECRET         - API secret"
      echo "  OPNSENSE_CREDENTIAL_FILE - Path to credentials file"
      echo ""
    '';
  };

  # The packages
  inherit opnsense-api-client opnsense-controller;

  # Default: Python environment with both packages
  default = pkgs.python3.withPackages (ps: [
    opnsense-api-client
    opnsense-controller
  ]);
}
