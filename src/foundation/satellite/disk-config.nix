# disk-config.nix — disko layout for a Hetzner Cloud x86 satellite (ADR-010 P3).
# Single disk, GPT + BIOS-boot partition (Hetzner Cloud x86 boots BIOS/Legacy),
# root ext4. nixos-anywhere partitions/formats from this — no hardware-config.
{
  disko.devices.disk.main = {
    device = "/dev/sda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition (GRUB core.img on GPT+BIOS)
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
