# ADR-012 — Backup Enhancement

| | |
|---|---|
| **Status** | Draft |
| **Version** | 0.3 |
| **Date** | 2026-08-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#402** (flexible backup install on a cluster — origin); **#389** (remote/off-site backup setup + single-node); **#382** (adding a node does not install the backup client); **#456** (no placement policy for a pre-existing local PBS); **#214** (`pbsType`/external bare-metal PBS); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite off-site backup, pull model, compromise isolation); [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (named, not numbered foundation modules); [backup/QUICKREF.md](../../src/foundation/backup/QUICKREF.md) (PBS namespaces, multi-source pull/push — #227) |
| **Implementation** | [ADR-012-implementation.md](../design/ADR-012-implementation.md) — plan, decisions log, package tracker |
| **Changelog** | v0.1 — skeleton + Context, three decisions drafted; expanded with symmetric peers, unified credentials, placement policy, bootstrap/promotion, manager/controller tooling; implementation tracker started (Lars, 2026-07-04). v0.2 — P1–P9 implemented: P1/P2/P3 live-verified on tappaas1; P4/P5/P6/P8 offline-green; P7 (TS layer) built+verified on cicd; P9 docs + live test plan (Lars, 2026-07-05). v0.3 — **restructured** the Decision into three sections — (1) supported backup topologies, (2) configuring/detecting the Backup module, (3) configuring clients & backups; a single `backup` module is always provisioned, only the **local** case installs PBS software (now clarified to run **directly on the cluster node's Proxmox OS, not a VM**); backup-buddy / cross-PBS **pull roles** given their own §1.4 (compromise invariant demoted to §1.4.1); **simplified the push/pull model** — only two movements exist (clients *push* to their configured PBS with write-no-delete creds; off-site buddies *pull*), so **no PBS→PBS push / "append-only push receiver" is needed** and immutability is reframed as datastore-at-rest hardening, not push safety; reworked placement into a single install-resolved **`placementState`** (ships empty → `node:<name>` or `shim`; install-forced `external` is permanent), **dropping the `placement` policy field** and merging `remote-only` into `external`; `pbsUrl` (default `backup.mgmt.internal`) is the target clients push to; introduced the **backup-type taxonomy** (`vm`/`filesystem`/`userdata`/`dataset`) + the **schedule cascade**; folded in **#456** (consume an externally-managed PBS by URL — satellite / external / local-external); moved the **workload-placement taxonomy** to [Appendix A](#appendix-a--workload-placement-taxonomy-companion--future-adr), destined for its own ADR; added **§2.7 module-schema changes** (exact `module-fields.json`/`backup.json` deltas — new `pbsUrl`, `backup.type`/`schedule`, **`provides` reduced to `["vm"]`**, `pushTarget`/`alwaysBackup` deprecated) with an analysis recommending **retiring `alwaysBackup`** in favour of opt-out backup policy; added **§4 migration** (existing-TAPPaaS upgrade, #456 adoption, datastore relocation-by-pull, non-PBS) with its own plan; and made the implementation plan **explicitly include documentation** updates. No decisions reversed; P1–P9 status unchanged (Lars, 2026-08-29). |

Make the `backup` foundation module flexible about **where PBS lives** (or whether it lives in the cluster at all), keep the **per-node backup client** in step with cluster membership, give **off-site/remote backup** real setup, subsetting, and independent retention — without ever letting a compromised local cluster reach the off-site copy — and let a module declare **what kind** of backup it needs, not just on/off.

---

## Context

The current [`backup`](../../src/foundation/backup/) module makes assumptions that hold for the reference three-node cluster but break for the deployments TAPPaaS now targets (single node, two node, no suitable `tankc`, off-site-only, a PBS the site already runs). They are captured in open Release-1.2 issues.

### 1. PBS placement is hardcoded (#402)

[backup.json](../../src/foundation/backup/backup.json) pins `"node": "tappaas3"` and `"storage": "tankc1"`, and [install.sh](../../src/foundation/backup/install.sh) creates the PBS VM there unconditionally. If `tappaas3` doesn't exist, or the cluster has no `tankc` pool, or the operator wants no in-cluster PBS at all (push straight to an off-site target), install either fails or silently lands PBS somewhere unsuitable. Meanwhile many app modules `dependsOn` `backup:vm`, so **without *some* `backup` module present those modules can't install** — backup can't simply be skipped.

### 2. The per-node backup client drifts out of sync (#382)

[install.sh](../../src/foundation/backup/install.sh) enumerates `pvesh get /nodes` **once, at install time**, and installs `proxmox-backup-client` on every node then present. A node added later (via the [`cluster`](../../src/foundation/cluster/) module's node-add flow) **never gets the client**, so backups of VMs on that node can't run. There is no reconcile step; `update.sh` doesn't currently re-provision clients on new nodes.

### 3. Off-site/remote backup is under-specified (#389, #402)

[QUICKREF.md](../../src/foundation/backup/QUICKREF.md) already documents the PBS namespace model (#227): `remote/<name>` for a TAPPaaS buddy's PBS **pulled** in (Class A) and `external/<name>` for a third party **pushed** in (Class B). [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) specifies the satellite as an off-site PBS the home PBS is pulled into. What is still missing:

- A supported way to **push** the local backup to a remote target for operators who don't want to run in-cluster PBS at all (or run a single node with no room for it) — #402's "allow a remote push backup to be specified."
- **Single-node / small-site** backup: no second node to host PBS, so backup must go **directly to a remote/satellite** — #389's follow-up comment.
- Backing up **only a subset** of the local backup set off-site, with a **different retention policy** than the local copy it derives from — #389.
- A tested guarantee that **a compromised local system cannot compromise the remote backup** — #389.

### 4. No policy for a pre-existing local PBS (#456)

Earlier placement covered a PBS the module *installs* on a node (a `node:<name>` state) and a PBS that *doesn't exist yet* (a `shim`). Neither covers a site that **already runs its own PBS on the local network**, provisioned outside TAPPaaS: it has a real local datastore, so `shim` doesn't apply, and the module didn't place it, so a `node:<name>` state would describe work that never happened. The module needs a way to *consume* such a PBS — given its address (URL), register Proxmox storage and drive jobs/clients — without discovering storage or installing anything. (This ADR resolves it with the `external` state, §2.1.)

This ADR decides the model for all four, plus a taxonomy of **what** each module backs up. It builds on ADR-010 (which owns the *satellite node itself*); ADR-012 is about the **`backup` module's behavior and configuration**.

---

## Decision

The solution is organised in three parts, matching how an operator actually reasons about backup:

1. **[Supported backup topologies](#1-supported-backup-topologies)** — the shapes a site's backup can take.
2. **[Configuring & detecting the Backup module](#2-configuring--detecting-the-backup-module)** — how the module finds where PBS should live, falls back to a shim, keeps clients in sync, and is driven by tooling.
3. **[Configuring clients & backups](#3-configuring-clients--backups)** — what each module backs up (the backup-type taxonomy) and how the schedule is specified.

The [workload-placement taxonomy](#appendix-a--workload-placement-taxonomy-companion--future-adr) that earlier drafts carried inline (`node`/`standalone`/`satellite`/`external`/`remote`/`rogue`) is a *broader* concern than backup and is moved to **Appendix A**, to graduate into its own ADR.

---

## 1. Supported backup topologies

A site's backup is described by **where its primary PBS datastore lives and who manages it**. In **all three** topologies a **single `backup` module is provisioned** on `tappaas-cicd` — always installed, always satisfying `dependsOn: backup`. The difference is only whether that module also **provisions PBS software**:

| Topology | PBS software provisioned by the module? | Local datastore? | How selected | Typical site |
|---|---|---|---|---|
| **Shim** (§1.1) | no | no | state `shim` — no `tankc` found (and not forced external) | first boot, testing, before storage exists |
| **Local PBS on a cluster node** (§1.2) | **yes** — installed on the node's Proxmox OS (not a VM) | yes | state `node:<name>` — a `tankc` is found | reference 2–3-node cluster |
| **Externally-managed PBS** (§1.3) | no — **consumed** by URL | depends on flavor | state `external` — operator forces it + gives a URL | single-node, off-site-only, or a site that already runs PBS (#456) |

Only the **local PBS** case realises PBS software and a datastore; shim and external-PBS both provision the module without any PBS software of their own. Off-site *relationships* between PBS instances (a satellite pulling the home PBS, a buddy) layer on top and are covered in **§1.4**.

### 1.1 Shim — no datastore (bootstrap / testing)

A shim is JSON/marker only: **no PBS software, no datastore**, flagged so it is recognisable as a shim, with a warning emitted. It exists so the dependency graph stays satisfiable — modules that `dependsOn` `backup:vm` (or `backup:remote`) still install against it. The shim `provides` the same capability names but records that no datastore is realised locally; a module that hard-requires a live datastore surfaces that at test time, not install time.

A shim is a **placeholder promoted in place later** (§2.3): once a `tankc` pool or a target URL appears, `update-module.sh backup` turns it into any of the real topologies **and existing `dependsOn: backup` consumers keep working** without reinstall. Useful for bootstrapping a system and for testing the dependency graph before storage exists.

### 1.2 Local PBS on a cluster node (module-provisioned)

The module **discovers** a `tankc` pool (configured node first, then any node — see §2.2) and installs **PBS software directly on that cluster node's Proxmox OS** — via the Proxmox PBS package, it is **not** a separate guest VM — and owns the datastore on the node's `tankc` pool. This is the reference topology, now conditional on a `tankc` pool being present. The datastore it creates is the local backup target for the site's guests (§3).

A local PBS can also participate in **buddy relationships** with other PBS instances — including acting as a **pull source** for another TAPPaaS system. Those cross-PBS relationships are covered in **§1.4**.

### 1.3 Externally-managed PBS (consumed by URL)

The module can use a PBS it **does not provision**. The single knob is a **URL** to that PBS (plus a credential, §2.5); the flavor is orthogonal:

- **satellite** — this Site's own off-site outpost ([ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md)), reached over the WireGuard tunnel. The URL is the tunnel address.
- **external** — a truly external / third-party or buddy PBS reachable over the public network. The URL is its public host.
- **local external (#456)** — a PBS already running on the **local network**, provisioned and managed outside TAPPaaS. The URL is its LAN address. The module registers it as Proxmox storage and drives jobs + client rollout, but **discovers no storage and installs nothing**.

The mechanics that differ between these are only *reachability* (tunnel vs public vs LAN) and *whether there is a local datastore too*. The **credential mechanics are identical** (§2.5).

A **local external** PBS (#456) is simply the site's configured target: clients push to it exactly as they would to a local TAPPaaS PBS. When a satellite or external PBS is instead used as a *second, off-site* copy of a local PBS, that copy is made by **pulling** (§1.4).

### 1.4 Off-site copies: clients push, buddies pull

There are only **two** data movements in the whole model, and neither requires a PBS to push to another PBS:

**1. Clients push to their configured PBS.** Every backup client (the per-node `proxmox-backup-client`, §2.4) *pushes* its snapshots to the one PBS configured for the site. Whether that PBS is a local TAPPaaS PBS (§1.2) or an externally-managed one (§1.3, including the single-node `external` case) is **irrelevant to the client** — it just uploads to the configured target. On a **shim** there is no target, so the push is a **no-op**. The client credential is **write, no delete** and the **PBS owns prune/retention**, so a compromised node can add snapshots but never delete or rewrite them — local *or* remote.

**2. Off-site buddies pull.** A second, off-site copy is **always** made by the destination *pulling* from the source — never by the source pushing out.

- A **satellite** (ADR-010) pulls from the home PBS it is a satellite for (over the tunnel).
- A **peer TAPPaaS** acting as your off-site buddy pulls from your PBS.
- Symmetrically, your PBS can be the buddy that pulls *another* system's backups in.

A TAPPaaS backup system therefore registers two lists — and there is **no push between backup systems** in either:

| Registered relationship | Who initiates | Credential this side holds |
|---|---|---|
| **Pull buddies** — systems authorised to pull *from* me (my off-site copies) | the buddy pulls me | none on the buddy — I only *grant* it a read-only token on me (§2.5) |
| **Pull sources** — remote systems I pull *from* (I am their off-site copy) | I pull them | a read-only token on each source (§2.5) |

A local PBS plus a pulling satellite is a classic **3-2-1**.

#### 1.4.1 Why this is safe — and why no PBS→PBS push is needed

*A compromise of one system must not be able to delete, encrypt, or tamper with a copy held on another.* The two movements above satisfy this **structurally**, with no special "append-only push" machinery:

- **Client push (write-no-delete).** Clients only ever hold write-no-delete credentials and the PBS owns prune, so a compromised node cannot destroy backups on the PBS it pushes to — even when that PBS is an external one (the single-node `external` case). This is the **only** push in the system, and it is safe by credential scope, not by any special mode.
- **Buddy pull (no reverse credential).** The source PBS holds no credential to its off-site buddies — the buddy reaches in and pulls (ADR-010 §3.1, §7.2). A compromise of the source cannot touch the pulled copy.

**Do we need an "append-only push" between backup systems? No.** Every inter-PBS copy is a pull, so there is never a source→destination write path to harden. The old draft's append-only *push receiver* existed only to make such a push safe — but that push is unnecessary: an off-site that can pull (a satellite over the tunnel, or a peer) covers every supported topology, and a site with no local PBS simply has its clients push to the external PBS directly (still write-no-delete). *(A pure push-only third-party target that refuses to pull is the sole case a PBS→PBS push would serve; it is **out of scope** for TAPPaaS topologies.)*

- **Immutability is datastore hardening, not push safety.** Optional immutable history (remote-side ZFS snapshots, or S3 Object Lock on a satellite's backend per ADR-010 §7.3) still has value — but reframed: it protects a datastore against deletion via its *own* admin plane (an attacker who reaches PBS root), which matters most for the copy a compromised node can actually reach. It is belt-and-suspenders on top of the structural pull/write-no-delete isolation, not the thing that makes off-site safe.
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
| `node:<name>` | not external, `tankc` found (on node `<name>`) | install PBS on `<name>`'s Proxmox OS + own the datastore | §1.2 |
| `shim` | not external, and **no `tankc` found** | catch-all fallback: marker only, no datastore | §1.1 |
| `external` | **install told to force external** (+ a `pbsUrl`) | consume the externally-managed PBS; provision nothing. **Permanent once set.** | §1.3 |

Two operator inputs shape resolution, both on `backup.json`:

- **`node`** *(optional)* — restrict `tankc` discovery to a **single named node**. If unset, all nodes are searched.
- **`pbsUrl`** — the PBS the clients push to (§1.4). **Defaults to `backup.mgmt.internal`** (the local PBS DNS name). Overridden to the external PBS's URL (satellite tunnel addr / public host / LAN addr, §1.3) when going `external`.

Forcing `external` is an **install-time action** (an install argument + `pbsUrl`), not a config policy field — it *overwrites* `placementState` to `external`, and that is then the **permanent** state. This one state covers every externally-managed flavour — satellite, public external, or a pre-existing LAN PBS (#456) — because the module's behaviour is identical (provision nothing, register the PBS at `pbsUrl` as storage, clients push there). *(It subsumes the earlier `remote-only`, which was indistinguishable.)*

> **Naming note (open):** #214 introduced a `pbsType`/`external` notion for bare-metal PBS. How the install-time "force external" is spelled (a dedicated flag, `pbsType`, …) is an implementation detail for the tracker — the **decision here** is: no `placement` policy field; `placementState` ships empty and is install-resolved; `external` is set at install (with `pbsUrl`) and is permanent.

### 2.2 The resolution order

At install/update, `install.sh` resolves `placementState`:

1. **Told to force `external`?** → `placementState = external` (requires `pbsUrl`). No discovery, nothing provisioned. Sticky thereafter.
2. Already a concrete state (`node:<name>` or `external`) → **keep it** (idempotent).
3. Empty *(released default)* or `shim` → **derive auto**: discover a `tankc` pool — searching **only `backup.json.node`** if set, otherwise **across all nodes**. Found on node `<name>` → `placementState = node:<name>` (install PBS there); **not found → `shim`** (the catch-all fallback; lay the marker, warn).

So `node` is a *discovery constraint* (which node[s] to search) and `node:<name>` is the *state* that results when a `tankc` is actually found. An empty state and a `shim` are both re-derived on every update (so a `shim` promotes to `node:<name>` the moment a `tankc` appears); `external` and `node:<name>` are kept.

### 2.3 Shim & promotion

**Reinstallability is a first-class requirement.** A shim must be **promotable in place** — no teardown, no dependent reinstall. Because empty/`shim` states are re-derived on every `update-module.sh backup` (§2.2):

| From `shim` to… | Trigger | Effect of `update.sh` |
|---|---|---|
| **`node:<name>`** (local PBS) | a `tankc` now exists (on `node`, or any node if unpinned) | re-derives to `node:<name>`; creates the datastore + per-node clients; the shim marker becomes a real datastore |
| **`external`** | operator re-runs install/update **forcing external** + `pbsUrl` | overwrites to `external` (permanent); registers the consumed PBS as storage + wires jobs; provisions nothing |

The **same command that heals node membership (§2.4) also advances backup from `shim` to a real state.** This is the concrete answer to #402's "allow backup to be reinstalled later and ensure existing `dependsOn` modules then work."

### 2.4 Per-node client reconcile (#382)

Installing the per-node `proxmox-backup-client` becomes an **idempotent reconcile**, not a one-shot at PBS-install time:

- The client-install loop is factored into a reusable step that **enumerates the *current* cluster membership** and installs the client on any node missing it.
- **`update-module.sh backup` runs this reconcile**, so the routine update flow heals a cluster whose membership grew. Re-running is a no-op on nodes that already have the client.
- **Node-add triggers the reconcile automatically.** When `site-manager` adds a node, its node-add flow **automatically calls `module-manager modify backup`** (which runs the reconcile above) as the final step — so the new node gets its backup client with **no operator follow-up**. This is a triggered, automatic action, **not** a documented manual step the operator must remember.

### 2.5 Unified credential model

Matching the two movements (§1.4), there are exactly **two** credential shapes, and neither varies with the peer type (local, satellite, external, or local-external):

- **Pull token (read-only)** — held by a *destination* to pull from a *source*. A **read-only** API token (`Datastore.Read`/`Audit`) on the source PBS — `readAuthId` in [`remote.json`](../../src/foundation/backup/services/remote/remote.json), prompted at onboarding and **never stored in the JSON**. Used for every buddy/satellite pull relationship.
- **Backup login (write-no-delete)** — held by a *client* to push snapshots to its configured PBS. A `<name>@pbs` login with the **`DatastoreBackup` role scoped to one namespace** (write, no delete); the **PBS owns prune**. Used by every node's backup client against the local PBS, and — unchanged — when the configured PBS is an `external` one. (The same shape backs [`external.json`](../../src/foundation/backup/services/external/external.json), for the edge case of receiving a push from a non-TAPPaaS third party into `external/<name>`.)
- **Encryption:** `encryptionRequired: true` — the data-owner's key encrypts on the client before transit; every PBS holding a copy stores ciphertext only and never holds the key. See **key storage & restore** below.
- **No secrets in config:** the JSON carries host/URL/store/namespace/retention/schedule only; API auth-ids and passwords are prompted at onboarding and live in `/etc/secrets` (TAPPaaS convention). The *same* config file is safe whether it points at a buddy, a satellite, a remote, or a local-external PBS.

The one unavoidable variance is the **URL** (tunnel address vs public host vs LAN address, §1.3). The credential mechanics do not change. Note that **no credential ever authorises one PBS to push to another** — inter-PBS movement is pull-only (§1.4).

#### 2.5.1 Encryption key storage & the restore flow

A client-side encryption key is only useful if it **outlives the client that made the backup** — a restore needs the key precisely when the original VM is gone. So the key is **never kept only on the client**:

- **Where it lives.** At onboarding, `backup-manager` generates the client encryption key and **escrows it centrally in `/etc/secrets` on `tappaas-cicd`** (the same store as the other backup secrets), managed by the `identity`/secrets layer — independent of any VM being backed up. Each client is *handed* its key to encrypt with, but the durable copy is central.
- **Normal restore (a VM lost, the cluster/cicd intact).** Provision a fresh VM (or restore host), fetch the escrowed key from `/etc/secrets` on `tappaas-cicd`, and run the PBS restore with it — the ciphertext in the datastore decrypts and the VM comes back. The original client never has to exist for this to work.
- **Full-site DR (the cluster *and* `tappaas-cicd` are lost).** The escrow is inside the very system being rebuilt, so it cannot be the only copy. The encryption key is therefore the **DR linchpin** (ADR-010 §3.2/§7): the operator must hold an **out-of-band copy** — offline/printed, or in the satellite's separate secret store off-site. DR order is: rebuild `tappaas-cicd`, load the out-of-band key back into `/etc/secrets`, then restore from the off-site (pulled) PBS copy using that key.

**Key export / import for the out-of-band copy.** `backup-manager` provides an operator command to **export the encryption key(s) to removable media** — a PC, SD-card, or USB stick — so the operator can create and safekeep the mandatory out-of-band copy (`backup-manager key export <dest>`), and a matching **import** that loads a key back onto a **fresh system** during DR (`backup-manager key import <src>` → `/etc/secrets`). This is exactly the mechanism that makes full-site DR above possible: export once at onboarding, store the media somewhere safe/off-site, and import it into the rebuilt `tappaas-cicd` before restoring from the off-site copy. (Verb names indicative; the point is a first-class export-to-media / import-to-fresh-system path, not a manual file copy.)

**Corollary:** losing the escrowed key with no out-of-band copy makes an encrypted off-site copy unrecoverable — the compromise-isolation guarantee (§1.4.1) cuts both ways, so the out-of-band key copy is mandatory, not optional. This is the one restore that must be tested with *and* without the key (§Testing).

### 2.6 Tooling — `backup-manager`, `backup-controller`, satellite

Backup is split along the standard TAPPaaS **manager/controller** line, so the *same two components* drive backup on the local PBS **and** on a satellite/external PBS:

- **[`backup-manager`](../../src/foundation/tappaas-cicd/manager/backup-manager/)** — *owns config/policy.* Resolves the Site→Environment→Module backup-policy cascade (`resolve`, `status`, and the new `placement` / `peers` verbs) and owns the *desired* state: which modules are backed up, effective retention + schedule (§3.2), residency, placement state (§2.1), off-site peers, subset selectors, and per-peer retention. Read-only over live PBS: it *decides*, then calls the controller.
- **[`backup-controller`](../../src/foundation/tappaas-cicd/controller/backup-controller/)** — *owns runtime PBS state.* Talks to a live PBS (reusing [`pbs-job.sh`](../../src/foundation/backup/lib/pbs-job.sh) / [`pbs-namespace.sh`](../../src/foundation/backup/lib/pbs-namespace.sh)) to create datastores/namespaces, add guests to the managed job, apply schedules, register pull remotes, issue push credentials, trigger verify/prune. It is **PBS-endpoint-agnostic** — the target PBS is a **parameter (`--pbs <host>`), not a hardcode** — so the same ops target the local, satellite, or external PBS; only endpoint + credential differ. It degrades gracefully when PBS is unreachable.

**Division of labour with ADR-010:** `satellite-manager` (ADR-010) provisions the *node* — the VPS, tunnel, PBS install, datastore backend — and stops at "a reachable PBS endpoint (URL) exists." `backup-manager`/`backup-controller` then **control it as just another PBS** via the unified credentials (§2.5). The operator-facing [`backup-manage.sh`](../../src/foundation/backup/backup-manage.sh) verbs (`add-remote`, `add-external`, `add-push`, `list-sources`, …) are the thin CLI over the same controller ops, so onboarding a peer is the **same command** whether that peer is local, satellite, external, or local-external.

### 2.7 Module-schema changes (`module-fields.json` / `backup.json`)

The changes touch three groups in [`schemas/module-fields.json`](../../src/foundation/schemas/module-fields.json) (and the `backup` module's [`backup.json`](../../src/foundation/backup/backup.json)).

**A. Backup-module fields** (authored on `backup.json`, `usedBy: ["backup:vm"]`):

| Field | Change | Detail |
|---|---|---|
| `placement` | **remove** | The current `placement` policy field is deleted — its job is now the install-resolved `placementState` (§2.1). A legacy value is read *once* during migration (§4) to seed the state, then dropped. |
| `node` | **repurpose** | From an `auto` *hint* to a **discovery constraint**: when set, only this node is searched for `tankc`; when unset, all nodes are. |
| `storage` | keep | The `tankc` pool name to find/use (default `tankc1`). |
| `placementState` | **change values + ships empty** | The single source of truth (§2.1). Was `local\|shim\|remote-only`; now **empty (released default)** or pattern `^(shim\|external\|node:.+)$`. Install-written, never hand-authored. Migration: legacy `local` → `node:<name>`, `remote-only` → `external`. |
| `pbsUrl` | **new** | The PBS the clients push to (§1.4). **Default `backup.mgmt.internal`** (local PBS DNS); overridden to the external PBS's URL when `placementState:external` (§1.3). Credential prompted-not-stored. |
| `pushTarget` | **deprecate** | Subsumed by `placementState:external` + `pbsUrl` — the external PBS is simply the configured target clients push to. Read for one release, then removed. |
| `pbsStorageName` | keep | PBS datastore / Proxmox storage name. |
| `immutableSnapshots` | keep, **reword** | Reframed as **datastore-at-rest hardening** (§1.4.1), not push safety. |
| `alwaysBackup` | **deprecate** | See the note below. |

**B. The per-module `backup` policy object** (authored on *any* module, the Site→Env→Module cascade leaf) — extend the existing `enabled`/`retention`/`exclude` with:

| Sub-field | Change | Detail |
|---|---|---|
| `type` | **new** | `vm` (default) \| `filesystem` \| `userdata` \| `dataset` — the backup-type taxonomy (§3.1). |
| `schedule` | **new** | The module's own schedule; inherits the Site→Env cascade (default once/day) when absent; **must be ≤ once/day** (§3.2). `userdata` cadence is module-defined. |
| `filesystemPaths` | **new** | `type:filesystem` only — the named guest paths to capture (guest-OS-type gated). |
| `exporter` | **new** | `type:userdata` only — the command/contract that writes the open-format export file (§3.1). |

**C. `provides` capabilities** (on `backup.json`):

- Today `["vm", "remote", "external"]`. A repo-wide check shows **only `backup:vm` is ever depended on** — nothing declares `dependsOn: backup:remote` or `backup:external`.
- **Change to `provides: ["vm"]`.** The `remote`/`external` roles are **runtime peer relationships** registered via `backup-manage.sh` (§1.4/§2.6), not dependency capabilities — and dropping `external` from `provides` removes the clash with the new `placementState: external`. All states (`node:<name>`/`shim`/`external`) still `provides: ["vm"]`, which is exactly what lets a **shim satisfy `dependsOn: backup:vm`** (§1.1).

**Schema hygiene (KI-1).** Land the `provides`-aware normalizer fix (implementation-doc KI-1) with these edits — otherwise the `backup:vm` self-capability fields (`placementState`, `pbsUrl`, `pbsStorageName`, …) keep tripping the false "orphan field" warnings.

**Note — why `alwaysBackup` exists, and retiring it.** It was introduced as a **bootstrap-ordering workaround**: PBS-job membership is driven by `dependsOn: backup:vm`, but the foundation VMs that come up *before* the backup server — `network`/`firewall`, `tappaas-cicd` — cannot declare that dependency (they precede backup; it would be a cycle / wrong order). `alwaysBackup` force-adds them to the job. It is genuinely needed **only under the current "membership = `dependsOn`" design.** The §3 backup-type/policy work is the moment to remove it: if PBS-job membership is derived from the **resolved `backup` policy** (`enabled` defaulting **true** — opt-*out*, not opt-in) plus `type`, then every VM including the foundation ones is in the job **by default**, `dependsOn: backup:vm` reverts to *install-ordering only*, and `alwaysBackup` becomes redundant. This is also fail-safe (a new module is backed up unless it opts out). **Recommendation: make backup opt-out and retire `alwaysBackup`** — flagged for operator confirmation, since default-on is a behaviour change.

---

## 3. Configuring clients & backups

This section is the **client side**: what each module backs up, and how the schedule is expressed. A module opts into backup through its JSON; this ADR adds a **backup-type taxonomy** so a module declares *what kind* of backup it needs, not just on/off.

### 3.1 Backup-type taxonomy

| Type | What is captured | Restore target | Where supported | Format |
|---|---|---|---|---|
| **`vm`** (full VM / LXC) | the whole VM or LXC — a PBS snapshot of the guest | same or a new VM/LXC | any Proxmox guest | PBS native |
| **`filesystem`** (subset inside a VM) | a **named subset** of the guest filesystem | into a running guest | **only known/supported guest OS types** (needs the guest agent + a known layout) | PBS native (file-level) |
| **`userdata`** (application data export) | an application-level export of the module's **user data** to a **named file** on the backup system | restorable on a **different** system | modules that implement an **exporter** | **open format** — e.g. a zip of the application's data |
| **`dataset`** (Proxmox dataset) | a Proxmox storage dataset | the dataset | sites with **external / NFS-served** data | PBS / dataset native |

Notes:

- **`vm`** is today's default — a full-guest snapshot, the safest general case.
- **`filesystem`** narrows a VM backup to a known subset of files; only offered where TAPPaaS knows the guest OS layout well enough to select and restore it reliably.
- **`userdata`** is deliberately **portable**: the module's exporter writes an **open-format** archive (a zip of the application's data) to a named file on the backup system, so it can be **restored onto a different system** — not tied to the original VM. It is the escape hatch from PBS-native lock-in for the data that matters most.
- **`dataset`** exists for the case where data is **not** inside a TAPPaaS-managed guest — e.g. external NFS-served storage attached as a Proxmox dataset.

### 3.2 How a backup is specified — the schedule cascade

Backup frequency resolves through the **Site → Environment → Module cascade** (owned by `backup-manager`, §2.6):

- The **Site** sets a **default** frequency. Out of the box that default is **once per day** (nightly), but a site may change it — e.g. a site whose default is **once per week**.
- A module that specifies **nothing** inherits the site default. So if the site default is weekly, *every* module is weekly unless it says otherwise.
- A module **may declare its own schedule** — typically **less** frequent than the site default for a module whose state rarely changes (e.g. an office suite: `once per week` or even `once per month`).
- **Hard ceiling: never more than once per day.** A module cannot request a sub-daily schedule. Once-a-day is the maximum frequency the platform backs anything up.

The common case is therefore: **most modules inherit the site default (once/day); a few rarely-changing modules pin a longer interval.**

**Exception — `userdata`.** The `userdata` export is **not** governed by the site cascade. Because only the module knows when its application data is in a consistent, exportable state, its cadence is **module-defined** (the module owns the exporter). The same **once/day ceiling** still applies.

### 3.3 Subset + independent off-site retention (#389)

The off-site copy need not mirror the local set 1:1:

- **Subset:** the off-site pull job selects a **subset** of the source backups/namespaces to replicate — e.g. only critical VMs off-site, everything locally. Expressed as a selector in the remote/push job config (PBS group-filter today).
- **Independent retention:** the off-site copy runs its **own retention policy**, distinct from the local one it derives from — typically *longer* off-site (DR archive). Because retention is **owned by the destination** (§1.4), the two policies are independent and the compromise invariant is preserved.

---

## 4. Migrating an existing backup setup

A deployment rarely starts empty. There are four starting points to migrate from, and **none should lose backup history**. Migration reuses the mechanisms already decided above (state re-resolution §2.1–2.3, buddy pull §1.4) — it introduces no new machinery.

### 4.1 Upgrading an existing TAPPaaS backup (hardcoded → placement state)

Pre-ADR-012 installs pin `node:tappaas3` / `storage:tankc1` and carry `placementState:local` (or empty on the oldest installs). `update-module.sh backup` **backfills the state in place, never a promotion-reinstall**:

- `placementState:local` (or empty) → `node:<name>`, where `<name>` is the node currently hosting the PBS — **the datastore is left exactly where it is**, no move, no dependent reinstall.
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
3. **Relocation runbook** — document + script the pull-seed → cut-over → decommission flow (§4.3) in `QUICKREF.md`; gate decommission on a test restore.
4. **Deprecation window** — `pushTarget`/`alwaysBackup` read-then-drop; emit a one-line deprecation notice on update; remove the fields and the `alwaysBackup` code path once the opt-out `backup` policy (§2.7) is the membership source.
5. **Migration tests** — legacy-fixture upgrade, #456 adoption preserving snapshots, and relocation-by-pull preserving history (see §Testing).

---

## Consequences

### Positive

- **Backup installs on any topology** — three-node, two-node, single-node, no-suitable-storage, or a site that already runs PBS (#456) — without failing the dependency graph.
- **`dependsOn: backup` never blocks an install** even when no datastore is realised; the shim (§1.1) keeps the graph satisfiable and promotes later in place (§2.3).
- **Adding a node no longer silently breaks its VMs' backups** — the client reconcile (§2.4) heals membership drift on the normal update cadence.
- **Off-site backup works for small sites** (single-node push, §1.3/§1.4), not just clusters big enough to host PBS.
- **The compromise invariant is explicit and testable** — off-site is pull-only, clients push with write-no-delete credentials, retention is owned by each PBS, optional immutable history (§1.4).
- **One model, every topology** — any PBS (local, satellite, external, local-external) is a symmetric peer with **identical credential setup** (§1.4/§2.5), consumed by URL, and driven by the same `backup-manager`/`backup-controller` (§2.6).
- **Modules declare *what* to back up** — the taxonomy (§3.1) distinguishes a full snapshot from a portable, open-format `userdata` export, and the schedule cascade (§3.2) gives sensible defaults with per-module override.
- **Reuse over invention** — leans on the existing #227 namespace/pull/push machinery, ADR-010's satellite, and PBS roles rather than new mechanisms.

### Negative / costs

- **More placement states to reason about** (`node:<name>` / `shim` / `external`) and to test.
- **Shim → real-PBS promotion** is a new lifecycle transition that must be idempotent and dependency-safe.
- **The single-node `external` case hands a client a credential to an external PBS** that must be provably delete-incapable (write-no-delete, PBS-owned prune); getting that scope wrong would silently break the invariant, so it needs adversarial testing (§Testing).
- **`userdata` exporters are per-module work** — each supporting module must implement and maintain its open-format exporter/importer.
- **Two backup-target wirings** — clients pushing to a *local* PBS vs directly to an *external* PBS — are two code/test paths, on top of the buddy pull path.

### Neutral / assumptions

- Assumes PBS namespace + role model (#227) and ADR-010's satellite remain the substrate.
- Single-node `external` assumes a reachable remote PBS/satellite that accepts the node's backup client and owns its own prune (Object Lock optional).
- Client-side encryption keys remain the operator's DR linchpin (ADR-010 §3.2/§7) — unchanged and out of scope here.
- The workload-placement taxonomy (Appendix A) is a **companion reference**, not a decision of this ADR.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Skip `backup` entirely when no `tankc`** | Breaks every module that `dependsOn: backup` — the shim (§1.1) keeps the graph satisfiable instead. |
| **Fail install if `tappaas3`/`tankc1` absent** | Excludes single-node and non-reference topologies that Release 1.2 must support. |
| **Re-enumerate nodes only at PBS reinstall** | Still misses nodes added between reinstalls; §2.4 makes it part of the routine `update.sh` reconcile. |
| **Give a client full read-write-delete on its PBS** | Violates the #389 invariant — a compromised node would delete its own backups. Clients always get write-no-delete; the PBS owns prune (§1.4). |
| **Only support a local PBS + buddy pull for off-site** | Leaves single-node / no-local-PBS sites with no off-site option; letting clients push directly to an `external` PBS (§1.3) fills that gap safely. |
| **A PBS→PBS "append-only push" mechanism** | Unneeded — every inter-PBS copy is a pull, so there is no source→destination write path to harden. The only push is client→PBS, made safe by write-no-delete creds (§1.4.1). |
| **Satellite as a pull-only target** | Too narrow — a satellite PBS is just another PBS and can also be an `external`-state site's *direct backup target* (its clients push to it), not only a puller of the home PBS (§1.4). |
| **Separate credential flow per peer type** | Triples the surface for no benefit — PBS tokens/roles are identical; one unified flow (§2.5) is simpler and less error-prone. |
| **Require migration onto module-provisioned PBS (reject #456)** | Forces a site with a working PBS to tear it down; consuming it by URL (§1.3) adopts what exists instead. |
| **Only `vm` backups (no taxonomy)** | Loses portable, open-format `userdata` exports and dataset/filesystem cases; the taxonomy (§3.1) lets a module declare the right kind. |

## Implementation Plan (phased)

1. **Placement resolution + shim (#402)** — resolve `placementState` from the `external` force / `node` discovery-constraint inputs in `backup.json`; make `install.sh` discover `tankc` (only the pinned `node` if set, else any node), install PBS on the node where found (→ `node:<name>`), or lay down a flagged shim with a warning (→ `shim`); record the resolved state idempotently.
2. **Shim promotion (#402)** — `update-module.sh backup` promotes a shim to real PBS once storage appears, preserving `dependsOn: backup` consumers.
3. **Client reconcile (#382)** — factor the per-node client install into an idempotent step keyed on current cluster membership; wire into `update.sh`; reference from node-join.
4. **External-target / no-local-PBS path (#402, #389)** — clients push to an `external` PBS with a **write-no-delete** credential; remote-owned prune; single-node `external` wiring.
5. **Immutability + subset/retention (#389)** — optional datastore-at-rest immutability (Object Lock / remote ZFS snapshots) as hardening (§1.4.1); add subset selector + independent off-site retention.
6. **Symmetry + unified credentials (§1.4/§2.5)** — confirm any PBS can be both a pull source (others pull from it) and a pull destination (it pulls others) on one datastore (namespace-partitioned), plus a client-backup target; consolidate the two credential shapes (read-only pull token / write-no-delete backup login) as the single path for every peer type.
7. **Tooling (§2.6)** — extend `backup-manager` with placement (state + resolution), off-site peers, subset and per-peer retention in the cascade; make `backup-controller` **PBS-endpoint-agnostic**; keep `backup-manage.sh` as the thin operator CLI.
8. **Bootstrap & promotion (§2.3)** — wire placement resolution into `install.sh`; make `update-module.sh backup` promote a shim to `node:<name>` / `external` / node+satellite without dependent reinstall.
9. **Hardening (#389)** — the compromise-isolation test suite.
10. **Consume a pre-existing PBS (#456)** — add the install-forced `external` placement state (URL via `pbsUrl`: satellite / external / local-external); register consumed storage + jobs + client rollout without discovering storage or installing PBS. *(new — v0.3)*
11. **Backup-type taxonomy + schedule cascade (§3)** — add the `vm`/`filesystem`/`userdata`/`dataset` type to module JSON; implement the Site→Env→Module schedule cascade (default once/day, module override ≤ once/day, `userdata` exception); define the `userdata` open-format exporter contract. *(new — v0.3)*
12. **Module-schema changes (§2.7)** — **remove the `placement` field**; make `placementState` ship empty with the new value set; add `pbsUrl` (default `backup.mgmt.internal`), `backup.type`/`schedule`/`filesystemPaths`/`exporter`; **reduce `provides` to `["vm"]`**; deprecate `pushTarget`/`alwaysBackup`; land the KI-1 `provides`-aware normalizer fix. *(new — v0.3)*
13. **Retire `alwaysBackup` → opt-out backup (§2.7)** — make PBS-job membership derive from the resolved `backup` policy (`enabled` default true) + `type`; `dependsOn: backup:vm` becomes install-ordering only; verify foundation VMs stay covered. *(new — v0.3; operator-confirmed default-on)*
14. **Migration (§4)** — legacy `placementState` backfill; `#456` adoption preserving snapshots; datastore relocation-by-pull; `pushTarget`/`alwaysBackup` deprecation window. *(new — v0.3)*
15. **Documentation (all changes)** — update `backup/README.md`, `QUICKREF.md`, `TEST.md`; the module-authoring guide ([`apps/00-Template`](../../src/apps/00-Template/)) for `backup.type`/`schedule` + placement states + `userdata` exporter contract; the migration + key export/import runbooks; and this ADR + its [implementation tracker](../design/ADR-012-implementation.md). *(new — v0.3)*

## Testing Strategy

- **Placement:** with `tankc` → PBS on the right node; no `tankc` → a **shim** (no VM), a warning, and a `dependsOn: backup` module still installs; adding `tankc` + re-running `update.sh` **promotes** the shim and the dependent module still works.
- **Consume pre-existing PBS (#456):** install-forced `external` + a `pbsUrl` → the module registers storage + jobs and rolls out clients **without** discovering storage or installing PBS; a `dependsOn: backup` module backs up to the consumed datastore.
- **Client reconcile (#382):** add a node after backup is installed; `update-module.sh backup` installs the client on the new node only; re-running is a no-op.
- **Off-site subset/retention (#389):** an off-site job replicates only the selected subset and applies a **different** (longer) retention than local.
- **Compromise isolation (the headline #389 tests):**
  - **Pull:** with the remote's read-only token, deleting/pruning the *local* datastore is denied.
  - **Push:** the local push credential can add a snapshot but **cannot delete or prune** the remote namespace; a delete attempt is refused.
  - **Immutability:** deleting/overwriting a retention-locked (Object Lock / snapshot) off-site chunk is refused even with elevated remote credentials.
  - A **simulated local-cluster compromise** cannot erase, encrypt, or rewrite the off-site history.
- **Restore:** a restore **from the off-site copy** to a clean PBS succeeds *with* the encryption key and fails *without* it.
- **Single-node (#389):** an `external` single node's clients back up directly to a remote/satellite and restore from it.
- **Symmetry (§1.4):** a satellite PBS simultaneously *pulls* the home PBS and *receives the direct client backups* of a single-node `external` site, in separate namespaces, on one datastore.
- **Unified credentials (§2.5):** onboarding a pull source and a client-backup target uses the *same* flow (prompt-not-store read-only token / scoped write-no-delete DatastoreBackup) whether the peer is local, satellite, external, or local-external.
- **Tooling (§2.6):** `backup-controller` performs the same operation against the local PBS and a satellite/external PBS with only endpoint/credential differing.
- **Backup-type taxonomy (§3.1):** each type backs up and restores — `vm` full-guest; `filesystem` subset on a supported guest OS; `userdata` exports an **open-format** file that restores **onto a different system**; `dataset` captures an external/NFS dataset.
- **Schedule cascade (§3.2):** a module with no schedule inherits the site default; changing the site default to weekly makes unspecified modules weekly; a module override to weekly/monthly holds; a sub-daily request is **rejected** (once/day ceiling); `userdata` cadence is module-defined and still ≤ once/day.
- **Bootstrap/promotion (§2.3):** `shim → external` and `shim → node:<name>` (and `→ node+satellite`) via a config change + `update.sh` re-resolving `placementState`; dependents keep working throughout.
- **Schema (§2.7):** a `backup.json` with the new fields + `provides:["vm"]` validates; a shim still `provides: backup:vm`; the `provides`-aware normalizer emits no false orphan warnings (KI-1).
- **`alwaysBackup` retirement (§2.7):** with opt-out policy, the foundation VMs (`network`/`firewall`/`tappaas-cicd`) are in the job with **no** `alwaysBackup` list; a module with `backup.enabled:false` is excluded.
- **Migration (§4):** a legacy fixture (`placementState:local`, `pushTarget`, `alwaysBackup`) upgrades to `node:<name>` with the datastore untouched; a `#456` `external` adoption leaves the pre-existing snapshots restorable; a relocation-by-pull preserves history and only decommissions the old datastore after a test restore.

## Acceptance

- [x] `install.sh` resolves placement — discovers `tankc` and installs PBS on the node, else lays down a flagged shim (with warning). *(#402)* — **live-verified on tappaas1** *(implemented as the `auto`/`node:`/`shim`/`remote-only` policy enum; the v0.3 rename to `placementState` states `node:<name>`/`shim`/`external` is not yet in code)*
- [x] Shim → real-PBS **promotion** via `update-module.sh backup` works and preserves `dependsOn: backup` consumers. *(#402)* — **live-verified**
- [x] Per-node client install is an **idempotent reconcile** owned by `update.sh`; a node added later gets its client. *(#382)* — **live-verified (single node)**
- [x] **External / no-local-PBS** off-site path implemented with a **write-no-delete** client credential and remote-owned retention. *(#402, #389)* — offline; live push pending 3-node *(coded as `remote-only`)*
- [x] Off-site **subset** selection + **independent retention** work. *(#389)* — implemented; live pending 3-node
- [x] Any PBS (local, satellite, remote) works as **both** a pull source and a pull destination, and as a client-backup target; peer onboarding is the **same** credential flow regardless of peer type. *(§1.4/§2.5)*
- [x] **PBS-endpoint-agnostic** tooling — the TS `backup-manager` (+ `--pbs`) drives the same ops at local or satellite PBS; `backup-controller` honors `--pbs`. *(§2.6)* — **built + verified on cicd**; satellite targeting pending cluster
- [x] A `shim` promotes to **`node:<name>` (local)**, **`external`**, or **node + satellite** via a config change + `update-module.sh backup`, dependents intact. *(§2.3, #402)* — **live-verified (shim→local)** *(coded as `auto`/`remote-only`)*
- [ ] **Drop the `placement` field; `placementState` ships empty and is install-resolved; merge `remote-only` → `external`** per v0.3 §2.1 — code currently ships `placement: auto/node:/shim/remote-only` + `placementState: local`. — **not started (v0.3)**
- [ ] **Consume a pre-existing PBS (#456)** — install-forced `external` (`pbsUrl`) registers storage + jobs + clients without discovering storage or installing PBS. — **not started (v0.3)**
- [ ] **Backup-type taxonomy (§3.1)** — `vm`/`filesystem`/`userdata`/`dataset` implemented; `userdata` produces an open-format file restorable on a different system. — **not started (v0.3)**
- [ ] **Schedule cascade (§3.2)** — Site→Env→Module resolution with once/day ceiling and the `userdata` exception. — **not started (v0.3)**
- [ ] **Module-schema changes (§2.7)** — `pbsUrl`, `backup.type`/`schedule`/`filesystemPaths`/`exporter` added; `provides` reduced to `["vm"]`; `pushTarget`/`alwaysBackup` deprecated; KI-1 normalizer fix landed. — **not started (v0.3)**
- [ ] **`alwaysBackup` retired** — PBS-job membership derives from the opt-out `backup` policy; foundation VMs stay covered without the list. — **not started (v0.3, operator-confirmed)**
- [ ] **Migration (§4)** — legacy state backfill (no datastore move), `#456` adoption preserves snapshots, relocation-by-pull preserves history. — **not started (v0.3)**
- [ ] **Documentation updated (§Impl 15)** — `backup/README.md` + `QUICKREF.md` + `TEST.md`, the `00-Template` module-authoring guide, and the migration + key export/import runbooks. — **not started (v0.3)**
- [ ] **Compromise-isolation tests pass** — local compromise cannot delete/encrypt/rewrite the off-site copy; immutability holds. *(#389)* — **suite documented in `TEST.md`; runs on the 3-node cluster**
- [ ] Restore-from-off-site proven **with** the key and fails **without** it. — **cluster-pending**
- [x] `QUICKREF.md` / `TEST.md` updated (v0.2 baseline). Status advanced **Draft → Proposed** after operator review (still Draft — pending operator sign-off + cluster live tests).

---

## Appendix A — Workload placement taxonomy (companion — future ADR)

> **Status:** companion reference, **not** a decision of this ADR. Earlier ADR-012 drafts carried this inline (as §1.2); it is a *broader* concern than backup — it classifies **any** workload TAPPaaS is aware of, not just PBS placement — and is parked here to graduate into **its own ADR**. It does **not** replace the `node:<name>`/`shim`/`external` placement states (§2.1), which stay as the implemented mechanism.

Separately from backup placement, **#456** raised whether *placement itself* — independent of `backup` — needs a shared taxonomy across any workload TAPPaaS tracks. The classification below sorts a workload — a VM, LXC, container, or service, TAPPaaS-wrapped or not — by whether this Site **tracks** it, whether this Site (or another) **manages** it, and, if this Site manages it, where it sits in this Site's cluster and zone model:

| Term | Description | Site-tracked? | Site-managed? | Cluster member? | Zone | Example |
|---|---|---|---|---|---|---|
| `node` | A workload that's a full member of this Site's own cluster. | Yes | this Site | Yes | local zone (e.g. `mgmt`) | reference 2-3 node install |
| `standalone` | Part of this Site, but stands on its own outside the cluster. | Yes | this Site | No | local zone (e.g. `mgmt`) | a PBS + witness node outside the cluster |
| `satellite` | This Site's own outpost beyond the local zone, reachable only through a tunnel — the entry point for reaching this Site from outside. | Yes | this Site | No | dedicated `edge` zone (tunnel-only) | ADR-010 VPS |
| `external` | Tracked but not managed by this Site. | Yes | No | n/a | n/a | pre-migration Proxmox VM/LXC; third-party push-in; a pre-existing local PBS (#456) |
| `remote` | Lives at a different, independently-managed TAPPaaS Site. | Yes | another Site | n/a | n/a | `remote/<name>` buddy's PBS (§1.4); dev Site vs prod Site |
| `rogue` | Neither tracked nor managed by this Site. | No | No | n/a | n/a | undiscovered workload |

`node`/`standalone` also carry an orthogonal `-pending` status (storage not yet provisioned) — this is what `shim` maps onto, not a 5th peer value.

**The `external` case worth spelling out:** an operator with a working Proxmox cluster who wants to adopt TAPPaaS doesn't have to migrate everything at once. They back up their existing VMs/LXCs, install TAPPaaS, and restore. Until each workload is migrated onto `node`/`standalone`/`satellite` canon, TAPPaaS's only job is to *recognise it exists* (`external`) — enough to avoid resource conflicts, nothing more. `external` can never itself be a cluster member: cluster membership is the compliant end-state it migrates toward. **#456's pre-existing local PBS is precisely an `external` workload the backup module consumes** (§1.3).

This vocabulary already lines up with this ADR: `satellite` is ADR-010's role, and `remote`/`external` reuse the exact PBS namespace names from §1.4. Whether and how the two should converge — e.g. `shim` mapping onto the taxonomy's `-pending` status rather than being its own policy value — is left for the future dedicated ADR, not decided here.
