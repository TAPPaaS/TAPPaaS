# ADR-012 Implementation — Plan, Decisions & Tracker

**Companion to:** [ADR-012 — Backup Enhancement](../ADR/ADR-012-backup-enhancement.md) (the *why* + the decided design)
**Purpose of this doc:** a single place that (1) records **implementation-level decisions**, (2) breaks the work into **packages** with deliverables/dependencies/test-criteria, and (3) **tracks live execution state** — status, tests, commits — per package.
**Status:** **Complete.** P1–P9 (v0.2) and P10–P20 (v0.3) are implemented, offline-green and live-verified on the 3-node reference cluster; the ADR moved to **Accepted — implemented** on 2026-09-09. Two things are deliberately left open and named as such: a genuinely separate off-site PBS **host** (a satellite over a tunnel), which no single-site test can cover, and the §4.3 **relocation-by-pull** runbook, which is written but not rehearsed. See [v0.3 — remaining work](#v03--remaining-work-p10p20).
**Branch:** `main` — ADR-007 has landed; `backup-manager` / `backup-controller` and the named foundation layout are on `main`. (The v0.2 note below about building on `ADR007` is historical.)
**Started:** 2026-07-04 · **v0.3 planning:** 2026-09-09

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
| P7 | Tooling: manager/controller | §5 | ✅ | **cicd** TS 60/0 + ctrl 11/0 | (slice 3) | TS layer (operator choice) built + live-verified on cicd |
| P8 | Bootstrap & promotion wiring | §4 | 🧪 | offline | (slice 1) | remote-only wiring done (folded into P4) |
| P9 | Hardening & docs | #389 | 🧪 | docs done | (slice 4) | QUICKREF+TEST done; compromise-isolation suite + ADR→Proposed pending cluster/operator |
| P10 | Placement state (`placement` dropped, `external`, `pbsUrl`) | #402, #214 | ✅ | offline 67/0 + **live** | (working tree) | migrated live: `local` → `node:tappaas3`, job + storage.cfg byte-identical |
| P11 | Consume a pre-existing PBS | #456 | ✅ | offline 123/0 + **live** | (working tree) | live: consumed the site PBS by URL, 165 snapshots visible, torn down clean |
| P12 | Schema + `provides` + KI-1 normalizer | §2.7 | ✅ | mm 123/0, bm 26/0 + TS 77/0 | (working tree) | KI-1 was already fixed upstream — verified, not re-fixed |
| P13 | `backup:filesystem` capability | §3.1, #545 | ✅ | offline 203/0 + **live** | (working tree) | mothership `config/` captured, restored byte-identical, refused without the key |
| P14 | Schedule cascade + bucket jobs | §3.2 | ✅ | offline 172/0 + TS 116/0 + **live** | (working tree) | weekly/monthly bucket jobs created + moved + torn down live |
| P15 | Retire `alwaysBackup` via `integratesWith` | #501, #545 | ✅ | offline 134/0 + TS 82/0 + **live** | (working tree) | **found + fixed live: the mothership was never in the backup job** |
| P16 | Shape-based module discovery | #544 | ✅ | mm 123/0, bm 26/0 + TS 96/0 + **live** | (working tree) | 7 phantom modules gone; also fixed `reconcile`'s numeric-vmid blindness |
| P17 | Node-add triggers client reconcile | #382 §2.4 | ✅ | sm 11/0 + **live** | (working tree) | automatic step, non-fatal; verified in the installed binary |
| P18 | Foundation coverage + rehearsed recovery | #545 | ✅ | **live rehearsals** + runbook | (working tree) | firewall + mothership + config/ all restored and verified; 2 restore bugs found |
| P19 | Encryption-key export / import | §2.5.1 | ✅ | ctrl 18/0 + **live round trip** | (working tree) | export → media → import onto a fresh escrow, byte-identical |
| P20 | Migration + documentation + ADR acceptance | §4, §15 | ✅ | docs + ADR updated | (working tree) | 18/19 acceptance boxes; the two-PBS #389 half remains |

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

## Known issues / deferred fixes

Recorded here to fix later — each **needs a real GitHub issue first** to think through, because the fix touches shared infrastructure beyond ADR-012.

### KI-1 — reconcile emits false "orphan field" warnings for provider modules (backup)

**Symptom.** `update-module backup` (shim *or* local) prints ~9 warnings at "Step 0: Reconcile config":
```
[Warning] field 'placement' is usedBy=[backup:vm] but the module does not depend on any of them — kept at top level
[Warning] field 'pbsStorageName' / 'alwaysBackup' / 'backup' / 'placementState' … (same)
[Warning] field 'image' / 'imageType' / 'imageLocation' / 'storage' is usedBy=[cluster:vm,cluster:lxc] … (same)
```

**Root cause.** `regroup_to_pattern_a` in [`convert-json-to-config.sh`](../../src/foundation/tappaas-cicd/manager/site-manager/convert-json-to-config.sh) decides a field's owner by matching its schema `usedBy` against the module's **`dependsOn` only** — it never consults **`provides`**. The `backup` module **provides** `backup:vm` (it *is* the PBS server; `dependsOn: []`, `provides: ["vm","remote","external"]`), so its own service-config fields (`placement`, `placementState`, `pbsStorageName`, `alwaysBackup`, `backup`, all `usedBy:[backup:vm]`) look like orphans. The four `image*`/`storage` fields (`usedBy:[cluster:vm]`) that backup's own `install.sh` uses for its apt install are a second flavour of the same mismatch.

**Notes.**
- **Not shim-specific** — the check never references placement/shim; a *local* backup update warns identically. The operator just noticed it on a shim.
- **Pre-existing, amplified by ADR-012** — `alwaysBackup`/`backup`/`pbsStorageName`/`image*`/`storage` already warned; ADR-012 added `placement`/`placementState` (same pattern).
- **Harmless today** — "kept at top level" means the fields stay flat and the module's scripts still read them via `get_config_value`. It is warning noise, not a functional bug.

**Not the fix.** Stripping the fields on a shim (the first instinct) is wrong: it silences nothing on a local backup, and a shim specifically *needs* `placement` + `placementState` (and `pbsStorageName`/`storage` at promotion) — removing them breaks P2 promotion.

**Proposed direction (to design in the issue).** Make the owner/orphan check **`provides`-aware**: a field whose `usedBy` capability is one the module *provides* (self-capability `<module>:<provide>`, e.g. `backup:vm`) is the provider's own config, not an orphan. This clears the 5 `backup:vm` warnings for backup and any future provider module, shim or local, with no config loss. **Caveats:** (a) the 4 `image*`/`storage` warnings are `usedBy:[cluster:vm]`, so a provides-fix won't clear them — they need a separate small schema decision (attribute backup's direct usage, mark `general`, or accept); (b) the fix lives in the **shared** normalizer that runs for *every* module, so it needs its own test + care, not a backup-only patch.

---

---

# v0.3 — remaining work (P10–P20)

**Planned 2026-09-09.** Branch `main` (ADR-007 landed; `backup-manager`/`backup-controller` and the
named foundation layout are on `main` now). P1–P9 above are complete; what follows is the ADR v0.3
restructure (ADR [Implementation Plan](../ADR/ADR-012-backup-enhancement.md#implementation-plan-phased)
items 10–15) plus the two issues that fell out of it (#544, #545), plus the §2.4 node-add hook that
was specified but never wired.

## What changed in the repo since v0.2 (re-baselined 2026-09-09)

| Assumption in the ADR text | Reality on `main` today | Consequence |
|---|---|---|
| Backup fields live in `schemas/module-fields.json` (§2.7) | Field schemas are **service-owned**: the backup fields are in [`backup/services/vm/fields.json`](../../src/foundation/backup/services/vm/fields.json) with ADR-020 `class`/`apply`/`changeNote` metadata. `module-fields.json` keeps only generic fields (+ a stale `fieldOrder`). | §2.7's file reference is stale — **all schema deltas land in the service fields file** (D15). |
| `alwaysBackup` retirement waits on #501 | **#501 has landed** — `integratesWith` is in the schema and wired through `module-manager` install/update/delete/converge/validate. | P15 is unblocked; it is not a dependency wait. |
| Off-site/2-PBS work "pending the incoming 3-node cluster" | The cluster **exists**: `tappaas1/2/3`, PBS active on `tappaas3`, datastore `tappaas_backup` on `tankc1`, one managed job (`TAPPaaS-backup-vm-managed`, 9 VMIDs, 21:00), `proxmox-backup-client` on all 3 nodes. | The deferred v0.2 live tests (compromise isolation, restore-with/without-key, subset, immutability) run in this round. |
| §2.4 "node-add triggers the reconcile automatically" | `site-manager node add` ends at storage registration ([provision.ts](../../src/foundation/tappaas-cicd/manager/site-manager/src/provision.ts)) — **no backup call**. | Own package (P17). |
| #544 "discovery scans `config/*.json`" | Confirmed: `backup-manager`'s `listModules` uses a stale 5-name deny-list, so `last-update-result.json` / `module-fields.json` classify as modules. `module-manager` already has a shape-based `isModuleConfig` to reuse. | P16. |

> ⚠ **Operational note (not ADR work).** `tankc1` on `tappaas3` — the site's only local backup
> datastore — is **DEGRADED**: a single HGST HDD with 10.4K read / 2.58K write / 27.7K cksum errors,
> no redundancy, "no known data errors" so far. Live testing in this round keeps test data on
> `tankc1` to a few small snapshots and prefers the sandbox PBS (T4) for volume.

## Decisions log — v0.3 additions

| # | Decision | Source |
|---|----------|--------|
| D14 | **Forcing `external` uses `install-module.sh`'s native field override** — `install-module.sh backup --force --placementState external --pbsUrl <url>` (friendly wrapper: `backup-manage.sh use-external <url>`). No new `pbsType` field. Resolves the ADR §2.1 open naming note. | ADR §2.1 (2026-09-09) |
| D15 | **Schema deltas land in `backup/services/vm/fields.json`**, not `schemas/module-fields.json`; every new/changed field carries ADR-020 `class`/`apply`/`changeNote`. `fieldOrder` in `module-fields.json` is updated for ordering only. | repo re-baseline (2026-09-09) |
| D16 | **Per-module schedules are realised as one cluster backup job per distinct resolved schedule** ("schedule buckets"). Marker becomes `TAPPaaS-backup-vm-managed` (daily — **the existing production job, unchanged, keeps its marker and 21:00**) plus `TAPPaaS-backup-vm-managed-<bucket>` for `weekly`/`monthly`. Membership stays a set operation over each bucket's `--vmid` list; a module that changes bucket is removed from the old job and added to the new one in the same reconcile. | operator choice (2026-09-09), ADR §3.2 |
| D17 | **`backup:filesystem` is a second service directory** `backup/services/filesystem/` (own `fields.json` carrying `filesystemPaths`). Capture mechanism: `install-service.sh` deploys a guest-side `proxmox-backup-client` + systemd timer that pushes a host-type backup of the declared paths into namespace `fs/<module>` on the configured PBS, with a write-no-delete `<module>@pbs` login and the escrowed encryption key. **Gated on NixOS guests** (the one guest layout TAPPaaS knows); any other `ostype` fails the service install with a clear message rather than half-capturing. | ADR §3.1 (2026-09-09) |
| D18 | **`alwaysBackup` retires via `integratesWith`.** PBS-job membership = union of `dependsOn` and `integratesWith` over `backup:vm` / `backup:filesystem`. `alwaysBackup` is read for one release with a deprecation warning and ignored once every listed module declares the relationship; then the field and its code path are removed. Backup stays opt-in — a module declaring neither is not in any job. | ADR §2.7, #501 (2026-09-09) |
| D19 | **#544 fix = shared, shape-based module discovery.** Extract `module-manager`'s `isModuleConfig`-style discovery into `tappaas-cicd/lib/ts/src/` and consume it from both managers; `backup-manager` then filters to modules declaring a backup capability. The deny-list disappears. | #544 (2026-09-09) |
| D20 | **#545 coverage (proposed + implemented this round).** `network` (the firewall VM) and `tappaas-cicd` gain `integratesWith: ["backup:vm"]`; **`config/` is captured as `backup:filesystem` on `tappaas-cicd`** (`/home/tappaas/config` + `/etc/secrets`); `cluster` and `templates` get **no** backup — they hold no state outside `config/` and are rebuilt by install. Every one of these gets a **written and rehearsed** restore path before #545 is claimed closed. | ADR §2.7, #545 (2026-09-09) |
| D21 | **Live-test policy on the production cluster** (operator-approved 2026-09-09): mutating live tests **may touch the real cluster backup job additively**, under these rails — capture `pvesh get /cluster/backup` + `/etc/pve/storage.cfg` before any mutation and restore afterwards; **never** delete, prune, forget or overwrite an existing snapshot group; restores always target a **new, unused VMID** (never over a live VM); test guests use a reserved VMID (`99x`); volume tests go to the sandbox PBS (T4), not to degraded `tankc1`. | operator choice (2026-09-09) |
| D23 | **The `placementState` pattern tolerates the legacy values for one release** (`^$|^(shim|external|node:.+|local|remote-only)$`). A deployed config is validated *before* the module's own `update.sh` gets to migrate it, so a strict v0.3-only pattern would fail validation on every existing install. The strict pattern lands when the deprecation window closes. | implementation (2026-09-09) |
| D22 | **Migration is a read-once backfill.** `placement` is read once to seed `placementState` (`auto`/`node:*` → `node:<name>` once discovery resolves, `shim` → `shim`, `remote-only` → `external`), then dropped on write-back. `pushTarget` seeds `pbsUrl` when the state resolves to `external`. Legacy `placementState:local` → `node:<name>` with **no datastore move and no dependent reinstall**. | ADR §4.1 (2026-09-09) |

## Packages

### P10 — Placement state model: drop `placement`, add `external` + `pbsUrl` (#402, #214) · D14, D22

- **Deliverables:** `lib/pbs-placement.sh` reworked to the §2.2 resolution order — forced `external` wins; a concrete `node:<name>`/`external` is kept; empty or `shim` re-derives. `placement_policy()` retires; new `pbs_placement_state` values `shim` \| `external` \| `node:<name>`; new `pbs_pbs_url` (default `backup.mgmt.internal`) and `pbs_is_external`. `install.sh`/`update.sh` branch on the state instead of the policy. `update.sh` backfills legacy configs (D22). Shim guards in `services/vm/{install,update,test}-service.sh` learn the difference between "no datastore" (shim → skip) and "datastore elsewhere" (external → proceed against the registered storage). `pbs-job.sh` `pbs_node`/`pbs_storage_name` honour `external`.
- **Depends on:** nothing (first package).
- **Test criteria:** extended `lib/test-pbs-placement.sh` covering the full derivation matrix (empty/shim/node:/external × forced/not × tankc found/not) and the legacy fixtures (`placement:auto`+`placementState:local`, `remote-only`+`pushTarget`); new `lib/test-pbs-migrate.sh` for the backfill; live: `update-module backup` on this cluster leaves `placementState: node:tappaas3`, the datastore untouched and the job's VMID list byte-identical.

### P11 — Consume a pre-existing PBS (#456) · D14

- **Deliverables:** `lib/pbs-external.sh` — idempotently register the PBS at `pbsUrl` as a Proxmox `pbs` storage (fingerprint + prompt-not-store credential), **no datastore creation, no PBS package install, no `tankc` discovery**; run the client reconcile; wire the managed job to that storage. `backup-manage.sh use-external <url> [--datastore <ds>]` as the operator wrapper over D14's field override.
- **Depends on:** P10.
- **Test criteria:** unit — storage-arg derivation + idempotence + "never creates a datastore". Live (additive, rolled back) — register `tappaas3`'s PBS **by URL** from `tappaas1` as a second storage under a test name/namespace, back up the scratch guest into it, confirm pre-existing snapshots stay listable and restorable, then remove the test storage.

### P12 — Schema + `provides` + KI-1 normalizer (§2.7) · D15

- **Deliverables:** in `services/vm/fields.json` — remove `placement`; re-spec `placementState` (ships empty, pattern `^(shim|external|node:.+)$`, runtime-written); add `pbsUrl`; add `backup.schedule`; mark `pushTarget` + `alwaysBackup` deprecated. In `backup.json` — drop `placement`, keep `node`/`storage` as *discovery constraints*, add `pbsUrl` default, set `provides: ["vm","filesystem"]`. **KI-1**: make `regroup_to_pattern_a` in `site-manager/convert-json-to-config.sh` `provides`-aware (a field whose `usedBy` names a capability the module *provides* is the provider's own config, not an orphan) + its own unit test; the four `image*`/`storage` warnings (`usedBy:[cluster:vm]`) are attributed explicitly in the same pass.
- **Depends on:** P10 (same coherent change; land together).
- **Test criteria:** `module-manager validate backup` clean; the reconcile step emits **zero** orphan-field warnings for backup; schema round-trip of a shim, a `node:<name>` and an `external` config; `module-manager` fixture suite green.

### P13 — `backup:filesystem` capability (§3.1) · D17

- **Deliverables:** `services/filesystem/{fields.json,install-service.sh,update-service.sh,delete-service.sh,test-service.sh}`; `filesystemPaths` schema; guest-side client + timer + write-no-delete login; namespace `fs/<module>`; NixOS-only gate with an explicit failure otherwise; restore path documented in `restore.sh`.
- **Depends on:** P10, P12.
- **Test criteria:** unit — namespace/path/timer derivation, OS gate. Live — `tappaas-cicd` itself is the first consumer (this is also #545's `config/` capture, P18): declare the paths, run the capture, confirm the snapshot exists in `fs/tappaas-cicd`, restore it into a scratch directory and diff.

### P14 — Schedule cascade with bucket jobs (§3.2) · D16

- **Deliverables:** `site-fields.json` gains `backup.defaultSchedule` (default `daily`); `services/vm/fields.json` `backup.schedule`; `backup-manager` resolves module > environment > site > `daily` and **rejects sub-daily** (once/day ceiling) in `validate`/`modify`; `list`/`resolve`/`show` surface the effective schedule. `pbs-job.sh` becomes bucket-aware (ensure/move/remove across `-weekly`/`-monthly` jobs, daily keeping today's marker); `backup-controller` gets the apply verb; `backup-manager reconcile` plans bucket moves.
- **Depends on:** P12.
- **Test criteria:** TS cascade unit tests (inherit, env override, module override, sub-daily rejected); bash bucket unit tests (move between buckets, no-op re-run, daily marker preserved). Live — pin the scratch guest to `weekly`, reconcile, confirm a `-weekly` job appears carrying only it **and the production daily job's VMID list is unchanged**; unpin, confirm the weekly job is emptied/removed.

### P15 — Retire `alwaysBackup` via `integratesWith` (§2.7, #501) · D18

- **Deliverables:** membership becomes the union of `dependsOn` + `integratesWith` over the backup capabilities; `network` and `tappaas-cicd` declare `integratesWith: ["backup:vm"]`; `alwaysBackup` read-with-warning, then removed from `backup.json` and the code path.
- **Depends on:** P12.
- **Test criteria:** unit — union membership, opt-out (neither relationship → not in any job), deprecation warning fires once. Live — **the production job's VMID list is byte-identical before and after the switch** (the headline regression); a scratch module declaring neither is absent from every job.

### P16 — #544: shape-based module discovery · D19

- **Deliverables:** extract shape-based discovery into `tappaas-cicd/lib/ts/src/`, consume from `module-manager` and `backup-manager`; `backup-manager` filters to modules declaring `backup:vm`/`backup:filesystem` in `dependsOn` **or** `integratesWith`; the `NON_MODULES` deny-list is deleted.
- **Depends on:** P15 (shares the membership predicate).
- **Test criteria:** TS unit with fixtures including `last-update-result.json`, `zones.effective.json`, `module-fields.json`, `*.orig`, an unparseable file → none classify as modules. Live — `backup-manager list` on this cicd shows only real modules.

### P17 — Node-add triggers the client reconcile (§2.4, #382)

- **Deliverables:** `site-manager node add` calls `module-manager modify backup` (the reconcile) as its final step, after storage registration; failure is a warning with the exact manual command, never a failed join.
- **Depends on:** P10.
- **Test criteria:** unit/dry-run of the added step. Live — a re-run of the reconcile on the current 3 nodes is a clean no-op (all three already carry the client); a simulated "missing client" node (package check stubbed) shows the install path being taken.

### P18 — #545: foundation coverage + rehearsed recovery · D20

- **Deliverables:** apply D20's coverage; write the recovery runbooks for the firewall VM, the mothership and `config/`; **rehearse each one** and record the transcript in the package log; only then claim #545.
- **Depends on:** P13, P15.
- **Test criteria:** firewall VM restored from PBS to a **new VMID, left stopped / NICs detached** (no IP conflict), disk contents verified; `tappaas-cicd` restore rehearsed the same way; `config/` capture restored into a scratch dir and diffed against live; each runbook re-read after the rehearsal so it matches what actually happened.

### P19 — Encryption-key escrow: export / import (§2.5.1)

- **Deliverables:** `backup-manager key export <dest>` (escrow → removable media, for the mandatory out-of-band copy) and `key import <src>` (media → `/etc/secrets` on a fresh mothership); escrow generation folded into onboarding; documented DR order.
- **Depends on:** P13 (shares the client-key handling).
- **Test criteria:** unit — path/permission handling (0600, refuses a world-readable dest). Live — the ADR's mandatory pair: restore the scratch guest from the sandbox PBS **with** the key (succeeds) and **without** it (fails cleanly, with a message that names the key).

### P20 — Migration (§4) + documentation (§15) + ADR acceptance

- **Deliverables:** the §4.5 migration plan realised (state backfill, #456 adoption, relocation-by-pull runbook, deprecation window); `backup/README.md`, `QUICKREF.md`, `TEST.md`; the `00-Template` authoring guide (backup capabilities, `backup.schedule`, placement states); migration + key runbooks; ADR acceptance checkboxes and this tracker updated.
- **Depends on:** all of the above.
- **Test criteria:** legacy-fixture upgrade test green; docs reviewed against the code that shipped (no aspirational text).

**Execution order:** **P10 + P12** (one coherent state+schema change) → **P11** → **P15 → P16 → P17** (small, independent) → **P14** → **P13** → **P18** → **P19** → **P20**.

## Test plan on this machine (`tappaas-cicd`, live cluster)

Five tiers. T0–T2 run on every package; T3–T4 run where the package touches live PBS.

| Tier | What | How | Risk |
|---|---|---|---|
| **T0 — static** | `bash -n` + **shellcheck** (installed here) on every changed script; `jq empty` on every changed JSON; `tsc --noEmit` (strict) via `nix-shell -p typescript nodejs_22` on changed TS. | per package, before tests | none |
| **T1 — offline unit** | `backup/test.sh`, `manager/backup-manager/test.sh`, `manager/module-manager/test.sh`, `manager/site-manager/test.sh`, `controller/backup-controller/test.sh`, `test-module.sh backup`. Baseline today: backup 34/0, TS cascade 60/0, controller 11/0. | per package | none |
| **T2 — live read-only** | `backup-manager placement\|peers\|list\|validate`, `backup-controller job-status\|namespaces`, `pvesm status` on all three nodes, `pvesh get /cluster/backup`. | per package | none |
| **T3 — live mutating (additive, rolled back)** | Scratch LXC `bktest` (VMID `99x`, tanka1 on tappaas1, ~1 GB) as the guinea pig: job membership, bucket moves, external-storage registration, filesystem capture, restore-to-new-VMID, key with/without. **Rails (D21):** `pvesh get /cluster/backup` + `/etc/pve/storage.cfg` captured to the scratchpad before the first mutation and restored after the last; no delete/prune/forget outside the test's own groups; production VMIDs never removed. | P11, P13, P14, P15, P17, P18, P19 | low, bounded |
| **T4 — two-PBS suite (#389)** | A **sandbox PBS**: file-backed zpool on `tappaas1`'s `tanka1` → its own datastore → registered as a buddy. Runs `TEST.md`'s six-step compromise-isolation checklist (pull delete-denied, push write-no-delete, immutability holds, subset/groupFilter, restore with/without key, simulated compromise) with production `tappaas_backup` only ever as a **pull source** (read-only on production). Torn down at the end. | P19, P20 | low — production is read-only in this tier |

**Package gate (unchanged from above):** plan → implement → T0 → T1 → T2 → T3/T4 where applicable → log here. **All green → the work stays staged in the working tree for the operator to commit** (never `git commit`/`git push`). **Any red → stop the line**, log it here, fix, re-run; do not advance to the next package.

**Stop-the-line / escalate to the operator** (do not improvise): any red gate that survives one fix attempt; anything needing a real external, satellite or third-party PBS credential; anything that would delete or overwrite production backup data; `tankc1` health degrading further; a design fork not already settled by D14–D22.

---

## Package logs

### 2026-09-09 — the peer vocabulary settled: pull / remote / receive

Operator review of #608 landed on names that say what each relationship *is*, and on one relationship that had no implementation at all. No migration was written: no deployment has a peer configured, which the operator confirmed and `backup-manager peers` agreed with.

| Kind | What it is | Namespace here | Credential |
|---|---|---|---|
| **`pull`** | we pull a copy of **their** backups | `pull/<n>` | we hold a read-only login **on them** |
| **`remote`** | **they** pull **ours** — where our off-site copies live | *none* — a read grant on data we already hold | we grant them read-only; we hold nothing on them |
| **`receive`** | they push **theirs** into ours, having no PBS of their own | `receive/<n>` | we issue them write-no-delete; we own retention |

- **`remote` is new.** The symmetric half of `pull` existed only as prose telling an operator to issue a token by hand (RESTORE.md §8.4). It is now `scripts/remote/{onboard,offboard}.sh` plus `peer add remote`.
- **The `push` peer is retired**, scripts and lib with it. Sending this cluster's vzdump backups to a remote PBS is `placementState: external` + `pbsUrl` — a *placement*, not a peer — and keeping both mechanisms is why the word "external" meant two opposite things (a client pushing **into** us, and us consuming **someone else's** PBS). `pushTarget` was already deprecated as subsumed by exactly that; retiring the service follows the field.
- **Files and namespaces follow the verbs**: `remote-<n>.json`/`remote/<n>` → `pull-<n>.json`/`pull/<n>`, `external-<n>.json`/`external/<n>` → `receive-<n>.json`/`receive/<n>`, freeing `remote-<n>.json` for its new meaning. `install.sh` creates the `pull` and `receive` parent namespaces; the old empty `remote`/`external` parents on an existing datastore are harmless and can be dropped by hand.
- **`peer delete` requires the kind.** One name legitimately holds two relationships — a buddy is usually both a `pull` and a `remote` — so inferring it would eventually tear down the wrong half of a working pair. Omitting it now names what the peer actually is and suggests the right command.

**The security shape of `remote`, which is the only operation that grants access to our own data.** It grants `DatastoreReader` — read-only, no write, no prune — and **non-propagating by default**. That default is load-bearing rather than tidy: PBS ACLs inherit into child namespaces, so a propagating grant on the root would hand a buddy `fs/tappaas-cicd` — this site's `config/` **and** `/etc/secrets` capture — plus every other peer's data, when the intent was "let them pull our VM backups". `pbs_acl_ensure` gained a propagate argument for it, onboarding warns when propagation is asked for explicitly, and the unit test asserts the default is off.

Also removed from `backup-manage.sh`: the `add-remote`/`add-external`/`add-push` verbs, now that `backup-manager peer` is the operator surface and duplicating it in two CLIs is how the two drift apart.

Suites: backup all-pass, backup-manager 26/0 with **143** TS asserts, module-manager 123/0, site-manager 13/0, backup-controller 18/0, tappaas-cicd 54/0. ADR §1.4 and §2.7C rewritten; changelog **v0.5**.

### 2026-09-09 — `services/` tells the truth again, and peers get a manager (#608 follow-through)

The question behind #608 turned out to be structural, not documentary: `services/remote|external|push` were never services. In this codebase `services/<name>/install-service.sh` means one specific thing — a provider coordinate `module-manager` invokes on a consuming module's behalf — and these three were invoked only by `backup-manage.sh`, on an operator's say-so. Nothing declared them, `provides` did not list them, and the dependency resolver never reached them. Documenting the disposition (last entry) explained the anomaly; it did not remove it.

**Moved** to `backup/scripts/`, beside the module's other helper scripts, following the `tappaas-cicd/scripts/` convention:

| Was | Now |
|---|---|
| `services/{remote,external,push}/install-service.sh` | `scripts/{remote,external,push}/onboard.sh` |
| `…/delete-service.sh` | `…/offboard.sh` |
| `…/update-service.sh` | `…/refresh.sh` (never invoked by anything, then or now) |
| `backup/backup-manage.sh` | `scripts/backup-manage.sh` |
| `backup/restore.sh` | `scripts/restore.sh` |

`services/` now contains exactly `vm` and `filesystem` — a 1:1 map to `provides`, which is what the directory name has always claimed.

**Peers became first-class manager CRUD.** New `src/peers.ts` owns the config; `backup-manager peer add pull|receive|push <name>` and `peer delete <name>` are the operator surface:

- The **manager writes `config/<kind>-<n>.json`**, then runs the module's `scripts/<kind>/onboard.sh`, which prompts for the credential and does the live PBS work (namespace, user, ACL, sync-job, storage registration). That split is deliberate and matches `restore`: reimplementing those PBS calls in TypeScript would duplicate tested bash **and** route a credential through another process. The credential is still never written to any config (§2.5).
- **`--config-only`** on both add and delete, for writing/removing the config when the far PBS is unreachable — and, on delete, for dropping a peer while deliberately leaving its PBS side alone.
- Validation refuses what cannot work before a credential is typed: a pull/push peer with no `--host`, a push peer with no `--auth-id` (the login the *remote* issues by adding a receive peer for this site), an unknown kind, an unusable name, and an existing peer without `--force`.

**A defect the tests caught in my own design.** The push peer's namespace lives on **their** datastore and is named after **us** — they created it by adding a receive peer for this site. My first implementation defaulted it to the *peer's* name, so `peer add push offsite` would have written into `external/offsite`, a namespace the remote never authorised. It now reads `site.json` `.name`, and the unit test asserts the namespace is named after this site rather than the peer.

**Also:** `--host`/`--auth-id`/etc. are parsed through one flag table rather than another else-if arm each; `peer delete` offboards *before* removing the config, since the script reads that config to know what to tear down; and an offboard that fails leaves the config in place to retry rather than orphaning the PBS side.

Docs, the ADR §2.7C table, `DEPENDENCIES.csv` and the generated service README all follow the new layout. Suites: backup all-pass, backup-manager 26/0 with **140** TS asserts (24 new, covering kind vocabulary, all three configs, the namespace rule, no-clobber, delete, and script resolution), module-manager 123/0, site-manager 13/0, backup-controller 18/0, tappaas-cicd 54/0.

### 2026-09-09 — RESTORE.md, second pass (operator review)

- **§1 restructured.** Restoring *in place* (1.2a) now comes before restoring *beside* (1.2b), and the two are lettered rather than numbered — the sequence 1.1 → 1.4 is linear, and these are two ways to do one step, not two steps. Both now read "This will:" followed by what actually happens.
- **§2 uses the manager throughout.** The last `./restore.sh` is gone: `backup-manager restore restore <module> --vmid <in-backup> --target-vmid <installed>` covers it, because a later `--vmid` overrides the one the manager supplies. That was accidental parser behaviour; `restore.sh --help` now states it, so the documented command rests on a contract rather than a coincidence.
- **`cd` dropped everywhere.** `module-manager` and `backup-manager` resolve a module by name from the deployed config or a repository catalog. The one real exception — installing a module that is in no catalog — is stated once instead of a `cd` on every example.
- **§3.0 is new, and is the section the operator asked for.** A node dying does not mean its guests died: anything HA-managed was probably **already failed over**, and restoring it would give you two of it. The check is `module-manager list --json`, comparing each module's declared `node` against its live `actualNode` — the JSON exposes both, which the table does not. It matters most for `network` (nothing reaches the world without it) and `tappaas-cicd` (where the recovery commands run), so the section leads with those two and branches three ways: evacuated → migrate home later; not running anywhere → restore, firewall first; mothership gone → §5.2 before anything else.
- **§3.3 answers "what ran on that node?"** with two commands and why they disagree: `module-manager list --json | jq 'select(.node=="<dead>")'` for the *declaration* (what should end up on the replacement), and `ls /etc/pve/nodes/<dead>/qemu-server/` for the *record* of what it was carrying — `/etc/pve` is cluster-replicated, so it survives the node and is readable from any survivor.
- **§3.4 brings the evacuated modules home.** `module-manager migrate` realises the **declared** placement and takes no node argument (ADR-019), so the fix for "running in the wrong place" is to run it. Two cautions that are easy to learn the hard way: the mothership migrating itself moves the machine your shell is on, and if the dead node is not coming back the right fix is to change the declaration, not to migrate onto a node that no longer exists.

Every command in the section was run against the live cluster before it was written down.

### 2026-09-09 — RESTORE.md published, CLI help rewritten, and two more restore defects

- **RESTORE.md is on the site.** The Documentation repo gained a sync rule (`src/foundation/backup/RESTORE.md` → `generated/disaster-recovery.md`) and a nav entry at the end of **Operate → Disaster Recovery**.
- **Two new sections.** **`templates`** — rebuilt, never restored: templates are derived artifacts, and restoring an old one would hand every future install a stale base (clones are copies, so existing modules are unaffected by a rebuild). **Recovering from an off-site buddy** — what you need before you start (the key, and a read-only auth-id they must issue, because the pull direction means you hold no credential on them *by design*), pulling their copy back into a rebuilt local datastore, restoring directly from their PBS when there is no local one yet, and the symmetric case of being the buddy.
- **The commands are the manager's now.** RESTORE.md documented `restore.sh` directly; it now uses `backup-manager restore`, which resolves a *module name* to its VMID and forwards the rest to the same script. `restore.sh` stays documented for the one case the manager cannot express: restoring a backup whose VMID is not the module's current one (§2).

**Two defects, found by running the commands the document now recommends:**

1. **`backup-manager restore` could not find `restore.sh` in the installed binary.** It resolved the path by walking seven directories up from `__dirname` — fine from a checkout, but from `/nix/store/<hash>-backup-manager/lib/...` that is `/`, so it looked for `/backup/restore.sh`, printed *"Would run: … (foundation restore.sh not found)"* and **exited 0**. The restore verb reported success and restored nothing. It now resolves from the module's own recorded `.location` in `config/backup.json` (the answer that works from anywhere), then the repo walk, then the conventional path — and a missing script is a **non-zero failure**, because a recovery verb that exits 0 having done nothing is the worst possible failure mode.
2. **`restore list` printed raw unix timestamps.** `1788894052` is not something an operator picks a snapshot from, and the document told them to "note the date". Now rendered newest-first as `2026-09-08 19:00:52 UTC (today) 1788894052`, keeping the raw value because that is what the restore takes.

**CLI help rewritten (both binaries).** `backup-manager --help` described 8 of its 13 verbs and pointed at ADR sections; someone asking a command for help should not be handed a document reference. Every verb now has a description written for the person running it, ADR shorthand is gone, and "(was backup-status)" archaeology with it. `backup-controller --help` was worse: `usage()` grepped **every** `^#` line in the file, so internal implementation notes appeared as help text. It now prints the header block only.

**Wording** — removed "do not meet them for the first time during an incident" and "Knowing which is which before an incident is most of the recovery" per operator preference.

### 2026-09-09 — Documentation consolidation: QUICKREF retired, RESTORE.md written

Operator call: `QUICKREF.md` had drifted, and what a reader actually needs mid-incident is a document organised by **what broke**, not by which command exists.

- **[backup/RESTORE.md](../../src/foundation/backup/RESTORE.md)** is new and is now the recovery document: a module rolled back (including the step everyone skips — re-applying the declaration afterwards, and confirming HA and replication came back), a module restored onto a system that never had it (declare first, restore second, because a backup carries disks and Proxmox config but not the module's TAPPaaS declaration), a lost node (evict from the cluster *before* re-adding the name, then restore its guests, then re-fold HA), the special cases, and relocating a datastore. Every procedure is labelled **rehearsed** or **unrehearsed** — the ones that have actually been run say so, and the ones written from the code admit it rather than implying a confidence nobody earned.
- **The special cases are now decided rather than implied.** `network` is backed up but should usually be *rebuilt* — the firewall is the most declaratively-generated thing in the system (prebuilt image + rendered `config.xml` + zones/rules/DNS/proxy applied from declared state), so a restore reproduces a point in time including its drift; restore it only when it holds state TAPPaaS does not declare (GUI changes, VPN peers, DHCP reservations). `cluster`, `templates` and `backup` own no guest, so there is nothing to back up — recovery is node recovery plus reinstall. `tappaas-cicd` cannot be restored from itself: `restore.sh` runs *on* it, so restoring VMID 130 from VMID 130 destroys the machine running the command — the rebuild is driven from a node.
- **`QUICKREF.md` deleted**, its surviving day-to-day content folded into `README.md` (coverage/datastore/peer/key commands, retention and the schedule table); `docs/design/backup-recovery-runbook.md` deleted too rather than left to drift alongside RESTORE.md. All referrers repointed — README, INSTALL, DESIGN, TEST, the filesystem service README, `00-Template`, ADR-010, and ADR-012's own Related/plan/acceptance rows.

**Two defects found while writing it** — documenting a restore path meant reading it, and it did not survive the reading:

1. **`restore.sh` repeated #434.** Its overwrite path did `qm stop; sleep 2; qm destroy`. On an HA-managed guest `qm stop` only *requests* a stop from the CRM — the exact race that left this site's gateway down for 7h41m and the reason `ha-vm-lib.sh` exists. It now drives HA through `havm_stop`, confirms the transition, hands the resource back to HA if the stop fails, and refuses to destroy anything it could not confirm stopped.
2. **Restores could inherit an earlier incarnation's disks.** The destroy used a bare `--purge`, so volumes carrying the VMID that the config no longer references survived into the restored guest — one boots the machine while another quietly consumes the pool. Now `--purge --destroy-unreferenced-disks 1`.

**Backup-policy change (#545).** The mothership's capture was `/home/tappaas/config` only; `/etc/secrets` is now captured too, so a rebuilt mothership gets its secrets back rather than only its declarations. Two credential files remain **outside** any capture and are documented as such in RESTORE.md §5.3 — `~/.opnsense-credentials.txt` and `~/.pbs-credentials.txt` — because a `.pxar` archive must be a directory and single files cannot simply be listed in `filesystemPaths`. Both are recoverable by reissuing the credential; the runbook says how.

**Exec-mode slip, corrected.** The ADR-012 scripts were `git add`ed before their `chmod +x`, so eleven of them were committed **644** while every sibling is **755** — `./services/filesystem/update-service.sh` failed with *Permission denied* when run directly. Restored to 755 in the working tree (the repo's #565 deep test asserts the tracked mode is authoritative; it is a deep-tier test, which is why the normal run did not catch it).

### 2026-09-09 — #389: the compromise-isolation invariant, tested live

The headline §1.4.1 claim — *a compromise of one system must not be able to delete, encrypt or tamper with a copy held on another* — was documented as a six-step checklist waiting for a second PBS. It does not need one to be worth testing: what makes the claim true is **credential scoping**, and that can be attacked on a single server.

[`backup/test-compromise-isolation.sh`](../../src/foundation/backup/test-compromise-isolation.sh) (12/12, self-tearing-down) creates a sandbox destination datastore and a **read-only** credential on the production datastore, then:

1. **Pulls a subset** — a sync job with `--group-filter type:host` replicates the `config/` capture into the destination's own namespace, and **no VM backups come across** (the filter is checked only after a sync that actually moved something — asserting "no VMs" on an empty datastore passes for the wrong reason).
2. **Attacks the source with the puller's own credential** — the credential an attacker holding the off-site system would have. `snapshot forget` is refused (`missing Datastore.Modify|Datastore.Prune`), `prune` is refused, and the source snapshot is still there afterwards. It *can* read, as a puller must.
3. **Gives the destination its own prune job**, independent of the source's retention.

Production is only ever a pull **source** and is never written to; the datastore, credential, remote and both jobs are removed at the end (verified: the node is back to one datastore, no remotes, no sync jobs).

**What it still does not cover, and says so:** a genuinely separate PBS *host*. Two datastores on one server exercise credential scoping, the sync path and the subset filter faithfully, but not network isolation or a satellite over a tunnel.

**Two bugs in my own test, worth recording** because both would have produced a green run that proved nothing: `--keep-last 0` is rejected by PBS *argument* validation before any permission check, so the prune attack never reached the thing it was testing; and a nested destination namespace needs its **parent** to exist first (`cannot create new namespace, parent fs doesn't already exists`) — which is exactly why the module's own `pbs_ns_ensure` walks the parent chain, and why a hand-rolled sync job has to do it too.

### 2026-09-09 — P20: migration, documentation, ADR acceptance

- **Migration (§4).** The state backfill (§4.1) and #456 adoption (§4.2) are implemented, unit-tested against legacy fixtures and **live-verified** — see P10 and P11. The deprecation window is open: `pushTarget` and `alwaysBackup` are read for one release, marked deprecated in the schema, and the resolver that reads `alwaysBackup` can no longer truncate. **Relocation-by-pull (§4.3) is documented but not rehearsed** — it needs a second datastore, and I have not invented one; it is called out as unrehearsed rather than quietly claimed.
- **Docs.** `QUICKREF.md`'s ADR-012 section was rewritten from the v0.2 model it still described (a `placement` policy field, `remote-only`) to the v0.3 one — placement states, the two capabilities, the schedule cascade and its ceiling, key export/import, and the relocation runbook. `README.md`'s capability table now says what the module actually does, and its "what is not included" says plainly that backup is opt-in and stays opt-in. `TEST.md` lists the real suites and counts (203 offline asserts across eight suites, plus the components' own) and the live rehearsals. `00-Template/README.md` gained **"Getting your module backed up"** — pick a kind, declare neither if you want none, use `integratesWith` if you bootstrap first, and the once/day ceiling.
- **A doc-only claim I removed:** QUICKREF's "Test Restore to Different Node" recipe restored *over* the original VMID on another node. It is now the `--target-vmid` rehearsal, with the warning about never starting a copy on its original's network.
- **ADR acceptance: 18 of 19 boxes.** Every v0.3 row is checked with what actually proved it, and the one that is not — the **two-PBS** half of the #389 compromise-isolation suite (buddy pull, subset, off-site retention) — says so, alongside the half that *is* proven live (a client credential provably cannot delete its own snapshots). The restore-with/without-key box is checked for the `config/` capture and explicitly notes that doing it *from an off-site copy* still awaits a second PBS.
- **ADR §2.7's file reference corrected** in place: field definitions live with the service that owns them since #567, so the deltas landed in the module's own manifests, not `schemas/module-fields.json`.

### 2026-09-09 — P18: #545 — coverage decided, and the recovery actually rehearsed

**Coverage (D20).** `network` (the firewall) and `tappaas-cicd` are backed up as VMs via `integratesWith: backup:vm`; `config/` is captured as a `backup:filesystem` (P13); `cluster` and `templates` get **nothing**, deliberately — they hold no state outside `config/` and install rebuilds them. Backup is opt-in, and covering what does not need it is how a backup set becomes noise.

**Two shapes for the mothership, on purpose.** A VM snapshot restores the machine; the file capture restores `config/` in seconds into a running system and, unlike a snapshot, **onto a different mothership** — which is the case that matters, because full-site DR restores `config/` before there is a VM to restore into.

**Rehearsed live, all three:**

- **`config/`** — restored from `fs/tappaas-cicd` into a scratch directory, `diff -r` against the live tree **clean, 85 files**; the same restore without the key **refused**.
- **Firewall (VMID 110 → 910)** — restored alongside the running original, **stopped**, **fresh MACs on both NICs**, GPT intact (EFI + FreeBSD boot + FreeBSD UFS, 3.2 GiB referenced), then destroyed.
- **Mothership (VMID 130 → 930)** — it had **no VM backup at all** (it joined the job only today, in P15), so its first backup was taken: 32 GiB, 84 s. Restored to 930, **root filesystem mounted read-only** and verified as genuinely the mothership — `/home/tappaas/config` with 23 module configs, `/etc/nixos`, the operator's home — then unmounted and destroyed.
- Production came out untouched: the job still lists exactly its ten VMIDs, `storage.cfg` semantically identical, no leftover disks.

**`restore.sh --target-vmid` is new, and was necessary.** It restores *alongside* the original — stopped, fresh MACs, and it refuses a VMID already in use — so a rehearsal can never eat the thing it is rehearsing. Without it, the only way to test a restore was to overwrite production.

**Two bugs in `restore.sh`, both fatal, both invisible until a real restore:**

1. **The "latest backup" lookup parsed the pretty-printed table.** `pvesh … | grep volid | tail -1 | awk '{print $3}'` — `grep volid` matched the **table header**, the only line containing that word, so it extracted a box-drawing character and tried to restore from `tappaas_backup:backup/│`. Now JSON + `sort_by(.ctime) | last`, with a volid-shape check that refuses anything else.
2. **A restore that did nothing reported success.** `pvesh create … | tee` makes the pipeline exit with *tee's* status, so the remote `set -e` never fired and the only detection left was grepping output for the word "error". The first rehearsal printed *"Restore completed successfully!"* while creating no VM whatsoever. The exit code is now captured and authoritative, and the script **asks Proxmox whether the guest actually exists** before claiming success — a backup tool that reports a phantom restore is worse than one that fails.
   *(A third, smaller one: backticks inside an unquoted heredoc are command substitution — a comment mentioning `pvesh … | tee` was executed on the local side.)*

**[backup/RESTORE.md](../../src/foundation/backup/RESTORE.md)** is the written path #545 asks for (first written as `docs/design/backup-recovery-runbook.md`, then folded into the module doc when `QUICKREF.md` was retired): what is covered and why, restoring `config/`, the mothership (both paths, and the DR ordering — key import **before** any restore that must decrypt), the firewall, and how to verify coverage without waiting for a disaster. Every procedure in it is one that was run.

### 2026-09-09 — P19: the out-of-band encryption key (§2.5.1)

Backups are encrypted client-side, so a key that does not outlive its client is the difference between a restore and a pile of ciphertext. TAPPaaS escrows every client key centrally — but that escrow sits **inside the system a full-site DR is rebuilding**, so it cannot be the only copy. These verbs are the copy that leaves the building, and its way back in.

- **`backup-controller key list|export <dest>|import <src>`** does the file work (it owns live state); **`backup-manager key …`** is the operator verb the ADR names, delegating to it — the same manager/controller split as everything else here.
- **`export`** writes each escrowed key to `<media>/tappaas-backup-keys/`, mode 600, plus a **plain-text README** naming the three DR steps. Whoever needs that media will be rebuilding a site and will not have this repository to hand.
- **`import`** loads keys into the escrow on a fresh mothership and **never overwrites an already-escrowed key** — anywhere but a rebuilt mothership, a silent replacement could strand every backup made with the key it replaced. It reports what it left alone.
- **Live round trip:** exported the mothership's real key → media → imported onto a throwaway escrow → **byte-identical** (`cmp`) → re-import left it untouched. Combined with P13's live pair (restore succeeds with the key, is refused without it), §2.5.1 is now demonstrated end to end rather than asserted.
- **Tests:** 7 new asserts in the controller suite against a throwaway escrow, never the real one — list, export, the README, the 0600 mode, byte-identical import, the no-overwrite rule, and rejection of an unknown subcommand (18/0).
- **The `pipefail` trap again.** The first form of the list assertion was `cmd 2>&1 | grep -q "demo"`: `grep -q` exits on its first match, the controller takes SIGPIPE, and under `set -o pipefail` the whole pipeline reports failure — so a passing behaviour read as a failing test. Capturing the output first and matching against the variable is the form that says what it means. Same shape as the password-generator bug in P13; worth remembering that in this codebase every script runs under `pipefail`.

### 2026-09-09 — P13: `backup:filesystem` — captured, restored and proven, live

The second backup capability: named paths INSIDE a guest, rather than the whole guest. Only the guest can read its own files, so this is the one part of the backup system that runs *inside* a workload — a `proxmox-backup-client` push into `fs/<module>`, on a timer, with a **write-no-delete** login and a client-side encryption key. No new credential mechanics: it is §2.5's client shape, scoped to one namespace.

- **`lib/pbs-fs.sh`** — namespace/archive/authid derivation, the guest-OS gate, PBS-side provisioning (namespace + a login that may write but not delete in it), and the capture manifest. **`services/filesystem/`** — install/update/delete/test-service plus **`tappaas-fs-backup.sh`**, the guest-side runner: deliberately tiny and dependency-free beyond `proxmox-backup-client` + `jq`, because a backup that only works while the rest of the platform is healthy is not much of a backup.
- **Deliberate hard failures.** A guest OS TAPPaaS does not know the layout of is refused outright (NixOS today) rather than half-captured; a declared path that does not exist in the guest fails the capture rather than being skipped — a backup that silently stopped covering something is the exact failure this ADR exists to prevent.
- **Deleting a module keeps its file backups.** `delete-service.sh` removes the manifest, the runner and the guest's write credential, and leaves the namespace, its snapshots and the escrowed key: removing a module is precisely when its backups matter.
- **Schema tiers.** `backup` is now read by *both* capabilities, and the composer refuses a field defined in two tiers ("one definition, one home"), so the definition moved up to the module tier `backup/fields.json` with `filesystemPaths` folded in, while each service keeps only its own change semantics — the split #567 designed.
- **First consumer: the mothership (#545/D20).** `tappaas-cicd` declares `integratesWith: ["backup:filesystem"]` with `filesystemPaths: ["/home/tappaas/config"]`; `tappaas-cicd.nix` gained `proxmox-backup-client` and a daily **20:30** timer (ahead of the 21:00 VM job, so a night's capture and snapshot describe the same state). Validated with `nixos-rebuild dry-build` before switching.
- **Live, end to end:** provisioned → captured **634 KiB of `config/`, client-side encrypted** → **restored and `diff -r` against the live tree: identical, all 85 files** → **restore without the key refused** (`missing key - manifest was created with key e9:04:…`, 0 files) → **the capture credential could not erase its own history** (`permission check failed - missing Datastore.Modify|Datastore.Prune`), snapshot still present. That is §2.5.1's mandatory with-key/without-key pair and the write-no-delete invariant, demonstrated rather than asserted.
- **Three bugs found by running it** (none reachable offline): a `set -o pipefail` + `head` password generator that killed the installer one line after producing a good password (the same idiom in `install.sh` hardened too); `/etc/secrets` created `0700 root` under `umask 077`, so the service user could not traverse it — the error named the file, not the directory actually denying it; and the missing **PBS certificate fingerprint**, without which every capture failed at connect. The fingerprint is public and now travels in the manifest, which carries no credential.
- **Also fixed: the orphan-field check now honours `integratesWith`** (KI-1's family, reopened by #501 — a module that *integrates* with `backup:vm` carries its fields as legitimately as one that depends on it). All five sampled deployed configs normalize with **zero warnings**; two regression asserts added, including one that a genuinely orphaned field is still reported.
- **Tests:** new `lib/test-pbs-fs.sh` (31) + `site-manager` 13/0; backup suite **203/0**; `services/filesystem/test-service.sh` 3/0 deep against the live capture. The deep check queries the datastore from the PBS node's own API — its first form used `proxmox-backup-client` without a repository spec or credential and reported "no capture found" while a capture sat right there.

### 2026-09-09 — P14: the schedule cascade, realised as bucket jobs (§3.2, D16)

Proxmox schedules a **job**, not a guest, so "this module is weekly" only means something if there is a weekly job. One cluster backup job per distinct resolved frequency — the buckets D16 chose.

- **Vocabulary, deliberately small:** `daily | weekly | monthly`, or a bare `HH:MM` (daily at that time — the spelling site/environment configs already used, so nothing existing had to change). Everything else is refused. That smallness is what makes §3.2's ceiling enforceable at all: "at most once a day" cannot be checked against a free-form calendar expression without reimplementing systemd's parser.
- **The ceiling is an error, not a rounding.** `hourly`, `*:00`, `06,18:00`, `mon,thu 06:00` and friends fail — at the module that declared them, naming the module, the spec and the allowed values. Silently giving a module that asked for hourly a daily backup would hide exactly the thing it needs to be told.
- **Cascade:** `module.backup.schedule > environment.backup.schedule > site.backup.defaultSchedule > "daily"`, implemented twice — `pbs_schedule_resolve` (bash, for the module's own service scripts) and `resolvePolicy` (TS, for the manager) — as the repo already does for retention, with both unit-tested against the same precedence table.
- **Buckets:** `daily` keeps the **original marker and start time**, so an installed site's nightly job is untouched by this change; `weekly` (`sun 21:00`) and `monthly` (`*-*-01 21:00`) get their own marker-tagged jobs, created on demand and deleted when they empty. `pbs_place_vmid` makes a schedule change a **move**: add to the new bucket, remove from every other — a guest in two jobs would be backed up twice where the cadences coincide. `delete-service.sh` now clears a guest from every bucket, since which one it was in depends on a schedule that may have changed.
- **Schema:** `site.backup.defaultSchedule` (new), `environment.backup.schedule` (re-spec'd to the same vocabulary), `backup.schedule` on any module (new). `backup-controller add-to-job` gained `--bucket`; `apply-schedule` now asserts the calendar event on that bucket's job instead of setting one shared start time.
- **Tests:** new `lib/test-pbs-schedule.sh` (38 — vocabulary, every sub-daily form refused, calendar events, markers, the full cascade, and the loud failure) plus 20 TS asserts incl. `validate` rejecting a sub-daily schedule by name. Backup suite **172/0**, TS **116/0**.
- **Live:** placed a throwaway VMID in the weekly bucket → a `-weekly` job appeared with `sun 21:00`; moved it to monthly → the weekly job was **deleted as it emptied** and a `-monthly` job appeared with `*-*-01 21:00`; removed it → both gone. **The production daily job (10 VMIDs, 21:00) was byte-identical at every step.** `backup-manager resolve nextcloud` now reports `schedule: daily, scheduleBucket: daily`, and `reconcile --apply` asserts the daily job's schedule as a no-op.
- **Fixed the pre-existing `validate` error** noted under P10: this site's `site.json` had `backup: null` while ten modules were in the job, so `backup-manager validate` failed on a dangling target. `site-manager site modify` gained `--backupDefaultSchedule` / `--backupDefaultRetention`, and the site now carries `{target: backup.mgmt.internal, defaultSchedule: daily}`. **`backup-manager validate` is green for the first time this session.**

### 2026-09-09 — P17: node-add reconciles the backup client (§2.4, #382)

§2.4 specifies this as a **triggered, automatic action, explicitly not a documented manual step** — and it had never been wired: `site-manager node add` ended at storage registration. A node joining after backup was installed therefore carried no `proxmox-backup-client`, so every VM later placed on it would have been silently unbacked.

- `site-manager node add` now runs `module-manager modify backup` as its final step — after the join, the `node reconcile --apply` capture and the storage registration, so the reconcile sees the *new* membership rather than the old one.
- A failure **warns and names the exact remedy** rather than failing the join: by that point the node is already in the cluster, and the fix is one idempotent command.
- **Tests:** 3 asserts in `site-manager/test.sh` — that the call exists, that it is sequenced after node capture/storage registration, and that its failure path warns instead of dying (11/0).
- **Live:** `module-manager modify backup` (the exact call) runs the client reconcile across all three nodes and the membership reconcile, rc=0, idempotent no-op on nodes that already have the client. Verified the step is present in the installed `site-manager` binary.

### 2026-09-09 — P16: shape-based module discovery (#544) — plus a second inert-verb bug

- **One discovery rule, shared.** New `lib/ts/src/module-discovery.ts` owns `isModuleConfig` / `discoverModules` / `declaresBackup`. `module-manager` now delegates to it (its own copy deleted) and `backup-manager`'s five-name deny-list is gone. A deny-list is the wrong shape for this: it fails open and silently, so every state file nobody thought to add classified as a module.
- **`backup-manager` gains `listBackupModules`** — the opted-in subset (`backup:vm` / `backup:filesystem` under `dependsOn` **or** `integratesWith`) — and `reconcile` targets that instead of "every json in config/". `list` keeps showing every real module with its `IN-PBS-JOB` flag, which is what makes an opted-out module visible as opted-out.
- **Live before → after:** `backup-manager list` reported **19 rows including 7 phantoms** (`last-update-result`, `module-fields`, `switch-configuration-actual`, `switch-configuration-desired`, `vllm-amd.meta`, `zones.effective`, `zones.rename`), each with a fabricated policy. It now reports **12 real modules**, with `network` and `tappaas-cicd` correctly showing `IN-PBS-JOB true` after P15.
- **Second bug, found by the same live run.** `reconcile` warned *"module 'X' is wired into the PBS job but has no vmid — skipped"* for **every** module: `moduleVmid` read `.vmid` as a string, but a deployed config writes it as a **number** (the test fixtures used strings, so the unit tests passed while the verb was inert against any real config dir — it could never add anyone to the job). Fixed to accept both; `reconcile` now returns *"0 actions, 0 warnings"* against the live cluster, which is the true answer. Fixtures updated to carry `kind: "module"` as real deployed configs do.
- **Build note:** the managers build through the **flake**, which only sees git-tracked files — a new untracked `.ts` under `lib/ts/` compiles locally but is invisible to `nix build`, surfacing as `TS7006 implicitly any` at the import site. New files must be `git add`ed (staged, not committed) before the component build sees them.
- **Tests:** 12 new discovery asserts driven by the exact files #544 names, plus unparseable JSON, a JSON array, `.orig` backups, peer configs, and a provider-only module (`templates` — no vmid/vmname, must still be a module); 4 vmid-type asserts. TS **96/0**, module-manager **123/0**.

### 2026-09-09 — P15: retire `alwaysBackup` via `integratesWith` — and a live bug it was hiding

**The bug.** `pbs_always_vmids` ended each iteration with `[[ -n "$vmid" ]] && printf ...`. When an entry resolved to no deployed config that expression returns 1, and under the `set -euo pipefail` every caller runs with, the loop died — inside a process substitution, so the parent saw a clean EOF and carried on reporting success. `backup.json` shipped `alwaysBackup: ["network", "firewall", "tappaas-cicd"]`, and **`firewall` has no `config/firewall.json`** (a stale name — the firewall VM is the `network` module, VMID 110). So the list silently truncated after the first entry: **`tappaas-cicd` (VMID 130, the mothership) has never been in the backup job**, on a system whose config claimed it was, for as long as the field has existed. Confirmed live before the fix (`pbs_always_vmids` under `set -e` returns `110` alone; without it, `110 130`).

- **Membership is now the opt-in union.** `pbs_optin_vmids` collects every deployed module declaring `backup:vm` under **`dependsOn` OR `integratesWith`** (#501, D18); `pbs_ensure_declared` reconciles the whole set into the job and — deliberately — never lets one unresolvable entry cost the others their backup. `pbs_ensure_always` stays as a one-release alias. The TS `moduleInPbsJob` mirrors the same predicate, so manager and module agree on who is in the job.
- **`alwaysBackup` retired from the release.** `network` and `tappaas-cicd` now declare `integratesWith: ["backup:vm"]` — the relationship #501 added for exactly this case (a foundation VM that boots before the backup server and so cannot depend on it). The field stays in the schema, marked deprecated and read for one release, so an un-migrated deployment keeps its coverage; the resolver that reads it is no longer able to truncate.
- **Backup stays opt-in.** A module declaring neither relationship is in no job — asserted directly, since "hardware and test modules must not be backed up" is the reason this is not simply default-on.
- **Tests:** new `lib/test-pbs-membership.sh` (11), including the regression that would have caught this — `alwaysBackup` completeness **under `set -e`**, which is the only condition the bug appears under. Backup suite **134/0**, TS **82/0** (5 new membership asserts).
- **Live:** adopted `integratesWith` into the two deployed configs with the standard 3-way merge (`apply-json-merge.sh` — config only, no service restart, diff was exactly the three added lines), then `update-module.sh backup`. The job went from 9 VMIDs to 10: **`130` added, all nine pre-existing VMIDs untouched**. The deployed `backup.json` lost `alwaysBackup` (the release no longer ships it) and membership is now purely opt-in, resolving to the same ten.
- **Deviation from the plan's test criterion.** P15 was written to assert the job list comes out *byte-identical*. It does not, and must not: the pre-change list was wrong. The invariant actually worth asserting — and asserted — is that **no VMID was removed** and the only addition is the one the old list already intended.

### 2026-09-09 — P11: consume a pre-existing PBS (#456) — live-verified

- **The registration mechanic is now shared.** `lib/pbs-storage.sh` owns `pbs_storage_register` / `pbs_storage_unregister` / `_pbs_pvesm_has` plus the pure `_pbs_url_host`/`_pbs_url_port`. `pbs-push.sh` (which had its own copy) is now a two-line delegation that only supplies the `offsite-<name>` naming — the difference between a push target and a consumed PBS is the storage NAME and who owns the datastore, not the registration.
- **`lib/pbs-external.sh`** consumes a PBS by URL: registers it under the module's own `pbsStorageName`, so `pbs-job.sh` targets it with **no further wiring** — a client pushing to an external PBS is indistinguishable downstream from one pushing to a local PBS (§1.4). It creates no datastore, installs nothing, and discovers no storage. `pbs_external_verify` is strictly read-only and reports how many existing backups are visible — the #456 "existing snapshots stay restorable" claim, checked rather than asserted.
- **`backup-manage.sh use-external <url> [--datastore|--namespace|--fingerprint]`** is the operator verb: prompt-not-store credential (§2.5), register, verify, and only THEN record `placementState=external` + `pbsUrl` — a failed registration leaves the config untouched rather than claiming a PBS that was never wired. Guarded by `pbs_external_allowed`: refused from a live `node:<name>` (going external is permanent and would orphan a datastore full of backups); allowed from unresolved/shim/external.
- **install.sh's external branch** records the state, reconciles clients (they push to the external PBS, §1.4) and points at `use-external` for the credentialed step — deliberately never prompting inside an install that may be unattended, the same rule the push path follows.
- **Tests:** new `lib/test-pbs-external.sh` (20 — URL parsing incl. scheme/port/tunnel forms, the permanence guard from every state, datastore-name choice, refusal of an unparseable URL); backup suite **123/0 offline**.
- **Live on the cluster:** consumed the site's own PBS **by URL** (`backup.mgmt.internal`) under a throwaway storage name — registered, active, **165 existing backups visible and restorable**, second register a no-op, then unregistered. `/etc/pve/storage.cfg` came back semantically identical (only Proxmox's own reordering of `content`/`nodes` lists differed) and the production job was untouched throughout.

### 2026-09-09 — P10 + P12: placement state model + schema (live-verified)

- **`lib/pbs-placement.sh` rewritten to the state model.** `placement_policy`/`pbs_discover_placement` are gone; `placementState` is the only source of truth, resolved by `pbs_resolve_placement_state` per §2.2 (external sticky → concrete `node:<name>` kept → empty/shim re-derived). New readers `pbs_pbs_url` (default `backup.mgmt.internal`), `pbs_state_node`, `pbs_is_external`, `pbs_is_local`; `pbs_migrate_placement_state` (§4.1 backfill) and `pbs_legacy_pbs_node` (finds where a legacy PBS actually runs).
- **The resolved node moved into the state.** `node:<name>` carries it; `.node` is now only the §2.1 discovery constraint (shipped empty = search every node). This was forced by the 3-way merge: `.node` is a release field, so the merge resets it to the release default (#581 rule 4) *before* the module's `update.sh` runs — writing the resolved node there could not survive. `pbs_node()` (pbs-job.sh), `backup-controller`, `restore.sh` and `backup-manage.sh` all read the state first and fall back to `.node`.
- **install.sh / update.sh** branch on the state: `external` records + reconciles clients + points at `use-external` (registration is P11); `node:<name>` realizes/keeps the datastore; `shim` warns and exits 0. `update.sh` migrates legacy state first, backfills a pre-ADR-012 install to `node:<name>` **without a promotion-reinstall**, and still promotes a shim in place.
- **Schema (P12)** in `services/vm/fields.json` (D15 — *not* `module-fields.json`, which since #567 holds only the generic fields): `placement` removed; `placementState` re-spec'd (ships empty, pattern accepts the legacy `local`/`remote-only` for one release so a not-yet-migrated config still validates — **D23**); `pbsUrl` added; `pushTarget`/`alwaysBackup` marked deprecated. `backup.json`: `placement` gone, `node: ""`, `pbsUrl` default, `provides: ["vm"]` (`remote`/`external` were runtime peer roles nothing ever depended on; dropping `external` also clears the clash with the new state name).
- **KI-1 was already fixed upstream** — `regroup_to_pattern_a` consults `provides` today, and a dry-run over the live and source `backup.json` emits zero orphan warnings. Verified, not re-fixed; the tracker's KI-1 entry is stale.
- **TS manager** follows the model: `Placement` gains `kind`/`node`/`pbsUrl` (legacy values folded in by `classifyPlacement`), `validate` reports external/unresolved, `placement` prints the state.
- **Tests:** `test-pbs-placement.sh` rewritten (44, was 20) + new `test-pbs-migrate.sh` (23) covering the whole derivation matrix and every legacy-fixture path; backup suite **103/0 offline**, module-manager **123/0**, backup-manager **26/0 + TS 77/0** (was 60), backup-controller **11/0**; shellcheck clean on all changed scripts (only pre-existing warnings remain).
- **Live on the 3-node cluster** (`update-module.sh backup`): merge dropped `placement`, added `pbsUrl`, reset `node` to `""`; `placementState` migrated `local` → **`node:tappaas3`**; the cluster backup job (9 VMIDs, 21:00) and `/etc/pve/storage.cfg` came out **byte-identical**; consumer test (`nextcloud`) 4/0 with 17 backups, newest 13h old. `backup-manager placement/peers` and `backup-controller job-status/namespaces` verified against the migrated config.
- **Gap found live** — the deep tier caught `backup-controller`'s own `pbs_node()` override still reading `.node`, which the merge had just blanked: PBS became unreachable to the controller. Fixed to read the state first; deep tier green afterwards. Offline tests could not have surfaced it (the override only exists in the installed controller).
- **Pre-existing finding, not caused by this work:** `backup-manager validate` errors with *"modules have backup enabled and are wired into the PBS job, but site.backup.target is not set"* — this site's `site.json` has `backup: null` while 9 modules are in the job. P14 needs `site.backup` anyway (`defaultSchedule`), so it is fixed there.

Append-only narrative per package. Add an entry when a package starts, blocks, or completes.

### 2026-07-05 — Fix: DNS test excludes datastore-less backup (shim/remote-only)
`network/test.sh` "Standard 4: DNS for in-cluster modules" failed on a shim (`✗ DNS cannot resolve backup.mgmt.internal`): a shim has `vmname: backup` but realizes no local host, so it has no DNS record by design (a local backup registers `backup.mgmt.internal → PBS node IP` in install.sh; a shim exits before that and has no IP). Fixed by skipping modules with `placementState` in {`shim`,`remote-only`}, mirroring the existing `aliasType=network` exclusion. Verified live on tappaas1's shim — Standard 4 now excludes backup and resolves identity/logging/network; full network suite 50/0.

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

### 2026-07-05 — Slice 3: P7 tooling — TS layer (operator choice), built + verified on cicd
Operator chose "push into the TS layer" (2026-07-05). Extended the TypeScript `backup-manager` + made the bash `backup-controller` endpoint-tolerant.
- **backup-manager (TS)** — `types.ts` adds `Placement` + `Peer`; `config.ts` adds `readPlacement()` (backup.json placement/placementState/pbsStorageName/pushTarget) and `listPeers()` (remote-/external-/push-<n> → pull/receive/push); `main.ts` adds verbs **`placement`** and **`peers`** (+ `--json`), a **shim warning in `validate`**, and a global **`--pbs <host>`** flag; `client.ts` **CliClient is endpoint-agnostic** — constructed with a PBS endpoint, it prefixes every controller call `--pbs <host>` so the same ops drive local or a satellite PBS. `listModules` now also skips `push-` configs.
- **backup-controller (bash)** — `parse_args` accepts/strips `--pbs <host>`; `pbs_node` is overridden to honor it for PBS-datastore ops (cluster-job pvesh stays local). Full satellite targeting (tunnel FQDN) validates on the cluster.
- **Verified on cicd:** `nix-build` (tsc **strict** + noUnusedLocals) green; TS unit test **60/0** (14 new placement/peers asserts); live verbs against the shim config — `placement`, `placement --json`, `peers`, `validate` (emits the shim warning), `reconcile --pbs satellite.example` (targets endpoint → offline preview); `backup-controller` test.sh **11/0** and accepts `--pbs`.
- **Remaining:** **P9** (compromise-isolation test suite, QUICKREF/TEST consolidation doc, ADR Draft → Proposed).

### 2026-07-05 — Slice 4: P9 docs + test plan (offline)
- **QUICKREF.md** — new "ADR-012 — Placement, off-site push, subset, immutability" section: placement/shim table + promote flow, the off-site symmetry table (pull `add-remote` / receive `add-external` / send `add-push`), subset (`groupFilter`) + independent retention, opt-in `immutableSnapshots`, and the endpoint-agnostic `backup-manager --pbs` tooling. Plus the `backup-manager placement|peers|validate` verbs.
- **TEST.md** — documented the full ADR-012 unit suite (placement 20 / client 4 / push 3 / immutable 7 / TS 60) **and** the **compromise-isolation suite (#389)** as a concrete 6-step live checklist to run on the 3-node cluster (pull delete-denied, push write-no-delete, immutability holds, subset, remote-only restore with/without key, simulated compromise).
- **ADR acceptance** checkboxes updated: 8/11 done (live-verified or offline+cicd); the 2 genuinely two-PBS tests (compromise isolation, restore-from-off-site) + ADR→Proposed remain **cluster/operator-pending**.
- **ADR status stays Draft** — advancing to Proposed is the operator's call after the cluster live tests.

**Summary — P1–P9:** P1/P2/P3 live-verified on tappaas1; P4/P5/P6/P8 implemented + offline-green; P7 (TS) built + verified on cicd; P9 docs + live test plan. What remains is purely **live validation on the incoming 3-node + tankc cluster** (off-site push/pull/subset/immutability/restore + the compromise-isolation suite) and the operator's Draft→Proposed sign-off.
