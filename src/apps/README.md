# TAPPaaS Applications

Each module in the `apps` directory adds a capability to your TAPPaaS installation.
See the module's own `README.md` for install instructions.

To create a new module, see [00-Template](./00-Template/README.md).

## Installing a module

```bash
install-module.sh <module>
```

## Deploying multiple instances of the same module

`deploy-instances.sh` deploys N **new** instances of any VM-backed module on top of however
many are already installed. Instance names and VMIDs are assigned automatically within the
base module's hundreds block (e.g. base 500 → stays in 500–599).

```bash
deploy-instances.sh <module> <count>

# Examples
deploy-instances.sh windows-server 3   # add 3 new instances
deploy-instances.sh vaultwarden 2      # add 2 new instances
```

`count` is the number of **new** instances to add — not the total desired. Already-installed
instances are shown in the confirmation table and never touched.

## VM console screenshot

When you can't SSH into a VM — during setup, after a failed boot, or Windows OOBE — take
a screenshot directly from the Proxmox QEMU monitor. Works for all OS types.

```bash
ssh root@<node>.mgmt.internal "qm screendump <VMID> > /tmp/screen.ppm && base64 /tmp/screen.ppm"
```

Paste the output into a base64 decoder (e.g. `base64 -d > screen.ppm`) to view it.
The VMID for each module is in its JSON file and in `src/module-catalog.json`.
