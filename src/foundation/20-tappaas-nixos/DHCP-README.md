# DHCP Hostname Registration - Known Issue

This document describes a known issue with hostname registration for VMs cloned from the `tappaas-nixos` template (VM 8080).

## Current Behavior

When cloning a NixOS VM from the template:
1. The cloned VM gets its hostname set via cloud-init (from the Proxmox cloud-init configuration)
2. The VM's internal hostname is correctly set to the new name
3. **However**, the DHCP lease registered with the DHCP server may show the template's hostname (`tappaas-nixos`) instead of the clone's hostname

## Why This Happens

1. **NixOS manages the static hostname declaratively** - The hostname in `/etc/hostname` is set at build time to `tappaas-nixos` and cannot be changed at runtime via standard tools like `hostnamectl`.

2. **NetworkManager reads from systemd-hostnamed** - When NetworkManager's DHCP client sends the hostname in DHCP requests, it reads from `systemd-hostnamed`, which uses the static hostname from `/etc/hostname`.

3. **cloud-init's hostname module runs after network** - By default, cloud-init sets the hostname after the network is already up, meaning the first DHCP request uses the template's hostname.

4. **DHCP lease caching** - Once the DHCP server has a lease with a hostname, it may not update the hostname on subsequent renewals unless a full release/request cycle occurs.

## Workaround

The hostname displayed in the DHCP lease is primarily cosmetic for DNS purposes. The VM itself has the correct hostname set by cloud-init. If accurate DHCP hostname registration is required:

1. **Manual DHCP renewal after boot**: SSH into the cloned VM and run:
   ```bash
   sudo nmcli connection modify "Wired connection 1" ipv4.dhcp-hostname "$(hostname)"
   sudo nmcli device reapply eth0
   ```

2. **Use static DHCP reservations**: Configure the DHCP server (OPNsense) with static mappings that associate MAC addresses with hostnames.

## Attempted Solutions

A more complex solution involving two systemd services was attempted:
- `cloud-init-hostname`: Set kernel hostname from cloud-init before network starts
- `cloud-init-hostname-dhcp`: Update NetworkManager's dhcp-hostname and trigger DHCP renewal

This approach had several challenges on NixOS:
- NixOS doesn't allow `hostnamectl set-hostname` or `nmcli general hostname` at runtime
- Connection profiles cloned from the template retain old dhcp-hostname settings
- Timing issues between services and NetworkManager's DHCP client

The solution was reverted in favor of the simpler static hostname configuration.

## Related Files

- `tappaas-nixos.nix` - Main NixOS configuration (uses `networking.hostName = lib.mkDefault "tappaas-nixos"`)
- Cloud-init handles setting the actual VM hostname after boot
