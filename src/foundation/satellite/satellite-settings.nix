# satellite-settings.nix — per-deployment values for satellite.nix (ADR-010 P3).
#
# satellite-manager regenerates this from ~/config/satellite-<name>.json per
# install. This committed copy is the reference/test deployment (the sat1 host).
# Secrets are NOT here: the satellite's own WireGuard private key is generated
# on-host; only the HOME (OPNsense) *public* key is referenced.
{
  hostName = "satellite1";
  bootDevice = "/dev/sda"; # Hetzner Cloud x86 single disk, BIOS/Legacy GRUB

  roles = [ ]; # minimal first deploy: tunnel + base only. Add "reverse-proxy"/"admin-vpn"/"backup" later.

  tunnel = {
    satelliteAddr = "10.255.0.0"; # /31 link, satellite end
    homeAddr = "10.255.0.1"; # /31 link, home (OPNsense) end
    wgPort = 51820; # public UDP listener
  };

  # OPNsense infra-tunnel WireGuard PUBLIC key (home dials in). From the P2
  # live bring-up (server 'tappaas-edge-sat1'). The satellite generates its OWN
  # key on first boot; satellite-manager reads it back to update the OPNsense peer.
  homePublicKey = "Pj6B7Iz+ZTlWWkjToPbjRFai5Adhy+Dx6Q3Z/oG8rz8=";

  homeCaddyAddr = "10.255.0.1"; # reverse-proxy forward target (over the tunnel)
  adminWgPort = 51821; # admin-vpn public UDP relay port
  homeAdminWgAddr = "10.255.0.1"; # admin-vpn: OPNsense admin-WG listener (over tunnel)

  # Standing root key = OPERATOR out-of-band key (NOT a tappaas-cicd key) — §7.3.
  operatorSshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMbnK/kG1ZWpo/pCtAqoD0VsztCDSidMcFcQa3OmPMK2 larsrossen@MacBookAir.hrossen.dk"
  ];
}
