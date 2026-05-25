{
  description = "TAPPaaS mothership (tappaas-cicd) NixOS system — version pinned in flake.lock";

  # The NixOS release for the mothership. Bump this ref (and run `nix flake
  # update`) to upgrade NixOS; flake.lock records the exact nixpkgs revision so
  # the build is reproducible and the version is declared in git (not in the
  # imperative root `nix-channel`). Do NOT bump system.stateVersion on upgrade.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs, ... }: {
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
