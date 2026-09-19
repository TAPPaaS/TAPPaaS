# pvenode — tests

`test.sh <instance>`:

1. root login by the mothership's key — without it nothing else is checked;
2. the node runs Proxmox VE, and its hostname is the instance name;
3. `site.json` `hardware.nodes` lists it, and `pvecm status` reports the cluster quorate;
4. root filesystem below 90% full;
5. clock synchronised (corosync depends on it);
6. (information) a pending reboot — the cluster module's reboot pass takes it, so it is not a
   failure here.

Unit tests for the choice `adopt` makes (Proxmox → `pvenode`, membership in `site.json`) are in
`tappaas-cicd/scripts/test/test-adopt.sh`.
