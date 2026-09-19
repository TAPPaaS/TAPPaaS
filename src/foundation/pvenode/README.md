# pvenode

Primary audience: TAPPaaS admin.

A **Proxmox VE cluster node as a module** (ADR-026 D4, #665). Each node of the cluster is an
instance — `config/tappaas1.json`, `config/tappaas2.json`, … — named after the node, so
`module-manager module list` shows the machines the Site runs on, and `module test` checks them.

## What you get

| Capability | How |
|---|---|
| The nodes in TAPPaaS's inventory | one instance per node, `kind: machine`, `os: debian` |
| Health checks | reachable by key, Proxmox VE, in this Site's cluster and quorate, disk below 90%, clock synchronised |
| Registration without effort | the cluster module's update registers every node that is not an instance yet; `site-manager node add` registers a node it joins |

## What is not included (stage 1)

- **Patching.** A node's OS is still patched by the cluster module (`update-os.sh`), with the
  cluster's reboot pass. `module update <node>` does nothing and says so. Moving patching here
  is ADR-026 D4 stage 2.
- **Joining.** A node becomes an instance only once it is a member of this Site's cluster
  (`site.json` `hardware.nodes`). Joining is `site-manager node add`; adopting never joins.
- **Removing a node.** `module delete <node>` only unregisters it — the node, and its place in
  the cluster, are untouched.

## Requirements

- A member of this Site's cluster, reachable as root with the mothership's key (which every
  node already is).
