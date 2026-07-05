# ADR-012 — Backup Enhancement

| | |
|---|---|
| **Status** | Draft |
| **Version** | 0.1 |
| **Date** | 2026-07-04 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#402** (flexible backup install on a cluster — origin); **#389** (remote/off-site backup setup + single-node); **#382** (adding a node does not install the backup client); [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (satellite off-site backup, pull model, compromise isolation); [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (named, not numbered foundation modules); [backup/QUICKREF.md](../../src/foundation/backup/QUICKREF.md) (PBS namespaces, multi-source pull/push — #227) |
| **Implementation** | [ADR-012-implementation.md](../design/ADR-012-implementation.md) — plan, decisions log, package tracker |
| **Changelog** | v0.1 — skeleton + Context, three decisions drafted; expanded with symmetric peers (§3.1), unified credentials (§3.2), placement policy detail (§1.1), bootstrap/promotion (§4), and manager/controller tooling (§5); implementation tracker started (Lars, 2026-07-04) |

Make the `backup` foundation module flexible about **where PBS lives** (or whether it lives in the cluster at all), keep the **per-node backup client** in step with cluster membership, and give **off-site/remote backup** real setup, subsetting, and independent retention — without ever letting a compromised local cluster reach the off-site copy.

---

## Context

The current [`backup`](../../src/foundation/backup/) module makes three assumptions that hold for the reference three-node cluster but break for the deployments TAPPaaS now targets (single node, two node, no suitable `tankc`, off-site-only). All three are captured in open Release-1.2 issues.

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

This ADR decides the model for all three. It builds on ADR-010 (which owns the *satellite node itself*); ADR-012 is about the **`backup` module's behavior and configuration** that make ADR-010's pull target, and the simpler push/single-node cases, usable.

---

## Decision

### 1. Flexible PBS placement + a `backup` shim (#402)

`install.sh` stops assuming `tappaas3`/`tankc1` and instead **discovers** where in-cluster PBS should live, in this order:

1. **`tankc` on the configured node** (default `tappaas3` if it exists) → install PBS there (today's behavior, now conditional).
2. **`tankc` on any other node** → install PBS on that node.
3. **No suitable `tankc` anywhere** → **do not create the PBS VM.** Instead install a **shim `backup` module**: JSON/marker only, no VM, flagged so it is recognizable as a shim. Emit a **warning**.

The shim exists so the dependency graph stays satisfiable: modules that `dependsOn` `backup:vm` (or `backup:remote`) can still install against the shim. The shim `provides` the same capability names but records that no datastore is realized locally — a module that hard-requires a live datastore surfaces that at test time, not install time.

**Reinstallability is a first-class requirement.** A shim (or a full PBS) must be **upgradeable in place later** — once a `tankc` pool appears, `update-module.sh backup` (or a re-run of `install.sh`) promotes the shim to a real PBS **and existing modules with `dependsOn: backup` keep working** without reinstall. Placement and shim state live in `backup.json` (or a generated state file) so the decision is inspectable and idempotent.

#### 1.1 Storage/node selection — the placement policy

Placement is expressed as config, not code: `backup.json` gains an explicit **placement policy** replacing the current hard `node`/`storage` literals.

| Policy | Meaning | Local PBS datastore | Where backups land | Typical site |
|---|---|---|---|---|
| `auto` (default) | discover a `tankc` pool (configured node first, then any node) and install PBS there; **falls back to `shim` if no `tankc` is found** | yes (else shim) | local, optionally replicated off-site | reference 2–3-node cluster |
| `node:<name>` | pin PBS to a named node's `tankc`, overriding discovery | yes | local (+ optional off-site) | operator wants a specific node |
| `shim` | no datastore — JSON/marker only, flagged as a shim; still satisfies `dependsOn: backup` | no | none yet (promote later, §4) | first boot, before storage exists |
| `remote-only` | no local PBS at all; back up **directly to a satellite/remote PBS** by push (§3) | no | off-site only | single-node / no room for local PBS |

**Relationship to the satellite (ADR-010).** The satellite is just *another PBS instance* to the module — its placement is orthogonal to the local policy:

- `auto`/`node:` **+ a satellite** → classic **3-2-1**: a local datastore *plus* the satellite **pulling** it off-site (ADR-010's pull role). The satellite holds the off-site copy; the local side holds no credential to it.
- `remote-only` **+ a satellite** → single-node/small site with **no local datastore**; the local side **pushes** straight to the satellite (or any remote PBS). The satellite is then the *only* copy, so its append-only hardening (§3.5) is mandatory.
- `shim` → a placeholder that becomes either of the above once storage or a satellite exists (§4).

### 2. Node-join reconciles the backup client (#382)

Installing the per-node `proxmox-backup-client` becomes an **idempotent reconcile**, not a one-shot at PBS-install time:

- The client-install loop is factored into a reusable step that **enumerates the *current* cluster membership** and installs the client on any node missing it.
- **`update-module.sh backup` runs this reconcile**, so the routine update flow heals a cluster whose membership grew. Running it repeatedly is a no-op on nodes that already have the client.
- The [`cluster`](../../src/foundation/cluster/) module's node-add flow references this: adding a node is not complete until `update-module.sh backup` has provisioned its client. (Whether the node-add flow calls it automatically vs. documents it as a required follow-up is settled in implementation; the decision here is that **the reconcile exists and is owned by `update.sh`.**)

### 3. Off-site backup — symmetric peers, unified credentials, compromise isolation (#389, #402)

Off-site backup is **not one mechanism**. The direction (pull vs push) is chosen by *who holds delete rights*, driven by the compromise-isolation invariant, not convenience — but the *pieces* (a PBS instance, a namespace, a credential) are the **same** everywhere.

#### 3.1 Every PBS is a symmetric backup peer — pull replicator *and* push receiver

Whether it is the **local** `backup` module, a **satellite** PBS (ADR-010), or a plain **remote** PBS, every TAPPaaS PBS instance can play **both** roles on the same datastore, partitioned by namespace (#227):

| Role | Namespace | Direction | Delete rights |
|---|---|---|---|
| **Pull replicator** (Class A) | `remote/<name>` | this PBS *pulls* another PBS's backups in | this PBS (destination); `--remove-vanished false` |
| **Push receiver** (Class B) | `external/<name>` | another node *pushes* its backups in | this PBS (receiver); pusher has write-no-delete |
| Local VM backups | root | this cluster's own VMs | local |

So the satellite is **not** a special "pull-only" target: a satellite PBS can *pull* the home PBS (the ADR-010 role) **and** *receive pushes* from a single-node site that has no local PBS (§3.4) — simultaneously, in different namespaces. Likewise the local `backup` module can *receive* a buddy's push while *pulling* from its own satellite. This symmetry is exactly what lets one small set of tooling (§5) cover every topology.

#### 3.2 Unified credential model — same setup for local, satellite, or remote

**The credential setup is identical regardless of which PBS is the peer** (as far as PBS allows). It already exists in the module as two service templates — [`remote.json`](../../src/foundation/backup/services/remote/remote.json) (pull) and [`external.json`](../../src/foundation/backup/services/external/external.json) (push receive); this ADR makes them the *single* path for local, satellite, and remote alike:

- **Pull (Class A):** the *destination* holds a **read-only** API token (`Datastore.Read`/`Audit`) on the *source* PBS — `readAuthId` in `remote.json`, prompted at onboarding and **never stored in the JSON**. Same whether the source is a buddy's PBS or (satellite case) the home PBS.
- **Push receive (Class B):** the *receiver* issues the pusher a `<name>@pbs` login with the **`DatastoreBackup` role scoped to one namespace** (write, no delete) — `external.json`. Same whether the receiver is the local PBS, a satellite, or a rented remote PBS.
- **Encryption:** `encryptionRequired: true` on both — the data-owner's key encrypts before transit; the peer stores ciphertext and never holds the key.
- **No secrets in config:** the JSON carries host/store/namespace/retention/schedule only; API auth-ids and passwords are prompted at onboarding and live in `/etc/secrets` (TAPPaaS convention), so the *same* config file is safe whether it points at a buddy, a satellite, or a remote.

The one unavoidable variance: a satellite reached over the ADR-010 WireGuard tunnel uses the tunnel address as `remoteHost`; a public remote PBS uses its public host. The *credential mechanics* (read-only token vs scoped DatastoreBackup, prompt-not-store, client-side encryption) do not change.

#### 3.3 Two off-site shapes, one invariant

| Shape | Who initiates | When to use | Delete rights held by |
|---|---|---|---|
| **Pull** (preferred — ADR-010 Class A) | the **remote/satellite** pulls the local PBS | there is a local PBS to pull *from*, and a remote PBS/satellite to pull *into* | the **remote** only |
| **Push** (#402) | the **local** side pushes to a remote target | **single-node / no in-cluster PBS**, or the operator explicitly wants no local datastore | see §3.5 — must be **append-only** at the remote |

**Invariant (the #389 headline requirement):** *a compromise of the local system must not be able to delete, encrypt, or tamper with the off-site copy.* Pull satisfies this structurally — the local side holds no credential to the remote (ADR-010 §3.1, §7.2). **Pull is therefore the default whenever a local PBS exists.**

#### 3.4 Single-node / remote-only (#389)

When there is no second node and no room for in-cluster PBS (placement policy `remote-only`, §1), the local site **has no PBS to be pulled from**, so pull is not available and **push is the only option**. This is the single-node case from #389's follow-up: back up **directly to a remote/satellite**. Because push hands the local side a write path to the remote, §3.5's append-only hardening is **mandatory** here, not optional.

#### 3.5 Making push safe — append-only / immutable at the remote

A naive push (local holds full read-write-delete on the remote datastore) **violates the invariant** — ransomware on the local node would delete the off-site copy too. Push is only sanctioned with **append-only semantics at the remote**, mirroring the existing Class B `external/<name>` model (QUICKREF, #227) and ADR-010 §7.3:

- The local push credential has **write, no delete** (PBS `DatastoreBackup` role on its namespace only) — it can add snapshots but not remove them.
- **Retention/prune is owned by the remote**, on the remote's schedule — never driven by the local (compromised) side.
- Where the backend supports it, add **immutable history** (S3 Object Lock / WORM per ADR-010 §7.3, or remote-side ZFS snapshots) so even a stolen push credential can't rewrite the past.
- Backups are **client-side encrypted with the local key**; the remote stores ciphertext only and never holds the decryption key (ADR-010 §3.2).

#### 3.6 Subset + independent retention (#389)

The off-site copy need not mirror the local set 1:1:

- **Subset:** the off-site job (pull or push) selects a **subset** of the local backups/namespaces to replicate — e.g. only critical VMs off-site, everything locally. Expressed as a selector in the remote/push job config.
- **Independent retention:** the off-site copy runs its **own retention policy**, distinct from the local one it derives from — typically *longer* off-site (DR archive) than the churn-heavy local set. Because retention is **owned by the destination** (§3.3/§3.5), the two policies are naturally independent and the compromise invariant is preserved.

#### 3.7 Relationship to ADR-010

ADR-010 owns the **satellite node** (provisioning, tunnel, trust boundary) and specifies the satellite *pull* backup role. ADR-012 owns the **`backup` module** that exposes these as configuration: the pull remote registration (already `backup-manage.sh add-remote`), the new **push / remote-only** path for single-node sites, and the subset/retention selectors. A satellite deployment uses ADR-010 for the node and ADR-012's pull config; a single-node site with a plain remote PBS uses ADR-012's push path without a full satellite.

### 4. Configuring backup at bootstrap — and promoting a shim later

Backup is configured **once at bootstrap** and can be **re-pointed later without reinstalling** dependents. The flow is driven by the placement policy (§1.1).

#### 4.1 At bootstrap

1. `install.sh` reads `backup.json`'s placement policy.
2. **`auto` / `node:`** → discover `tankc`, create the PBS VM + datastore, install per-node clients (§2). Off-site (satellite pull / remote push) is added *afterward* as a peer (§3) — it is not required at bootstrap.
3. **`shim`** (or `auto` finds no `tankc`) → write the flagged shim marker, emit a warning, satisfy `dependsOn: backup`. No datastore yet.
4. **`remote-only`** → no local datastore; register the remote/satellite as a **push target** (§3.4) and wire the local push job. The remote PBS/satellite must exist first (or be provisioned via `satellite-manager`, ADR-010).

The single bootstrap knob is therefore the **placement policy** plus, for off-site, one peer config (`remote-*.json` / `external-*.json`, §3.2). Nothing about the peer type changes the bootstrap shape — the operator picks a policy, and optionally names a peer.

#### 4.2 Promoting a shim — to local, satellite, or remote

A shim is a **placeholder promoted in place**; existing `dependsOn: backup` consumers keep working (§1). Promotion is a config change followed by `update-module.sh backup`:

| From shim to… | Change | Effect of `update.sh` |
|---|---|---|
| **local PBS** | set policy `auto`/`node:` once a `tankc` exists | creates the datastore + per-node clients; the shim marker is replaced by a real datastore |
| **remote-only (push)** | set policy `remote-only`, add a push-target peer config | wires the local push job to the remote/satellite; still no local datastore |
| **local + satellite** | promote to local (above), then `satellite-manager install` + register the satellite as a **pull** peer | full 3-2-1 |

Because promotion is just a placement-policy change reconciled by `update.sh`, the **same command that heals node membership (§2) also advances backup from "shim" to any real shape** — no teardown, no dependent reinstall. This is the concrete answer to #402's "allow backup to be reinstalled later and ensure existing modules with `dependsOn` then work."

### 5. Tooling — `backup-manager`, `backup-controller`, and controlling the satellite

Backup is split along the standard TAPPaaS **manager/controller** line, so the *same two components* drive backup on the local PBS **and** on a satellite:

- **[`backup-manager`](../../src/foundation/tappaas-cicd/manager/backup-manager/)** — *owns config/policy.* It resolves the Site→Environment→Module backup-policy cascade (`resolve`, `status`) and owns the *desired* state: which modules are backed up, effective retention, residency (local vs off-site) and — extended by this ADR — **placement policy (§1), off-site peers (pull/push), subset selectors, and per-peer retention (§3)**. It is read-only over live PBS: it *decides*, then calls the controller to apply.
- **[`backup-controller`](../../src/foundation/tappaas-cicd/controller/backup-controller/)** — *owns runtime PBS state.* It talks to a live PBS — reusing the foundation PBS libs [`pbs-job.sh`](../../src/foundation/backup/lib/pbs-job.sh) / [`pbs-namespace.sh`](../../src/foundation/backup/lib/pbs-namespace.sh) — to create datastores/namespaces, add VMs to the managed job, apply schedules, register pull remotes, issue push credentials, and trigger verify/prune. It degrades gracefully when PBS is unreachable.

**How they control a satellite.** The controller must be made **PBS-endpoint-agnostic** — the PBS it acts on is a *parameter, not a hardcode* — so the *same* `backup-controller` operations target the local PBS or the satellite PBS; only the endpoint (tunnel host) and credential (§3.2) differ. Division of labour with ADR-010:

- **`satellite-manager` (ADR-010) provisions the *node*** — the VPS, the WireGuard tunnel, the PBS install, the datastore backend (S3 / volume). It stops at "a reachable PBS endpoint exists."
- **`backup-manager` / `backup-controller` (this ADR) drive the *backup logic* on it** — register the home PBS as a pull *source* on the satellite, or register the satellite as a push *target* for a `remote-only` site; create the `remote/<name>` / `external/<name>` namespace; set subset + retention; wire verify/prune — all via the unified credential model (§3.2).

One mental model results: **the satellite is provisioned by `satellite-manager`, then *controlled as just another PBS* by the same backup tooling** that controls the local datastore. The operator-facing [`backup-manage.sh`](../../src/foundation/backup/backup-manage.sh) verbs (`add-remote`, `add-external`, `list-sources`, …) are the thin CLI over the same controller operations, so onboarding a peer is the **same command** whether that peer is local, satellite, or remote.

---

## Consequences

### Positive

- **Backup installs on any topology** — three-node, two-node, single-node, or no-suitable-storage — without failing the dependency graph (§1 shim).
- **`dependsOn: backup` never blocks an install** even when no datastore is realized; the shim keeps the graph satisfiable and can be promoted later in place.
- **Adding a node no longer silently breaks its VMs' backups** — the client reconcile (§2) heals membership drift on the normal update cadence.
- **Off-site backup works for small sites** (single-node push, §3.4), not just clusters big enough to host PBS.
- **The compromise invariant is explicit and testable** — pull-by-default, append-only push, remote-owned retention, immutable history (§3.3/§3.5).
- **One model, every topology** — any PBS (local, satellite, remote) is a symmetric pull-and-push peer with **identical credential setup** (§3.1/§3.2), and the same `backup-manager`/`backup-controller` control the local datastore and a satellite alike (§5).
- **Reuse over invention** — leans on the existing #227 namespace/pull/push machinery, ADR-010's satellite, and PBS roles rather than new mechanisms.

### Negative / costs

- **More placement states to reason about** (`auto` / `node:` / `shim` / `remote-only`) and to test.
- **Shim → real-PBS promotion** is a new lifecycle transition that must be idempotent and dependency-safe.
- **Push introduces a local→remote credential** that must be provably delete-incapable; getting the append-only/immutability hardening wrong would silently break the invariant, so it needs adversarial testing (§Testing).
- **Two off-site directions** (pull/push) mean two code/test paths in the module.

### Neutral / assumptions

- Assumes PBS namespace + role model (#227) and ADR-010's satellite remain the substrate.
- Single-node push assumes a reachable remote PBS/satellite that supports append-only or Object Lock.
- Client-side encryption keys remain the operator's DR linchpin (ADR-010 §3.2/§7) — unchanged and out of scope here.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Skip `backup` entirely when no `tankc`** | Breaks every module that `dependsOn: backup` — the shim (§1) keeps the graph satisfiable instead. |
| **Fail install if `tappaas3`/`tankc1` absent** | Excludes single-node and non-reference topologies that Release 1.2 must support. |
| **Re-enumerate nodes only at PBS reinstall** | Still misses nodes added between reinstalls; §2 makes it part of the routine `update.sh` reconcile. |
| **Push with full read-write-delete to the remote** | Violates the #389 invariant — a compromised local node would delete the off-site copy. Only append-only push is sanctioned (§3.5). |
| **Only support pull (ADR-010) for off-site** | Leaves single-node / no-local-PBS sites with no off-site option; push (§3.4) fills that gap safely. |
| **Satellite as a pull-only target** | Wastes the symmetry — a satellite PBS is just another PBS and can also *receive* pushes (§3.1), which is exactly what a `remote-only` single-node site needs. |
| **Separate credential flow per peer type** (local vs satellite vs remote) | Triples the surface for no benefit — PBS tokens/roles are identical; one unified flow (§3.2) is simpler and less error-prone. |

## Implementation Plan (phased)

1. **Placement policy + shim (#402)** — add the `auto`/`node:`/`shim`/`remote-only` policy to `backup.json`; make `install.sh` discover `tankc`, install PBS where found, or lay down a flagged shim with a warning; record placement state idempotently.
2. **Shim promotion (#402)** — `update-module.sh backup` promotes a shim to real PBS once storage appears, preserving existing `dependsOn: backup` consumers.
3. **Client reconcile (#382)** — factor the per-node client install into an idempotent step keyed on current cluster membership; wire it into `update.sh`; reference it from the node-join flow.
4. **Push / remote-only path (#402, #389)** — add a local→remote push job with a **write-no-delete** credential; remote-owned prune; single-node `remote-only` wiring.
5. **Immutability + subset/retention (#389)** — enforce append-only / Object Lock (or remote ZFS snapshots) on push; add subset selector + independent off-site retention to the remote/push job config.
6. **Symmetry + unified credentials (§3.1/§3.2)** — confirm any PBS acts as both pull replicator and push receiver on one datastore (namespace-partitioned); consolidate `remote.json`/`external.json` as the single credential path for local, satellite, and remote peers.
7. **Tooling (§5)** — extend `backup-manager` with placement policy, off-site peers, subset and per-peer retention in the cascade; make `backup-controller` **PBS-endpoint-agnostic** so it drives the local and satellite PBS identically; keep `backup-manage.sh` as the thin operator CLI.
8. **Bootstrap & promotion (§4)** — wire placement policy into `install.sh`; make `update-module.sh backup` promote a shim to local / remote-only / local+satellite without dependent reinstall.
9. **Hardening & docs (#389)** — the compromise-isolation test suite (§Testing) + `TEST.md`/`QUICKREF.md` updates.

## Testing Strategy

- **Placement:** on a cluster with `tankc` → PBS installs on the right node; with no `tankc` → a **shim** is created (no VM), a warning is emitted, and a module that `dependsOn: backup` still installs; adding `tankc` + re-running `update.sh` **promotes** the shim and the dependent module still works.
- **Client reconcile (#382):** add a node after backup is installed; `update-module.sh backup` installs the client on the new node only; re-running is a no-op.
- **Off-site subset/retention (#389):** an off-site job replicates only the selected subset and applies a **different** (longer) retention than local.
- **Compromise isolation (the headline #389 tests):**
  - **Pull:** with the remote's read-only token, deleting/pruning the *local* datastore is denied.
  - **Push:** the local push credential can add a snapshot but **cannot delete or prune** the remote namespace; a delete attempt is refused.
  - **Immutability:** deleting/overwriting a retention-locked (Object Lock / snapshot) off-site chunk is refused even with elevated remote credentials.
  - A **simulated local-cluster compromise** cannot erase, encrypt, or rewrite the off-site history.
- **Restore:** a restore **from the off-site copy** to a clean PBS succeeds *with* the encryption key and fails *without* it.
- **Single-node (#389):** a `remote-only` single node backs up directly to a remote/satellite via push and restores from it.
- **Symmetry (§3.1):** a satellite PBS simultaneously *pulls* the home PBS and *receives a push* from a single-node site, in separate namespaces, on one datastore.
- **Unified credentials (§3.2):** onboarding a pull source and a push receiver uses the *same* flow (prompt-not-store token / scoped DatastoreBackup) whether the peer is local, satellite, or remote.
- **Tooling (§5):** `backup-controller` performs the same operation (e.g. register a pull remote, issue a push credential) against the local PBS and a satellite PBS with only endpoint/credential differing.
- **Bootstrap/promotion (§4):** `shim → remote-only` and `shim → local+satellite` via a placement-policy change + `update.sh`; dependents keep working throughout.

## Acceptance

- [ ] `backup.json` placement policy (`auto`/`node:`/`shim`/`remote-only`) implemented; `install.sh` discovers `tankc` and installs PBS or a flagged shim (with warning). *(#402)*
- [ ] Shim → real-PBS **promotion** via `update-module.sh backup` works and preserves `dependsOn: backup` consumers. *(#402)*
- [ ] Per-node client install is an **idempotent reconcile** owned by `update.sh`; a node added later gets its client. *(#382)*
- [ ] **Push / remote-only** off-site path implemented with a **write-no-delete** local credential and remote-owned retention. *(#402, #389)*
- [ ] Off-site **subset** selection + **independent retention** work. *(#389)*
- [ ] Any PBS (local, satellite, remote) works as **both** a pull replicator and a push receiver; peer onboarding is the **same** credential flow regardless of peer type. *(§3.1/§3.2)*
- [ ] `backup-controller` is **PBS-endpoint-agnostic** — same ops drive the local and satellite PBS; `satellite-manager` provisions the node, backup tooling controls the backup logic. *(§5)*
- [ ] A `shim` promotes to **local**, **remote-only (push)**, or **local + satellite** via a placement-policy change + `update-module.sh backup`, dependents intact. *(§4, #402)*
- [ ] **Compromise-isolation tests pass** — local compromise cannot delete/encrypt/rewrite the off-site copy; immutability holds. *(#389)*
- [ ] Restore-from-off-site proven **with** the key and fails **without** it.
- [ ] `QUICKREF.md` / `TEST.md` updated; status advanced **Draft → Proposed** after operator review.
