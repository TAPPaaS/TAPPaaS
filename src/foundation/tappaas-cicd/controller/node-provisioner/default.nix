{
  pkgs ? import <nixpkgs> { },
}:

let
  # PXE provisioning service for follow-on TAPPaaS nodes (design N3,
  # docs/design/node-provisioning.md / issue #404). Pure stdlib — no
  # third-party Python dependencies; mount/cpio/systemd-run/dnsmasq are
  # invoked as external commands at runtime.
  node-provisioner = pkgs.python3Packages.buildPythonPackage {
    pname = "node-provisioner";
    version = "0.1.0";
    pyproject = true;

    src = ./src;

    build-system = [ pkgs.python3Packages.setuptools ];

    dependencies = [ ];

    pythonImportsCheck = [ "node_provisioner" ];

    meta = {
      description = "PXE provisioning service for follow-on TAPPaaS nodes";
      license = pkgs.lib.licenses.mit;
    };
  };

in
{
  # Development shell with the package
  shell = pkgs.mkShell {
    packages = [
      (pkgs.python3.withPackages (ps: [
        node-provisioner
      ]))
    ];

    shellHook = ''
      echo "node-provisioner Development Shell"
      echo ""
      echo "Usage:"
      echo "  node-provisioner --help"
      echo ""
      echo "Environment variables:"
      echo "  TAPPAAS_CONFIG        - config dir (default /home/tappaas/config)"
      echo "  TAPPAAS_PXE_DIR       - asset dir (default /var/lib/tappaas-pxe)"
      echo "  TAPPAAS_NODE_SECRETS  - node password dir (default ~/.node-secrets)"
      echo "  TAPPAAS_IPXE_EFI      - explicit path to an ipxe.efi to serve"
      echo ""
    '';
  };

  # The package
  inherit node-provisioner;

  # Default: Python environment with the package (provides node-provisioner
  # on bin/)
  default = pkgs.python3.withPackages (ps: [
    node-provisioner
  ]);
}
