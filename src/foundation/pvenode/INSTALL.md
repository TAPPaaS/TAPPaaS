# pvenode — install

Primary audience: TAPPaaS admin. What the automation cannot do for you: nothing, normally.

The cluster module's update registers every node that has no instance yet (Step 7), and
`site-manager node add` registers each node it joins. To register one by hand:

```bash
module-manager module adopt tappaas2.mgmt.internal
```

`adopt` sees Proxmox VE on the machine, checks that `site.json` lists it as a cluster node, and
installs it as a `pvenode` instance named after the node. Nothing on the node changes. A
Proxmox host that is not in this Site's cluster is refused: join it first with
`site-manager node add <name>`.
