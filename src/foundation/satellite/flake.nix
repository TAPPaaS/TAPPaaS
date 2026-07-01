{
  description = "TAPPaaS satellite (ADR-010) — nixos-anywhere deployment for an external host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, ... }: {
    # Build/deploy with:
    #   nix run github:nix-community/nixos-anywhere -- \
    #     --flake .#satellite --target-host root@<ip> -i <provision-key>
    nixosConfigurations.satellite = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./disk-config.nix
        ./satellite.nix
      ];
    };
  };
}
