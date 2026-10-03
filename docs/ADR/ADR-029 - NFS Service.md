# ADR-029 — NFS Service (`pvehost:nfs`)

| | |
|---|---|
| **Status** | **Draft** (2026-10-03) |
| **Version** | 0.5 |
| **Date** | 2026-10-03 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#52** (Jellyfin — the first consumer) · [ADR-009](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates, `config."<module>:<service>"`) · [ADR-012](ADR-012-backup-enhancement.md) (`backup:filesystem` backs up the exports — D9; F.3 narrowed to external shares) · [ADR-019](<ADR-019 - HA and Cross-Node VM Migration Policy.md>) (an HA guest mounting non-HA data) · [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) (the change classes in `services/nfs/fields.json`) · [ADR-021](<ADR-021 - Split-Horizon DNS and Service Reachability.md>) (host-scoped rules, never `access-to`) · [ADR-022c](<ADR-022c - Node and Host.md>) (Host) · [ADR-026](<ADR-026 - Managed Machines as Modules.md>) (the export Host is a machine module; D6 instance names) · [ADR-027](<ADR-027 - Module Blueprint.md>) D3 (the six files of `services/nfs/`) |
| **Changelog** | v0.5 (2026-10-03, operator review) — D2a names the two outside-the-cluster servers apart: **registered, unmanaged** (a module instance with declared shares) and **unmodelled** (an address in a literal path). Several servers are several instances (`nas1`, `nas2`). Exports move out of `config."pvehost:nfs"` into the server's own module-tier **`nfs.exports[]`**: the `config` block is the consumer's, and no server — node or NAS — carries a `dependsOn`/`integratesWith` for NFS; the consumer's `dependsOn: pvehost:nfs` is the only edge. · v0.4 (2026-10-03, operator review) — the provider is **`pvehost`** (`pvehost:nfs`), not `cluster` or a new `storage` module (D1, Q3 closed); exports use **ZFS `sharenfs`** (new D4a, with the analysis), replacing the TAPPaaS-owned `exports.d` file; an NFS server in a guest is rejected (no ZFS sharing, costs a VM), and HA shared data points to CIFS/S3 in a next version (D8). Q9 added. File renamed from *Cluster NFS Service*. · v0.3 (2026-10-03) — **D2a**: a dedicated NFS server outside the cluster is a share source — registered as an `unmanaged` instance whose `exports[]` describe existing paths (`path`, `version`, pinned `v3Ports`), named in mounts like any export; TAPPaaS enforces the grant and the firewall rule on its side, prints what the server must carry, and detects access drift from the consumer. NFS across `wan` refused. Q4 (consumer-provisioned exports) rejected by the operator. · v0.2 (2026-10-03) — D9 rewritten: an export is backed up by its **Host's `backup:filesystem`**, one PBS group per export from a ZFS snapshot, with a mandatory `backup.enabled` on every export; restore lands beside the live dataset. ADR-012 F.3 remains only for external shares. Q8 (off-site) added. · v0.1 (2026-10-03) — first draft: one service, two declarations (export on a Host, mount on a guest); the `<host>:<name>` share reference; a four-layer access model with squash-to-owner identity; data outlives its consumers. |

A module that runs in a `cluster:vm` guest can mount a **named NFS share** at a directory
inside the guest, and a machine TAPPaaS manages can **export a ZFS dataset** from one of its
pools as that share — declared, reconciled and access-controlled like every other service.

---

## Context

**Jellyfin (#52) needs a large media library that does not belong in its VM.** Every
TAPPaaS guest today keeps all its data on its own virtual disk, normally on `tanka1` — the
fast, redundant pool that HA replicates. A multi-terabyte video library there is the wrong
trade on every axis: it costs SSD mirror capacity, it multiplies replication traffic, it
makes every backup of the guest enormous, and it ties the library's life to the VM's.
`tankb1` exists for exactly this data — `config-storage.sh` describes it as *"less
important services and data … typically not using disk redundancy and not participating in
HA replication"* — but the only way a guest can use it today is as a VM disk.

A second VM disk on `tankb1` (see *Alternatives*) solves the capacity part and none of the
rest. Three things are missing:

1. **Data with its own lifecycle.** Deleting or rebuilding the Jellyfin VM must not touch
   the library. Today a disk is the guest's, and goes with it.
2. **Data shared between guests.** The same library will want a second writer — a download
   or upload service, Nextcloud — and a VM disk has one owner.
3. **Storage that is not ours.** Many sites already run a dedicated NFS server — a NAS, a
   storage box, a file server another team looks after. A guest should be able to mount a
   share from it as a first-class declaration, with the firewall and the mount derived, and
   without the operator hand-editing `/etc/fstab` on a NixOS guest that will overwrite it on
   the next rebuild.

ADR-012 F.3 already anticipated "external NFS-served data that is not inside a
TAPPaaS-managed guest" and deferred it for lack of a model. This ADR is that model.

---

## 0. Vocabulary

| Term | Means |
|---|---|
| **export** | A ZFS dataset on a Host, created and exported over NFS by TAPPaaS. Has a **name** unique on its Host. |
| **export Host** | The machine module instance (ADR-026) whose pool carries the export — in v1 a cluster node (`pvehost`); a Debian machine (`debianhost`) later. |
| **registered, unmanaged NFS server** | An NFS server **outside the cluster** that the site owns — a NAS, a dedicated file server — registered as a module instance with `management: unmanaged` (D2a). TAPPaaS knows it and its shares by name, and never configures it. |
| **unmodelled NFS server** | An NFS server **also outside the cluster**, known to TAPPaaS only as an address in a mount's literal path — no module instance, no name, no declared shares. |
| **share** | Anything a guest can mount over NFS: a TAPPaaS export, a share on a registered server, or an unmodelled server's path. |
| **share reference** | The string a mount names its share by: `<host>:<name>` or `<host>:/<path>` (D2). |
| **mount** | A consumer's declaration that a share appears at a directory inside its guest. |
| **consumer** | The module that declares the mount. In v1 always a `cluster:vm` guest. |
| **grant** | An export's statement that a named consumer may mount it, `ro` or `rw`. |

---

## Decision

### D1 — One service, two declarations

The **`pvehost`** module — the cluster node as a module (ADR-026 D4) — **provides `nfs`**
(added to `pvehost.json` `provides`), implemented in `src/foundation/pvehost/services/nfs/`
with the ADR-027 D3 file set. The provider is the node, not the `cluster` module and not a
new `storage` module, because the thing being served is the node's own: its pools, its
datasets, its NFS server. The node is already a module instance with a name a share
reference can pin (ADR-026 D6.6), and it already backs itself up through
`backup:filesystem` (D9). `cluster` keeps what is genuinely cluster-wide — VM, LXC, HA
placement — and creating the pools stays in `config-storage.sh`.

`pvehost:nfs` is consumed in two places, by two kinds of module, with two different fields:

| Declared on | Field | What it says |
|---|---|---|
| a node's instance file (`config/tappaas2.json`) | `nfs.exports[]` — the node's own field | "create this dataset on this pool and let these consumers mount it" |
| a consumer's module file (`jellyfin.json`) | `config."pvehost:nfs".mounts[]` | "mount this share at this directory in my guest" |

The two fields sit in different places on purpose. **`config."<module>:<service>"` is the
consumer's block** (ADR-009): it says what a module wants from a service it depends on, so
the mount goes there. **A server describing its own shares consumes nothing**, so its
exports are a module-tier object of its own — `nfs.exports[]`, the way `backup` is a
module-tier object (ADR-012 §2.7) — defined once in the schema and read by `pvehost:nfs`.
The same `nfs` object describes the shares of a registered, unmanaged server (D2a). No
server carries a `dependsOn` or `integratesWith` for NFS: **the only dependency edge is the
consumer's `dependsOn: pvehost:nfs`**, and its share reference picks the server instance
(D2).
A `debianhost` that should export a pool gets the same service later, as `debianhost:nfs`
from a shared library — v1 exports from cluster nodes only.

Both are one service because **access is a join between them** (D5): neither side alone can
decide the export's client list, the firewall rule or the conflict between a `ro` grant and
an `rw` request. One service owns both halves and reconciles the pair; two services would
each own half a rule.

The service runs on the mothership like every other provider, reaching the export Host and
the guest over the same SSH paths `backup:filesystem` already uses.

### D2 — The share reference: `<host>:<name>` or `<host>:/<path>`

A mount names its share with one string, read like the `host:dir` of NFS itself. Where the
server lives decides how much TAPPaaS does — but the consumer writes the same mount either
way:

| Form | Example | Server | TAPPaaS does |
|---|---|---|---|
| `<instance>:<name>` on a **managed** Host | `tappaas2:media` | a cluster node (`pvehost`; `debianhost` later) | everything: creates the dataset, exports it, derives all four access layers (D5), backs it up (D9). |
| `<instance>:<name>` on a **registered, unmanaged server** | `nas1:video` | outside the cluster: a NAS or file server the site owns, registered as an `unmanaged` module instance (D2a) | the consumer side only: validates the grant, derives the firewall rule, mounts — and **reports** what the server must be configured with, never configures it. |
| `<fqdn-or-ip>:/<path>` | `files.partner.example:/exports/shared` | also outside the cluster: an **unmodelled** server — not a module, typically outside the Administrative Domain (ADR-022g) | the firewall rule and the mount, nothing else. |

The rule that separates the forms is unambiguous: **no leading slash → a named share on a
module instance; a leading slash → a literal path.** A literal path on a host that *is* a
module instance — managed, or registered and unmanaged — is refused at validate time: if TAPPaaS knows the
server, the share is named there, and a path form would be a way around the grant.

The `<instance>` is a module instance name (ADR-026 D6), not an address: an address changes,
an instance name does not, and the instance name is what lets the validator find the
declaration.

### D2a — A registered, unmanaged NFS server

Two kinds of NFS server sit **outside the cluster**, and the difference between them is
whether TAPPaaS models them:

| | Registered, unmanaged | Unmodelled |
|---|---|---|
| What it is | a NAS or file server **the site owns** | a server nobody here models — another party's, or a one-off |
| In TAPPaaS | a module instance, `kind: machine`, `management: unmanaged` (ADR-022g D3, ADR-026) | only the address in a mount's literal path (D2) |
| Named | yes — `config/<instance>.json`, a DNS name, a firewall alias | no |
| Shares declared | yes — `nfs.exports[]` descriptors | no |
| Configured by TAPPaaS | **never** — no login, no packages, no export table | never |

Registering is the recommended path for any server the site owns: it is what gives TAPPaaS
something to check grants and drift against. The literal form is the fallback for a server
that is not ours to describe.

A registered server's shares are declared in the same `nfs.exports[]` object a node uses,
but as **descriptors of what already exists** — a `path` instead of a `pool`:

```json
// config/nas1.json — a registered, unmanaged NFS server
"management": "unmanaged",
"nfs": {
  "exports": [
    {
      "name": "video",
      "path": "/volume1/video",
      "version": "4.1",
      "grants": [ { "consumer": "jellyfin", "access": "ro" } ]
    }
  ]
}
```

No `dependsOn`, no `integratesWith` and no `config."pvehost:nfs"` block: the server does not
consume the NFS service, it is described *to* it (D1).

**Several servers are several instances.** A site with two NAS boxes registers two
instances of the same module — `config/nas1.json` and `config/nas2.json`, each named after
its machine (ADR-026 D6, D8) — and a consumer names the one it wants: `nas1:video`,
`nas2:photos`. Share names need only be unique per server, so both may have a `backup`
share without colliding. What module type those instances belong to is Q9.

| Field | On a registered server |
|---|---|
| `name`, `grants` | as on a managed Host (D4). |
| `path` | **required** — the path the server exports. Forbidden on a managed Host. |
| `version` | `4.2` (default), `4.1`, `4.0` or `3`. Many NAS still default to older protocol versions; the mount follows what the server offers. |
| `v3Ports` | **required with `version: "3"`** — `{mountd, nlockmgr, statd}`. NFSv3 needs `rpcbind` (111) and the auxiliary daemons, whose ports are dynamic unless pinned; the firewall rule (layer 2) can only be host-scoped if they are pinned, so a v3 share with dynamic ports is refused. |
| `pool`, `quota`, `owner`, `properties`, `backup` | **forbidden** — TAPPaaS does not provision, own or back up this data. |

What TAPPaaS can and cannot do for such a share, by the D5 layers:

| Layer | Registered, unmanaged server | Unmodelled server (literal path) |
|---|---|---|
| 1 Authorization | **enforced on the TAPPaaS side**: the two-key check runs against the descriptor's grants exactly as for a managed export. | none — the mount is the only declaration. |
| 2 Network | derived: consumer → server `/32` on tcp/2049 (plus 111 and `v3Ports`, tcp and udp, for v3). No rule when consumer and server share a zone — that traffic never crosses OPNsense. | derived the same way, to the literal host. |
| 3 Client list | **reported, not applied**: `pvehost nfs show <instance>` prints, per share, the consumer addresses and `ro`/`rw` the server's export table must carry, and the recommended options (`root_squash`, `all_squash` to one owner — D5). | the operator's. |
| 4 File identity | recommended (squash-to-owner), not enforceable. If the server maps UIDs instead, files are created with each consumer's own app UID, which differs between guests — `show` warns. | the operator's. |

**Drift is detected, not healed.** `test-service.sh` runs from each consumer: the share
mounts, an `rw` mount can write and an `ro` mount cannot. A server whose export table has
fallen behind its descriptor fails that test and raises a health finding naming the share
and the missing client — the operator fixes the server, TAPPaaS cannot.

**Where the server may be.** In one of the site's zones, or on a private routed network the
firewall reaches. A server reached through `wan`/the internet is **refused** in v1 for both
forms: NFS with `sec=sys` is cleartext and trusts the client's claimed UID, which is
tolerable on our own VLANs and not across someone else's network (Q5 reopens this with TLS).

**Lifecycle and backup.** TAPPaaS never touches data on a registered, unmanaged server or an unmodelled one:
removing a mount unmounts and removes the rule; deleting the registered instance while
consumers still mount its shares is refused; there is no purge. Backing up that data is the
server's own business — ADR-012 F.3's `backup:dataset` remains the open question for it.

### D3 — The mount declaration

```json
"dependsOn": ["cluster:vm", "pvehost:nfs", "..."],
"config": {
  "pvehost:nfs": {
    "mounts": [
      {
        "path": "/var/lib/jellyfin/media",
        "share": "tappaas2:media",
        "access": "ro",
        "required": false
      }
    ]
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `path` | absolute path | — | The directory in the guest. Must not be `/`, `/nix`, `/etc`, `/var` or a parent of another mount's `path`. Created if absent. |
| `share` | share reference (D2) | — | What is mounted there. |
| `access` | `ro` \| `rw` | `ro` | What the consumer asks for. Must not exceed the grant (D5). Least privilege is the default. |
| `required` | boolean | `false` | `false`: the guest boots and the app starts without the share (`nofail`, `x-systemd.automount`). `true`: a systemd ordering dependency — the app's unit waits for the mount. |
| `options` | string[] | `[]` | Escape hatch for mount options from an allow-list (`rsize=`, `wsize=`, `timeo=`, `noatime`, `actimeo=`). `sec=`, `vers=`, `nolock` and anything security-relevant are TAPPaaS's, not the module's. |

Mounts are always **NFSv4.2, `hard`, `_netdev`** (D8 explains `hard`).

### D4 — The export declaration

The export is declared on the **Host**, not on the consumer, because the data belongs to the
Host's pool and outlives every consumer (D6).

```json
// config/tappaas2.json — the pvehost instance for node tappaas2
"nfs": {
  "exports": [
    {
      "name": "media",
      "pool": "tankb1",
      "quota": "4T",
      "backup": { "enabled": true },
      "grants": [
        { "consumer": "jellyfin", "access": "rw" }
      ]
    }
  ]
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | `^[a-z][a-z0-9-]*$` | — | Unique on the Host. The second half of the share reference. |
| `pool` | ZFS pool name | — | Must exist on this Host. Any pool is accepted; `tanka*` gets a validate warning (D8). |
| `quota` | size | none | ZFS `quota` on the dataset. Strongly recommended on a pool that also holds VM disks — a full pool stops every guest on it, not just the consumer. |
| `grants` | `[{consumer, access}]` | `[]` | Who may mount, and how much. `consumer` is a module instance name. An export with no grants exists and is mountable by nobody. |
| `owner` | `{uid, gid}` | allocated (D5) | The identity every client is squashed to. Allocated by TAPPaaS unless pinned. |
| `properties` | object | `{}` | ZFS properties from an allow-list: `recordsize`, `compression`, `atime`. (`1M` recordsize and `lz4` suit a media library; the defaults suit general files.) |
| `backup` | `{enabled, exclude[]}` | **none — `enabled` is required** | Whether the Host's `backup:filesystem` captures this export (D9). `exclude` takes patterns relative to the export root. |

What the service builds on the Host:

- the dataset **`<pool>/tappaas-nfs/<name>`**, mounted at `/<pool>/tappaas-nfs/<name>`. The
  `tappaas-nfs/` parent keeps exports out of the namespace Proxmox uses for VM disks
  (`<pool>/vm-<id>-disk-<n>`), so neither `pvesm` nor the storage-drift test ever mistakes
  one for the other;
- its root owned by `owner`, mode `0770`;
- the export itself as the dataset's **`sharenfs` property** (D4a), rendered from the grants;
  the parent `<pool>/tappaas-nfs` is set `sharenfs=off` explicitly, so nothing is exported by
  inheritance;
- the NFS server configured **v4-only** (`/etc/nfs.conf`: `vers3=n`; `rpcbind`, `mountd`
  and `statd` not exposed), so the only port is **tcp/2049**.

### D4a — The export is the dataset's `sharenfs` property

**Decided (v0.4): TAPPaaS exports with ZFS `sharenfs`, not with a file of its own in
`/etc/exports.d/`.** v0.1–v0.3 rejected `sharenfs`; the reasons given there do not survive a
look at the OpenZFS the nodes run (2.4.4 on PVE 9.2, `zfs-share.service` enabled by
default), and the operator has run `sharenfs` exports for years. The analysis:

| | `sharenfs` | own file `/etc/exports.d/tappaas.exports` |
|---|---|---|
| **Pool not imported / dataset not mounted** | **Not shared.** OpenZFS shares a dataset only once it is mounted, so a degraded `tankb1` that failed to import exports nothing. | **The decisive hazard.** The line stays; `exportfs` exports the *empty mountpoint directory on the root filesystem*, and consumers write into the node's root disk until it fills. The `mp` export option mitigates it, if every line remembers it. |
| **One object** | Export and dataset are the same object: `zfs destroy` unshares, `zfs rename` follows, `zfs get sharenfs` shows it. Nothing can name a dataset that is gone. | A second record that can disagree with the dataset — a line for a destroyed or renamed dataset. |
| **Boot ordering** | `zfs-share.service` shares after `zfs-mount.service`, by OpenZFS's own units. | Relies on `nfs-server` starting after the pools are mounted — true on a healthy boot, not on a late manual import. |
| **Diff unit (ADR-020)** | One value per dataset — exactly the per-export field the change model wants; `zfs get -r -s local sharenfs <pool>/tappaas-nfs` is the whole live state in one call. | One file diffed whole; the reconciler has to parse it back into exports to report *which* export drifted. |
| **"Hidden from `/etc/exports`"** (v0.1's objection) | **No longer true:** OpenZFS ≥ 2.0 on Linux writes the shares to `/etc/exports.d/zfs.exports` and runs `exportfs`, so `exportfs -v` and `cat` show them like any export. | Plain file. |
| **"Renders differently across versions"** (v0.1's objection) | True of the 0.8-era Linux libshare; one renderer since 2.0, and TAPPaaS controls the version through PVE. | — |
| **Syntax** | Linux `sharenfs` accepts exports(5) options plus OpenZFS's `rw=`/`ro=` host lists (`rw=@10.2.0.15/32:@10.2.0.16/32`). Per-host *options* beyond `rw`/`ro` cannot differ — **which D5 never needs**: squash and `sec` are the same for every client of one export. | Full exports(5) syntax, per-host options. |
| **`sharenfs=on`** | **Exports to everyone** with OpenZFS defaults. A real foot-gun — the renderer never writes `on`, and `validate`/`test-service.sh` refuse any TAPPaaS export whose live value is `on` or lacks a host list. | n/a |
| **Inheritance** | Child datasets inherit `sharenfs`. Contained: the `tappaas-nfs` parent is explicitly `off`, and exports have no children. | n/a |
| **`zfs send -p` / `-R`** | Carries the property: a received copy is shared on the target with the source's client list. TAPPaaS's own send/recv (export moves, future replication) always receives with `-x sharenfs`. | n/a |
| **Non-ZFS exports** | Impossible. Irrelevant: an export *is* a ZFS dataset (D4). A registered, unmanaged server's shares are not TAPPaaS-exported at all (D2a). | Works for any directory. |

The `sharenfs` rows that cost something — `on`, inheritance, send/recv — each have a
one-line rule; the file's cost is the unmounted-pool hazard, which is exactly the failure a
non-redundant `tankb1` disk makes likely. **What TAPPaaS writes** for each export:

```
zfs set sharenfs='rw=@<consumer-ip>/32:…,ro=@<consumer-ip>/32:…,sec=sys,root_squash,all_squash,anonuid=<owner>,anongid=<owner>,no_subtree_check' <pool>/tappaas-nfs/<name>
```

— and then reads back `exportfs -v`, because a `zfs set` with an option string libshare
cannot parse succeeds on the property and fails only at share time. An export with no
grants is `sharenfs=off`, not shared to nobody.

### D5 — Access rights: four layers, all derived from the grant

Access is the part of NFS that is easy to get wrong, so it is decided layer by layer.
For a managed share every layer is **derived** from the pair (export grant, consumer mount);
nothing is authored twice.

| # | Layer | Decided by | Rule |
|---|---|---|---|
| 1 | **Authorization** | the export's `grants` | **Two keys.** The Host grants, the consumer requests. A mount whose consumer has no grant, or asks `rw` against a `ro` grant, is a validate error naming both files. A grant nobody uses is reported, not an error. |
| 2 | **Network** | derived into `network:rules` | One **host-to-host** pass rule per (consumer, export Host): consumer alias → Host `/32`, tcp/2049. Never a zone-wide `access-to` (ADR-021 D3b's lesson). Removed when the last mount between the two goes. |
| 3 | **NFS client list** | the dataset's `sharenfs` (D4a) | Each granted consumer's **current address**, with `rw` or `ro` from the grant, `sec=sys`, `root_squash` always, `all_squash` with `anonuid/anongid = owner`. Never `no_root_squash`, never a subnet, never `*`. |
| 4 | **File identity** | `owner` | **Squash-to-owner** (below). |

**Squash-to-owner.** NFS with `sec=sys` trusts whatever UID the client claims, so per-user
UIDs across guests would buy nothing but a UID-coordination problem — Jellyfin's `jellyfin`
user is 997 on one guest and something else on the next. Instead, every request from every
granted client is squashed to the export's single `owner`, and the server checks access as
that owner. The consumer's app user reads and writes freely; files on the Host belong to one
identity per export; the guests need no shared UID map and no idmapd.

TAPPaaS allocates `owner` from a reserved range (**proposed 64000–64999**, Q2), one uid/gid
pair per export, recorded in the export declaration once allocated so it survives a rebuild
of the Host.

**What this trusts — stated plainly.** Anyone who is root on a granted consumer can read
(and with `rw`, change) everything in that export. That is the whole trust model of
`sec=sys`, and squashing does not change it. The isolation unit is therefore **the export**:
one export per trust boundary, and two consumers that should not see each other's data get
two exports, never one with two grants.

**The export Host is a hypervisor.** A `pvehost` export means a workload VM in `srv` talks
to a service on a cluster node in `mgmt`. Layer 2 keeps that to one port on one address from
one address, and v4-only removes the RPC portmapper surface — but it is still a new listener
on the hypervisor reachable from a workload zone. v1 accepts this for the Jellyfin case with
the narrowing above; the hardening that removes it — a dedicated storage zone the nodes get
an interface in, with `nfsd` bound only there — is **Q1**.

**In transit, v1 is cleartext.** The traffic stays on internal VLANs and crosses OPNsense.
RPC-with-TLS (`xprtsec=tls`, `tlshd`) is supported by the kernels in play and is the
intended next step (Q5); Kerberos (`sec=krb5p`) needs a KDC TAPPaaS does not have.

**Servers outside the cluster** get the subset of these layers TAPPaaS can reach from its
own side — D2a sets out which, per layer.

### D6 — The data belongs to the export, not to the consumer

Lifecycles follow ownership, and no TAPPaaS verb destroys share data as a side effect.

| Event | Effect |
|---|---|
| mount removed from a consumer, or consumer `delete`d | unmount, remove the guest's mount unit, drop the consumer from the client list, remove the firewall rule if it was the last. **Data untouched.** |
| grant removed while the consumer still mounts | refused at validate — remove the mount first, or both in one change. |
| export removed from the Host's declaration, with mounts | refused at validate, naming the mounting consumers. |
| export removed, no mounts | unexported and **kept**; the dataset is reported as an orphan by `test-service.sh` until purged. |
| purge | an explicit verb — `pvehost nfs purge <host>:<name>` — which demands confirmation and is never run by `update`, `delete` or the sweep. |

This is ADR-026's "`delete` unregisters, never wipes", applied to data.

### D7 — Change semantics (`services/nfs/fields.json`)

| Field | Class | Why |
|---|---|---|
| `mounts` | `in-place`, apply `reconcile` | Adding or removing a mount is a unit change and a remount; nothing reboots. Changing one mount's `share` is unmount + mount. |
| `mounts[].access` | `in-place` | Remount with the new mode — but only within the grant. |
| `nfs.exports` | `in-place`, apply `reconcile` | Adds and unexports; never destroys (D6). |
| `nfs.exports[].grants` | `in-place` | Re-renders `sharenfs` and the rules; re-sharing is live. |
| `nfs.exports[].quota` | `in-place` | `zfs set quota`; a value below current usage is refused at apply time. |
| `nfs.exports[].properties` | `in-place` | Applies to newly written blocks only — stated in the change note, because `recordsize` does not rewrite the existing library. |
| `nfs.exports[].backup` | `in-place` | Rewrites the Host's capture manifest; enabling starts at the next scheduled run, disabling stops future runs and **keeps** the snapshots already stored (they age out under retention). |
| `nfs.exports[].name`, `exports[].pool` | `immutable` | A rename breaks every share reference; a pool change is a data migration. Both are refused with the manual procedure in the README. |
| `nfs.exports[].owner` | `immutable` once allocated | Changing it would need a recursive `chown` of the dataset. |

### D8 — Availability: the share is as available as its Host, and says so

An export lives on **one Host and does not fail over.** That is the point of putting it on
`tankb1` and also its cost: when the Host is down, the share is gone.

- **The guest survives it.** `required: false` mounts are `nofail` + `x-systemd.automount`:
  the guest boots, the app starts, and only a process that touches the directory waits for
  the server. The mount is `hard`, so a write in flight waits for the server rather than
  silently failing — corruption is worse than a stall for every use TAPPaaS has in view.
- **HA for the data itself is not an NFS feature.** Neither a node export nor an NFS server in
  a guest (see *Alternatives*) survives the loss of the node holding the dataset. Shared data
  that must be highly available is a next-version topic for TAPPaaS, and the direction is
  **CIFS or S3** on replicated storage, not NFS.
- **HA does not cover it.** An HA guest (ADR-019) on `tanka1` migrates; its NFS mount
  follows it over the network unchanged. But an HA consumer with a `required: true` mount on
  a non-HA export is only as available as that export — `validate` warns, it does not
  refuse.
- **Same node is not a shortcut.** A consumer on the export Host's own node still reaches
  it through OPNsense (layer 2). That is a throughput ceiling worth knowing — ample for
  streaming, not for a database.
- **`tanka*` exports are allowed and warned.** They work, but replicate nothing — ZFS
  replication in HA covers VM disks, not `tappaas-nfs/` datasets — so the redundancy the
  operator thinks they bought is the mirror's, not HA's.

### D9 — Backup: the Host backs up its exports with `backup:filesystem`

An export is not on any guest's disk, so `backup:vm` does not cover it. It *is* a directory
on a machine module, and a machine module already has a file-level backup: since #662 a
`pvehost` captures `/etc`, `/var/lib/pve-cluster` and `/root` through `backup:filesystem`,
the same service a guest uses. **An export is backed up the same way, by its Host, as part
of the Host's `backup:filesystem`.** No new backup service; ADR-012 F.3's `backup:dataset`
is not needed for TAPPaaS exports and stays open only for external NFS shares, which no
Host of ours holds.

**Who backs it up — the Host, never the consumer.** The data lives on the Host and is backed
up once, there. A consumer's `filesystemPaths` must not name or contain one of its mount
`path`s — that would capture the share once per consumer, over NFS — and `validate`
refuses it.

**The decision is mandatory.** Every export carries `backup.enabled` with **no default**
(D4): `true`, or `false` as an explicit statement that this data may be lost. A missing
value is a validate error. A media library on a non-redundant `tankb1` disk is the case
where both answers are reasonable, and the point is that someone chose.

**The Host must consume `backup:filesystem`.** An export with `backup.enabled: true` on a
Host that neither `dependsOn` nor `integratesWith` `backup:filesystem` is a validate error.
A `pvehost` already has the `integratesWith` (#501), so on a cluster node this is free.

**How it is captured:**

| Concern | Rule |
|---|---|
| **Group** | One PBS backup group per export: namespace `fs/<host>` (the Host's own, with its existing write-no-delete credential and encryption key — ADR-012 §2.5), backup-id **`<host>-nfs-<name>`**. Not another archive in the Host's own `<host>` group: a multi-terabyte library must not share a snapshot, a run, or a prune with `/etc`. |
| **Consistency** | The runner takes `zfs snapshot <pool>/tappaas-nfs/<name>@tappaas-backup`, captures from `.zfs/snapshot/tappaas-backup/`, and destroys the snapshot afterwards — a point-in-time copy while consumers keep writing, with no consumer stopped. |
| **Cost** | `--change-detection-mode=metadata` (PBS ≥ 3.3): files whose metadata is unchanged reuse the previous snapshot's chunks without being read. Without it every run re-reads the whole library; with it a nightly run of an unchanged library is minutes. A PBS too old for it is a validate warning, not a silent multi-hour job. |
| **Schedule** | The Host's slot in the ADR-012 §3.2 cascade. Exports are captured after the Host's own paths, in the same run, one group after another; an export may not ask for more than once a day, like any `backup:filesystem` path. |
| **Exclusions** | `backup.exclude[]` — patterns relative to the export root (transcode caches, `.Trash-*`), the same semantics as a module's `backup.exclude`. |
| **Retention** | The cascade's, applied per group — so an export can keep fewer snapshots than its Host's configuration without either affecting the other. |
| **Off-site** | Not in v1. ADR-012 gives `fs/` no off-site grant by design, and a library sized to its own disk is the first data worth asking that again for (Q8). |
| **Same disk** | An export on the pool that holds the PBS datastore (normally `tankc1`), or on the PBS Host itself with `backup.enabled: true`, is a validate warning: that copy shares the failure it is meant to survive. |

**Restore** goes through `restore.sh`, with one new target: an export group restores into a
**new dataset beside the live one** (`<pool>/tappaas-nfs/<name>-restore-<date>`), never over
it. Numeric ownership is preserved, so the restored files belong to the export's `owner`
and every consumer can read them; the operator swaps, or copies the files they need, and
the restore dataset is purged like any orphan (D6). Restoring onto a *different* Host — the
case that matters when the Host's disk is the thing that died — is the same operation with
the export declared on the new Host first.

### D10 — Guest and Host realization

The consumer side is **gated on the guest OS facet** (ADR-022f), like `backup:filesystem`:

| Guest OS | Mount realized as |
|---|---|
| `nixos` | a generated **`/etc/nixos/tappaas-nfs.nix`** — `fileSystems."<path>"` entries plus `boot.supportedFilesystems = [ "nfs" ]` — imported by `tappaas-common.nix` with a `{ }` placeholder and applied by the guest's next rebuild. The pattern `backup:filesystem` established (#626/#691), including its rule: state only what the guest does not already declare. |
| `debian` | a marked block in `/etc/fstab`, then `systemctl daemon-reload` and the unit started. |
| anything else | refused at validate. |

The Host side is the node's Debian (ADR-026 D2): `nfs-kernel-server` from apt, the v4-only
`nfs.conf`, and `sharenfs` on each export dataset (D4a). A node gains the package on its
first export, not before — a node with no export runs no NFS server.

### D11 — Ordering and validation

- A consumer declaring `mounts` must `dependsOn: pvehost:nfs`; that is the only NFS
  dependency in the graph (D1). `module-manager validate` resolves every named share
  reference to an `nfs.exports[]` entry on the named instance — node or registered server —
  and checks D5 layer 1 against it.
- A managed share reference implies the consumer installs after its export Host — the same
  instance-pinning ADR-026 D6.6 gives a dependency.
- The export's client list holds addresses, and addresses come from DHCP. Every reconcile
  re-resolves them, and `test-service.sh` reports a client list that no longer matches its
  consumers' leases as drift, so a lease change heals on the next sweep at the latest.

---

## Worked example — Jellyfin (#52)

On the three-node reference cluster `tankb1` exists on `tappaas2`. The operator adds the
export to the node's instance file and the mount to Jellyfin:

```json
// config/tappaas2.json
"nfs": { "exports": [
  { "name": "media", "pool": "tankb1", "quota": "4T",
    "properties": { "recordsize": "1M", "compression": "lz4" },
    "backup": { "enabled": true, "exclude": [ ".Trash-*" ] },
    "grants": [ { "consumer": "jellyfin", "access": "rw" } ] }
]}
```

```json
// jellyfin.json
"dependsOn": ["cluster:vm", "templates:nixos", "backup:vm", "pvehost:nfs", "network:proxy", "network:rules"],
"config": {
  "cluster:vm":  { "storage": "tanka1", "diskSize": "32G", "...": "..." },
  "pvehost:nfs": { "mounts": [
    { "path": "/var/lib/jellyfin/media", "share": "tappaas2:media", "access": "rw" }
  ]}
}
```

What the service does: creates `tankb1/tappaas-nfs/media` (quota 4T, owner 64000:64000,
`0770`); installs `nfs-kernel-server` on `tappaas2`, v4-only; sets
`sharenfs='rw=@<jellyfin-ip>/32,sec=sys,root_squash,all_squash,anonuid=64000,anongid=64000,no_subtree_check'`
on the dataset;
adds the rule `tappaas_module_jellyfin → tappaas2/32 tcp/2049`; writes
`/etc/nixos/tappaas-nfs.nix` in the Jellyfin guest and rebuilds. The Jellyfin VM itself
stays small, on `tanka1`, HA-capable and cheap to back up; the library does not move when
the VM does, and survives `module delete jellyfin`. Because `tappaas2` already
`integratesWith` `backup:filesystem`, the library is captured nightly from a ZFS snapshot
into `fs/tappaas2` as the group `tappaas2-nfs-media`, beside — not inside — the node's own
configuration backup.

`rw` because Jellyfin writes `.nfo` files and artwork next to the media when configured to.
A site that keeps metadata inside the guest should grant and mount `ro`.

---

## Consequences

### Positive

- Large, low-value data leaves the redundant pool and the guest's backup, and gets a
  lifecycle of its own.
- A dedicated NFS server outside the cluster is a first-class share source: registered once,
  named in mounts like any export, with the two-key check, the firewall rule and an
  access-drift test on the TAPPaaS side — and a printed statement of what the server must
  carry.
- Access is derived from one grant, so the export list, the firewall and the mount cannot
  disagree; there is no `no_root_squash`, no subnet export and no zone-wide rule to drift
  into.
- Exports are backed up by the service that already backs up their Host — no new backup
  service, credential or namespace, and every export's backup is an explicit decision.

### Negative / costs

- For a registered, unmanaged server, the server-side client list is the operator's to keep in
  step; TAPPaaS detects a gap but cannot close it.
- A new listener on a hypervisor, reachable from a workload zone (D5, Q1).
- `sec=sys` means root on a consumer is full access to its exports; isolation is only per
  export.
- Cleartext NFS on internal VLANs until RPC-with-TLS (Q5).
- A share is a single point of failure for its consumers, and HA does not help (D8).
- A backed-up library costs its full size in the PBS datastore at least once, and its
  first capture is a long run; `quota` is also the ceiling on what the backup can grow to.
- Throughput is capped by OPNsense routing, even on the same node.
- Two more declarations for `module-manager validate` to cross-check, and a DHCP-dependent
  client list to keep in step.

### Neutral

- v1 consumers are `cluster:vm` guests. `cluster:lxc` consumers would more naturally get a
  bind mount than NFS (Q6).

---

## Alternatives considered

| Alternative | Why not (as the model) |
|---|---|
| **A second VM disk on `tankb1`** | Solves capacity only. The disk dies with the VM, has one reader, blocks migration of an HA guest to a node without `tankb1`, and lands in `backup:vm`. Still the right answer for a guest that just needs scratch space. |
| **virtiofs / Proxmox directory mappings** | Fast and needs no network, but only on the node that holds the data, and a guest with a virtiofs device cannot live-migrate — the opposite of what an HA consumer needs. |
| **NFS server in a small guest in `srv`** (nfs-ganesha in an LXC with the dataset bind-mounted) | Removes the hypervisor exposure, but **cannot use ZFS's own NFS sharing** (`sharenfs`, D4a) — the guest serves a bind-mounted directory with a userspace server — and **costs a guest's resources** on every export node. It buys no availability either: the dataset is still on one node. **Rejected** (operator, v0.4). |
| **Highly available shared storage** | Out of scope for NFS. If HA for shared data becomes a requirement, a next version of TAPPaaS goes to **CIFS or S3** on replicated storage (D8). |
| **SMB** | Better for desktop clients, worse for Linux services; a separate service if ever needed. |
| **A TAPPaaS-owned `/etc/exports.d/tappaas.exports`** | v0.1–v0.3's choice. Exports the empty mountpoint when a pool fails to import, and is a second record that can disagree with the dataset. **Replaced by `sharenfs`** (D4a, v0.4). |
| **`cluster:nfs`, or a new `storage` module** | v0.1–v0.3 placed the service on `cluster`. **Decided `pvehost`** (operator, v0.4): the pools, datasets and NFS server are the node's, the node is the instance a share reference names, and a `storage` module would be a module with no machine of its own (D1). |
| **Consumer-provisioned exports** (the mount names `pool` + `size`, TAPPaaS creates the export) | Nicer to write, wrong ownership: the data would follow the consumer's lifecycle, which is the problem D6 exists to prevent. **Rejected** (operator, v0.3) — also as a later shorthand: the export is always declared on its Host. |

---

## Open questions

- **Q1 — the hypervisor exposure.** Accept the one-port pinhole into `mgmt` (v1), or add a
  `storage` zone the nodes get an interface in with `nfsd` bound there? (A server in a guest
  is rejected — *Alternatives*.) *Recommendation: v1 as drafted; a storage zone before a
  second consumer.*
- **Q2 — the owner range.** 64000–64999 is free on NixOS and Debian defaults; confirm, and
  confirm that allocated values are written back into the Host's instance file.
- ~~Q3 — which module provides it~~ — **decided: `pvehost`** (v0.4): see D1.
- **Q9 — the module type of a registered, unmanaged NFS server.** D2a needs an
  `unmanaged` `kind: machine` module that its instances (`nas1`, `nas2`, …) belong to — one
  generic module for any appliance TAPPaaS does not patch, or one per appliance family?
  ADR-026's question, raised here.
- ~~Q4 — consumer shorthand~~ — **decided, rejected** (v0.3): see *Alternatives*.
- **Q5 — encryption.** Make RPC-with-TLS the default as soon as both the Debian Host and
  NixOS guest stacks ship `tlshd`?
- **Q6 — LXC consumers.** Bind mount on the same node, NFS across nodes, or not in scope?
- **Q7 — health.** Export usage against quota as an ADR-007e health signal?
- **Q8 — off-site for exports.** ADR-012 gives `fs/` no off-site grant. Should an export be
  able to opt into the off-site subset (ADR-012 §3.3) with its own retention?

---

## Implementation plan

1. `pvehost/services/nfs/` skeleton per ADR-027 D3; `nfs` added to `pvehost.json` `provides`;
   `fields.json` with D7's classes; schema entries for `mounts` and `exports`.
2. Export side on `pvehost`: dataset, owner allocation, v4-only server, `sharenfs`
   rendering and read-back, the `tappaas-nfs` parent `off`, orphan report.
3. Validate: share-reference resolution and the two-key check (D5 layer 1), D3 path rules,
   D8 warnings.
4. Network: derive the per-pair rule into `network:rules`.
5. Consumer side: NixOS fragment (with the `tappaas-common.nix` placeholder import), Debian
   fstab block.
6. Backup (D9): the Host's `backup:filesystem` runner learns export groups (snapshot,
   `<host>-nfs-<name>` backup-id, metadata change detection), the consumer-path refusal and
   the same-disk warning; `restore.sh` learns the restore-beside-the-live-dataset target.
7. Servers outside the cluster (D2a): `path`/`version`/`v3Ports` descriptors on an
   `unmanaged` instance, `pvehost nfs show`, the consumer-side access test and its health
   finding; the literal form; the `wan` refusal.
8. Jellyfin (#52) as the first consumer; then `debianhost` exports.

## Testing

- **Fast tier:** share-reference parsing (both forms; the path form refused on any module
  instance); descriptor rules (`path` required on an `unmanaged` instance and forbidden on a
  managed one, `pool`/`backup` forbidden there, v3 without `v3Ports` refused); the v3 rule
  carries 111 + the pinned ports; same-zone → no rule; a `wan` server refused;
  the two-key matrix (no grant / `ro` grant + `rw` mount / unused grant); `sharenfs`
  rendering (never `on`, never `no_root_squash`, never a subnet, `off` with no grants); fragment rendering for NixOS and Debian; `backup.enabled` missing → error; a consumer
  `filesystemPaths` under a mount path → error; the export group's backup-id and snapshot
  path in the rendered capture manifest.
- **Live, on hrossen:** export on `tankb1` of one node, consumer guest on another; write as
  the app user, see `owner` on the Host; a non-granted guest in the same zone is refused at
  both the firewall and the share; root on the consumer cannot create a root-owned file;
  export pool not imported → nothing is shared (the unmounted-mountpoint case D4a decides on); stop the export Host — the consumer stays up, the mount blocks, and recovers; migrate the
  consumer — the mount follows; `module delete` the consumer — the dataset and its data
  remain and are reported as unmounted; purge removes them. **Backup:** a capture runs while
  the consumer writes and the snapshot is gone afterwards; a second run of an unchanged
  export reads metadata only; delete a file, restore the group beside the live dataset, and
  the file is back with the owner uid; the capture credential cannot delete the group.
  **Server outside the cluster:** a Debian VM outside the cluster plays the NAS, registered
  `unmanaged`; mount `ro` from a consumer in another zone; `show` prints the client line;
  remove the consumer from the server's table by hand → the access test fails and raises the
  finding; restore it → green; repeat with an NFSv3-only server and pinned ports. Ends with the teardown phase and
  a leftover check (no dataset, nothing in `/etc/exports.d/zfs.exports`, no rule, no fragment).
