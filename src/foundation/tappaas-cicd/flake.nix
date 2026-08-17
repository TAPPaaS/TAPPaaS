{
  description = "TAPPaaS mothership (tappaas-cicd) NixOS system — version pinned in flake.lock";

  # The NixOS release for the mothership. Bump this ref (and run `nix flake
  # update`) to upgrade NixOS; flake.lock records the exact nixpkgs revision so
  # the build is reproducible and the version is declared in git (not in the
  # imperative root `nix-channel`). Do NOT bump system.stateVersion on upgrade.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

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
      people-manager      = component ./manager/people-manager;
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
