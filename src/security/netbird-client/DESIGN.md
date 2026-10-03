# NetBird Client — Design notes

## Current implementation

- Debian cloud-image VM (`templates:debian`, cloud-init), 1 vCPU / 1 GB / 4 GB.
- VM creation is handled by `cluster:vm` and HA registration by `cluster:ha`
  (both declared in `dependsOn` and run by the install engine before
  `install.sh`); the module `install.sh` itself only runs `update.sh`. The
  actual NetBird package install is still manual (see INSTALL.md Post-install).
- This client is different from the NetBird client installed by default on
  the `mgmt` network for TAPPaaS management access. This one is for business
  or home users who want a VPN connection into their solution/installation.
- You can have several jsons if you want clients in several TAPPaaS zones.

## Known issues / TODO

Preserved from the previous README:

- Convert to NixOS
- Convert to using the new install system
- Right now the module does not work

## Repository housekeeping

- The module has no `test.sh` yet.
