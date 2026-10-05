# storage:nfs service

Mounts **NFS shares** into a consumer's guest, **by share name** — never by the
machine that carries the share. Decided by
[ADR-029](../../../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) (v0.9); built in
#766 and #772.

1 field — `mounts`, `in-place`, `apply: "reconcile"`.

## Two declarations, one service

The operator declares the share; the consumer says what it mounts. Neither alone
decides access — the service joins them.

```bash
# the share — Site state in config/shares.json, written only by storage-manager
storage-manager nfs share add media --server tappaas1 --pool tankb1 --quota 4T --backup true
storage-manager nfs grant media jellyfin rw
```

```jsonc
// jellyfin.json — the consumer: the same file on every site
"dependsOn": ["cluster:vm", "network:rules", "storage:nfs", "..."],
"config": { "storage:nfs": { "mounts": [
  { "path": "/media", "share": "media", "subdir": "jellyfin", "access": "rw",
    "stopUnits": ["jellyfin.service"] }
]}}
```

`share add` allocates the share's owner (64000–64999) and has the server's NFS
hook (`pvehost/storage/nfs-server.sh`) build `tankb1/tappaas-nfs/media`
**mounted at `/tappaas-nfs/media`** (the same path on every node); the **share
alias `nfs-media.mgmt.internal`** → `tappaas1.mgmt.internal` is created. The
dataset is shared through ZFS `sharenfs` to each consumer that is granted,
deployed and mounts it — NFSv4 only, `root_squash`, every client squashed to the
owner. The guest mounts `nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin`, so
a share that moves to another node or pool changes only the alias.

Share names are unique across the Site; a registered NAS's shares are named and
reached the same way. Only `<ip-or-host>:/<path>`, for a server TAPPaaS does not
model, is used as written.

`network:rules` is listed before `storage:nfs` on purpose: an update applies
dependencies in order, and this service also recompiles the consumer's rules
before a cross-zone mount, so the firewall path exists when the mount is tried.

## Pending, and migrating into a share that arrives later

| The share… | The consumer |
|---|---|
| is not declared | **pending**: installs anyway, `path` stays a directory on its own disk |
| exists but does not grant the consumer | **refused** — add the grant, or remove the mount |
| exists and grants it | mounted — or migrated into, when `path` already holds data |

A migration stops the app, so it runs only with consent — the consumer's
`rebootOk`, or `--allow-disruption`; otherwise the update reports *migration
pending*. It copies the directory into the share while the app runs, stops the
mount's `stopUnits` (and runs `stopCommand`), checks that nothing else still has a
file open there, copies the difference, keeps the local directory as
`<path>.pre-nfs`, mounts the share and starts the app again. Any failure leaves
the app running on its local data. The next healthy update removes
`<path>.pre-nfs`. A share that already holds data is never merged into. Once
migrated, a share that disappears is an error — never a silent fall back to a
local directory.

`storage-manager nfs grant` (and `nfs converge <share> --notify`) runs this
service's update for the consumers the share just became available to, so a
migration does not wait for the next sweep. A mount found as an automount that
is not yet triggered is a mount, not local data — it is never migrated.

## What a consumer gets

| Guest OS | The mounts arrive as |
|---|---|
| NixOS | `/etc/nixos/tappaas-nfs.nix` — NFS support and rsync always (so a later migration can run), plus a `fileSystems` entry per mount that is not pending; imported by `tappaas-common.nix`, applied by the rebuild that install and update run after the services |
| Debian | a marked block in `/etc/fstab`, applied at once |

Every mount is `hard,_netdev,noatime`; unless `required: true` it is also
`nofail` + `x-systemd.automount`, so the guest boots and the app starts while
the server is down.

## The firewall path

A consumer outside its share's server's zone needs one rule, and it is derived,
never written: `network:rules` reads the consumer's mounts and compiles one
host-to-host pass per share — consumer alias → a host alias holding the share
alias, tcp/2049; NFSv3 on a registered NAS adds rpcbind and its pinned
`v3Ports`. No rule within a zone, none for a pending mount. The apply that compiles the rule
waits (up to 90 s) until OPNsense has resolved the share alias into its table, so a
mount right after it — an install, a grant — does not race the resolution. Such a consumer must
depend on `network:rules`; a cross-zone mount without it is refused.

## What it refuses

- a share that exists but does not grant the consumer, or `rw` against an `ro`
  grant;
- a share whose server is not a module instance, or whose module cannot serve;
- a literal `<host>:/<path>` on a host that is a module instance, or on a public
  address; a share on a server in the `wan` zone;
- a mount over `/`, `/etc`, `/nix`, `/var`, `/usr`, `/boot` or a system path; a
  `subdir` with `..` or a leading `/`;
- a mount through the firewall from a consumer that does not depend on
  `network:rules`.

## What it never does

Destroy data. Removing a mount unmounts; deleting the consumer removes its mounts
and **takes its address out of every client list at once** (ADR-029 D16);
`storage-manager nfs share delete` unshares and keeps the dataset (an orphan);
only `nfs share purge --yes` destroys it.

## Not built yet (#772)

Backup of shares (WP6), registered NAS servers beyond the share-reference check
(WP7), the storage zone (WP9), LXC consumers (WP10), quota health (WP11), and a
`storage-manager nfs share move` verb.

**Not encrypted.** NFS runs cleartext on internal VLANs. RPC-with-TLS is
deferred: OpenZFS 2.4.4's `sharenfs` refuses `xprtsec=tls`, and exports stay on
`sharenfs` (ADR-029 v0.7, D5 records what was proven; #771).

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`storage:nfs` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `mounts`

The NFS shares this guest mounts (ADR-029 v0.9 D3). Each entry: {path, share, subdir?, access?, required?, stopUnits?, stopCommand?, startCommand?}. share is a Site-unique share NAME — never the machine that carries it; it is reached through its DNS alias nfs-<share>.mgmt.internal — or <ip-or-host>:/<path> for an unmodelled server. A share not declared in config/shares.json leaves the mount pending: the directory stays local, and is migrated into once the share appears (with consent).

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `[{"path": "/media", "share": "media", "subdir": "jellyfin", "access": "rw", "stopUnits": ["jellyfin.service"]}]` |
| Required by | *(none)* |
| Used by | `storage:nfs` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** The mounts are reconciled whole: update-service.sh rewrites the guest's generated mount list (NixOS fragment, applied by the rebuild the update runs; Debian fstab block, applied at once). Changing share or subdir remounts and moves no data; only a pending mount whose share has appeared is migrated into, and only with consent (rebootOk or --allow-disruption) — that is the one change that stops the app. Nothing reboots.

<!-- END GENERATED FIELDS -->
