# ADR-012 — Backup Enhancement

| | |
|---|---|
| **Status** | **Accepted** (v1.0, 2026-09-18) — the decision, signed off by the operator with #600, #602, #605, #607, #609 and #612 settled. Implementation is tracked separately (*Acceptance → Implementation*, and #407): most of it is live-verified on the reference cluster; what v1.0 adds is not built yet. |
| **Version** | 1.0 |
| **Date** | 2026-08-29 (v0.9: 2026-09-18) |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#402** (flexible backup install on a cluster — origin); **#389** (remote/off-site backup setup + single-node); **#382** (adding a node does not install the backup client); **#456** (no placement policy for a pre-existing local PBS); **#214** (`pbsType`/external bare-metal PBS); **#501** (complement `dependsOn` with `integratesWith`); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite off-site backup, pull model, compromise isolation); [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (named, not numbered foundation modules); [ADR-022](<ADR-022 - Workload Ontology.md>) + [ADR-022d](<ADR-022d - Workload Classification.md>) (the workload vocabulary and classification this ADR's Appendix A graduated into — draft, with two points open against §2.1); [backup/RESTORE.md](../../src/foundation/backup/RESTORE.md) (recovery per scenario) and [backup/README.md](../../src/foundation/backup/README.md) (PBS namespaces, multi-source pull/push — #227); **#544** (backup discovery scans `config/*.json` — misclassifies non-module state files; **resolved §2.7**); **#545** (backup + tested recovery for the foundation modules & `config/`; **resolved §2.7 / D20**) |
| **Refined by** | [ADR-026](<ADR-026 - Managed Machines as Modules.md>) (the Host a PBS lands on is a module) · [ADR-022d](<ADR-022d - Workload Classification.md>) (`kind`) · [ADR-022e](<ADR-022e - Module Scope.md>) (`scope` replaces `tier`) · [ADR-022f](<ADR-022f - Kind Values and Operating System.md>) (`application`, OS facet) · [ADR-022g](<ADR-022g - Management.md>) (`management`, `placementState: external`) |
| **Implementation** | [ADR-012-implementation.md](../design/ADR-012-implementation.md) — plan, decisions log, package tracker |
| **Changelog** | v1.0 (2026-09-18) — decision accepted. An empty `placementState` never provisions over a PBS that already serves the Site (§2.2, #602); `external` has a deliberate exit, `backup-manager placement reset` (§2.3, #607); every off-site target records its Location (§1.5, #609); `shim` stays and `vmname` gives way to the instance name, registered as a DNS alias of the Host (§2.7, #612); #600 answered by §1.3; acceptance split into decision and implementation (#605). · v0.9 (2026-09-18) — topologies renumbered (§1.3 machine, §1.4 external); `placementState` keeps `external`, amending ADR-022g D5; the satellite moved to §1.3; external defined as "TAPPaaS does not model the host". v0.8 (2026-09-18) — fourth topology: a local PBS on a machine that is not a cluster member (§1.2a), which ADR-026's `debianhost` makes patchable. v0.7 (2026-09-17) — aligned to the ADR-022 vocabulary: `kind: application`, `scope: site`, `management`, `placementState: external`. v0.6 — backup-buddy relationship moved to ADR-024. v0.5 — off-site retention and the schedule cascade. v0.4 — as-built after the live verification on the reference cluster. v0.3 — unified credential model and promotion. v0.2 — placement resolved as state, per-node client reconcile (#382). v0.1 — skeleton: topologies, placement policy, off-site (#402, #389, #456). |

Make the `backup` foundation module flexible about **where PBS lives** (or whether it lives in the cluster at all), keep the **per-node backup client** in step with cluster membership, give **off-site/remote backup** real setup, subsetting, and independent retention — without ever letting a compromised local cluster reach the off-site copy — and let a module declare **what kind** of backup it needs, not just on/off.

---

## Context

The current [`backup`](../../src/foundation/backup/) module makes assumptions that hold for the reference three-node cluster but break for the deployments TAPPaaS now targets (single node, two node, no suitable `tankc`, off-site-only, a PBS the site already runs). They are captured in open Release-1.2 issues.

### 1. PBS placement is hardcoded (#402)

[backup.json](../../src/foundation/backup/backup.json) pins `"node": "tappaas3"` and `"storage": "tankc1"`, and [install.sh](../../src/foundation/backup/install.sh) creates the PBS VM there unconditionally. If `tappaas3` doesn't exist, or the cluster has no `tankc` pool, or the operator wants no in-cluster PBS at all (push straight to an off-site target), install either fails or silently lands PBS somewhere unsuitable. Meanwhile many app modules `dependsOn` `backup:vm`, so **without *some* `backup` module present those modules can't install** — backup can't simply be skipped.

### 2. The per-node backup client drifts out of sync (#382)

[install.sh](../../src/foundation/backup/install.sh) enumerates `pvesh get /nodes` **once, at install time**, and installs `proxmox-backup-client` on every node then present. A node added later (via the [`cluster`](../../src/foundation/cluster/) module's node-add flow) **never gets the client**, so backups of VMs on that node can't run. There is no reconcile step; `update.sh` doesn't currently re-provision clients on new nodes.

### 3. Off-site/remote backup is under-specified (#389, #402)

The PBS namespace model (#227) is documented in [backup/README.md](../../src/foundation/backup/README.md): `remote/<name>` for a TAPPaaS buddy's PBS **pulled** in (Class A) and `external/<name>` for a third party **pushed** in (Class B). [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) specifies the satellite as an off-site PBS the home PBS is pulled into. What is still missing:

- A supported way to **push** the local backup to a remote target for operators who don't want to run in-cluster PBS at all (or run a single node with no room for it) — #402's "allow a remote push backup to be specified."
- **Single-node / small-site** backup: no second node to host PBS, so backup must go **directly to a remote/satellite** — #389's follow-up comment.
- Backing up **only a subset** of the local backup set off-site, with a **different retention policy** than the local copy it derives from — #389.
- A tested guarantee that **a compromised local system cannot compromise the remote backup** — #389.

### 4. No policy for a pre-existing local PBS (#456)

Earlier placement covered a PBS the module *installs* on a node (a `node` state) and a PBS that *doesn't exist yet* (a `shim`). Neither covers a site that **already runs its own PBS on the local network**, provisioned outside TAPPaaS: it has a real local datastore, so `shim` doesn't apply, and the module didn't place it, so a `node` state would describe work that never happened. The module needs a way to *consume* such a PBS — given its address (URL), register Proxmox storage and drive jobs/clients — without discovering storage or installing anything. (This ADR resolves it with the `external` state, §2.1.)

This ADR decides the model for all four, plus a taxonomy of **what** each module backs up. It builds on ADR-010 (which owns the *satellite node itself*); ADR-012 is about the **`backup` module's behavior and configuration**.

---

## 0. Vocabulary (ADR-022)

This ADR predates the ADR-022 ontology. The decisions below are unchanged; the
words they use are now these.

| This ADR said | ADR-022 says | Which rib |
|---|---|---|
| `tier: foundation` | **`scope: site`** — backup belongs to the Site and serves every Environment | 022e D1 |
| (no field) | **`kind: application`** — backup installs PBS onto a Host and owns no system of its own | 022f D1, D3 |
| `status: external` | **`management: unmanaged`** — registered, with no install/update/test/delete lifecycle | 022g D3 |
| `placementState: external` | **unchanged — and now precise.** The datastore is outside this Site's Administrative Domain: TAPPaaS does not model the host and does not maintain the PBS on it | 022g D2 |

Three consequences worth stating, because each closes a question this ADR left open:

**Backup is `kind: application` in every variant** (022f D4). The variants differ
only in the Host the packages land on, and whether that Host is a cluster member
is a fact about the Host, not about backup. Managing the application is
independent of its Host (022f D5): the same packages, datastore, jobs and
clients, whether the Host is in the cluster or beside it.

**`external` stays the placement value — this amends ADR-022g D5**, which renames
it `consumed`. The rename was proposed while *external* still meant several things
at once, and "consumed" was the way to say "not ours" without using an overloaded
word. 022g D2 has since made *external* mean exactly one thing — outside this
Site's Administrative Domain — which is precisely this placement, so the
replacement is no longer needed and reads less naturally than the term it
replaced. **Erik to confirm.**

The line this draws is sharper than "who installed it": an external PBS is one
whose **host TAPPaaS does not model at all**. A PBS on a machine registered as a
module — `managed` or `unmanaged` — is §1.3, even if someone else installed the
host. A PBS reachable at a local URL inside one of our own zones is still external
if the host is unknown to `module-manager` (§1.4).

**`scope` is not `stack`** (022e D5). Backup is `scope: site` and participates in
whatever Stack aggregates the capability; the two are separate facets and neither
replaces `tier`'s other meaning — `zone.tier` keeps that (022e D7).

---

## Decision

The solution is organised in three parts, matching how an operator actually reasons about backup:

1. **[Supported backup topologies](#1-supported-backup-topologies)** — the shapes a site's backup can take.
2. **[Configuring & detecting the Backup module](#2-configuring--detecting-the-backup-module)** — how the module finds where PBS should live, falls back to a shim, keeps clients in sync, and is driven by tooling.
3. **[Configuring clients & backups](#3-configuring-clients--backups)** — what each module backs up (the backup-type taxonomy) and how the schedule is specified.

The workload-placement taxonomy that earlier drafts carried inline (`node`/`standalone`/`satellite`/`external`/`remote`/`rogue`) is a *broader* concern than backup. It was parked in Appendix A and has since **graduated into [ADR-022d](<ADR-022d - Workload Classification.md>)**; [Appendix A](#appendix-a--workload-placement-taxonomy-graduated--adr-022d) is now a pointer to it, plus the two points where ADR-022d's draft and this ADR's implemented decisions still have to be reconciled.

---

## 1. Supported backup topologies

A site's backup is described by **where its primary PBS datastore lives and who manages it**. In **all four** topologies a **single `backup` module is provisioned** on `tappaas-cicd` — always installed, always satisfying `dependsOn: backup`. The difference is only whether that module also **provisions PBS software**:

| Topology | PBS software provisioned by the module? | Local datastore? | How selected | Typical site |
|---|---|---|---|---|
| **Shim** (§1.1) | no | no | state `shim` — no `tankc` found (and not forced `external`) | first boot, testing, before storage exists |
| **Local PBS on a cluster node** (§1.2) | **yes** — installed on the node's Proxmox OS (not a VM) | yes | state `node` — a `tankc` is found | reference 2–3-node cluster |
| **Local PBS on a machine** (§1.3) | **yes** — installed on a machine that is not a cluster member | yes | state `node`, with `node` naming a `kind: machine` module | a site whose datastore lives off the cluster |
| **External PBS** (§1.4) | no | no | state `external` — operator forces it + gives a URL | an organisation that already has a PBS |

Only the two **local PBS** cases realise PBS software and a datastore; shim and external both provision the module without any PBS software of their own. Off-site *relationships* between PBS instances (a satellite pulling the home PBS, a buddy) layer on top and are covered in **§1.4**.

### 1.1 Shim — no datastore (bootstrap / testing)

A shim is JSON/marker only: **no PBS software, no datastore**, flagged so it is recognisable as a shim, with a warning emitted. It exists so the dependency graph stays satisfiable — modules that `dependsOn` `backup:vm` (or `backup:remote`) still install against it. The shim `provides` the same capability names but records that no datastore is realised locally; a module that hard-requires a live datastore surfaces that at test time, not install time.

A shim is a **placeholder promoted in place later** (§2.3): once a `tankc` pool or a target URL appears, `update-module.sh backup` turns it into any of the real topologies **and existing `dependsOn: backup` consumers keep working** without reinstall. Useful for bootstrapping a system and for testing the dependency graph before storage exists.

### 1.2 Local PBS on a cluster node (module-provisioned)

The module **discovers** a `tankc` pool (configured node first, then any node — see §2.2) and installs **PBS software directly on that cluster node's Proxmox OS** — via the Proxmox PBS package, it is **not** a separate guest VM — and owns the datastore on the node's `tankc` pool. This is the reference topology, now conditional on a `tankc` pool being present. The datastore it creates is the local backup target for the site's guests (§3).

A local PBS can also participate in **buddy relationships** with other PBS instances — including acting as a **pull source** for another TAPPaaS system. Those cross-PBS relationships are covered in **§1.4**.

### 1.3 Local PBS on a machine that is not a cluster member

The same topology as §1.2 with a different Host: the PBS packages land on a
**`kind: machine` module** (ADR-022f) instead of on a cluster node. `placementState`
is still `node` — the field names a **Host**, and ADR-022c D3 is explicit
that it does not assert cluster membership. Live evidence predating this section:
`config/backup.json` already carries `node: "backup"` while `site.json` lists only
`tappaas1` and `tappaas2`.

**Why this works at all:** a Proxmox node reports `ID=debian` (measured on
`tappaas1`, 2026-09-18) — PVE is a package set and a kernel flavour on top of
Debian, not a separate OS. So `proxmox-backup-server` installs identically on a
cluster node and on a plain Debian machine, and backup manages the datastore,
jobs and clients the same way on both (ADR-022f D5).

**What differs is who patches the Host.** On a cluster node the `cluster` module
does. A machine outside the cluster has no owner today — ADR-022f D5 calls this
"a gap for the module model, not for backup" — which is why this topology depends
on the `debianhost` module of **[ADR-026](<ADR-026 - Managed Machines as Modules.md>) D3**.
Until that exists, a site can run this topology only by patching the machine by hand.

**Management stays `managed` for the application.** TAPPaaS installs the PBS and
runs its lifecycle; that the Host is not a cluster member changes nothing about
the application (022f D5). A PBS someone *else* installed, on a host TAPPaaS does
not model at all, is §1.4 — not this.

**The satellite is this topology, not §1.4.** ADR-010's off-site outpost is a
`kind: machine` module (ADR-010 §8, ADR-026 D1) carrying the `backup` role: TAPPaaS
provisions it, keys it and installs the PBS on it. It is emphatically **not**
external — it is the Site's own machine, and off-site is a Location (ADR-022b), not
a domain boundary. What is unusual about it is its `management` value, which starts
`managed` during provisioning and becomes `unmanaged` once it is running, so that
the vault stays independent of the home cluster (ADR-026 D5, ADR-010 §7.3). Either
way the host is a module TAPPaaS knows, which is what puts it here.

### 1.4 External PBS (a PBS outside this Site, reached by URL)

The module can use a PBS it **does not provision and does not manage**. The single
knob is a **URL** to that PBS (plus a credential, §2.5).

**External** here carries its ADR-022g D2 meaning exactly: *outside this Site's
Administrative Domain*. The host is not a TAPPaaS module — `module-manager` does
not know it exists — and the PBS installed on it is maintained by whoever owns it.
That is the whole of the definition, and it is what separates this topology from
§1.3.

What varies is only **reachability**, and it does not change the model:

- a PBS on the **public network** — the URL is its public host;
- a PBS belonging to another organisation you have an arrangement with — likewise;
- a PBS sitting in a zone that *is* part of this TAPPaaS network — then the URL is
  simply a **local URL**. Being reachable locally does not make it ours: nothing
  about the host or its packages is known to or managed by TAPPaaS.

> **Not to be confused with §1.3.** A machine registered in TAPPaaS — `managed` or
> `unmanaged` — is a module: it has a config, the model knows its OS, and a PBS on
> it is an `application` TAPPaaS installs and maintains. An external PBS has none
> of that. The distinction is not where the box sits or whether you can ping it; it
> is whether TAPPaaS models the host at all.

The **credential mechanics are identical** in every case (§2.5): clients push with a
write-no-delete token and the remote PBS owns prune and retention.

An external PBS is simply the site's configured target: clients push to it exactly
as they would to a local TAPPaaS PBS. When it is used instead as a *second,
off-site* copy beside a local datastore, that is §1.5.

### 1.5 Off-site copies: clients push, buddies pull

**Off-site is recorded, not asserted (#609).** An off-site copy is worth having because a fire
or a theft at the building does not reach it — a *physical* separation, which only data can
show. Every off-site target therefore declares a **`location`** in the same shape as the Site's
own (`site.json` `location`: ISO country, optional city and facility — a Location in the sense
of ADR-022b): the satellite as a field of its machine module (ADR-026), a peer PBS in its
`pull-`/`remote-` config. A check flags an "off-site" copy whose location equals the Site's,
and one that declares none. Without it, a satellite in the same room as the cluster and one in
another country are indistinguishable, and the 3-2-1 claim below cannot be tested.

There are only **two** data movements in the whole model, and neither requires a PBS to push to another PBS:

**1. Clients push to their configured PBS.** Every backup client (the per-node `proxmox-backup-client`, §2.4) *pushes* its snapshots to the one PBS configured for the site. Whether that PBS is a local TAPPaaS PBS (§1.2) or a consumed one (§1.4, including the single-node `external` case) is **irrelevant to the client** — it just uploads to the configured target. On a **shim** there is no target, so the push is a **no-op**. The client credential is **write, no delete** and the **PBS owns prune/retention**, so a compromised node can add snapshots but never delete or rewrite them — local *or* remote.

**2. Off-site buddies pull.** A second, off-site copy is **always** made by the destination *pulling* from the source — never by the source pushing out.

- A **satellite** (ADR-010) pulls from the home PBS it is a satellite for (over the tunnel).
- A **peer TAPPaaS** acting as your off-site buddy pulls from your PBS.
- Symmetrically, your PBS can be the buddy that pulls *another* system's backups in.

A TAPPaaS backup system therefore registers three peer relationships — and there is **no push between backup systems** in any of them (v0.5):

| Relationship | What it is | Who initiates | Credential this side holds | Namespace here |
|---|---|---|---|---|
| **`pull`** | we pull a copy of *their* backups (we are their off-site) | we do | a read-only token **on them** | `pull/<name>` |
| **`remote`** | *they* pull ours — **this is where our off-site copies live** | they do | none on them; we *grant* them a read-only token **on us** | none — it is a read grant on data we already hold |
| **`receive`** | they *push* their backups into ours, having no PBS of their own. In essence we are the external PBS for another TAPPaaS system | they do | none; we *issue* them a write-no-delete login | `receive/<name>` |

`pull` and `remote` are the same movement seen from the two ends: to keep an off-site copy of this site's data with a buddy, this site adds a **`remote`** peer and the buddy adds a **`pull`** peer.

**There is no peer kind for sending our backups to another PBS**, deliberately. A site with no local datastore points its own *clients* at a PBS it does not own through **placement** (`placementState: external` + `pbsUrl`, §1.3) — a property of this module's installation, not a relationship with a peer. And a TAPPaaS PBS never pushes to another PBS at all: every inter-PBS copy is a pull, which is what makes §1.5.1 structural.

> **The `remote` grant does not propagate.** PBS ACLs inherit into child namespaces, so a `DatastoreReader` grant on the root namespace would hand the peer `fs/` — this site's `config/` and `/etc/secrets` capture — and every other peer's data, alongside the VM backups it was meant to cover. `remote` therefore grants **non-propagating** by default, and says so when an operator asks for propagation explicitly.

A local PBS plus a pulling satellite is a classic **3-2-1**.

#### 1.4.1 Why this is safe — and why no PBS→PBS push is needed

*A compromise of one system must not be able to delete, encrypt, or tamper with a copy held on another.* The two movements above satisfy this **structurally**, with no special "append-only push" machinery:

- **Client push (write-no-delete).** Clients only ever hold write-no-delete credentials and the PBS owns prune, so a compromised node cannot destroy backups on the PBS it pushes to — even when that PBS is a consumed one (the single-node `external` case). This is the **only** push in the system, and it is safe by credential scope, not by any special mode.
- **Buddy pull (no reverse credential).** The source PBS holds no credential to its off-site buddies — the buddy reaches in and pulls (ADR-010 §3.1, §7.2). A compromise of the source cannot touch the pulled copy.

**Do we need an "append-only push" between backup systems? No.** Every inter-PBS copy is a pull, so there is never a source→destination write path to harden. The old draft's append-only *push receiver* existed only to make such a push safe — but that push is unnecessary: an off-site that can pull (a satellite over the tunnel, or a peer) covers every supported topology, and a site with no local PBS simply has its clients push to the external PBS directly (still write-no-delete). *(A pure push-only third-party target that refuses to pull is the sole case a PBS→PBS push would serve; it is **out of scope** for TAPPaaS topologies.)*

- **At-rest immutability is a separate, optional layer — and deferred.** The structural pull + write-no-delete isolation above is what makes the off-site copy safe. Freezing a datastore against tampering via its *own* admin plane (PBS/node root) is an *additional* hardening layer, **not** part of this guarantee — it is left to [Future improvements](#future-improvements), so deferring it does not weaken §1.4.
- Backups are **client-side encrypted with the local key**; any PBS holding a copy stores ciphertext only and never holds the decryption key (ADR-010 §3.2).

Because each PBS owns retention over its own datastore, an off-site copy naturally runs its own (typically longer) retention independent of the source (§3.3), and the invariant is preserved.

---

## 2. Configuring & detecting the Backup module

This section is the **module/server side**: how the module decides where PBS lives, falls back to a shim, promotes later, keeps per-node clients in sync, handles credentials, and is driven by tooling.

### 2.1 Placement is a resolved *state*, not a policy

There is **no `placement` policy field.** The released module ships with `placementState` **empty**; `install.sh` resolves it once, and the resolved value is written back to `config/backup.json` so it is inspectable and idempotent. `placementState` is the single source of truth:

| `placementState` | How it gets there | Meaning | Topology |
|---|---|---|---|
| *(empty)* | the released module default | **unresolved** — install derives it | — |
| `node` | not forced `external`, a `tankc` is found | install PBS on the Host named by `node` + own the datastore | §1.2, §1.3 |
| `shim` | not forced `external`, and **no `tankc` found** | catch-all fallback: marker only, no datastore | §1.1 |
| `external` | **install told to force `external`** (+ a `pbsUrl`) | use the PBS someone else installed; provision nothing. **Sticky:** kept until the operator deliberately leaves it (§2.3). | §1.3 |

Two operator inputs shape resolution, both on `backup.json`:

- **`node`** *(optional)* — restrict `tankc` discovery to a **single named node**. If unset, all nodes are searched.
- **`pbsUrl`** — the PBS the clients push to (§1.5). **Defaults to `backup.mgmt.internal`** (the local PBS DNS name). Overridden to the external PBS's URL (public host / LAN addr, §1.4) when going `external`.

Forcing `external` is an **install-time action** (an install argument + `pbsUrl`), not a config policy field — it *overwrites* `placementState` to `external`, and that is then **sticky** — never re-derived, and left only by a deliberate `backup-manager placement reset` (§2.3, #607). This one state covers every external flavour — satellite, public external, or a pre-existing LAN PBS (#456) — because the module's behaviour is identical (provision nothing, register the PBS at `pbsUrl` as storage, clients push there). *(It subsumes the earlier `remote-only`, which was indistinguishable.)*


### 2.2 The resolution order

At install/update, `install.sh` resolves `placementState`:

1. **Told to force `external`?** → `placementState = external` (requires `pbsUrl`). No discovery, nothing provisioned. Sticky until left deliberately (§2.3).
2. Already a concrete state (`node` or `external`) → **keep it** (idempotent).
3. **Empty → first ask whether a PBS already serves this Site (#602).** Probe the Host named in `backup.json.node`, and `pbsUrl`, for a PBS answering on `:8007` that holds the datastore `pbsStorageName`. One found on a Host this Site manages is **adopted**: `placementState = node`, `node` = that Host — nothing is installed, nothing moves. One found on a host this Site does not manage **stops** resolution: that is `external`, and it is forced deliberately (rule 1), never inferred. **An empty state is never a licence to provision over a running PBS** — on install or on update. On a PVE node the old probe (`pvesm status`) is only one way to see a datastore; on any other Host (§1.3) it sees nothing, which is how a second PBS would otherwise be installed beside the real one.
4. Still empty — **nothing serves** — or `shim` → **derive auto**: discover a `tankc` pool — searching **only `backup.json.node`** if set, otherwise **across all nodes**. Found on node `<name>` → `placementState = node` (install PBS there); **not found → `shim`** (the catch-all fallback; lay the marker, warn).

So the `node` **field** is a *discovery constraint* (which Host(s) to search) before resolution and names the Host after it, while `placementState: node` is the *state* that results. A `shim` is re-derived on every update, so it promotes to `node` the moment a `tankc` appears; an empty state is resolved once — by adopting a PBS that already serves the Site (rule 3), or by discovery when none does (rule 4) — and is then concrete.

### 2.3 Shim & promotion

**Reinstallability is a first-class requirement.** A shim must be **promotable in place** — no teardown, no dependent reinstall. Because empty/`shim` states are re-derived on every `update-module.sh backup` (§2.2):

| From `shim` to… | Trigger | Effect of `update.sh` |
|---|---|---|
| **`node`** (local PBS) | a `tankc` now exists (on `node`, or any node if unpinned) | re-derives to `node`; creates the datastore + per-node clients; the shim marker becomes a real datastore |
| **`external`** | operator re-runs install/update **forcing external** + `pbsUrl` | overwrites to `external` (permanent); registers the external PBS as storage + wires jobs; provisions nothing |

**Leaving `external` (#607)** is the one move that is never automatic — the state is sticky
precisely so that an operator's choice is not re-derived away — and it has one deliberate door:

| From `external` to… | Trigger | Effect |
|---|---|---|
| **re-derived** (`node`, or `shim`) | `backup-manager placement reset`, confirmed | clears `placementState` and runs §2.2 from rule 3; the external PBS stays **registered as a `pull` peer**, so the history on it remains restorable (§4.3); clients move to the new `pbsUrl` on the next reconcile. The external datastore itself is never touched |

The **same command that heals node membership (§2.4) also advances backup from `shim` to a real state.** This is the concrete answer to #402's "allow backup to be reinstalled later and ensure existing `dependsOn` modules then work."

### 2.4 Per-node client reconcile (#382)

Installing the per-node `proxmox-backup-client` becomes an **idempotent reconcile**, not a one-shot at PBS-install time:

- The client-install loop is factored into a reusable step that **enumerates the *current* cluster membership** and installs the client on any node missing it.
- **`update-module.sh backup` runs this reconcile**, so the routine update flow heals a cluster whose membership grew. Re-running is a no-op on nodes that already have the client.
- **Node-add triggers the reconcile automatically.** When `site-manager` adds a node, its node-add flow **automatically calls `module-manager modify backup`** (which runs the reconcile above) as the final step — so the new node gets its backup client with **no operator follow-up**. This is a triggered, automatic action, **not** a documented manual step the operator must remember.

### 2.5 Unified credential model

Matching the two movements (§1.5), there are exactly **two** credential shapes, and neither varies with the peer type (local, satellite, external, or local-external):

- **Pull token (read-only)** — held by a *destination* to pull from a *source*. A **read-only** API token (`Datastore.Read`/`Audit`) on the source PBS — `readAuthId` in [`pull.json`](../../src/foundation/backup/scripts/pull/pull.json), prompted at onboarding and **never stored in the JSON**. Used for every buddy/satellite pull relationship.
- **Backup login (write-no-delete)** — held by a *client* to push snapshots to its configured PBS. A `<name>@pbs` login with the **`DatastoreBackup` role scoped to one namespace** (write, no delete); the **PBS owns prune**. Used by every node's backup client against the local PBS, and — unchanged — when the configured PBS is an `external` one. (The same shape backs [`receive.json`](../../src/foundation/backup/scripts/receive/receive.json), for the edge case of receiving a push from a non-TAPPaaS third party into `external/<name>`.)
- **Encryption:** `encryptionRequired: true` — the data-owner's key encrypts on the client before transit; every PBS holding a copy stores ciphertext only and never holds the key. See **key storage & restore** below.
- **No secrets in config:** the JSON carries host/URL/store/namespace/retention/schedule only; API auth-ids and passwords are prompted at onboarding and live in `/etc/secrets` (TAPPaaS convention). The *same* config file is safe whether it points at a buddy, a satellite, a remote, or a local-external PBS.

The one unavoidable variance is the **URL** (tunnel address vs public host vs LAN address, §1.3). The credential mechanics do not change. Note that **no credential ever authorises one PBS to push to another** — inter-PBS movement is pull-only (§1.5).

#### 2.5.1 Encryption key storage & the restore flow

A client-side encryption key is only useful if it **outlives the client that made the backup** — a restore needs the key precisely when the original VM is gone. So the key is **never kept only on the client**:

- **Where it lives.** At onboarding, `backup-manager` generates the client encryption key and **escrows it centrally in `/etc/secrets` on `tappaas-cicd`** (the same store as the other backup secrets), managed by the `identity`/secrets layer — independent of any VM being backed up. Each client is *handed* its key to encrypt with, but the durable copy is central.
- **Normal restore (a VM lost, the cluster/cicd intact).** Provision a fresh VM (or restore host), fetch the escrowed key from `/etc/secrets` on `tappaas-cicd`, and run the PBS restore with it — the ciphertext in the datastore decrypts and the VM comes back. The original client never has to exist for this to work.
- **Full-site DR (the cluster *and* `tappaas-cicd` are lost).** The escrow is inside the very system being rebuilt, so it cannot be the only copy. The encryption key is therefore the **DR linchpin** (ADR-010 §3.2/§7): the operator must hold an **out-of-band copy** — offline/printed, or in the satellite's separate secret store off-site. DR order is: rebuild `tappaas-cicd`, load the out-of-band key back into `/etc/secrets`, then restore from the off-site (pulled) PBS copy using that key.

**Key export / import for the out-of-band copy.** `backup-manager` provides an operator command to **export the encryption key(s) to removable media** — a PC, SD-card, or USB stick — so the operator can create and safekeep the mandatory out-of-band copy (`backup-manager key export <dest>`), and a matching **import** that loads a key back onto a **fresh system** during DR (`backup-manager key import <src>` → `/etc/secrets`). This is exactly the mechanism that makes full-site DR above possible: export once at onboarding, store the media somewhere safe/off-site, and import it into the rebuilt `tappaas-cicd` before restoring from the off-site copy. (Verb names indicative; the point is a first-class export-to-media / import-to-fresh-system path, not a manual file copy.)

**Corollary:** losing the escrowed key with no out-of-band copy makes an encrypted off-site copy unrecoverable — the compromise-isolation guarantee (§1.5.1) cuts both ways, so the out-of-band key copy is mandatory, not optional. This is the one restore that must be tested with *and* without the key (§Testing).

### 2.6 Tooling — `backup-manager`, `backup-controller`, satellite

Backup is split along the standard TAPPaaS **manager/controller** line, so the *same two components* drive backup on the local PBS **and** on a satellite/external PBS:

- **[`backup-manager`](../../src/foundation/tappaas-cicd/manager/backup-manager/)** — *owns config/policy.* Resolves the Site→Environment→Module backup-policy cascade (`resolve`, `status`, and the new `placement` / `peers` verbs) and owns the *desired* state: which modules are backed up, effective retention + schedule (§3.2), residency, placement state (§2.1), off-site peers, subset selectors, and per-peer retention. Read-only over live PBS: it *decides*, then calls the controller.
- **[`backup-controller`](../../src/foundation/tappaas-cicd/controller/backup-controller/)** — *owns runtime PBS state.* Talks to a live PBS (reusing [`pbs-job.sh`](../../src/foundation/backup/lib/pbs-job.sh) / [`pbs-namespace.sh`](../../src/foundation/backup/lib/pbs-namespace.sh)) to create datastores/namespaces, add guests to the managed job, apply schedules, register pull remotes, issue push credentials, trigger verify/prune. It is **PBS-endpoint-agnostic** — the target PBS is a **parameter (`--pbs <host>`), not a hardcode** — so the same ops target the local, satellite, or external PBS; only endpoint + credential differ. It degrades gracefully when PBS is unreachable.

**Division of labour with ADR-010:** `satellite-manager` (ADR-010) provisions the *node* — the VPS, tunnel, PBS install, datastore backend — and stops at "a reachable PBS endpoint (URL) exists." `backup-manager`/`backup-controller` then **control it as just another PBS** via the unified credentials (§2.5). The operator-facing [`backup-manage.sh`](../../src/foundation/backup/scripts/backup-manage.sh) verbs (`add-remote`, `add-external`, `add-push`, `list-sources`, …) are the thin CLI over the same controller ops, so onboarding a peer is the **same command** whether that peer is local, satellite, external, or local-external.

### 2.7 Module-schema changes (`module-fields.json` / `backup.json`)

The changes touch three groups of fields. **Note (implementation, 2026-09-09):** since #567 field definitions live with the service that owns them, so these land in the backup module's own manifests — [`backup/fields.json`](../../src/foundation/backup/fields.json) (shared by both services) and [`services/vm/fields.json`](../../src/foundation/backup/services/vm/fields.json) / [`services/filesystem/fields.json`](../../src/foundation/backup/services/filesystem/fields.json) — **not** in `schemas/module-fields.json`, which now holds only the generic fields.

**A. Backup-module fields** (authored on `backup.json`, `usedBy: ["backup:vm"]`):

| Field | Change | Detail |
|---|---|---|
| `placement` | **remove** | The current `placement` policy field is deleted — its job is now the install-resolved `placementState` (§2.1). A legacy value is read *once* during migration (§4) to seed the state, then dropped. |
| `node` | **repurpose** | Two jobs, in order. *Before* resolution it is a **discovery constraint**: when set, only this host is searched for `tankc`; when unset, all cluster members are. *After* resolution it names the **Host the PBS actually landed on** — which is what `placementState: node` refers to. Since ADR-026 that Host may be a cluster member or a `kind: machine` module; ADR-022c D3 is explicit that the field does not assert cluster membership. |
| `storage` | keep | The `tankc` pool name to find/use (default `tankc1`). |
| `vmname` | **replaced by the instance name** (#612) | Backup is `kind: application` — it owns no VM, so the field names nothing true. What it has been used for is the PBS's **DNS name**, the endpoint every client pushes to: `install.sh` registers `<vmname>.<zone>.internal` (`backup.mgmt.internal`) in OPNsense. That name is the backup **instance's** name — `config/<instance>.json`, ADR-026 D6.1, default `backup` — so no field is needed. It is registered as an **alias of the Host in `node`** (a cluster node or a `debianhost` machine), not as today's A record of an IP captured at install, which goes stale when the PBS moves (§4.3) or the Host's address changes. `pbsUrl` defaults to `<instance>.<zone>.internal`; for `external`, clients use `pbsUrl` and nothing is registered locally. Needs ADR-026 D6.3/D6.4 (instance names) and #665 (machines as modules) first, and an alias verb in `dns-manager`. |
| `placementState` | **change values + ships empty** | The single source of truth (§2.1). Was `local\|shim\|remote-only`; now **empty (released default)** or `^(shim\|external\|node)$`. Install-written, never hand-authored. Migration: legacy `local` → `node` (with `node` set to the host it was found on), `remote-only` → `external`. `node` names a **Host**, which since ADR-026 may be a cluster member or a `kind: machine` module. |
| `pbsUrl` | **new** | The PBS the clients push to (§1.5). **Default `backup.mgmt.internal`** (local PBS DNS); overridden to the external PBS's URL when `placementState: external` (§1.4). Credential prompted-not-stored. |
| `pushTarget` | **deprecate** | Subsumed by `placementState: external` + `pbsUrl` — the external PBS is simply the configured target clients push to. Read for one release, then removed. |
| `pbsStorageName` | keep | PBS datastore / Proxmox storage name. |
| `kind` | **new** (ADR-022f) | `application` in every variant — backup installs PBS onto a Host and owns no system of its own. Not `device`: that is reserved for something where only network reachability is configured. |
| `scope` | **new** (ADR-022e) | `site` — replaces `tier: foundation`. Installed in `mgmt`, serves every Environment. |
| `management` | **new** (ADR-022g) | `managed` when TAPPaaS installs and maintains the PBS; `unmanaged` for an external one, which is registeredmed one, which is registered so the Site knows it exists and has no install/update/test/delete lifecycle. |
| `alwaysBackup` | **deprecate** | See the note below. |

*(`immutableSnapshots` is **not** part of this change — at-rest immutability is deferred to [Future improvements](#future-improvements).)*

**B. The per-module `backup` policy object** (authored on *any* module, the Site→Env→Module cascade leaf) — extend the existing `enabled`/`retention`/`exclude` with:

| Sub-field | Change | Detail |
|---|---|---|
| `schedule` | **new** | The module's own schedule; inherits the Site→Env cascade (default once/day) when absent; **must be ≤ once/day** (§3.2). |
| `filesystemPaths` | **new** | For a `dependsOn: backup:filesystem` module only — the named guest paths to capture (guest-OS-type gated). |

There is **no `type` field** — the backup kind is a `dependsOn` capability (`backup:vm` / `backup:filesystem`, §3.1).

**C. `provides` capabilities** (on `backup.json`):

- Today `["vm", "remote", "external"]`. A repo-wide check shows **only `backup:vm` is ever depended on** — nothing declares `dependsOn: backup:remote` or `backup:external`.
- **Change to `provides: ["vm", "filesystem"]`.** Add **`filesystem`** so a module can `dependsOn: backup:filesystem` (§3.1). Drop `remote`/`external`: those are **runtime peer relationships** registered via `backup-manage.sh` (§1.5/§2.6), not dependency capabilities — and dropping `external` also removes the clash with `placementState: external`. All states (`node`/`shim`/`external`) still provide both, which is what lets a **shim satisfy `dependsOn: backup:vm`/`backup:filesystem`** (§1.1).

**What happens to the service directories (#608).** `provides` and `services/` stop being a 1:1 mirror, deliberately, so this states the disposition of each:

| Directory | Disposition | Why |
|---|---|---|
| `services/vm/` | **kept** — implements `backup:vm` | a capability a module depends on |
| `services/filesystem/` | **new** — implements `backup:filesystem` | a capability a module depends on |
| `services/remote/` | **moved + renamed** → `scripts/pull/` | not a service: nothing declares it and module-manager never invokes it. It is the operator's pull onboarding |
| `services/external/` | **moved + renamed** → `scripts/receive/` | likewise, for a system that pushes its backups into ours |
| `services/push/` | **retired** | it sent this cluster's vzdump backups to a remote PBS — the case `placementState: external` + `pbsUrl` now owns (§1.4). Keeping both was why "external" meant two opposite things |
| *(new)* `scripts/remote/` | **added** | the symmetric half of `pull`: granting a peer read-only access so they can pull **our** backups (§1.5) |

Dropping the three names from `provides` is exactly the intent: a **module** can no longer declare `dependsOn: backup:remote` (nothing ever did), while an **operator** can still onboard the peer.

Leaving them under `services/` was the deeper problem, and #608 is the symptom: in this codebase `services/<name>/install-service.sh` means precisely "a provider coordinate module-manager invokes for a consuming module", and these were never that. They moved to **`backup/scripts/<kind>/{onboard,offboard,refresh}.sh`**, beside the module's other helper scripts, so `services/` maps 1:1 to `provides` again. The operator surface is **`backup-manager peer add|delete <kind> <name>`** (§1.4, §2.6), which writes `config/<kind>-<n>.json` and then runs the onboarding script — the manager owning config, the script owning the live PBS work and the credential prompt.

Deprecating `pushTarget` (§2.7A) is what retired `services/push/` with it: both described the same superseded mechanism.

Deprecating `pushTarget` (§2.7A) does **not** affect `services/push/`, which never read it — it reads `.makeDefault` in its own `push-<n>.json`. `pushTarget` was only a pointer on `backup.json` naming a default push target, superseded by `placementState: external` + `pbsUrl`.

**Schema hygiene (KI-1).** Land the `provides`-aware normalizer fix (implementation-doc KI-1) with these edits — otherwise the `backup:vm` self-capability fields (`placementState`, `pbsUrl`, `pbsStorageName`, …) keep tripping the false "orphan field" warnings.

**Note — why `alwaysBackup` exists, and retiring it.** It was introduced as a **bootstrap-ordering workaround**: PBS-job membership is driven by `dependsOn: backup:vm`, but the foundation VMs that come up *before* the backup server — `network`/`firewall`, `tappaas-cicd` — cannot declare that dependency (they precede backup; it would be a cycle / wrong order). `alwaysBackup` force-adds them to the job. It is genuinely needed **only under the current "membership = `dependsOn`" design.**

**Backup must stay opt-in — not become default-on.** Some modules deliberately want *no* backup (hardware modules, test/scratch modules), so membership must remain an explicit relationship, not blanket coverage. The fix is therefore **not** an opt-out policy; it is to **retire `alwaysBackup` when #501 lands the `integratesWith` relationship** (which complements `dependsOn`). A module that wants backup but *cannot* `dependsOn: backup:vm` — the foundation VMs that bootstrap before the backup server — instead declares **`integratesWith: backup`**, an integration relationship that adds it to the PBS job **without** imposing `dependsOn`'s install-ordering / hard-dependency. That covers exactly the VMs the `alwaysBackup` list exists for; modules that want no backup declare neither. **Retire `alwaysBackup` as part of #501.**

**Discovery & the foundation gap (#544, #545) — both resolved (v0.6).** Two issues fell out of this design and were resolved with it.

**#544 — module discovery is shape-based, not a deny-list.** `backup-manager`'s target discovery scanned `config/*.json` behind a stale deny-list, so every non-module file nobody had thought to add (`last-update-result.json`, `zones.effective.json`, `module-fields.json`, …) was reported as a backup target — and the `backup-status` health gate then failed on files that were never modules. The rule now lives once, in [`lib/ts/src/module-discovery.ts`](../../src/foundation/tappaas-cicd/lib/ts/src/module-discovery.ts), imported by **both** `module-manager` and `backup-manager` so the two cannot drift apart again: a config is a module if it carries `kind: "module"` or a module-shaped field (`dependsOn` / `integratesWith` / `provides` / `location`) — never because a name is absent from a list. A deny-list was the wrong shape for this because it fails *open* and silently.

Narrowing to the opted-in set (`backup:vm | backup:filesystem`) is a **second, separate** step (`listBackupModules`), used by `reconcile`. `list` deliberately reports every module and answers opt-in and job membership as two fields (#627): "never asked for backup" and "asked and did not get it" are different states, and only the second is a finding.

**#545 — what the foundation modules back up (D20).** Backup is opt-in (above), so each of the four foundation modules states a case rather than inheriting coverage:

| Module | Declares | Why |
|---|---|---|
| `network` (the firewall) | `integratesWith: ["backup:vm"]` | a real guest holding routing / DNS / DHCP / firewall / proxy state. It installs *before* the backup server, which is exactly why the relationship is `integratesWith` and not `dependsOn` |
| `tappaas-cicd` (the mothership) | `integratesWith: ["backup:vm", "backup:filesystem"]` + `backup.filesystemPaths = ["/home/tappaas/config", "/etc/secrets"]` | **both shapes, deliberately** — see below |
| `cluster` | neither | provider-only: it configures Proxmox itself and owns no guest. A lost node is recovered *as a node* (RESTORE.md §3), and the module is reinstalled |
| `templates` | neither | the templates are **derived** — built from a published image plus declared config. Backing them up would store what the build already reproduces, and restoring an old one hands every future module install a stale base |

The mothership carries two backup shapes on purpose. The **VM snapshot restores the machine**; the **`backup:filesystem` capture restores `config/` in seconds into a *running* system, and onto a *different* mothership** — which is the case that actually matters, because full-site DR needs `config/` back before there is a VM to restore it into. `/etc/secrets` is captured alongside `config/` so a rebuilt mothership recovers its secrets and not merely its declarations.

Two limits are stated rather than implied. **(a)** `~/.opnsense-credentials.txt` and `~/.pbs-credentials.txt` sit in `/home/tappaas/` and are **not** captured — a `.pxar` archive must be a directory, so single files cannot simply be listed in `filesystemPaths`; both are recoverable by reissuing the credential ([RESTORE.md §5.3](../../src/foundation/backup/RESTORE.md)). **(b)** The `fs/` namespace is **not** reachable through a `remote` peer grant, because §1.4 makes that grant non-propagating precisely so a buddy never reads this site's `config/` and secrets. Off-site, therefore, `config/` comes back inside the mothership's VM snapshot rather than as the small archive.

**The recovery path is written and was rehearsed** — the half of #545 that mattered, since a backup with no rehearsed restore is not a backup. [backup/RESTORE.md](../../src/foundation/backup/RESTORE.md) states per module what is *restored* versus *rebuilt*, and covers restoring `config/`, the mothership by both paths (including the DR ordering — key import **before** any restore that must decrypt), the firewall, `cluster`/`templates`/`backup` having nothing to restore, and how to verify coverage without waiting for a disaster. Every procedure in it was run against the reference cluster (2026-09-09): `config/` restored to a scratch directory and `diff -r`-clean over 85 files, and **refused without the key**; the firewall and the mothership each restored to a spare VMID *beside* the running original, verified, and destroyed. The rehearsal is what surfaced the two fatal `restore.sh` defects no offline test could reach — including a restore that created no VM at all while printing "Restore completed successfully!".

**Rehearsed again on the test system (hrossen, 2026-09-18)**, which is G1.5's exit gate and not a repeat of the same run: the live `fs/tappaas-cicd` namespace holds nine nightly snapshots, the latest restored **173 of 173 files** with no file missing or extra and every differing line a `updateTime` stamp or `last-update-result.json` — both written by the 02:00 sweep that ran *after* the 20:32 capture — and the same restore **refused without the key** (`missing key - manifest was created with key …`, nothing extracted). `backup-manager list` confirms the D20 table is what is actually deployed: `network` and `tappaas-cicd` opted in and in the daily job, `cluster` and `templates` in neither. This rehearsal found a **third defect, in the runbook rather than the code**: `/etc/secrets` could not be restored by following [RESTORE.md](../../src/foundation/backup/RESTORE.md), because no command for it was given and the obvious adaptation of the `config/` one fails partway on file ownership. Restoring that archive needs root; §5.1 now says so and the corrected command was verified to produce a tree identical to the live `/etc/secrets`.

---

## 3. Configuring clients & backups

This section is the **client side**: what each module backs up, and how the schedule is expressed. A module declares the *kind* of backup it needs — and opts in at all — through a **`dependsOn`** relationship on a backup capability, **not** a `type` field.

### 3.1 Backup types are capabilities you `dependsOn`

The `backup` module `provides` one capability per supported backup type (§2.7); a module picks its kind by depending on the matching capability. **Two are supported:**

| Capability | Declared as | What is captured | Restore target | Where supported |
|---|---|---|---|---|
| **`backup:vm`** (full VM / LXC) | `dependsOn: ["backup:vm"]` | the whole VM or LXC — a PBS snapshot of the guest | same or a new VM/LXC | any Proxmox guest |
| **`backup:filesystem`** (subset inside a guest) | `dependsOn: ["backup:filesystem"]` | a **named subset** of the guest filesystem | into a running guest | **only known/supported guest OS types** (guest agent + a known layout) |

- **`backup:vm`** is the default, safest general case — a full-guest snapshot.
- **`backup:filesystem`** narrows to a known subset of files; the paths come from the module's `backup.filesystemPaths` (§2.7), and it's only offered where TAPPaaS knows the guest OS layout well enough to select and restore reliably.
- A module that wants **no** backup (hardware modules, test/scratch modules) simply depends on **neither** — backup stays opt-in (§2.7, #501).
- Two further types — **`userdata`** (portable open-format export) and **`dataset`** (Proxmox / external-NFS dataset) — are on the roadmap but **not yet specified**; see [Future improvements](#future-improvements).

### 3.2 How a backup is specified — the schedule cascade

Backup frequency resolves through the **Site → Environment → Module cascade** (owned by `backup-manager`, §2.6):

- The **Site** sets a **default** frequency. Out of the box that default is **once per day** (nightly), but a site may change it — e.g. a site whose default is **once per week**.
- A module that specifies **nothing** inherits the site default. So if the site default is weekly, *every* module is weekly unless it says otherwise.
- A module **may declare its own schedule** — typically **less** frequent than the site default for a module whose state rarely changes (e.g. an office suite: `once per week` or even `once per month`).
- **Hard ceiling: never more than once per day.** A module cannot request a sub-daily schedule. Once-a-day is the maximum frequency the platform backs anything up.

The common case is therefore: **most modules inherit the site default (once/day); a few rarely-changing modules pin a longer interval.**

### 3.3 Subset + independent off-site retention (#389)

The off-site copy need not mirror the local set 1:1:

- **Subset:** the off-site pull job selects a **subset** of the source backups/namespaces to replicate — e.g. only critical VMs off-site, everything locally. Expressed as a selector in the remote/push job config (PBS group-filter today).
- **Independent retention:** the off-site copy runs its **own retention policy**, distinct from the local one it derives from — typically *longer* off-site (DR archive). Because retention is **owned by the destination** (§1.5), the two policies are independent and the compromise invariant is preserved.

---

## 4. Migrating an existing backup setup

A deployment rarely starts empty. There are four starting points to migrate from, and **none should lose backup history**. Migration reuses the mechanisms already decided above (state re-resolution §2.1–2.3, buddy pull §1.4) — it introduces no new machinery.

### 4.1 Upgrading an existing TAPPaaS backup (hardcoded → placement state)

Pre-ADR-012 installs pin `node:tappaas3` / `storage:tankc1` and carry `placementState:local` (or empty on the oldest installs). `update-module.sh backup` **backfills the state in place, never a promotion-reinstall**:

- `placementState:local` (or empty) → `node`, with `backup.json.node` naming the Host currently running the PBS (§2.2 rule 3) — **the datastore is left exactly where it is**, no move, no dependent reinstall. It never resolves onto a Host that is not already serving PBS (#602).
- `placementState:remote-only` → `external`, synthesising `pbsUrl` from the old push-target config.
- The deprecated `pushTarget` / `alwaysBackup` fields are **read for one release**, honoured, then dropped on write-back once their behaviour is covered by `pbsUrl` / the opt-out `backup` policy (§2.7).

### 4.2 Adopting a pre-existing local or external PBS (#456)

A site already runs a PBS — on the LAN (#456) or off-site — provisioned outside TAPPaaS:

- Force `external` at install (with `pbsUrl`) and run `update-module.sh backup` (or install). The module **registers it as Proxmox storage**, rolls out per-node clients (§2.4), and starts the managed job — **without creating a datastore or touching the PBS's existing contents**.
- **Existing snapshots stay readable and restorable** (same datastore); new TAPPaaS backups land alongside them in the configured namespace. Nothing is migrated or rewritten.

### 4.3 Relocating the datastore while preserving history

When the PBS itself moves (old node → a new `tankc`, or external → a new local PBS), the old snapshots must not be discarded:

- Seed the new datastore by **pulling** from the old PBS as a temporary pull source (`add-remote` → sync → verify, §1.4), then cut the clients' configured target over to the new PBS.
- Decommission the old datastore only once the pull **and a test restore** are green. This is pure §1.4 pull — no special migration path.

### 4.4 Coming from a non-PBS / third-party backup

- Stand up the ADR-012 backup in any topology, run backups **forward**, and retire the old system once coverage **and a test restore** are confirmed.
- Historic third-party archives are **out of scope** (not PBS-format): keep them read-only on the side until their retention lapses; do not attempt to import them into PBS.

### 4.5 Migration implementation plan

1. **State backfill** — `update.sh` maps legacy `placementState`/`placement` values to the new states (§4.1); idempotent; covered by a unit test with legacy fixtures.
2. **`#456` adoption path** — install-forced `external` + `pbsUrl` registers an existing PBS as storage without provisioning; verify existing snapshots remain restorable (§4.2).
3. **Relocation runbook** — document + script the pull-seed → cut-over → decommission flow (§4.3) in [`backup/RESTORE.md`](../../src/foundation/backup/RESTORE.md); gate decommission on a test restore.
4. **Deprecation window** — `pushTarget`/`alwaysBackup` read-then-drop; emit a one-line deprecation notice on update; remove the fields and the `alwaysBackup` code path once `integratesWith` (#501) covers the foundation VMs (§2.7).
5. **Migration tests** — legacy-fixture upgrade, #456 adoption preserving snapshots, and relocation-by-pull preserving history (see §Testing).
6. **The ADR-022 vocabulary is a numbered migration** (added v0.7). Deployed
   configs carry `placementState: external`, `tier: foundation` and no `kind`,
   `scope` or `management`; this ADR now specifies `scope: site` and
   the two new fields. That is a change to the *shape* of `config/`, so under
   ADR-025 D7 it ships as a `migrations/NNNN-*.sh` with a before→after fixture
   test, not as a hand edit — and it cannot merge to `main` until the migration
   runner is on `stable`, which it now is. Until that migration exists, the code
   still writes `external` and this ADR is ahead of it.

---

## Future improvements

Deliberately **deferred** — kept on the roadmap but **not specified or decided** by this ADR. Each needs its own design pass (and likely its own issue) before implementation; none of them is required for the compromise-isolation guarantee (§1.5.1).

### F.1 Datastore at-rest immutability (`immutableSnapshots`)

An opt-in WORM-ish tier that freezes backup *history* against tampering through a datastore's **own admin plane** — a threat the structural pull + write-no-delete model (§1.5.1) does **not** cover (it protects the off-site copy from a *source* compromise, not a datastore from its own root). Two tiers:

- **ZFS snapshots** (in-cluster): a systemd timer on the PBS node takes periodic **read-only ZFS snapshots** of the datastore's dataset, pruned to `keep`. Survives credential-holder tampering and PBS prune/GC — **but not node-local root** (`zfs destroy`). The weaker tier.
- **S3 Object Lock / WORM** (satellite-side, ADR-010 §7.3): enforced by the object store independent of any host root — even node/PBS root cannot rewrite the past. The stronger tier; out of the backup module's scope.

Proposed (deferred) shape: a `backup.json` field `immutableSnapshots { enabled, schedule, keep }` driving the ZFS tier. Deferring it does not weaken §1.4.

### F.2 `userdata` backup — portable application-data export

An application-level export of a module's **user data** to a **named file** on the backup system, in an **open format** (e.g. a zip of the app's data), restorable **onto a different system** — the escape hatch from PBS-native lock-in for the data that matters most. **Underspecified:** the exporter/importer contract, file naming/placement, scheduling (likely module-defined, since only the module knows when its data is consistent — still ≤ once/day), and whether it rides the PBS job or is a side artifact. Kept because it is a real requirement; deferred because it is not yet designed. Would be exposed as a `backup:userdata` capability (§3.1).

### F.3 `dataset` backup — Proxmox / external-NFS datasets

Backing up a Proxmox storage **dataset** — e.g. external NFS-served data that is **not** inside a TAPPaaS-managed guest. **Underspecified:** how the dataset is selected, whether it rides the PBS job or a separate mechanism, retention, and restore. Kept for the external-NFS case; deferred pending design. Would be exposed as a `backup:dataset` capability (§3.1).

---

## Consequences

### Positive

- **Backup installs on any topology** — three-node, two-node, single-node, no-suitable-storage, or a site that already runs PBS (#456) — without failing the dependency graph.
- **`dependsOn: backup` never blocks an install** even when no datastore is realised; the shim (§1.1) keeps the graph satisfiable and promotes later in place (§2.3).
- **Adding a node no longer silently breaks its VMs' backups** — the client reconcile (§2.4) heals membership drift on the normal update cadence.
- **Off-site backup works for small sites** (single-node push, §1.3/§1.4), not just clusters big enough to host PBS.
- **The compromise invariant is explicit and testable** — off-site is pull-only, clients push with write-no-delete credentials, retention is owned by each PBS (§1.5).
- **One model, every topology** — any PBS (local on a node, local on a machine, satellite, external) is a symmetric peer with **identical credential setup** (§1.4/§2.5), consumed by URL, and driven by the same `backup-manager`/`backup-controller` (§2.6).
- **Modules declare *what* to back up** — the `dependsOn: backup:vm` / `backup:filesystem` capabilities (§3.1) let a module pick its backup kind (or opt out entirely), and the schedule cascade (§3.2) gives sensible defaults with per-module override.
- **Reuse over invention** — leans on the existing #227 namespace/pull/push machinery, ADR-010's satellite, and PBS roles rather than new mechanisms.

### Negative / costs

- **More placement states to reason about** (`node` / `shim` / `external`) and to test.
- **Shim → real-PBS promotion** is a new lifecycle transition that must be idempotent and dependency-safe.
- **The single-node `external` case hands a client a credential to a PBS we do not own** that must be provably delete-incapable (write-no-delete, PBS-owned prune); getting that scope wrong would silently break the invariant, so it needs adversarial testing (§Testing).
- **Two backup-target wirings** — clients pushing to a *local* PBS vs directly to an *external* PBS — are two code/test paths, on top of the buddy pull path.

### Neutral / assumptions

- Assumes PBS namespace + role model (#227) and ADR-010's satellite remain the substrate.
- Single-node `external` assumes a reachable remote PBS/satellite that accepts the node's backup client and owns its own prune.
- Client-side encryption keys remain the operator's DR linchpin (ADR-010 §3.2/§7) — unchanged and out of scope here.
- The workload-placement taxonomy is **not** a decision of this ADR: it graduated into [ADR-022d](<ADR-022d - Workload Classification.md>), and [Appendix A](#appendix-a--workload-placement-taxonomy-graduated--adr-022d) points there. Two of ADR-022d's draft decisions (`kind`'s meaning, and `shim` as a state) touch what this ADR implemented, and are listed there as open.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Skip `backup` entirely when no `tankc`** | Breaks every module that `dependsOn: backup` — the shim (§1.1) keeps the graph satisfiable instead. |
| **Fail install if `tappaas3`/`tankc1` absent** | Excludes single-node and non-reference topologies that Release 1.2 must support. |
| **Re-enumerate nodes only at PBS reinstall** | Still misses nodes added between reinstalls; §2.4 makes it part of the routine `update.sh` reconcile. |
| **Give a client full read-write-delete on its PBS** | Violates the #389 invariant — a compromised node would delete its own backups. Clients always get write-no-delete; the PBS owns prune (§1.5). |
| **Only support a local PBS + buddy pull for off-site** | Leaves single-node / no-local-PBS sites with no off-site option; letting clients push directly to an `external` PBS (§1.3) fills that gap safely. |
| **A PBS→PBS "append-only push" mechanism** | Unneeded — every inter-PBS copy is a pull, so there is no source→destination write path to harden. The only push is client→PBS, made safe by write-no-delete creds (§1.5.1). |
| **Satellite as a pull-only target** | Too narrow — a satellite PBS is just another PBS and can also be an `external`-state site's *direct backup target* (its clients push to it), not only a puller of the home PBS (§1.5). |
| **Separate credential flow per peer type** | Triples the surface for no benefit — PBS tokens/roles are identical; one unified flow (§2.5) is simpler and less error-prone. |
| **Require migration onto module-provisioned PBS (reject #456)** | Forces a site with a working PBS to tear it down; consuming it by URL (§1.3) adopts what exists instead. |
| **Only `vm` backups (one capability)** | `backup:filesystem` covers the file-subset case now, and `userdata`/`dataset` are on the roadmap ([Future improvements](#future-improvements)); a single capability would lose all of these. The `dependsOn` capabilities (§3.1) let a module declare the right kind or none. |

## Implementation Plan (phased)

1. **Placement resolution + shim (#402)** — resolve `placementState` from the `external` force / `node` discovery-constraint inputs in `backup.json`; make `install.sh` discover `tankc` (only the pinned `node` if set, else any node), install PBS on the node where found (→ `node`, with `node` set to where it landed), or lay down a flagged shim with a warning (→ `shim`); record the resolved state idempotently.
2. **Shim promotion (#402)** — `update-module.sh backup` promotes a shim to real PBS once storage appears, preserving `dependsOn: backup` consumers.
3. **Client reconcile (#382)** — factor the per-node client install into an idempotent step keyed on current cluster membership; wire into `update.sh`; reference from node-join.
4. **External-target / no-local-PBS path (#402, #389)** — clients push to an `external` PBS with a **write-no-delete** credential; remote-owned prune; single-node `external` wiring.
5. **Subset + independent retention (#389)** — add the off-site pull subset selector + independent destination-owned retention. *(At-rest immutability deferred — [Future improvements](#future-improvements).)*
6. **Symmetry + unified credentials (§1.4/§2.5)** — confirm any PBS can be both a pull source (others pull from it) and a pull destination (it pulls others) on one datastore (namespace-partitioned), plus a client-backup target; consolidate the two credential shapes (read-only pull token / write-no-delete backup login) as the single path for every peer type.
7. **Tooling (§2.6)** — extend `backup-manager` with placement (state + resolution), off-site peers, subset and per-peer retention in the cascade; make `backup-controller` **PBS-endpoint-agnostic**; keep `backup-manage.sh` as the thin operator CLI.
8. **Bootstrap & promotion (§2.3)** — wire placement resolution into `install.sh`; make `update-module.sh backup` promote a shim to `node` / `external` / node+satellite without dependent reinstall.
9. **Hardening (#389)** — the compromise-isolation test suite.
10. **Consume a pre-existing PBS (#456)** — add the install-forced `external` placement state (URL via `pbsUrl`: satellite / external / local-external); register consumed storage + jobs + client rollout without discovering storage or installing PBS. *(new — v0.3)*
11. **Backup-type capabilities + schedule cascade (§3)** — add **`backup:filesystem`** to the module's `provides`; wire `dependsOn: backup:vm` / `backup:filesystem` to PBS-job membership + the filesystem path capture; implement the Site→Env→Module schedule cascade (default once/day, module override ≤ once/day). `userdata`/`dataset` deferred ([Future improvements](#future-improvements)). *(new — v0.3)*
12. **Module-schema changes (§2.7)** — **remove the `placement` field**; make `placementState` ship empty with the new value set; add `pbsUrl` (default `backup.mgmt.internal`), `backup.schedule`/`filesystemPaths`; **set `provides` to `["vm", "filesystem"]`**; deprecate `pushTarget`/`alwaysBackup`; land the KI-1 `provides`-aware normalizer fix. *(new — v0.3)*
13. **Retire `alwaysBackup` via `integratesWith` (§2.7, depends on #501)** — once #501 adds `integratesWith`, the foundation VMs that can't `dependsOn: backup:vm` join the PBS job by declaring `integratesWith: backup`; remove the `alwaysBackup` list + code path. Backup stays opt-in (hardware/test modules declare neither). *(new — v0.3)*
14. **Migration (§4)** — legacy `placementState` backfill; `#456` adoption preserving snapshots; datastore relocation-by-pull; `pushTarget`/`alwaysBackup` deprecation window. *(new — v0.3)*
15. **Documentation (all changes)** — update `backup/README.md`, `RESTORE.md`, `TEST.md`; the module-authoring guide ([`apps/00-Template`](../../src/apps/00-Template/)) for the backup `dependsOn` capabilities + `backup.schedule` + placement states; the migration + key export/import runbooks; and this ADR + its [implementation tracker](../design/ADR-012-implementation.md). *(new — v0.3)*

## Testing Strategy

- **No second PBS (#602):** an empty `placementState` on a site whose PBS already runs — on a cluster node and on a non-PVE machine (§1.3) — adopts it; nothing is provisioned, even where a `tankc` pool exists elsewhere.
- **Off-site separation (#609):** a copy declared off-site whose `location` equals the Site's, or is missing, is flagged.
- **Leaving `external` (#607):** `placement reset` re-derives; the old external PBS is listed as a `pull` peer and a restore from it still works.
- **Placement:** with `tankc` → PBS on the right node; no `tankc` → a **shim** (no VM), a warning, and a `dependsOn: backup` module still installs; adding `tankc` + re-running `update.sh` **promotes** the shim and the dependent module still works.
- **Consume pre-existing PBS (#456):** install-forced `external` + a `pbsUrl` → the module registers storage + jobs and rolls out clients **without** discovering storage or installing PBS; a `dependsOn: backup` module backs up to the consumed datastore.
- **Client reconcile (#382):** add a node after backup is installed; `update-module.sh backup` installs the client on the new node only; re-running is a no-op.
- **Off-site subset/retention (#389):** an off-site job replicates only the selected subset and applies a **different** (longer) retention than local.
- **Compromise isolation (the headline #389 tests):**
  - **Pull:** with the remote's read-only token, deleting/pruning the *local* datastore is denied.
  - **Push:** the local push credential can add a snapshot but **cannot delete or prune** the remote namespace; a delete attempt is refused.
  - A **simulated local-cluster compromise** cannot erase, encrypt, or rewrite the off-site history.
- **Restore:** a restore **from the off-site copy** to a clean PBS succeeds *with* the encryption key and fails *without* it.
- **Single-node (#389):** an `external` single node's clients back up directly to a remote/satellite and restore from it.
- **Symmetry (§1.5):** a satellite PBS simultaneously *pulls* the home PBS and *receives the direct client backups* of a single-node `external` site, in separate namespaces, on one datastore.
- **Unified credentials (§2.5):** onboarding a pull source and a client-backup target uses the *same* flow (prompt-not-store read-only token / scoped write-no-delete DatastoreBackup) whether the peer is local, satellite, external, or local-external.
- **Tooling (§2.6):** `backup-controller` performs the same operation against the local PBS and a satellite/external PBS with only endpoint/credential differing.
- **Backup-type capabilities (§3.1):** a `dependsOn: backup:vm` module gets a full-guest backup+restore; a `dependsOn: backup:filesystem` module (supported guest OS) gets its named path subset backed up + restored; a module depending on **neither** is not in the PBS job.
- **Schedule cascade (§3.2):** a module with no schedule inherits the site default; changing the site default to weekly makes unspecified modules weekly; a module override to weekly/monthly holds; a sub-daily request is **rejected** (once/day ceiling).
- **Bootstrap/promotion (§2.3):** `shim → external` and `shim → node` (and `→ node+satellite`) via a config change + `update.sh` re-resolving `placementState`; dependents keep working throughout.
- **Schema (§2.7):** a `backup.json` with the new fields + `provides:["vm"]` validates; a shim still `provides: backup:vm`; the `provides`-aware normalizer emits no false orphan warnings (KI-1).
- **`alwaysBackup` retirement (§2.7 / #501):** foundation VMs join the PBS job via `integratesWith: backup` with **no** `alwaysBackup` list; a module declaring neither `dependsOn` nor `integratesWith` backup (hardware/test) is excluded.
- **Migration (§4):** a legacy fixture (`placementState:local`, `pushTarget`, `alwaysBackup`) upgrades to `node` with the datastore untouched; a `#456` `consumed` adoption leaves the pre-existing snapshots restorable; a relocation-by-pull preserves history and only decommissions the old datastore after a test restore.

## Acceptance

Two lists (#605). ADR-013: **Accepted** means the *decision* is agreed; whether the code exists and has
run on hardware is a separate question, and one list answering both could never complete.

### Decision — accepted 2026-09-18 (v1.0)

- [x] Four supported topologies (§1): shim, local PBS on a cluster node, **local PBS on a machine that is not a cluster member** (§1.3, #600), external; off-site copies by client push and buddy pull (§1.5).
- [x] Placement is a resolved state `node | shim | external` (§2.1); **an empty state never provisions over a running PBS** (§2.2, #602).
- [x] `external` is sticky, with **one deliberate exit**, `backup-manager placement reset` (§2.3, #607).
- [x] Every off-site target **records its Location** (§1.5, #609).
- [x] Module-schema changes (§2.7), including `vmname` replaced by the instance name as the PBS's DNS alias; `shim` stays (#612).
- [x] Credential model (§2.5), tooling (§2.6), backup types (§3.1), schedule cascade (§3.2), migration (§4).

### Implementation — tracked in #407 and [ADR-012-implementation.md](../design/ADR-012-implementation.md)

**Added by v1.0, not built yet:**

- [ ] §2.2 rule 3 in `install.sh` and `update.sh`: probe for a serving PBS before any discovery (#602).
- [ ] `backup-manager placement reset` (#607).
- [ ] `location` on the satellite and on peer PBS configs, and the separation check (#609).
- [ ] `vmname` replaced by the instance name; `<instance>.<zone>.internal` registered as an alias of the `node` Host (#612) — after ADR-026 D6.3/D6.4 and #665.
- [ ] The code writes `placementState: node` with the Host in `backup.json.node`, as §2.1 decides, instead of today's `node:<name>`; a migration rewrites existing sites (#600).

**Built and verified:**

- [x] `install.sh` resolves placement — discovers `tankc` and installs PBS on the node, else lays down a flagged shim (with warning). *(#402)* — **live-verified on tappaas1** *(implemented as the `auto`/`node:`/`shim`/`remote-only` policy enum; the v0.3 rename to `placementState` states `node`/`shim`/`external` is not yet in code)*
- [x] Shim → real-PBS **promotion** via `update-module.sh backup` works and preserves `dependsOn: backup` consumers. *(#402)* — **live-verified**
- [x] Per-node client install is an **idempotent reconcile** owned by `update.sh`; a node added later gets its client. *(#382)* — **live-verified (single node)**
- [x] **External / no-local-PBS** off-site path implemented with a **write-no-delete** client credential and remote-owned retention. *(#402, #389)* — offline; live push pending 3-node *(coded as `remote-only`)*
- [x] Off-site **subset** selection + **independent retention** work. *(#389)* — implemented; live pending 3-node
- [x] Any PBS (local, satellite, remote) works as **both** a pull source and a pull destination, and as a client-backup target; peer onboarding is the **same** credential flow regardless of peer type. *(§1.4/§2.5)*
- [x] **PBS-endpoint-agnostic** tooling — the TS `backup-manager` (+ `--pbs`) drives the same ops at local or satellite PBS; `backup-controller` honors `--pbs`. *(§2.6)* — **built + verified on cicd**; satellite targeting pending cluster
- [x] A `shim` promotes to **`node` (local)**, **`external`**, or **node + satellite** via a config change + `update-module.sh backup`, dependents intact. *(§2.3, #402)* — **live-verified (shim→local)** *(coded as `auto`/`remote-only`)*
- [x] **Drop the `placement` field; `placementState` ships empty and is install-resolved; merge `remote-only` → `external`** per v0.3 §2.1. — **live-verified**: the reference cluster migrated `local` → `node:tappaas3` with the datastore untouched and the backup job byte-identical.
- [x] **Consume a pre-existing PBS (#456)** — `backup-manage.sh use-external <url>` (or the install-time field override). **Live-verified**: consumed the site's PBS by URL under a throwaway storage name, 165 pre-existing backups visible and restorable, nothing created or modified.
- [x] **Backup-type capabilities (§3.1)** — `backup:filesystem` added and **live-proven**: the mothership's `config/` captured, restored byte-identically (85 files), refused without the key, and its capture credential unable to delete its own history. Opt-out (neither relationship) is asserted.
- [x] **Schedule cascade (§3.2)** — resolved Site→Env→Module with the once/day ceiling **rejected by name**, realised as one cluster job per distinct frequency. **Live-verified**: weekly and monthly bucket jobs created, moved between and torn down with the production daily job untouched.
- [x] **Module-schema changes (§2.7)** — landed in the module's own field manifests (`backup/fields.json` + `services/*/fields.json`), **not** `schemas/module-fields.json`: since #567 that file holds only the generic fields. `provides` = `["vm", "filesystem"]`; `pushTarget`/`alwaysBackup` deprecated. KI-1 was already fixed upstream — verified; its `integratesWith` sibling (#501) was found and fixed here.
- [x] **`alwaysBackup` retired (via #501 `integratesWith`)** — the list is gone from the release; membership is the `dependsOn` ∪ `integratesWith` union. Retiring it **uncovered a live gap**: a stale entry silently truncated the list under `set -e`, so `tappaas-cicd` had never been in the backup job at all. It is now.
- [x] **Shape-based module discovery (#544)** — the deny-list is gone; `module-manager` and `backup-manager` import one shared rule, so a state file in `config/` can no longer be reported as a backup target. **Live-verified**: `backup-manager list` returns the 12 real modules with no `ENVIRONMENT = "-"` phantoms, and the `backup-status` health gate is green on a cluster whose backups are fine.
- [x] **Foundation coverage + rehearsed recovery (#545, D20)** — `network` and `tappaas-cicd` join the job via `integratesWith`; `config/` + `/etc/secrets` are captured as `backup:filesystem`; `cluster` and `templates` are **deliberately uncovered**. All three recovery paths **rehearsed live** (2026-09-09) and written up in [backup/RESTORE.md](../../src/foundation/backup/RESTORE.md) — `config/` restored `diff`-clean and refused without the key, firewall and mothership each restored beside the running original and destroyed. The rehearsal found and fixed **two fatal `restore.sh` defects**. *Stated limits:* the two credential files of §2.7, and `fs/` has no off-site grant by design.
- [x] **Migration (§4)** — state backfill live-verified (no datastore move, no dependent reinstall) and unit-tested against legacy fixtures; #456 adoption live-verified to preserve snapshots. Relocation-by-pull is documented as a runbook; it needs two datastores to exercise and is **not yet rehearsed**.
- [x] **Documentation updated (§Impl 15)** — `README.md`, `QUICKREF.md` (ADR-012 section rewritten to the v0.3 model), `TEST.md`, the `00-Template` authoring guide ("Getting your module backed up"), and a new [backup/RESTORE.md](../../src/foundation/backup/RESTORE.md) covering a module rollback, a module restored onto a fresh system, a lost node, and the special cases (`network`, `tappaas-cicd`, `cluster`/`templates`). *(QUICKREF.md was retired into README.md + RESTORE.md.)*
- [x] **Compromise-isolation tests pass** — local compromise cannot delete/encrypt/rewrite the off-site copy. *(#389)* — **live-proven** by [`backup/test-compromise-isolation.sh`](../../src/foundation/backup/test-compromise-isolation.sh) (12/12): a destination pulls a **subset** with a read-only credential; that credential's attempts to **delete and to prune the source are both refused** and the source snapshot survives; the destination owns its own retention. A client's write-no-delete credential is separately proven unable to erase its own history. *Not covered:* a genuinely separate PBS **host** — the suite pulls between two datastores on one server, so it exercises credential scoping, the sync path and the subset filter, but not network isolation or a satellite over a tunnel.
- [x] Restore proven **with** the key and refused **without** it — live, on the mothership's `config/` capture (`missing key - manifest was created with key …`). The key's out-of-band export/import round trip is proven too. Doing this *from an off-site copy* still awaits a second PBS.
- [x] `QUICKREF.md` / `TEST.md` updated (v0.2 baseline). Status advanced **Draft → Proposed** (operator sign-off 2026-09-02; pending cluster live tests).

---

## Appendix A — Workload placement taxonomy (graduated → ADR-022d)

> **This taxonomy has left.** It was carried here as a companion reference
> "destined for its own ADR"; that ADR now exists as
> [ADR-022d — Workload Classification](<ADR-022d - Workload Classification.md>),
> together with [ADR-022a — Administrative Domain](<ADR-022a - Administrative Domain.md>)
> D6/D7, both built on the vocabulary of
> [ADR-022 — Workload Ontology](<ADR-022 - Workload Ontology.md>).
> **ADR-022a + ADR-022d are the source; this section is a pointer.** The table
> that used to sit here is not reproduced, because two copies of a
> classification drift, and the drift is invisible until someone acts on the
> stale one.

The six values this appendix carried — `node` · `standalone` · `satellite` ·
`external` · `remote` · `rogue` — are retired by splitting the one flat list
into the two questions it was answering at once: **who administers the
workload** (ADR-022a D6: `this-site` / `no-site` / `other-site` / `unknown`)
and, when it is ours, **what type of device/workload it is** (ADR-022d
`kind`: `vm` / `lxc` / `host` / `cluster`, expanding). All six survive as
coordinates in that model; none is lost. See ADR-022's mapping table (spine, not either rib).

**What this ADR still decides**, and what ADR-022d does not touch: the backup
module's own `placementState` (§2.1) — `node` / `shim` / `external`. That
is where *this site's PBS* runs, and it stays the implemented mechanism.

### Open against ADR-022d (both drafts, raised not decided)

Two points where ADR-022d as drafted would change something ADR-012 has already
built and live-verified. Recorded here so the two are reconciled deliberately
rather than by whichever document is read last:

1. **`kind` would carry two orthogonal meanings.** In the code today `kind` is
   an *object-type marker*: the tooling stamps `kind: "module"` onto every
   deployed `config/<module>.json`, and shape-based module discovery
   (`isModuleConfig`, the #544 fix) reads it to tell a module from the other
   JSON in `config/`. ADR-022d redefines `kind` as *what type of device/workload
   it is* (`vm` / `lxc` / `host` / `cluster`, expanding), retiring `external-host`.
   Those are answers to different
   questions. Discovery survives — it falls back to a module-shaped field when
   `kind` is not `"module"` — but the authoritative marker stops being
   authoritative. Either `kind` needs to keep an object-type value, or the
   marker needs its own field.
   **Resolved 2026-09-18 (#611, ADR-022d v0.18):** neither — the marker is
   retired. `kind` names the workload (backup is `application`), discovery is
   shape-based, and migration 0004 keeps the marker only where it is a config's
   sole module signal.

2. **`shim` as `realized: false`.** ADR-022d §3 argues `shim` is a *state* of a
   placement rather than a peer value of one, so that "placed on a host but not
   yet built" becomes expressible. The argument is sound. It is also a schema
   change to `placementState`, which a live cluster has already been migrated
   onto (§4.1, v0.4) — so if it is taken it needs its own migration, not a
   redefinition. Until then `placementState: shim` stands as implemented.
   **Decided 2026-09-18 (#612): `shim` stays.** It is live and migrated, and a `realized` flag has
   no consumer today; "placed on a Host but not built" can be revisited when one needs it.

*(Erik's ADR-022 §1 lists `external` as meaning five things. One of them —
the peer service where a client pushes **into** us — no longer exists: v0.5
renamed it `receive`, precisely to stop that word meaning two opposite
directions. The other four are outside this ADR.)*
