# pvehost — tests

`test.sh <instance>`:

1. root login by the mothership's key — without it nothing else is checked;
2. the node runs Proxmox VE, and its hostname is the instance name;
3. it is a member of this Site's cluster (its cluster status names another of the site's nodes, or the site), and `pvecm status` reports it quorate;
4. root filesystem below 90% full;
5. clock synchronised (corosync depends on it);
6. (information) a pending reboot — the cluster module's reboot pass takes it, so it is not a
   failure here.

Unit tests for the choice `adopt` makes (Proxmox → `pvehost`, membership in `site.json`) are in
`tappaas-cicd/scripts/test/test-adopt.sh`.
