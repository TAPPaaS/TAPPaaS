# NetBird Client — Design notes

## Current implementation

- Debian cloud-image VM (`templates:debian`, cloud-init), 1 vCPU / 1 GB / 4 GB.
- `install.sh` provisions the VM via `install-vm.sh`, runs `apt update/upgrade`
  and installs `curl`, then registers HA via `update-HA.sh`. The actual
  NetBird package installation line is present but commented out, so the
  client must be installed manually (see INSTALL.md Post-install).
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

- `install copy.sh` appears to be a stale copy of an older install script
  (pre-`install-vm.sh` flow, using `Create-TAPPaaS-VM.sh` directly) and is a
  candidate for removal.
- The module has no `test.sh` yet.
