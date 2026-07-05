# ADR-012 Implementation — Plan, Decisions & Tracker

**Companion to:** [ADR-012 — Backup Enhancement](../ADR/ADR-012-backup-enhancement.md) (the *why* + the decided design)
**Purpose of this doc:** a single place that (1) records **implementation-level decisions**, (2) breaks the work into **packages** with deliverables/dependencies/test-criteria, and (3) **tracks live execution state** — status, tests, commits — per package.
**Status:** Planning (ADR still `Draft`; no package started)
**Branch:** `ADR007` — the `backup-manager` / `backup-controller` this ADR extends exist **only** on `ADR007` (see [Relationship to ADR-007 & ADR-010](#relationship-to-adr-007--adr-010--build-sequencing))
**Started:** 2026-07-04

> Modeled on [ADR-010-implementation.md](ADR-010-implementation.md) — one document, because ADR-012 is a single self-contained capability (backup-module behaviour), not a multi-ADR taxonomy.

---

## How to read this doc

- **[Decisions log](#decisions-log)** — every decision that constrains the build, with a pointer to the ADR section that made it. Append a row when a new implementation choice is settled; never silently contradict the ADR.
- **[Implementation packages](#implementation-packages)** — P1…P9, the *what* of each package (deliverables + dependencies + test criteria).
- **[Package tracker](#package-tracker)** — live execution state; a row is **not done** until it passes the gate below.
- **[Open questions](#open-questions)** — the mechanical leftovers still to settle.
- **[Package logs](#package-logs)** — append-only narrative per package.

### Convention: `config/` means the target system, not the repo

As in ADR-007/010: `config/backup.json`, `config/remote-<name>.json`, `config/external-<name>.json` refer to **`~tappaas/config/` on `tappaas-cicd`** (operator/runtime state) — **not** files committed to the repo. The repository ships only **schemas**, **service templates** (`backup/services/*/`), **scaffolding**, and **test fixtures**.

### Package gate (Definition of Done)

A package is done only when:

1. **Plan** — decompose it; identify the `test.sh` in scope (existing + new); list the issues it closes.
2. **Implement** — specialist agents per CLAUDE.md routing (architect / bash-dev / typescript-dev / infra / tester / security).
3. **Validate** — `bash-script-validator` (ShellCheck + security) on every changed script; `tsc --noEmit` on changed TS.
4. **Deep test** — run existing + new `test.sh` (deep/regression mode), backgrounded per the long-task rules. Record pass/fail counts.
5. **Gate** — ALL green → commit (`Closes #NNN`) → push. ANY red → stop-the-line, log here, fix, re-test. Do **not** advance.

**Status legend:** ⬜ not started · 🟦 in progress · 🧪 testing · ✅ done (green, committed, pushed) · 🟥 blocked/red

---

## Relationship to ADR-007 & ADR-010 & build sequencing

**Decision (2026-07-04): implement ADR-012 on `ADR007`, alongside ADR-010.**

ADR-012 changes the **`backup` module** and its `tappaas-cicd` control surfaces. Both worlds it touches exist only on the ADR-007 branch, and one integration point is the ADR-010 satellite:

| ADR-012 touch-point | On `main` (pre-ADR007) | On `ADR007` (the target world) |
|---------------------|------------------------|--------------------------------|
| Backup config/policy | `backup-manage.sh` only | **`backup-manager`** (cascade resolve/status) + **`backup-controller`** (live PBS) |
| Off-site pull/push credentials | ad-hoc | `backup/services/remote/` (pull) + `backup/services/external/` (push), namespaces (#227) |
| Satellite as a PBS peer | n/a | **ADR-010** satellite PBS (pull role today) — ADR-012 makes it a symmetric pull/push peer |
| Placement / node discovery | hard `node:tappaas3`/`storage:tankc1` in `backup.json` | policy-driven (`auto`/`node:`/`shim`/`remote-only`) |

- **Depends on ADR-007** for the manager/controller split (P6–P8 extend those components).
- **Integrates with ADR-010** for the satellite peer: `satellite-manager` provisions the node; ADR-012's `backup-*` drive the backup logic on it. ADR-010 P6 (satellite backup role) and ADR-012 P4/P6 are the two sides of the same seam — coordinate so the satellite's pull-from-home and its push-receive-from-single-node share one credential path.
- **#382 (client reconcile) is independent** of both — it only needs the cluster + a live PBS, so it is the shippable quick win (P3) and does not wait on the rest.

**Additive-first.** New placement logic and the shim are additions to `backup/install.sh`/`update.sh`; the credential unification consolidates existing templates rather than inventing new ones. This keeps collision with the in-flight ADR-007/010 branches low.

---

## Decisions log

Decisions already made in the ADR (the build must honour these). Implementation-level decisions get appended here with a date.

| # | Decision | Source |
|---|----------|--------|
| D1 | **Placement is policy, not literals** — `backup.json` carries `auto` \| `node:<name>` \| `shim` \| `remote-only`, replacing the hard `node`/`storage`. `auto` discovers `tankc` (configured node first, then any node) and installs PBS there; **if no `tankc` is found anywhere, `auto` falls back to `shim`** (never fails the install). So `shim` is both an explicit policy and `auto`'s no-storage outcome. | [ADR §1 / §1.1](../ADR/ADR-012-backup-enhancement.md) |
| D2 | **Shim when no `tankc`** — no PBS VM; a flagged JSON/marker satisfies `dependsOn: backup`; a warning is emitted. Promotable in place later. | ADR §1 |
| D3 | **Shim promotion is idempotent + dependency-safe** — `update-module.sh backup` promotes shim → local / remote-only / local+satellite with no dependent reinstall. | ADR §1, §4.2 |
| D4 | **Per-node client install is an idempotent reconcile** keyed on *current* cluster membership, **owned by `update.sh`** (not one-shot at PBS-install). Heals a later-added node (#382). | ADR §2 |
| D5 | **Every PBS is a symmetric peer** — pull replicator (`remote/<name>`) *and* push receiver (`external/<name>`) on one datastore, namespace-partitioned (#227). The satellite is **not** pull-only. | ADR §3.1 |
| D6 | **Unified credential model** — same setup for local/satellite/remote: pull = read-only token (`readAuthId`, prompt-not-store); push-receive = `<name>@pbs` scoped `DatastoreBackup` (write-no-delete); `encryptionRequired: true`; no secrets in JSON. | ADR §3.2 |
| D7 | **Pull is the default off-site shape** whenever a local PBS exists (structural compromise isolation — local holds no delete credential to the remote). | ADR §3.3 |
| D8 | **`remote-only` push for single-node** — no local PBS ⇒ push direct to satellite/remote is the only option; append-only hardening is **mandatory** there. | ADR §3.4 |
| D9 | **Push must be append-only at the remote** — write-no-delete credential; remote-owned prune; immutability (S3 Object Lock / remote ZFS snapshots); client-side encryption at the source. | ADR §3.5 |
| D10 | **Subset + independent retention** — off-site job selects a subset of namespaces/VMs and runs its own (typically longer) retention, owned by the destination. | ADR §3.6 |
| D11 | **`backup-controller` must be PBS-endpoint-agnostic** — the target PBS is a parameter, not a hardcode; same ops drive local and satellite PBS (only endpoint + credential differ). `backup-manager` owns placement/peers/subset/retention in the cascade. | ADR §5 |
| D12 | **Division of labour with ADR-010** — `satellite-manager` provisions the node/tunnel/PBS; `backup-manager`/`backup-controller` control the backup logic on it via the unified credentials. `backup-manage.sh` stays the thin operator CLI. | ADR §5, §3.7 |
| D13 | **Build on `ADR007`, coordinate the satellite seam with ADR-010.** #382 (P3) is independent and shippable first. | [Relationship](#relationship-to-adr-007--adr-010--build-sequencing) (2026-07-04) |

---

## Implementation packages

Nine packages, mirroring the ADR [Implementation Plan](../ADR/ADR-012-backup-enhancement.md#implementation-plan-phased). Each lists **deliverables**, **depends-on**, and **test criteria** (the `test.sh` cases that gate it).

### P1 — Placement policy + shim (#402) · D1, D2

- **Deliverables:** add the placement-policy field to `backup.json` + `schemas` (`module-fields.json` or a backup-specific schema); `install.sh` discovers a `tankc` pool (configured node → any node), installs PBS where found, else writes a flagged shim marker + warning; placement state recorded idempotently and inspectable.
- **Depends on:** ADR-007 backup module structure (present on `ADR007`).
- **Test criteria:** with `tankc` → PBS on the right node; no `tankc` → shim created (no VM), warning emitted, a `dependsOn: backup` module still installs; policy round-trips through the schema validator.

### P2 — Shim promotion (#402) · D3

- **Deliverables:** `update-module.sh backup` (via `update.sh`) promotes a shim to a real datastore once a `tankc` appears, preserving `dependsOn: backup` consumers; promotion is a placement-policy change, not a teardown.
- **Depends on:** P1.
- **Test criteria:** add `tankc` + re-run `update.sh` → shim becomes a real PBS and the dependent module still works; re-running is a no-op.

### P3 — Per-node client reconcile (#382) · D4  *(independent quick win)*

- **Deliverables:** factor the per-node `proxmox-backup-client` install into an idempotent step keyed on current cluster membership; wire into `update.sh`; reference from the `cluster` module's node-add flow.
- **Depends on:** nothing (only a live cluster + PBS).
- **Test criteria:** add a node after backup is installed → `update-module.sh backup` installs the client on the new node only; re-running is a no-op; a VM on the new node backs up.

### P4 — Push / remote-only path (#402, #389) · D8, D9

- **Deliverables:** a local→remote push job with a **write-no-delete** credential; remote-owned prune; `remote-only` placement wiring (no local datastore); single-node bootstrap flow (§4.1).
- **Depends on:** P1 (policy), P6 (credentials), coordinate with ADR-010 P6 (satellite as push receiver).
- **Test criteria:** a `remote-only` single node pushes directly to a remote/satellite and restores from it; the push credential **cannot** delete/prune the remote namespace.

### P5 — Immutability + subset/retention (#389) · D9, D10

- **Deliverables:** enforce append-only / Object Lock (or remote ZFS snapshots) on the push target; subset selector + independent off-site retention in the remote/push job config.
- **Depends on:** P4; ADR-010 §7.3 backend (S3 Object Lock) for the satellite case.
- **Test criteria:** off-site job replicates only the selected subset with a different (longer) retention; deleting a retention-locked off-site chunk is refused even with elevated remote credentials.

### P6 — Symmetry + unified credentials (§3.1/§3.2) · D5, D6

- **Deliverables:** confirm/enable any PBS as both pull replicator and push receiver on one datastore (namespace-partitioned); consolidate `remote.json`/`external.json` as the single credential path for local, satellite, and remote peers; ensure secrets are prompt-not-store in all three cases.
- **Depends on:** existing #227 namespace machinery (present).
- **Test criteria:** a satellite PBS simultaneously *pulls* the home PBS and *receives a push* from a single-node site, in separate namespaces; peer onboarding uses the *same* flow regardless of peer type.

### P7 — Tooling: manager/controller (§5) · D11, D12

- **Deliverables:** extend `backup-manager` with placement policy, off-site peers, subset and per-peer retention in the Site→Env→Module cascade; make `backup-controller` **PBS-endpoint-agnostic** (target PBS a parameter) so it drives local and satellite PBS identically; keep `backup-manage.sh` as the thin operator CLI over the same controller ops.
- **Depends on:** P1, P4, P6; ADR-007 manager/controller contract; ADR-010 `satellite-manager`.
- **Test criteria:** `backup-controller` performs the same op (register a pull remote / issue a push credential) against the local PBS and a satellite PBS with only endpoint+credential differing; `backup-manager status`/`resolve` reflect placement + off-site peers.

### P8 — Bootstrap & promotion wiring (§4) · D3

- **Deliverables:** wire the placement policy into the bootstrap flow (`install.sh` §4.1); make promotion (§4.2) reachable via `update-module.sh backup` for shim → local / remote-only / local+satellite.
- **Depends on:** P1, P2, P4, P7.
- **Test criteria:** `shim → remote-only` and `shim → local+satellite` via a placement-policy change + `update.sh`; dependents keep working throughout.

### P9 — Hardening & docs (#389)

- **Deliverables:** the compromise-isolation test suite (pull/push/immutability/simulated-compromise); `QUICKREF.md` + `TEST.md` updates; advance ADR status **Draft → Proposed** after operator review.
- **Depends on:** P4, P5, P7.
- **Test criteria:** all §Testing "compromise isolation" cases pass; restore-from-off-site succeeds **with** the key and fails **without** it.

---

## Package tracker

Live execution state. A row is **not done** until it passes the [package gate](#package-gate-definition-of-done).

| P | Package | Issues | Status | Tests | Commit | Notes |
|---|---------|--------|--------|-------|--------|-------|
| P1 | Placement policy + shim | #402 | ✅ | offline 20/0 + **live** | (this commit) | live-verified on tappaas1 (no tankc → shim) |
| P2 | Shim promotion | #402 | ✅ | **live** rc=0 | (this commit) | live shim→local promotion green on tappaas1 |
| P3 | Per-node client reconcile | #382 | ✅ | offline 4/0 + **live** | (this commit) | reconcile runs on install+update, idempotent |
| P4 | Push / remote-only path | #402, #389 | 🧪 | offline 3/0 | (slice 1) | code done; live pending 3-node cluster |
| P5 | Immutability + subset/retention | #389 | 🧪 | offline 7/0 | (slice 2) | code done; ZFS-snapshot + group-filter live pending cluster |
| P6 | Symmetry + unified credentials | §3.1/§3.2 | 🧪 | offline | (slice 1) | push leg added → pull+receive+push all exist |
| P7 | Tooling: manager/controller | §5 | ⬜ | — | — | `backup-controller` → endpoint-agnostic |
| P8 | Bootstrap & promotion wiring | §4 | 🧪 | offline | (slice 1) | remote-only wiring done (folded into P4) |
| P9 | Hardening & docs | #389 | ⬜ | — | — | flips ADR → Proposed |

> **Discovery (2026-07-05, from reading the code):** P6's symmetry is **already ~80% built** by #227 — `pbs-namespace.sh` is a complete idempotent toolbox (namespace/remote/sync-job/prune-job/acl/user), `services/remote/` does Class A **pull** and `services/external/` does Class B **push-receive**, both with the prompt-not-store credential model. The only missing leg of the symmetry is this cluster **pushing out** (the mirror of external-receive) → **P4 `services/push/`**. Slices: **(1) P4+P6+P8** push/remote-only + symmetry; **(2) P5** subset/retention + immutability; **(3) P7** tooling; **(4) P9** hardening/docs. Live testing of all deferred to the incoming 3-node + tankc cluster.

**Suggested order:** **P3** (independent quick win) → **P1 → P2** (placement/shim) → **P6** (unify credentials) → **P4 → P5** (push/off-site) → **P7** (tooling) → **P8** (bootstrap/promotion) → **P9** (hardening/docs).

---

## Open questions

Mechanical leftovers to settle during the build (none block the design):

1. **Schema home for the placement policy** — extend `schemas/module-fields.json`, or a dedicated `backup-fields.json`? (Lean: a backup-specific schema, mirroring `satellite-fields.json`.)
2. **Shim marker representation** — a `status: "shim"` field in `backup.json`, a separate state file, or a `provides` variant? Must be recognizable by the dependency resolver and by `update.sh` promotion.
3. **`node-add` auto-call vs documented follow-up** — does the `cluster` node-add flow call `update-module.sh backup` automatically, or is it a documented required step? (ADR left this to implementation.)
4. **Subset selector syntax** — namespace list, VM-tag match, or explicit VMID list in the remote/push job config.
5. **`backup-controller` endpoint parameter** — CLI flag (`--pbs <host>`) vs a resolved peer config; how the tunnel host for a satellite is threaded in.
6. **`remote-only` restore ergonomics** — single-node DR pulls back from the remote/satellite; confirm `restore.sh` works against a non-local source without a local datastore.

---

## Package logs

Append-only narrative per package. Add an entry when a package starts, blocks, or completes.

### 2026-07-04 — Planning
- ADR-012 drafted (symmetric peers, unified credentials, placement policy, bootstrap/promotion, manager/controller tooling); cross-linked with ADR-010; issues #402/#389/#382 annotated.
- This tracker created. No package started. Branch `ADR007`.
- Sequencing decided: P3 first (independent), then placement/shim, credentials, push/off-site, tooling, bootstrap, hardening.

### 2026-07-04 — P1 + P2 + P3 implemented (offline-green; deep/live pending)
- **New libs:** `backup/lib/pbs-placement.sh` (placement policy, tankc discovery, shim state read/write) and `backup/lib/pbs-client.sh` (idempotent per-node client reconcile).
- **P1** — `backup.json` gains `placement` (`auto` default); `install.sh` resolves placement up front and branches: `local` → realize PBS on the discovered `tankc` node; `shim` (or `auto` finds no tankc) → write a `placementState:"shim"` marker + warning and exit 0 (no VM); `remote-only` → record marker (push wiring is P4). Resolved node/storage + `placementState` written back to `config/backup.json`. Schema (`module-fields.json`) gains `placement` + `placementState`.
- **P2** — `update.sh` promotes a `shim` → `local` in place when the configured policy now resolves to a tankc (re-execs the idempotent `install.sh`); an explicit `shim` policy stays a shim; **empty state (legacy pre-ADR-012 installs) is backfilled to `local`, never promotion-reinstalled.** Dependent `dependsOn:backup` modules are untouched.
- **P3** — the one-shot client loop is now `pbs_client_reconcile`, keyed on *current* cluster membership, called by **both** `install.sh` and `update.sh` — so `update-module.sh backup` installs the client on a node added later (#382). Per-node idempotent (skips when `dpkg -s proxmox-backup-client` present); warns (not dies) per unreachable node.
- **Shim guards:** `services/vm/{install,update}-service.sh` degrade gracefully under a shim (dependents install; the VM is registered once promoted).
- **Tests:** new `lib/test-pbs-placement.sh` (20) + `lib/test-pbs-client.sh` (4); full `backup/test.sh` **46/0 offline**. `bash -n` clean on all changed scripts; IDE shellcheck clean (only the universal SC1091 "can't follow /home/tappaas/bin" info). shellcheck CLI not installed in this env — run it on cicd before the gate.
### 2026-07-05 — P1/P2/P3 LIVE-verified on tappaas1 (single-node)
Tested on the single-node cluster `tappaas1` (a broken backup pinned at the non-existent `tankc1`; `logging`+`identity` updates were failing on the `backup:vm` post-update test). Deployed the working-tree files to `tappaas-cicd` and ran end-to-end:
- **Teardown** — removed the broken PBS (datastore, storage, package, orphan `/tankc1`) via the `uninstall.sh --only pbs` steps. Left only `tanka1`.
- **P1 (shim)** — `install-module backup --force` → *"No usable 'tankc' pool found (policy auto) — installing backup as a SHIM"*, `placementState:"shim"`, rc=0.
- **Shim guards** — `update-module logging` → **green** (the `backup:vm` test-service now skips under a shim instead of the previous fatal *"PBS storage not configured"*). `update-module identity` clears the backup gate too (its remaining failure is an unrelated `network:proxy` HTTPS 000).
- **Gap found live #1** — `services/vm/test-service.sh` also needed the shim guard (only install/update-service had it). **Fixed** + redeployed.
- **P2 (promotion)** — created a file-backed `tankc1` zpool (test artifact) + `pvesm add`; `update-module backup` → detected shim, re-discovered `tankc1`, re-ran install.sh, **created datastore + user + prune/GC/verify jobs + storage + backup job**, post-tests green, rc=0; `placementState:"local"`.
- **Gap found live #2** — install.sh's non-interactive password used `openssl`, which is **not installed on tappaas-cicd** → silent empty password → PBS *"must be ≥8 characters"*. **Fixed**: `/dev/urandom`-based generator + a hard ≥8-char guard (`die`) so it can never silently proceed. This also hardens every non-interactive fresh install.
- **P3 (reconcile)** — `update-module backup` runs *"Reconciling proxmox-backup-client across cluster nodes (#382)"* on both install and update, idempotent (client already present → no-op).
- **Result:** all three packages green on hardware; two real bugs caught and fixed that offline tests could not have surfaced.
- **Cleanup (operator decision):** reverted tappaas1 to the honest **shim** state — tore down the promoted PBS, destroyed the file-backed `tankc1` test pool + image, reinstalled backup (`auto` → shim), confirmed `logging` still updates green. The node now correctly reflects "no backup-tier storage → shim" until a real `tankc` disk is added. cicd checkout aligned to the pushed commit (`477e6a2`); operator's `resolve-module.sh` WIP preserved.

### 2026-07-05 — Slice 1: P4 + P6 + P8 implemented (offline-green; live pending cluster)
- **P4 (push / remote-only)** — new `lib/pbs-push.sh` (register a remote PBS as a Proxmox `pbs` storage `offsite-<name>`, idempotent, %q-safe creds) + `services/push/{push.json,install-service.sh,delete-service.sh}` (the mirror of external-receive: WE push, write-no-delete, remote owns prune/retention). `backup-manage.sh` gains `add-push`/`remove-push` and shows push targets in `list-sources`. When a push target is `--make-default`, install-service sets `.pbsStorageName` to the push storage so the existing pbs-job.sh machinery (alwaysBackup + dependsOn:backup:vm) routes the opted-in VMs off-site. Schema gains `pushTarget`.
- **P8 (remote-only wiring)** — install.sh's `remote-only` branch records placement and guides `add-push` onboarding (the push credential is prompt-not-store, so it is an operator step, never an unattended hang).
- **P6 (symmetry + unified credentials)** — with the push leg added, all three off-site roles now exist on one PBS: **pull** (`add-remote`/Class A), **receive** (`add-external`/Class B), **push** (`add-push`, new). All share the prompt-not-store credential model and the §3.5 write-no-delete / remote-owned-prune invariant. Confirmed the mechanism; the operator-facing consolidation doc is P9.
- **Tests:** new `lib/test-pbs-push.sh` (3); `backup/test.sh` **49/0 offline**; all changed scripts `bash -n` clean; JSON valid.
- **Not yet:** live test on the 3-node cluster (push a VM off-site to a real remote PBS, verify write-no-delete + remote-owned prune). Deferred to the incoming cluster.
- **Remaining:** **P7** (endpoint-agnostic — **TS layer**, operator decision 2026-07-05), **P9** (compromise-isolation test suite, QUICKREF/TEST, ADR → Proposed).

### 2026-07-05 — Slice 2: P5 (subset + independent retention + immutability) offline-green
- **Subset (#389 "back up only a subset")** — `pbs_syncjob_ensure` gains an optional PBS **group-filter** (9th arg); `services/remote/install-service.sh` reads `.groupFilter` (string or array) from `remote-<name>.json` and passes it, so a remote/satellite pull can replicate only part of the source (e.g. `type:vm` or specific groups). `remote.json` template documents it.
- **Independent retention** — already present (each `remote-<name>.json` / `external-<name>.json` carries its own `retention` → an admin-owned, namespace-scoped prune-job, destination-owned). Confirmed; no code change needed.
- **Immutability (§3.5 / ADR-010 §7.3)** — new `lib/pbs-immutable.sh`: opt-in **ZFS-snapshot** WORM tier. When `backup.json .immutableSnapshots.enabled`, install/update deploy a systemd timer on the PBS node that takes read-only `@immutable-<ts>` snapshots of the datastore dataset and prunes to `keep`. History can't be rewritten by a sync/push credential holder or PBS prune/GC — only node-local root (the documented weaker tier; **S3 Object Lock stays the satellite/ADR-010 stronger tier**, provisioned satellite-side, out of module scope). Schema gains `immutableSnapshots`.
- **Tests:** new `lib/test-pbs-immutable.sh` (7 — dataset derivation + OnCalendar mapping); `backup/test.sh` **56/0 offline**.
- **Live pending (3-node):** group-filter pull subset, and the ZFS-snapshot timer (needs a real ZFS datastore) — deferred to the cluster.
