# pvehost

Primary audience: TAPPaaS admin.

A **Proxmox VE cluster node as a module** (ADR-026 D4, #665). Each node of the cluster is an
instance — `config/tappaas1.json`, `config/tappaas2.json`, … — named after the node, so
`module-manager module list` shows the machines the Site runs on, and `module test` checks them.

## What you get

| Capability | How |
|---|---|
| The nodes in TAPPaaS's inventory | one instance per node, `kind: machine`, `os: debian` |
| Health checks | reachable by key, Proxmox VE, in this Site's cluster and quorate, disk below 90%, clock synchronised |
| Serving NFS shares | the node is a server for the storage module (ADR-029 v0.9 D19): `storage/nfs-server.sh` builds, re-quotas, shares and unshares the shares `config/shares.json` places on it — declared with `storage-manager`, never in the node's own config; `module update <node>` re-converges them and `module test <node>` checks them |
| Configuration backup | through `backup:filesystem`, like a guest (#662): `/etc` whole (a fixed list of subdirectories goes stale when Proxmox moves something), `/var/lib/pve-cluster` (`/etc/pve` is only a FUSE view of pmxcfs — copying it back is not a restore), and `/root` minus the netboot ISOs that `make-install-media.sh` rebuilds. Declared with `integratesWith`, not `dependsOn` (#501): a node registers long before a backup server exists |
| Registration without effort | the cluster module's update registers every node that is not an instance yet; `site-manager node add` registers a node it joins |

## What is not included (stage 1)

- **Patching.** A node's OS is still patched by the cluster module (`update-os.sh`), with the
  cluster's reboot pass. `module update <node>` does nothing and says so. Moving patching here
  is ADR-026 D4 stage 2.
- **Joining.** A node becomes an instance only once it is a member of this Site's cluster
  (its own cluster status names another of the site's nodes, or the site). Joining is
  `site-manager node add`; adopting never joins.
- **The node's record.** The instance is the node: the cluster's nodes are exactly the
  `pvehost` instances (`site-manager node list`). Besides `address`, `uplinks` and `location`
  it carries `storagePools`, the tankXY zpools the node holds guest disks on; adoption records
  them from the node, and the cluster update adds the node to each pool's storage list.
- **Removing a node.** `module delete <node>` only unregisters it — the node, and its place in
  the cluster, are untouched.

## Requirements

- A member of this Site's cluster, reachable as root with the mothership's key (which every
  node already is).
