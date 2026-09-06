# TAPPaaS Applications

Each module in the `apps` directory adds a capability to your TAPPaaS installation.
See the module's own `README.md` for install instructions.

To create a new module, see [00-Template](./00-Template/README.md).

## Installing a module

```bash
module-manager module add <module>
```

## VM console screenshot

When you can't SSH into a VM — during setup, after a failed boot, or Windows OOBE — take
a screenshot directly from the Proxmox QEMU monitor. Works for all OS types.

```bash
ssh root@<node>.mgmt.internal "qm screendump <VMID> > /tmp/screen.ppm && base64 /tmp/screen.ppm"
```

Paste the output into a base64 decoder (e.g. `base64 -d > screen.ppm`) to view it.
The VMID for each module is in its JSON file and in `src/module-catalog.json`.
