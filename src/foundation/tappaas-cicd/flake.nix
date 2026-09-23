{
  description = "TAPPaaS mothership (tappaas-cicd) NixOS system — version pinned in flake.lock";

  # ONE pin for the estate (ADR-028 D1). The mothership does not choose its own
  # nixpkgs: it follows the revision `templates/flake.lock` holds, which is what
  # update-os.sh forces onto every NixOS guest. Two locks refreshed by hand
  # could silently disagree — a relative path input makes that impossible
  # instead of merely discouraged. `nix flake update` on templates/ moves the
  # whole estate; this lock records the same revision, by construction.
  #
  # Relative path inputs resolve against the GIT TREE, so both flakes must stay
  # in this repository — outside one, `path:../templates` resolves to
  # /nix/store/templates and evaluation fails. Needs Nix >= 2.26 (2.31 here).
  # Do NOT bump system.stateVersion on upgrade.
  inputs.templates.url = "path:../templates";
  inputs.nixpkgs.follows = "templates/nixpkgs";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The mothership's own managers/controllers, exposed as flake packages so
      # they build against the nixpkgs pinned in flake.lock — the same revision
      # the system closure uses.
      #
      # Each component's default.nix still declares `pkgs ? import <nixpkgs> {}`
      # for standalone `nix-build`, but that ambient path is no longer on the
      # install route: it is unset under systemd (so the nightly never built
      # these at all) and resolves via the network flake registry interactively
      # (so it hung on HTTP 429 once the registry cache went stale). #467.
      component = dir: (import dir { inherit pkgs; }).default;
    in
    {
    packages.${system} = {
      backup-manager      = component ./manager/backup-manager;
      environment-manager = component ./manager/environment-manager;
      health-manager      = component ./manager/health-manager;
      module-manager      = component ./manager/module-manager;
      network-manager     = component ./manager/network-manager;
      identity-manager      = component ./manager/identity-manager;
      site-manager        = component ./manager/site-manager;
      identity-controller = component ./controller/identity-controller;
      node-provisioner    = component ./controller/node-provisioner;
      opnsense-controller = component ./controller/opnsense-controller;
      update-tappaas      = component ./update-tappaas;
    };

    nixosConfigurations.tappaas-cicd = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      # tappaas-cicd.nix imports the machine-specific
      # /etc/nixos/hardware-configuration.nix (root/boot by-uuid), so the system
      # must be built with `--impure`. That only permits reading that one
      # absolute path; nixpkgs itself stays pinned by flake.lock.
      modules = [ ./tappaas-cicd.nix ];
    };
  };
}
