# pvehost:nfs service

Mounts **NFS shares** into a consumer's guest: a ZFS dataset a cluster node
exports, a share on a NAS the site owns, or a path on a server nobody here
models. Decided by [ADR-029](../../../../../docs/ADR/ADR-029%20-%20NFS%20Service.md);
built in #766.

2 fields — both `in-place`, `apply: "reconcile"`.

## Two declarations, one service

The node says what it serves; the consumer says what it mounts. Neither alone
decides access — the service joins them.

```jsonc
// config/tappaas1.json — the node (its own module-tier field, no dependsOn)
"nfs": { "exports": [
  { "name": "media", "pool": "tankb1", "quota": "4T",
    "backup": { "enabled": true },                    // required: true or false
    "grants": [ { "consumer": "jellyfin", "access": "rw" } ] }
]}

// jellyfin.json — the consumer
"dependsOn": ["cluster:vm", "pvehost:nfs", "..."],
"config": { "pvehost:nfs": { "mounts": [
  { "path": "/var/lib/jellyfin/media", "share": "tappaas1:media", "access": "rw" }
]}}
```

`pvehost update tappaas1` builds `tankb1/tappaas-nfs/media`, allocates its owner
(64000–64999, written back into the node's file), and shares it through ZFS
`sharenfs` to each granted consumer's address — NFSv4 only, `root_squash`, every
client squashed to the owner. The consumer's install (or update) checks the
mount against the grant, has the node build the export if it is declared but not
built yet, and writes the mount into the guest.

## What a consumer gets

| Guest OS | The mounts arrive as |
|---|---|
| NixOS | `/etc/nixos/tappaas-nfs.nix` — `fileSystems` entries, imported by `tappaas-common.nix`, applied by the rebuild that install and update run after the services |
| Debian | a marked block in `/etc/fstab`, applied at once |

Every mount is `hard,_netdev,noatime`; unless `required: true` it is also
`nofail` + `x-systemd.automount`, so the guest boots and the app starts while
the node is down.

## The firewall path

A consumer outside its server's zone needs one rule, and it is derived, never
written: `network:rules` reads the consumer's mounts and compiles one
host-to-host pass per server — consumer alias → node alias (the node's recorded
`address`), tcp/2049; NFSv3 on a registered NAS adds rpcbind and its pinned
`v3Ports`, tcp and udp. No rule within a zone. Such a consumer must therefore
depend on `network:rules`; a cross-zone mount without it is refused rather than
left to hang.

## What it refuses

- a share the node does not declare — **a consumer never creates an export**;
- a consumer the export does not grant, or `rw` against an `ro` grant;
- a `<host>:/<path>` share on a host that is a module instance (name the share
  instead, so the grant is checked);
- a mount over `/`, `/etc`, `/nix`, `/var`, `/usr`, `/boot` or a system path;
- a mount through the firewall from a consumer that does not depend on
  `network:rules`.

## What it never does

Destroy data. Removing a mount unmounts; deleting the consumer removes its
mounts; removing an export from the node unshares it and keeps the dataset
(reported as an orphan).

## Not built yet (#766)

Backup of exports (WP6),
registered NAS servers beyond the share-reference check (WP7), the storage zone
(WP9), LXC consumers (WP10), quota health (WP11) and the `pvehost nfs
show/purge` verbs.

**Not encrypted.** NFS runs cleartext on internal VLANs. RPC-with-TLS is
deferred: OpenZFS 2.4.4's `sharenfs` refuses `xprtsec=tls`, and exports stay on
`sharenfs` (ADR-029 v0.7, D5 records what was proven; #771).

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`pvehost:nfs` owns **2** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `nfs`

The NFS shares this machine serves (ADR-029 D4, D2a). On a cluster node each exports[] entry becomes the dataset <pool>/tappaas-nfs/<name>, shared through ZFS sharenfs to the consumers it grants; on a registered, unmanaged server each entry describes a share that already exists, by path.

| Attribute | Value |
|---|---|
| Type | `object` |
| Example | `{"exports": [{"name": "media", "pool": "tankb1", "quota": "4T", "properties": {"recordsize": "1M", "compression": "lz4"}, "backup": {"enabled": true}, "grants": [{"consumer": "jellyfin", "access": "rw"}]}]}` |
| Required by | *(none)* |
| Used by | `pvehost:nfs` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** The data belongs to the export, never to a consumer (ADR-029 D6): removing an export unshares it and keeps the dataset; only an explicit purge destroys it. A consumer never creates an export — a mount naming one that is not declared here is refused (D11).

**Why this change class.** Converged by the node's own update (pvehost/update.sh → nfs_node_reconcile): exports are created, re-quota'd, re-granted and unshared live; nothing reboots. name, pool and an allocated owner are immutable in substance — a rename or a pool move is a data migration and is not attempted; the reconcile treats the old dataset as an orphan and keeps it.

### `mounts`

The NFS shares this guest mounts (ADR-029 D3). Each entry: {path, share, access?, required?}. share is <instance>:<name> for a share declared on a module instance, or <host>:/<path> for an unmodelled server.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `[{"path": "/var/lib/jellyfin/media", "share": "tappaas1:media", "access": "rw"}]` |
| Required by | *(none)* |
| Used by | `pvehost:nfs` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** The mounts are reconciled whole: update-service.sh rewrites the guest's generated mount list (NixOS fragment, applied by the rebuild the update runs; Debian fstab block, applied at once). Adding or removing a mount remounts; nothing reboots and no share data is touched.

<!-- END GENERATED FIELDS -->
