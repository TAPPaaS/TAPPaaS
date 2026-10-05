# ADR-029 — NFS Service (`storage:nfs`)

| | |
|---|---|
| **Status** | **Proposed** (v0.9, 2026-10-06) — the share declarations move out of the node configs into a Site file, `config/shares.json`, owned by a new **`storage-manager`** with per-share verbs; consumers depend on **`storage:nfs`**, provided by a thin `storage` module; a server module only builds what is declared for it. v0.1–v0.8 built in #766/#772 (v0.8 deep-tested); v0.9 not built — nothing uses NFS yet |
| **Version** | 0.9 |
| **Date** | 2026-10-03 (v0.8: 2026-10-05; v0.9: 2026-10-06) |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#388** (origin: shared storage for modules, NFS first) · **#52** (Jellyfin — the first consumer) · [ADR-009](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates, `config."<module>:<service>"`) · [ADR-012](ADR-012-backup-enhancement.md) (`backup:filesystem` backs up the exports — D9; F.3 narrowed to external shares) · [ADR-019](<ADR-019 - HA and Cross-Node VM Migration Policy.md>) (an HA guest mounting non-HA data) · [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) (the change classes in `services/nfs/fields.json`) · [ADR-021](<ADR-021 - Split-Horizon DNS and Service Reachability.md>) (host-scoped rules, never `access-to`) · [ADR-022c](<ADR-022c - Node and Host.md>) (Host) · [ADR-026](<ADR-026 - Managed Machines as Modules.md>) (the export Host is a machine module; D6 instance names) · [ADR-027](<ADR-027 - Module Blueprint.md>) D3 (the six files of `services/nfs/`) |
| **Changelog** | v0.9 (2026-10-06, operator decision after installing Jellyfin on v0.8, #52) — **shares are Site state, not node state.** v0.8 made a share's name Site-unique and its server a DNS answer, which left the node's config the wrong home for the declaration: a move meant cutting an entry from one node file into another, uniqueness was a scan of every config, `modify --set nfs=…` replaced the whole object (and was refused, bug 1 below), and site state rode the release's 3-way merge of a module file. Decided: one Site file, **`config/shares.json`**, a map of shares keyed by name, owned by a new **`storage-manager`** (`network-manager`/`zones.json` is the precedent) with verbs that change one share — `nfs share add|modify|delete|purge`, `nfs grant|revoke`, `nfs show` — each validating, writing and converging (new D17, D18). The manager is the start of a storage control plane that can grow beyond NFS and beyond PVE hosts: a server module only implements a **server hook** that builds what `shares.json` declares for its instance (new D19). Consumers depend on **`storage:nfs`**, provided by a thin `storage` module, the way `network` provides services `network-manager` owns the state of (D1 rewritten) — **to confirm, Q17**. The node configs' `nfs` field and the `pvehost:nfs` coordinate are withdrawn; the one user (Jellyfin on the reference site) is moved by hand, no migration (D20). Three defects found by installing Jellyfin, fixed in the v0.9 build: a node-triggered migration ran no `network:rules`, so the mount it needed had no rule (D11); an automount of the share read as local data, so every update after a migration refused and rolled back (D14); `module-manager modify` refused a field owned by a service the module itself provides (a general fix, recorded under *Implementation plan*). · v0.8 (2026-10-05, operator redesign after consuming the service for Jellyfin, #52) — **a mount names a share, never a host.** Share names are unique across the Site (D2); each share gets a DNS alias `nfs-<share>.mgmt.internal` to whatever server carries it, a node exports every share at the same path `/tappaas-nfs/<share>`, and the firewall rule targets the alias — so a consumer's config, mount and rule survive a share moving (new D2b). The `<instance>:<name>` form is withdrawn; a registered NAS is reached through the alias like a node; only `<ip-or-host>:/<path>` for an unmodelled server is used as written. **A share no server declares leaves the mount pending** — the module installs and the directory stays local; a share that exists but does not grant the consumer stays an error (D11). **A share that appears later is migrated into** on update, with consent: two-pass copy, the mount's `stopUnits`/`stopCommand`/`startCommand`, an open-files guard, the local copy kept as `<path>.pre-nfs` and removed by the next healthy update (new D14). **`subdir`** lets several consumers use one share (new D15). **Fixed: a deleted consumer's address stayed in the export's client list** until the node's next update; the delete now reconverges the node without it, and the client list is built from consumers that are deployed and mount the share, not from grants alone (new D16). · v0.7 (2026-10-04, operator decision, #766 WP8) — **TLS deferred; `sharenfs` kept.** Probed live on PVE 9.2 / OpenZFS 2.4.4: `sharenfs` refuses `xprtsec=tls` as an invalid option, so Q5 (TLS by default) and D4a (`sharenfs`) cannot both hold. An `/etc/exports.d` file with `xprtsec=tls,mountpoint` was proven to work (plain mounts refused, TLS mount OK, an unmounted dataset refused) and is recorded as the way out, but the operator kept `sharenfs`: NFS stays cleartext on internal VLANs until OpenZFS accepts `xprtsec` (D5, Q5). The mount's `tls` field is withdrawn. · v0.6 (2026-10-03, operator answers) — Proposed. Q1: a node whose consumers span more than one zone serves NFS from a **storage zone**, not `mgmt` (D5). Q2: owner range 64000–64999 confirmed, written back. Q5: **RPC-with-TLS** is the default (D5). Q6: **LXC consumers in scope** (new D12). Q7: quota usage is a **health signal** (new D13). Q8: **no off-site** for exports (D9). Q9: a registered server is an instance of a generic **unmanaged `kind: machine`** module (D2a). Open questions replaced by the record of their answers. · v0.5 (2026-10-03, operator review) — D2a names the two outside-the-cluster servers apart: **registered, unmanaged** (a module instance with declared shares) and **unmodelled** (an address in a literal path). Several servers are several instances (`nas1`, `nas2`). Exports move out of `config."pvehost:nfs"` into the server's own module-tier **`nfs.exports[]`**: the `config` block is the consumer's, and no server — node or NAS — carries a `dependsOn`/`integratesWith` for NFS; the consumer's `dependsOn: pvehost:nfs` is the only edge. D11 states that a consumer never creates an export: a declared-but-unbuilt one is built on the consumer's install, an undeclared one is a validate error. · v0.4 (2026-10-03, operator review) — the provider is **`pvehost`** (`pvehost:nfs`), not `cluster` or a new `storage` module (D1, Q3 closed); exports use **ZFS `sharenfs`** (new D4a, with the analysis), replacing the TAPPaaS-owned `exports.d` file; an NFS server in a guest is rejected (no ZFS sharing, costs a VM), and HA shared data points to CIFS/S3 in a next version (D8). Q9 added. File renamed from *Cluster NFS Service*. · v0.3 (2026-10-03) — **D2a**: a dedicated NFS server outside the cluster is a share source — registered as an `unmanaged` instance whose `exports[]` describe existing paths (`path`, `version`, pinned `v3Ports`), named in mounts like any export; TAPPaaS enforces the grant and the firewall rule on its side, prints what the server must carry, and detects access drift from the consumer. NFS across `wan` refused. Q4 (consumer-provisioned exports) rejected by the operator. · v0.2 (2026-10-03) — D9 rewritten: an export is backed up by its **Host's `backup:filesystem`**, one PBS group per export from a ZFS snapshot, with a mandatory `backup.enabled` on every export; restore lands beside the live dataset. ADR-012 F.3 remains only for external shares. Q8 (off-site) added. · v0.1 (2026-10-03) — first draft: one service, two declarations (export on a Host, mount on a guest); the `<host>:<name>` share reference; a four-layer access model with squash-to-owner identity; data outlives its consumers. |

A module that runs in a `cluster:vm` guest can mount a **named NFS share** at a directory
inside the guest, and a machine TAPPaaS manages can **export a ZFS dataset** from one of its
pools as that share — declared once in the Site's `shares.json` through `storage-manager`,
reconciled and access-controlled like every other service.
The consumer names the share, never the machine that carries it; a share that does not exist
yet leaves the directory local, and one that appears later is moved into.

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

**What the first consumer taught (v0.8).** v0.1–v0.7 were built (#766) and Jellyfin started
consuming them. Three things did not fit a module that ships to every site:

1. **A module must install where no share exists.** `jellyfin.json` is the same file on a
   site with a media share and on one without; v0.7 refused the install outright when the
   share was missing.
2. **A module cannot know where the share is.** `tappaas1:media` hardcodes a node into a
   file that is not the operator's to edit — and the node differs per site, and changes when
   the operator moves the share.
3. **A share often arrives after the module.** Media accumulates on the guest's own disk
   first; when the operator later creates the share, the content must move into it rather
   than be hidden under a fresh, empty mount.

v0.8 answers all three, and fixes a defect the Jellyfin work found (D16).

---

## 0. Vocabulary

| Term | Means |
|---|---|
| **share declaration** | One entry of `config/shares.json` `nfs.shares`, keyed by the share's Site-unique name: which server carries it and how (D4). Changed only through `storage-manager` (D17). |
| **export** | A ZFS dataset on a Host, created and exported over NFS by TAPPaaS because a share declaration names that Host as its server. |
| **export Host** / **server** | The machine module instance (ADR-026) a share declaration names in `server` — a managed Host whose module implements the NFS server hook (D19: `pvehost` in v1, others later), or a registered, unmanaged server. |
| **server hook** | The script a server's module ships to build, test and purge the shares declared for one of its instances (D19). |
| **registered, unmanaged NFS server** | An NFS server **outside the cluster** that the site owns — a NAS, a dedicated file server — registered as a module instance with `management: unmanaged` (D2a). TAPPaaS knows it and its shares by name, and never configures it. |
| **unmodelled NFS server** | An NFS server **also outside the cluster**, known to TAPPaaS only as an address in a mount's literal path — no module instance, no name, no declared shares. |
| **share** | Anything a guest can mount over NFS: a TAPPaaS export, a share on a registered server, or an unmodelled server's path. |
| **share reference** | The string a mount names its share by: a share **name** (`media`), or `<ip-or-host>:/<path>` for an unmodelled server (D2). |
| **share alias** | The DNS name `nfs-<share>.mgmt.internal`, a CNAME of whichever server carries the share (D2b). |
| **pending mount** | A mount whose share no server declares yet: the directory stays on the guest's own disk (D11). |
| **migration** | Moving a pending mount's local content into its share once the share exists, then mounting it (D14). |
| **mount** | A consumer's declaration that a share appears at a directory inside its guest. |
| **consumer** | The module that declares the mount — a `cluster:vm` guest, or a `cluster:lxc` container (D12). |
| **grant** | A share declaration's statement that a named consumer may mount it, `ro` or `rw`. |

---

## Decision

### D1 — Three parts: a manager for the state, a module for the consumers, hooks on the servers

**v0.9 (operator decision):** the share declarations are Site state, owned by a manager —
not fields of the node that happens to carry a share. TAPPaaS already has this pattern:
`network-manager` owns `zones.json` and changes it through verbs, and the `network` module
provides the services consumers depend on (`network:rules`, `network:proxy`). Storage gets
the same shape:

| Part | Where | Owns |
|---|---|---|
| **`storage-manager`** | `tappaas-cicd/manager/storage-manager/` | `config/shares.json` — every share's declaration, keyed by its Site-unique name (D18); the verbs that change one share at a time (D17); converging servers and notifying consumers |
| **`storage` module** | `src/foundation/storage/` | the consumer-facing service **`storage:nfs`** (the ADR-027 D3 file set): checks a consumer's mounts against `shares.json`, mounts or migrates, writes the guest's mount list (D10, D14) |
| **server hooks** | in each server's module — `pvehost/storage/nfs-server.sh` in v1 | building on one instance what `shares.json` declares for it: dataset, mountpoint, owner, `sharenfs` (D4, D4a, D19) |

| Declared in | What it says |
|---|---|
| `config/shares.json` `nfs.shares.<name>` — through `storage-manager` | "this share lives on this server, built this way, and these consumers may mount it" |
| a consumer's module file (`jellyfin.json`), `config."storage:nfs".mounts[]` | "mount this share at this directory in my guest" |

**Why a manager.** A share's server is one of its attributes since v0.8 (the alias makes it
invisible to consumers), so the declaration belongs where the Site's share namespace is —
one file, a map keyed by name, which makes uniqueness structural instead of a scan, a move a
change of one field, and every change a verb that touches one share (D17). It is also not
NFS-specific in shape: `shares.json` is the place further storage kinds join (D18), and
`storage-manager` the control plane that drives whichever servers implement them — PVE hosts
now, `debianhost` and others later (D19).

**Why a module as well — a virtual one, like `cluster`.** A consumer's dependency names a
module's service (ADR-009); a manager is not one. The `storage` module is **virtual**: like
`cluster`, it has no machine of its own and installs nothing anywhere — `kind: application`,
`scope: site`, `stack: foundation`, registered once with the foundation so that
`config/storage.json` (a registration, as `config/cluster.json` is) lets the dispatcher resolve
`storage:nfs`. **The NFS service itself is delivered by the PVE nodes**: their hooks build the
datasets and share them (D19), and the data travels between a guest and a node. What the
`storage` module contributes is the consumer side's code — `services/nfs/`, run on the
mothership as every provider's service is — just as `cluster:vm`'s code lives in `cluster`
while the VMs run on the nodes. ADR-029 v0.4 rejected "a `storage` module" as a module with no machine of its own *serving
the shares*; v0.9's module serves nothing — the servers do, through their hooks — and only
gives the consumer side its coordinate, exactly as `network` does. The coordinate is
**`storage:nfs`** (Q17, confirmed v0.9): a share may live on any server, so a consumer's
dependency must not name a server type.

**The only dependency edge is the consumer's `dependsOn: storage:nfs`.** No server depends on
anything for NFS: `storage-manager` reads which servers to drive from `shares.json`, and a
server's own update calls its hook for the shares declared for it.

Both halves meet in one service because **access is a join** (D5): the share declaration's
grants and the consumer's mount decide the client list and the firewall rule together.

### D2 — The share reference: a share name, or `<ip-or-host>:/<path>`

**v0.8: a mount names a share, never the machine that carries it.** Share names are unique
across the Site — a node's exports and a registered server's descriptors share one
namespace — so the name alone identifies the share, and `validate` refuses a name declared
twice. A module can then ship `"share": "media"` to every site: where the share lives is the
operator's declaration on the server, never the module author's guess.

| Form | Example | Server | Reached through | TAPPaaS does |
|---|---|---|---|---|
| a share name, carried by a **managed** Host | `media` | a cluster node (`pvehost`; `debianhost` later) | the share alias (D2b) | everything: creates the dataset, exports it, derives all four access layers (D5), backs it up (D9). |
| a share name, carried by a **registered, unmanaged server** | `video` | outside the cluster: a NAS or file server the site owns (D2a) | the share alias (D2b) | the consumer side only: validates the grant, derives the firewall rule, mounts — and **reports** what the server must be configured with, never configures it. |
| `<ip-or-host>:/<path>` | `192.168.20.5:/exports/shared` | an **unmodelled** server — not a module, typically outside the Administrative Domain (ADR-022g) | the address as written | the firewall rule and the mount, nothing else. |

The rule that separates them: **a reference containing `:` is a literal; anything else is a
share name.** A literal whose host is a module instance is refused — if TAPPaaS knows the
server, its shares are named, and a literal would be a way around the grant.

The `<instance>:<name>` form of v0.1–v0.7 is **withdrawn**: it put a node's name into a
module's file. No deployment used it outside the #766 tests, so nothing migrates.

### D2a — A registered, unmanaged NFS server

Two kinds of NFS server sit **outside the cluster**, and the difference between them is
whether TAPPaaS models them:

| | Registered, unmanaged | Unmodelled |
|---|---|---|
| What it is | a NAS or file server **the site owns** | a server nobody here models — another party's, or a one-off |
| In TAPPaaS | a module instance, `kind: machine`, `management: unmanaged` (ADR-022g D3, ADR-026) | only the address in a mount's literal path (D2) |
| Named | yes — `config/<instance>.json`, a DNS name, a firewall alias; each share a share alias (D2b) | no |
| Shares declared | yes — share declarations in `shares.json` naming it as `server` | no |
| Configured by TAPPaaS | **never** — no login, no packages, no export table | never |

Registering is the recommended path for any server the site owns: it is what gives TAPPaaS
something to check grants and drift against. The literal form is the fallback for a server
that is not ours to describe.

A registered server's shares are declared in `shares.json` like a node's, but as
**descriptors of what already exists** — a `path` instead of a `pool` (D4):

```bash
storage-manager nfs share add video --server nas1 --path /volume1/video --version 4.1
storage-manager nfs grant video jellyfin ro
```

The NAS's own instance file carries nothing about NFS: the server does not consume the NFS
service, it is described *to* it (D1).

**Several servers are several instances.** A site with two NAS boxes registers two
instances of the same module — `config/nas1.json` and `config/nas2.json`, each named after
its machine (ADR-026 D6, D8). A consumer never names either: it mounts `video` or `photos`,
and the share alias points at the box that carries it. Share names are unique across the
Site (v0.8), so two boxes cannot both offer a share called `backup` — name them `backup-nas1`
and `backup-nas2`. Those instances belong to **one generic `unmanaged`, `kind: machine`
module** for appliances TAPPaaS registers but does not patch (Q9, decided v0.6); a module per
appliance family can follow if one ever needs behaviour of its own.

| Field | On a registered server |
|---|---|
| `server`, `grants` | as for a managed Host (D4). |
| `path` | **required** — the path the server exports. Forbidden on a managed Host. |
| `version` | `4.2` (default), `4.1`, `4.0` or `3`. Many NAS still default to older protocol versions; the mount follows what the server offers. |
| `v3Ports` | **required with `version: "3"`** — `{mountd, nlockmgr, statd}`. NFSv3 needs `rpcbind` (111) and the auxiliary daemons, whose ports are dynamic unless pinned; the firewall rule (layer 2) can only be host-scoped if they are pinned, so a v3 share with dynamic ports is refused. |
| `pool`, `quota`, `owner`, `properties`, `backup` | **forbidden** — TAPPaaS does not provision, own or back up this data. |

What TAPPaaS can and cannot do for such a share, by the D5 layers:

| Layer | Registered, unmanaged server | Unmodelled server (literal path) |
|---|---|---|
| 1 Authorization | **enforced on the TAPPaaS side**: the two-key check runs against the descriptor's grants exactly as for a managed export. | none — the mount is the only declaration. |
| 2 Network | derived: consumer → the share alias on tcp/2049 (plus 111 and `v3Ports`, tcp and udp, for v3). No rule when consumer and server share a zone — that traffic never crosses OPNsense. | derived the same way, to the literal host. |
| 3 Client list | **reported, not applied**: `storage-manager nfs show --server <instance>` prints, per share, the consumer addresses and `ro`/`rw` the server's export table must carry, and the recommended options (`root_squash`, `all_squash` to one owner — D5). | the operator's. |
| 4 File identity | recommended (squash-to-owner), not enforceable. If the server maps UIDs instead, files are created with each consumer's own app UID, which differs between guests — `show` warns. | the operator's. |

**Drift is detected, not healed.** `test-service.sh` runs from each consumer: the share
mounts, an `rw` mount can write and an `ro` mount cannot. A server whose export table has
fallen behind its descriptor fails that test and raises a health finding naming the share
and the missing client — the operator fixes the server, TAPPaaS cannot.

**Where the server may be.** In one of the site's zones, or on a private routed network the
firewall reaches. A server reached through `wan`/the internet is **refused** in v1 for both
forms: NFS with `sec=sys` is cleartext and trusts the client's claimed UID, which is
tolerable on our own VLANs and not across someone else's network. RPC-with-TLS — deferred,
D5 — is the precondition for ever lifting this.

**Lifecycle and backup.** TAPPaaS never touches data on a registered, unmanaged server or an unmodelled one:
removing a mount unmounts and removes the rule; deleting the registered instance while
consumers still mount its shares is refused; there is no purge. Backing up that data is the
server's own business — ADR-012 F.3's `backup:dataset` remains the open question for it.

### D2b — The share alias: where a share lives is a DNS answer

Every share has a DNS name, **`nfs-<share>.mgmt.internal`**, a CNAME of the server that
carries it — `tappaas1.mgmt.internal` for a node, the registered server's own name for a
NAS. It is created by `storage-manager` when it converges the share — for a node and for a
registered NAS alike, since the alias is about the share, not the server's kind — with
`dns-manager alias add`, the same
mechanism the backup Host alias uses (ADR-012 §2.7, #612), and deleted when the share is.

The domain is fixed — `mgmt.internal`, whatever zone the server sits in — so the name a
consumer mounts never changes, only what it points at. Every zone resolves `.internal`
names through the site resolver (ADR-021), so a consumer in `srvHome` resolves it as well as
one in `mgmt`.

Three things are written against the alias, never against the server:

| | Against the alias |
|---|---|
| the guest's mount | `nfs-media.mgmt.internal:/tappaas-nfs/media[/<subdir>]` |
| the firewall rule (D5 layer 2) | destination: a host alias whose content is `nfs-media.mgmt.internal` |
| the path inside the share | a node mounts every export at **`/tappaas-nfs/<share>`**, whatever pool it is on (D4) |

So moving a share — the operator sends the dataset to another node or pool and moves the
declaration — changes the CNAME and nothing a consumer holds. A registered NAS keeps its own
descriptor path (`/volume1/video`); that path is written into the guest's mount on each
update, so a share moved between NAS boxes still needs no change in a consumer's config.
Moving a share is still a data migration the operator performs (D7: `pool` is immutable in
place); the alias is what keeps every consumer's config, mount entry and firewall rule
unchanged. A consumer's *active* mount still has to be remounted once the old server stops
exporting — a `hard` mount stalls until then — so a move is done with the consumers'
mounts released, or followed by their restart.

**The cost:** a mount now depends on the site resolver. With the resolver down a mount that
is not yet active fails to resolve, exactly as every `.internal` name does; an active mount
is unaffected. The firewall's host alias holding the share alias is re-resolved by OPNsense
only when its cached resolution expires — the host alias TTL, **300 s** — and neither
`configctl filter refresh_aliases` nor a filter reload re-resolves it sooner (measured on the
reference site, 2026-10-05). So after a move, consumers behind the firewall reach the share
within about five minutes, not at once; a consumer in the server's own zone, which needs no
rule, at once. Forcing it sooner would mean deleting OPNsense's alias cache as root on the
firewall, which a rare, operator-driven move does not justify.

### D3 — The mount declaration

```json
"dependsOn": ["cluster:vm", "network:rules", "storage:nfs", "..."],
"config": {
  "storage:nfs": {
    "mounts": [
      {
        "path": "/media",
        "share": "media",
        "subdir": "jellyfin",
        "access": "rw",
        "stopUnits": ["jellyfin.service"]
      }
    ]
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `path` | absolute path | — | The directory in the guest. Not `/`, `/nix`, `/etc`, `/var`, `/usr`, `/boot` or a system path; not a parent of another mount's `path`. Created if absent. |
| `share` | share reference (D2) | — | A share name, or `<ip-or-host>:/<path>`. |
| `subdir` | relative path | none | A directory inside the share to mount instead of its root (D15). No `..`, no leading `/`. |
| `access` | `ro` \| `rw` | `ro` | What the consumer asks for. Must not exceed the grant (D5). |
| `required` | boolean | `false` | `false`: `nofail` + `x-systemd.automount` — the guest boots and the app starts without the share. `true`: the mount is needed at boot. |
| `stopUnits` | string[] | `[]` | systemd units in the guest to stop while the directory is migrated into the share (D14), and start again after. |
| `stopCommand`, `startCommand` | string | none | Commands run in the guest with sudo, for what is not a unit (a container run by Docker itself, an app's own maintenance mode). Run before `stopUnits` stop and after they start. |
| `options` | string[] | `[]` | Mount options from an allow-list (`rsize=`, `wsize=`, `timeo=`, `noatime`, `actimeo=`). `sec=`, `vers=`, `nolock` and anything security-relevant are TAPPaaS's. |

Mounts are always **NFSv4.2 (or the registered server's version), `hard`, `_netdev`** (D8
explains `hard`). The stop/start fields matter only to a migration (D14); a mount whose
share existed from the start never uses them.

### D4 — The share declaration (`config/shares.json`)

A share is declared once, in the Site's `shares.json`, not on the server and not on the
consumer: the data outlives every consumer (D6), and the server is only where it currently
lives (D2b). The file is written by `storage-manager` (D17); this is what it holds:

```json
{
  "nfs": {
    "shares": {
      "media": {
        "server": "tappaas1",
        "pool": "tankb1",
        "quota": "4T",
        "properties": { "recordsize": "1M", "compression": "lz4" },
        "backup": { "enabled": true, "exclude": [".Trash-*"] },
        "owner": { "uid": 64000, "gid": 64000 },
        "grants": { "jellyfin": "rw", "immich": "ro" }
      },
      "video": {
        "server": "nas1",
        "path": "/volume1/video",
        "version": "4.1",
        "grants": { "jellyfin": "ro" }
      }
    }
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| *(key)* | `^[a-z][a-z0-9-]*$` | — | The share's name — **unique across the Site by construction** (a map key), the share reference, and the alias `nfs-<name>`. |
| `server` | module instance | — | The managed Host or registered server that carries the share. Its module must implement the NFS server hook (D19) unless it is unmanaged. |
| `pool` | ZFS pool name | — | Managed Host only: must exist on the server. `tanka*` gets a warning (D8). |
| `quota` | size | none | ZFS `quota` on the dataset. Strongly recommended on a pool that also holds VM disks. |
| `properties` | object | `{}` | ZFS properties from an allow-list: `recordsize`, `compression`, `atime`. |
| `backup` | `{enabled, exclude[]}` | **none — `enabled` is required** for a managed share | Whether the server's `backup:filesystem` captures it (D9). |
| `owner` | `{uid, gid}` | allocated (D5) | The identity every client is squashed to; allocated by `storage-manager` from 64000–64999 and recorded here. |
| `grants` | `{consumer: "ro"\|"rw"}` | `{}` | Who may mount, and how much — a map, so one grant is added or revoked without touching the rest. |
| `path`, `version`, `v3Ports` | | | Registered server only (D2a). |

What the server hook builds for a managed share (D19):

- the dataset **`<pool>/tappaas-nfs/<name>`**, its ZFS `mountpoint` set to
  **`/tappaas-nfs/<name>`** — the same path on every node, whatever the pool (D2b); the
  `tappaas-nfs/` parent keeps exports out of the namespace Proxmox uses for VM disks;
- its root owned by `owner`, mode `0770`;
- the export itself as the dataset's **`sharenfs` property** (D4a), rendered from the grants
  and the consumers that mount the share (D16); the parent `<pool>/tappaas-nfs` set
  `sharenfs=off` explicitly;
- the NFS server configured **v4-only**, so the only port is **tcp/2049**.

`storage-manager` itself creates the share alias `nfs-<name>.mgmt.internal` → the server (D2b).

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
| 1 | **Authorization** | the export's `grants` | **Two keys.** The Host grants, the consumer requests. A mount whose share exists but grants this consumer nothing, or asks `rw` against a `ro` grant, is a validate error naming both files. A share no server declares is not a refusal but a pending mount (D11). A grant nobody uses is reported, not an error. |
| 2 | **Network** | derived into `network:rules` | One **host-to-host** pass rule per (consumer, share): consumer alias → a host alias holding the share alias (D2b), tcp/2049. Never a zone-wide `access-to` (ADR-021 D3b's lesson). None for a pending mount; removed with the mount. |
| 3 | **NFS client list** | the dataset's `sharenfs` (D4a) | The **current address of each consumer that is granted, deployed and mounts the share** (v0.8, D16), with `rw` or `ro` from the grant, `sec=sys`, `root_squash` always, `all_squash` with `anonuid/anongid = owner`. Never `no_root_squash`, never a subnet, never `*`. |
| 4 | **File identity** | `owner` | **Squash-to-owner** (below). |

**Squash-to-owner.** NFS with `sec=sys` trusts whatever UID the client claims, so per-user
UIDs across guests would buy nothing but a UID-coordination problem — Jellyfin's `jellyfin`
user is 997 on one guest and something else on the next. Instead, every request from every
granted client is squashed to the export's single `owner`, and the server checks access as
that owner. The consumer's app user reads and writes freely; files on the Host belong to one
identity per export; the guests need no shared UID map and no idmapd.

TAPPaaS allocates `owner` from the reserved range **64000–64999** (Q2, confirmed v0.6), one
uid/gid pair per export, **written back into the export declaration** once allocated so it
survives a rebuild of the Host.

**What this trusts — stated plainly.** Anyone who is root on a granted consumer can read
(and with `rw`, change) everything in that export. That is the whole trust model of
`sec=sys`, and squashing does not change it. The isolation unit is therefore **the export**:
one export per trust boundary, and two consumers that should not see each other's data get
two exports, never one with two grants.

**The export Host is a hypervisor.** A `pvehost` export means a workload VM in `srv` talks
to a service on a cluster node in `mgmt`. Layer 2 keeps that to one port on one address from
one address, and v4-only removes the RPC portmapper surface — but it is still a new listener
on the hypervisor reachable from a workload zone. How far that is acceptable depends on
how many zones reach it (Q1, decided v0.6):

| A node's consumers come from… | NFS is served on | Why |
|---|---|---|
| **one zone** (the Jellyfin case) | the node's `mgmt` address, behind the per-pair tcp/2049 rule | one workload zone, one port, one address per consumer — the narrowest pinhole that works, and no new network |
| **more than one zone** | a **`storage` zone**: the node gets an interface in it, `nfsd` is bound to that address only (`/etc/nfs.conf` `[nfsd] host=`), and the per-pair rules target the node's storage `/32` | `mgmt` is reached by no workload zone at all; a second zone reaching the hypervisor's management address is where the exposure stops being narrow |

The `storage` zone is a Service-type zone with no `access-to` of its own; it is created by
`network-manager` the first time a node needs it. The switch happens when a grant adds a
consumer from a second zone: `validate` says so, and applying it re-binds `nfsd` and
remounts every consumer of that node, so it is a disruptive change under ADR-020's consent
rules (`--force` / `rebootOk`), not a silent one. Dropping back to one zone does not move
NFS back — the storage zone, once there, stays.

**In transit: cleartext, until OpenZFS can share with TLS** (Q5, v0.7). v0.6 decided
RPC-with-TLS by default. Building it (#766 WP8) found that it cannot be expressed through
`sharenfs` (D4a): OpenZFS 2.4.4 — what PVE 9.2 ships — refuses `xprtsec=tls` in a `sharenfs`
value as an invalid option, so the export line TLS needs cannot be produced by the
mechanism D4a chose. The operator kept `sharenfs` and deferred TLS. NFS traffic therefore
stays cleartext, on internal VLANs, through OPNsense, behind the per-pair rule; the trust
statement above is unchanged by this, because TLS would not have replaced `sec=sys` either.

What was proven, so the next attempt starts from facts (tappaas1/tappaas2, 2026-10-04):

| | Result |
|---|---|
| `zfs set sharenfs='…,xprtsec=tls,…'` | refused: *'sharenfs' cannot be set to invalid options* |
| `/etc/exports.d` line with `xprtsec=tls,mountpoint` | accepted; `exportfs -s` shows `xprtsec=tls` |
| plain NFSv4.2 mount against it | refused (*Operation not permitted*) |
| `mount -o xprtsec=tls`, server cert from a CA in the client's `tlshd` truststore | mounted, NFSv4.2 over TLS |
| the same file, dataset unmounted (`mountpoint` option) | client refused (*No such file or directory*) — the hazard D4a was decided on |
| stacks | node: `ktls-utils` 1.0.0 in Debian 13, `tlshd` configured in `/etc/tlshd.conf` (`[authenticate.server] x509.certificate / x509.private_key`); guest: `ktls-utils` 1.3.0 in the pinned nixpkgs, **no NixOS module** — the unit would be declared in `tappaas-nfs.nix` |

Tracked in **#771** (Future Work). TLS returns when either OpenZFS accepts `xprtsec` in `sharenfs` — then it is one more option
in D4a's renderer plus `tlshd` and certificates — or the operator revisits D4a for the
exports-file route above. Either way TAPPaaS also needs a CA it does not have today. Kerberos
(`sec=krb5p`) needs a KDC TAPPaaS does not have and is not pursued.

**Servers outside the cluster** get the subset of these layers TAPPaaS can reach from its
own side — D2a sets out which, per layer.

### D6 — The data belongs to the export, not to the consumer

Lifecycles follow ownership, and no TAPPaaS verb destroys share data as a side effect.

| Event | Effect |
|---|---|
| mount removed from a consumer, or consumer `delete`d | unmount, remove the guest's mount unit, **reconverge the server without the consumer** so its address leaves the client list at once (D16), remove the firewall rule. **Data untouched.** |
| grant revoked while the consumer still mounts | `storage-manager nfs revoke` refuses — remove the mount first. |
| share deleted while consumers mount it | `storage-manager nfs share delete` refuses, naming the mounting consumers. |
| share deleted, no mounts | unexported, alias removed, data **kept**; the dataset is reported as an orphan (`storage-manager nfs show`, the server hook's test) until purged. |
| share deleted after a consumer migrated into it | **never a silent fallback** to the local directory: the mount stays declared and `validate` errors that its share is gone (D14). |
| purge | an explicit verb — `storage-manager nfs share purge <share>` (D17) — which demands confirmation and is never run by `update`, `delete` or the sweep. |

This is ADR-026's "`delete` unregisters, never wipes", applied to data.

### D7 — Change semantics

| Field | Class | Why |
|---|---|---|
| `mounts` | `in-place`, apply `reconcile` | Adding or removing a mount is a unit change and a remount; nothing reboots. Changing one mount's `share` is unmount + mount. |
| `mounts[].access` | `in-place` | Remount with the new mode — but only within the grant. |
| `mounts[].share`, `mounts[].subdir` | `in-place` | Unmount and mount the new source. **Data is not moved** between shares or subdirs: only a pending mount is migrated into (D14). |
| `mounts[].stopUnits`, `stopCommand`, `startCommand` | `none` | Read only by a migration. |

A share declaration changes only through `storage-manager` (D17); the same classes govern
what its `share modify --set` accepts:

| `shares.json` share field | Class | Why |
|---|---|---|
| `grants` (via `grant`/`revoke`) | `in-place` | Re-renders `sharenfs` and the rules; re-sharing is live. Revoking a grant a consumer still mounts is refused (D6). |
| `quota` | `in-place` | `zfs set quota`; a value below current usage is refused at apply time. |
| `properties` | `in-place` | Applies to newly written blocks only. |
| `backup` | `in-place` | Rewrites the server's capture manifest; disabling keeps the snapshots already stored. |
| *name*, `pool`, `server` | `migrate` — refused by `modify` | A rename breaks every consumer's share reference; a pool or server change is a data migration, done by the operator with the procedure in the README (send the dataset, then change `server`/`pool`), after which the alias follows and consumers notice nothing (D2b). A `share move` verb comes at a later stage (Q18, decided v0.9). |
| `owner` | `immutable` once allocated | Changing it would need a recursive `chown` of the dataset. |

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
| **Off-site** | **None** (Q8, decided v0.6). Export backups stay on the local PBS, as everything in `fs/` does under ADR-012. Data that must survive the site belongs in a module's own backup, not in an NFS export. |
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
| `nixos` | a generated **`/etc/nixos/tappaas-nfs.nix`** — `fileSystems."<path>"` entries (device: the share alias, D2b) plus `boot.supportedFilesystems = [ "nfs" ]` — imported by `tappaas-common.nix` and applied by the guest's next rebuild; a migration also mounts at once (D14). The pattern `backup:filesystem` established (#626/#691), including its rule: state only what the guest does not already declare. |
| `debian` | a marked block in `/etc/fstab`, then `systemctl daemon-reload` and the unit started. |
| anything else | refused at validate. |

The Host side is the node's Debian (ADR-026 D2): `nfs-kernel-server` from apt, the v4-only
`nfs.conf`, and `sharenfs` on each export dataset (D4a). A node gains the package on its
first export, not before — a node with no export runs no NFS server.

### D11 — Ordering, validation, and the pending mount

A consumer declaring `mounts` must `dependsOn: storage:nfs`; that is the only NFS dependency
in the graph (D1). What a mount's share reference finds decides what happens — **v0.8: a
share that does not exist is not a refusal**:

| The share reference finds… | Result |
|---|---|
| **no** server declaring the share | **pending**: the module installs, `path` stays a directory on the guest's own disk, no mount, no firewall rule, no client-list entry. `validate` reports it as information, naming the share. A consumer never creates a share (Q4): the data must not follow the consumer's lifecycle (D6). |
| the share, declared but not yet built | the consumer's install or update has `storage-manager` converge it — the server hook builds dataset, owner, `sharenfs`; the manager the alias — then mounts (or migrates, D14). |
| the share, **not granting** this consumer | **error** (operator decision, v0.8): a share that exists and leaves this consumer out is a configuration mistake, not a gap to wait out. The message prints the grant to add. So the install-anywhere promise holds while the share does not exist, not while it exists without the grant. |
| the share, granted, `rw` asked against `ro` | **error**. |
| the share, granted | mounted — or, if the mount was pending and `path` holds data, migrated into (D14). |
| a share on a **registered, unmanaged** server | checked against its descriptor, never created; a descriptor the real server lacks shows up as a failed access test (D2a). |
| an **unmodelled** server's path | mounted; nothing to check until the mount is tried. |

The pending → available transition reaches the consumer two ways: its own update on every
sweep, and `storage-manager`, which — after `share add` or `grant` — runs the service's update
for each consumer whose mount it just made available, so a migration need not wait for the
next sweep.

**The consumer's NFS update owns its firewall path (v0.9).** Found installing Jellyfin on
v0.8: a node-triggered update ran only `pvehost:nfs`, never the consumer's `network:rules`, so
a consumer installed before its share had no rule and the mount its migration needed timed
out. From v0.9 the `storage:nfs` update recompiles the consumer's rules (`rules-manager
reconcile <consumer>`) before it mounts or migrates whenever a mount crosses the firewall —
whoever triggered the update. The export's client list holds addresses resolved at each
reconcile; `test-service.sh` reports one that no longer matches a consumer's lease as drift.

### D12 — Container consumers (`cluster:lxc`)

LXC consumers are in scope (Q6, decided v0.6). They declare the same `mounts[]` with the same
share references, and the same grants authorize them — but an unprivileged container cannot
mount NFS itself, so **the node the container runs on does the mounting**, and the container
gets a Proxmox bind mount (`mpN`):

| Container's node vs. the share | Realized as |
|---|---|
| the export is on the **same node** | a bind mount of the dataset straight into the container — no NFS, no network, no rule |
| the export is on **another node**, or on a registered/unmodelled server | the node mounts the share (under `/mnt/tappaas-nfs/<share>`, through the share alias, with D3's options), then bind-mounts it into the container; the grant, client list and rule are the **node's**, on behalf of the container |
| the container is HA and may run on several nodes | the node-side mount is made on every node the container may be placed on, so a migration finds the path present |

Identity: files on the share belong to the export's `owner`. An unprivileged container sees
host UIDs shifted, so the service adds an `lxc.idmap` entry that maps the container's app
user to `owner` — the container-side equivalent of squash-to-owner. `access` is applied as
the bind mount's `ro` flag as well as on the export.

### D13 — Health: quota use

An export's usage against its `quota` is an ADR-007e health signal (Q7, decided v0.6):
warning at 80 %, critical at 95 %, read by `test-service.sh` from `zfs get used,quota` on the
node, notified through the site's notification target. An export without a quota reports
its pool's free space instead, because that is what it will exhaust. A registered,
unmanaged server reports nothing — TAPPaaS cannot see its disks.

### D14 — A share that arrives later is migrated into

A pending mount's directory fills with data on the guest's own disk. When its share becomes
available and granted, the consumer's update **moves that content into the share and then
mounts it** — never simply mounting over it, which would hide the data under an empty share.

| Step | What happens |
|---|---|
| 0. Decide | `path` already **is** the share — mounted from the expected source, *or an automount (autofs) of it* — → nothing to move. `path` empty or absent → nothing to move: mount and stop. The share (at `subdir`, D15) already holds data **and** `path` does too → **refused**, never merged; reported with both sizes, for the operator to resolve — unless what is there is this mount's own interrupted migration (a marker file it leaves while copying), which is **resumed**. Otherwise continue. |
| 1. Consent | A migration stops the app, so it runs only with consent: the consumer's `rebootOk: true`, or an update run with `--allow-disruption` (ADR-020's disruption gate, decided v0.8). Without it the update reports **migration pending** and changes nothing. |
| 2. First pass | Mount the share at a temporary path in the guest, leave the marker, and `rsync -rlptH --no-owner --no-group` the directory into it **while the app runs** — the bulk, which may take hours for a media library. No ownership or ACLs are copied: every write is squashed to the export's `owner` anyway (D5), and trying would fail on each file. |
| 3. Stop | `stopCommand`, then `stopUnits` (D3). |
| 4. Guard | Nothing may still have a file open under `path` (`fuser -m`). If something does — a unit nobody declared, a process outside systemd, a cron job — **abort**: start everything again, report what held the path, change nothing. A missing declaration costs a refused migration, never a lost write. |
| 5. Second pass | The same rsync with `--delete`, for the difference since the first pass — short, because the app was stopped. Then the marker goes. |
| 6. Swap | Rename `path` to **`<path>.pre-nfs`**, recreate `path` empty, mount the share there at once, and write the mount into the guest (D10) so the next rebuild keeps it. |
| 7. Start | `stopUnits` start, then `startCommand`. Then the service's own test: mounted, writable for `rw`. |

**An automount is the share, not local data (v0.9).** Found installing Jellyfin on v0.8: once
the guest's rebuild turned `path` into an automount point, the probe saw no NFS mount, then
listed the directory — which triggered the automount and listed the *share* — and called it
local data. The share "already held data", the update refused a merge and rolled back, and
`<path>.pre-nfs` was never removed: every update after a migration failed. The probe now
recognises an autofs mount at `path` whose unit mounts the expected source as the share, and
only then triggers it to check health. The deep suite had missed it because it always touched
the directory before updating; it now updates without touching it first.

**Until a migration succeeds the mount stays out of the guest's mount list** (D10): a
directory that holds local data is never handed to a rebuild that would mount the share
over it and hide that data — whether the migration waits for consent, waits for the guest
to gain NFS support, or failed.

**A failure before step 6** restarts the app on its untouched local data. **A failure after
it** moves `<path>.pre-nfs` back and restarts the app on it. Either way the update reports
the step that failed.

**`<path>.pre-nfs` is deleted by the next healthy update** — one in which the mount is active
and `test-service.sh` passes (decided v0.8). The rename costs no space while it lasts; the
consumer's own backup (`backup:vm`) covers a fatal error after the deletion. The update
that deletes it says so.

**No way back.** Once a consumer has migrated into a share, a share that later disappears is
an error (the service's update and the mount's own test), never a silent return to the
local directory: by then the local directory is gone, and starting the app on an empty one
would look like data loss. The guest keeps its mount entry until the operator either
declares the share again or removes the mount — dropping it would unmount on the next
rebuild and start the app on an empty directory.

Files arrive on the share owned by the export's `owner` (D5): the copy runs as root in the
guest, and every write is squashed.

### D15 — One share, several consumers: `subdir`

A mount may name a `subdir` (D3): the guest mounts
`nfs-<share>.mgmt.internal:/tappaas-nfs/<share>/<subdir>`, and the service creates the
directory on first use, owned by the export's `owner`. A `media` share can then carry
`jellyfin/`, `immich/` and a downloader's `incoming/`, each mounted where its module wants it.

The **grant stays per share**: every consumer granted `media` can reach every subdir of it —
a consumer could mount the share's root — because NFS exports the dataset, not the
directory. `subdir` is organisation, not isolation; consumers that must not see each other's
data get separate shares (D5). Two consumers may mount the same subdir; that is a shared
library, deliberately.

### D16 — The client list follows the consumers (a v0.7 defect)

**Found while consuming the service (#52):** a deleted consumer's address stayed in its
export's client list. The list was rebuilt only by the server's own update; deleting a
consumer removed its mounts and its firewall rule but never asked the server to rebuild.
After Jellyfin was deleted the share still granted read-write to its old address — blocked
only by the firewall, since Jellyfin's rule went with it. A later VM leased that address,
with an NFS rule of its own to the same node, could have mounted the share.

**Decided:**

- The client list (D5 layer 3) is built from consumers that are **granted, deployed and
  mount the share** — not from grants alone. A grant for a consumer that is gone, or that
  does not mount the share, contributes no address.
- `delete-service.sh` has `storage-manager` **reconverge every share that grants the
  consumer, without the consumer**, before it returns — the consumer's config still exists at
  that moment, so the server hook is told to leave it out.
- A mount removed by an update does the same for the server it named.
- `test-service.sh` on the server side reports an address in a client list that belongs to
  no deployed, mounting consumer as drift — the check that would have caught this.

### D17 — `storage-manager`: one share at a time

Shares are changed by verbs that act on **one share by name**; nobody hand-edits
`shares.json` or replaces the whole object to change one entry:

| Verb | Does |
|---|---|
| `storage-manager nfs share add <name> --server <instance> (--pool <p> [--quota <q>] --backup true\|false [--prop k=v…] \| --path <p> [--version v] [--v3-ports m,n,s])` | declares a share; refuses a name already declared, a server that cannot serve (D19), a pool the server lacks |
| `storage-manager nfs share modify <name> --set <field>=<value>…` | changes fields within their D7 class; refuses `migrate`/`immutable` ones with the procedure |
| `storage-manager nfs grant <share> <consumer> ro\|rw` · `revoke <share> <consumer>` | adds or removes one grant; `revoke` is refused while the consumer still mounts the share (D6) |
| `storage-manager nfs share delete <name>` | removes the declaration: unshared, alias removed, **data kept** and reported as an orphan; refused while a consumer mounts it (D6) |
| `storage-manager nfs share purge <name>` | destroys an orphan's dataset, after confirmation; never run by `update`, `delete` or the sweep (D6) |
| `storage-manager nfs show [<name>] [--server <instance>]` | the declarations, what each server holds live, who mounts what; for a registered server, the client lines its export table must carry (D2a) |
| `storage-manager nfs converge [<name>\|--server <instance>]` | re-applies the declarations — what a server's own update also does for its shares |

Every changing verb runs the same sequence: **lock** `shares.json` (one writer at a time),
**validate** the whole resulting file with the same rules `module-manager validate` uses
(Site-unique names, `backup.enabled` stated, a server that can serve, the pool present), **write**
it atomically, **converge** the affected share — the server hook, then the alias — and
**notify** the consumers whose mounts it changed (their `storage:nfs` update, with the consent
rules of D14). A verb that fails validation changes nothing. `--check` shows the plan without
applying it.

`storage-manager` is a manager in the ADR-007f sense: a CLI in `tappaas-cicd/manager/`, run on
the mothership as the `tappaas` operator, with its own `test.sh` (fast tier: the verbs against a
fixture `shares.json`; deep: the end-to-end suite, D-testing).

### D18 — `config/shares.json` (Site state, beside the module's registration)

One Site file, schema `schemas/shares-fields.json`, a section per protocol — `nfs` now
(`shares`, D4); further kinds (an SMB or S3 service, the ADR-029 D8 direction for HA shared
data) join as sibling sections managed by the same manager. It is not `config/storage.json`:
that name is the `storage` module's registration (D1), and site state is kept apart from a
module's own config the way `zones.json` is kept apart from `network.json`. It is Site state like
`zones.json`: never part of a module's release merge, written only by `storage-manager`,
backed up with the rest of `config/` (ADR-012 D20), and migrated by ADR-025 migrations when its
shape changes. An absent file is an empty one: a Site with no shares has nothing to declare.

### D19 — Server hooks: who can serve

A managed Host can serve a share when its module ships an **NFS server hook**,
`<module>/storage/nfs-server.sh`, with three verbs, each for one instance:

| Verb | Does |
|---|---|
| `converge <instance> [--exclude <consumer>…]` | builds and shares, on that machine, every share `shares.json` declares for it (D4, D4a, D16), and unshares (keeping the data) what is no longer declared for it |
| `test <instance>` | the live state against the declarations: dataset, mountpoint, client list (D16 drift) |
| `purge <instance> <share>` | destroys one orphan's dataset (called only by `share purge`) |

`pvehost` ships it in v1 (the v0.8 node code, moved behind the hook). A `debianhost` that
should serve a pool ships the same hook — from a shared library — and nothing else changes:
`storage-manager` finds the hook through the server instance's module (`moduleSource`, ADR-026
D6). A registered, unmanaged server needs no hook — TAPPaaS builds nothing there (D2a) — and a
managed instance whose module has none cannot be named as a share's `server`.

A server's own update calls its hook's `converge` for itself, so the sweep keeps every server
converged without a verb having run. The hook never decides *what* to serve — `shares.json`
does — only *how* on its kind of machine; that is what lets the storage control plane grow to
servers that are not PVE hosts.

### D20 — No migration: the one user moves by hand

ADR-025 asks for a migration whenever `config/` changes shape. v0.9 ships none (operator
decision): the only NFS user is the Jellyfin test install on the reference site, and a
migration written for one config would be code kept forever for nothing. That install is
moved by hand once v0.9 is deployed — the share declared with `storage-manager nfs share add`
and `grant` from what its node's `nfs.exports[]` held, the node's `nfs` field removed,
Jellyfin's `pvehost:nfs` (its `dependsOn` entry and `config` block) renamed `storage:nfs`, then
the node's and Jellyfin's update run. The `pvehost` module stops providing `nfs`; its field
definition and service directory go, and its node code moves behind the server hook (D19).

---

## Worked example — Jellyfin (#52)

`jellyfin.json` ships the same mount to every site:

```json
"dependsOn": ["cluster:vm", "templates:nixos", "backup:vm", "network:proxy", "network:rules", "storage:nfs"],
"config": {
  "storage:nfs": { "mounts": [
    { "path": "/media", "share": "media", "subdir": "jellyfin", "access": "rw",
      "stopUnits": ["jellyfin.service"] }
  ]}
}
```

**On a site with no media share** the mount is pending: Jellyfin installs, `/media` is a
directory on its own disk, and `validate` notes that the share `media` is not declared.

**Later the operator creates the share** on the node that has `tankb1`, and grants it:

```bash
storage-manager nfs share add media --server tappaas1 --pool tankb1 --quota 4T \
    --prop recordsize=1M --prop compression=lz4 --backup true
storage-manager nfs grant media jellyfin rw
```

`share add` validates, writes `shares.json`, and converges: tappaas1's hook creates
`tankb1/tappaas-nfs/media` at `/tappaas-nfs/media` (owner 64000:64000, allocated and recorded),
and the manager creates the alias `nfs-media.mgmt.internal` → `tappaas1.mgmt.internal`. `grant`
adds Jellyfin to the client list and runs Jellyfin's `storage:nfs` update, which first
recompiles its firewall rule (Jellyfin → `nfs-media.mgmt.internal`, tcp/2049), then — with
consent (`rebootOk`, or `--allow-disruption`) — migrates `/media` into
`/tappaas-nfs/media/jellyfin`; without consent it reports *migration pending*. The next
healthy update removes `/media.pre-nfs`.

If the operator later moves the share to another node, Jellyfin's config, mount and rule are
unchanged: the dataset is sent, `share modify`'s refusal names the procedure, `shares.json`'s
`server` changes, and the alias follows. Because tappaas1 `integratesWith` `backup:filesystem`,
the library is captured nightly as `tappaas1-nfs-media` (D9).

The Community Jellyfin module carries its own media-storage modes (`mediaStorage:
allocate|share`); adopting this mount replaces those, which is that module's change.

---

## Consequences

### Positive

- Large, low-value data leaves the redundant pool and the guest's backup, and gets a
  lifecycle of its own.
- A module ships one mount to every site: it installs where no share exists, needs no
  knowledge of where a share lives, and moves its data into a share that arrives later
  (v0.8).
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
- A new listener on a hypervisor, reachable from one workload zone — or, beyond one zone, a `storage` zone and an interface in it on every serving node (D5).
- `sec=sys` means root on a consumer is full access to its exports; isolation is only per
  export.
- NFS is cleartext on internal VLANs: TLS is deferred until OpenZFS can share with it (D5).
- A share is a single point of failure for its consumers, and HA does not help (D8).
- A backed-up library costs its full size in the PBS datastore at least once, and its
  first capture is a long run; `quota` is also the ceiling on what the backup can grow to.
- Throughput is capped by OPNsense routing, even on the same node.
- A mount depends on the site resolver for the share alias, and the firewall's view of a
  moved share lags by up to the 300 s host-alias TTL (D2b).
- A migration stops the app for its second pass, and needs consent to run (D14); share
  names are a Site-wide namespace the operator must keep unique.
- Two more declarations for `module-manager validate` to cross-check, and a DHCP-dependent
  client list to keep in step.

### Neutral

- Containers are consumers too, but realized differently — by the node, not inside the
  container (D12).

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
| **`cluster:nfs`, or a new `storage` module** | v0.1–v0.3 placed the service on `cluster`; v0.4 decided `pvehost`, rejecting a `storage` module as one with no machine of its own. **v0.9 revisits it** (operator): the state moves to `storage-manager`, the servers keep the building (D19), and a thin `storage` module only gives consumers their coordinate — the `network` / `network-manager` split (D1). |
| **Share declarations in the node's own config** (`nfs.exports[]` on the pvehost instance, v0.5–v0.8) | Fit while the node was the share's owner. Once v0.8 made a share Site-unique and its server a DNS answer, it left: a move as an edit of two node files, uniqueness as a scan, `modify --set nfs=…` as a whole-object replacement (and refused), Site state in a module's release merge. **Superseded** (operator, v0.9) by `shares.json` and `storage-manager` (D1, D17). |
| **Mark `nfs` as a provider-owned field** so a node may `modify` it | Classifies the field correctly and fixes the refusal, but keeps the declaration on the wrong object. The general fix it implies — a module may change fields owned by services it provides — is made anyway (*Implementation plan*). |
| **A host-qualified share reference** (`tappaas1:media`, v0.1–v0.7) | Put a node's name into a module's file: the same module could not ship to two sites, and a moved share broke every consumer. **Withdrawn** (operator, v0.8) for a Site-unique name reached through a share alias (D2, D2b). |
| **Resolve the share from config instead of DNS** (the service rewrites the guest's mount with the current server on each update) | Works for the mount, but the firewall rule and the guest both still name the server, so a moved share needs every consumer updated before it is reachable. The alias makes the move a single DNS change (operator choice, v0.8). |
| **Consumer-provisioned exports** (the mount names `pool` + `size`, TAPPaaS creates the export) | Nicer to write, wrong ownership: the data would follow the consumer's lifecycle, which is the problem D6 exists to prevent. **Rejected** (operator, v0.3) — also as a later shorthand: the export is always declared on its Host. |

---

## Resolved questions

Every question the drafts raised is answered; each answer lives in the decision it changed.

| Q | Question | Answer | Where |
|---|---|---|---|
| Q1 | The hypervisor exposure | One-zone consumers: pinhole into `mgmt`; consumers from several zones: a `storage` zone | D5 |
| Q2 | The owner range | 64000–64999, written back into the declaration | D5 |
| Q3 | Which module provides it | `pvehost` | D1 |
| Q4 | Consumer-provisioned exports | Rejected | D11, *Alternatives* |
| Q5 | Encryption | v0.6: RPC-with-TLS by default. **v0.7: deferred** (#771) — `sharenfs` cannot carry `xprtsec`; `sharenfs` kept | D5 |
| Q6 | LXC consumers | In scope, realized by the node with bind mounts | D12 |
| Q7 | Quota as a health signal | Yes — 80 % / 95 % | D13 |
| Q8 | Off-site for exports | No | D9 |
| Q9 | Module type of a registered server | One generic `unmanaged` `kind: machine` module | D2a |
| Q10 | How a consumer finds a share (v0.8) | By a Site-unique name, through the DNS alias `nfs-<share>.mgmt.internal`; a registered NAS the same way; only `<ip-or-host>:/<path>` is used as written | D2, D2b |
| Q11 | A share that exists but does not grant the consumer (v0.8) | Error; only an undeclared share leaves a mount pending | D11 |
| Q12 | Consent for a migration (v0.8) | Required: `rebootOk` or `--allow-disruption`; otherwise *migration pending* | D14 |
| Q13 | The `<path>.pre-nfs` copy (v0.8) | Deleted by the next healthy update; backups cover a fatal error | D14 |
| Q14 | Where the stop/start declaration lives (v0.8) | On each mount: `stopUnits`, plus `stopCommand`/`startCommand` for what is not a unit, behind an open-files guard | D3, D14 |
| Q15 | Where share declarations live (v0.9) | A Site file, `config/shares.json`, not the node configs | D1, D4, D18 |
| Q16 | Who changes them (v0.9) | A new `storage-manager`, one share per verb, growing beyond NFS and beyond PVE hosts | D17, D19 |
| Q17 | The consumer coordinate (v0.9) | `storage:nfs`, from a virtual `storage` module like `cluster`; the PVE nodes deliver the service | D1 |
| Q18 | A `share move` verb (v0.9) | Later; an operator procedure until then | D7, D17 |
| Q19 | A migration for v0.8's config (v0.9) | None — the one user is moved by hand | D20 |

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
8. ~~RPC-with-TLS~~ — **deferred** (v0.7, D5): `sharenfs` cannot carry `xprtsec`. Picked up
   again when OpenZFS can, starting from the probe results in D5.
9. The `storage` zone (D5): `network-manager` creates it on first need, the node's interface
   and `[nfsd] host=` binding, the switch as a consented disruptive change.
10. Container consumers (D12): node-side mount, `mpN` bind mount, the same-node shortcut,
    `lxc.idmap` to `owner`, mounts on every HA placement node.
11. Health (D13): quota use at 80/95 %, pool free space for an export without a quota.
12. Jellyfin (#52) as the first consumer; then `debianhost` exports.

**v0.8 changes to what #766 built** (tracked with the remaining work packages in #772):

13. Share references: a Site-unique share name, or `<ip-or-host>:/<path>`; the
    `<instance>:<name>` form removed; `validate` refuses a share name declared twice — in
    `nfs-lib.sh` and `module-manager/src/nfs.ts` alike.
14. Node: `mountpoint=/tappaas-nfs/<share>`; the share alias created and deleted with the
    export (`dns-manager alias`).
15. Pending mounts: no fragment entry, no rule, no client-list entry; reported, not refused.
16. Migration (D14): the consent gate, the two passes, stop/start, the open-files guard, the
    swap, the immediate mount, `.pre-nfs` removal on the next healthy update; the server's
    update running the consumers' updates.
17. `subdir` (D15): created owned by `owner`, part of the mount's device path.
18. The client list from deployed, mounting consumers; delete and mount removal reconverge
    the server without the consumer; the server-side drift check (D16).
19. `rules_manager`: the derived rule targets the share alias.

**v0.9** (not built; nothing uses NFS yet):

20. `storage-manager` (TS, `tappaas-cicd/manager/storage-manager/`): `shares.json` schema and
    loader, the lock, the verbs of D17 with `--check`, validation shared with `module-manager
    validate`, converge (hook + alias) and consumer notification; its fast tier.
21. The virtual `storage` module (registration only, installed with the foundation, like
    `cluster`): `storage:nfs` — the consumer side of v0.8 moved from `pvehost`, reading
    `shares.json` instead of scanning instances; it recompiles the consumer's `network:rules`
    before mounting or migrating across the firewall (D11); the automount-aware probe (D14).
22. `pvehost/storage/nfs-server.sh`: the v0.8 node code behind `converge|test|purge`; the node's
    update calls `converge`; `pvehost` stops providing `nfs`.
23. `rules_manager` and `module-manager validate` read shares from `shares.json`.
24. Move the reference site's Jellyfin test install by hand (D20).
25. The deep suite on the verbs, with the scenarios v0.8 missed: a share added after the
    consumer, migrated by the notification alone (the D11 rule); an update after migration that
    does not touch the directory first (D14).
26. **General, not NFS:** `module-manager modify` accepts a field owned by a service the module
    itself provides — `converge.ts` builds the field's owners from `dependsOn` + `integratesWith`
    only, where `validateOrphanFields` already counts `provides` (found as bug 1 on v0.8).

## Testing

- **Fast tier** (`pvehost/lib/test-nfs-lib.sh`, `module-manager/test/unit/nfs.test.ts` — the
  same cases in both): share references (name, literal, a literal on a module instance
  refused); a share name declared twice refused; the pending / not-granted / `rw`-against-`ro`
  matrix; `subdir` shape (no `..`, no leading `/`); the device path through the share alias
  with and without `subdir`; descriptor rules for a registered server; the `wan` refusal;
  `sharenfs` rendering (never `on`, never `no_root_squash`, never a subnet, `off` with no
  mounting consumer); the client list leaving out a granted consumer that is deleted or does
  not mount; the derived rule targeting the alias, none for a pending mount; NixOS and
  Debian rendering; `backup.enabled` missing → error.

- **Deep tier** — `storage-manager`'s `test.sh --deep` (v0.9; `pvehost/test.sh <node> --deep` in
  v0.8) runs the end-to-end suite against a real node of the running site, declaring and
  granting its share through the verbs. It brings its own fixture module (`pvehost/test-nfsconsumer/`, a
  disposable NixOS clone in the default environment's service zone, depending on
  `storage:nfs` and `network:rules`, carrying a small writer unit for `stopUnits`), a share
  named `deeptest-<random>` with a 1G quota on the node's `tankb1` (else its first data
  pool), and edits to the node's config that it backs up and restores. Every step is an
  assertion; the scenario runs in this order:

  1. **Pending** — install the fixture with its mount; the share is undeclared: the install
     succeeds, `path` is a local directory, no fragment entry, no rule, `validate` reports
     the pending share.
  2. **Not granted** — declare the share without a grant: `validate` and the service refuse.
  3. **Migration pending** — add the grant (v0.9: `storage-manager nfs grant`): the dataset, the
     `/tappaas-nfs/<share>` mountpoint and the alias exist; the consumer's update (run by
     the node, no consent) reports *migration pending* and changes nothing.
  4. **Guard** — seed files in `path`, hold one open from a process outside `stopUnits`, run
     with `--allow-disruption`: the migration aborts at the guard, names the holder, and the
     local data and app are untouched.
  5. **Migration** — release it and run again: two passes, the writer unit stopped and
     started, `path` mounted through `nfs-<share>.mgmt.internal`, the files on the node owned
     by `owner`, `<path>.pre-nfs` present.
  6. **Healthy update** — update once more: the mount is active, the test passes,
     `<path>.pre-nfs` is gone.
  7. **subdir** — a second mount on the same share with another `subdir`: created, owned by
     `owner`, separate from the first.
  8. **Firewall** — the consumer is in a service zone: exactly one rule, consumer →
     the alias, tcp/2049; the export's client list holds exactly the consumer's address,
     and the node's own test passes (alias, mountpoint, no client-list drift). (A second VM
     proving it cannot mount would cost another clone, or a probe from another module's
     guest; the server-side list is asserted instead.)
  9. **Move** — send the dataset to another node and move the declaration there: the alias
     follows it; the suite waits for the firewall's alias table to follow (up to 10 minutes —
     the 300 s TTL plus a refresh), then the consumer mounts it with its config unchanged. A consumer's *active* mount must be remounted after a move — the old
     server no longer exports it, and a `hard` mount stalls until it is; the suite unmounts
     before the move, as an operator would.
  10. **Delete** — delete the fixture: its address is gone from the export's client list
      **at once** (D16), its rule is gone, the share's data is kept and reported as unmounted.
  11. **Gone after migration** — a consumer whose migrated share is removed: `validate`
      errors, no fallback to a local directory.
  v0.9 adds: **a share that arrives after the consumer** is migrated by the notification
  `grant` sends, with no other step run — so the consumer's own rule compilation (D11) is what
  makes the mount reachable; and **an update after migration that does not touch the
  directory first**, which must leave the automounted share alone (D14).
  12. **Teardown, always** (a trap, also on failure): the fixture deleted, the node's config
      restored byte-for-byte, the test datasets destroyed after the NFS server releases them,
      the alias and the share's firewall alias deleted, `nfs-kernel-server` removed only if
      the test installed it (never `nfs-common`'s `/etc/nfs.conf.d`), stale pf tables
      dropped, the fixture's DNS records deleted. Then a **leftover check** that fails the
      run if any of it remains.

  Cost: one VM clone and three guest rebuilds — about 20 minutes — so it runs in `--deep`
  only, never in the sweep.

- **Server outside the cluster** (with WP7): a Debian VM plays the NAS, registered
  `unmanaged`; mount through its share alias from a consumer in another zone; `show` prints
  the client line; remove the consumer from the server's table by hand → the access test
  fails and raises the finding; restore it → green; repeat with NFSv3 and pinned ports.
