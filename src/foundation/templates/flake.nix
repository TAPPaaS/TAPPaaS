{
  description = "TAPPaaS prebuilt NixOS VM template image (config baked in)";

  # Pinned to the same NixOS release as system.stateVersion in tappaas-common.nix.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in
    {
      # The TAPPaaS baseline as a full NixOS system. Note there is deliberately
      # NO hardware-configuration.nix here: the image format module (selected via
      # `nixos-rebuild build-image --image-variant ...`) supplies the disk,
      # filesystem and EFI bootloader device.
      nixosConfigurations.tappaas-nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./tappaas-common.nix ];
      };

      # Convenience: build the EFI qcow2 directly with
      #   nix build .#image
      # (equivalent to: nixos-rebuild build-image --image-variant qemu-efi
      #                   --flake .#tappaas-nixos)
      packages.${system}.image =
        self.nixosConfigurations.tappaas-nixos.config.system.build.images.qemu-efi;
    };
}
