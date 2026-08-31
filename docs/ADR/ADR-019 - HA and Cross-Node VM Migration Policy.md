# ADR-019 — HA and Cross-Node VM Migration Policy

| | |
|---|---|
| **Status** | **Proposed** — draft (design before the fix; not implemented) |
| **Version** | 0.1 |
| **Date** | 2026-08-31 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007f Realization](<ADR-007f - Realization.md>) (managers/controllers own the imperative cluster actions) |
| **Refines** | [ADR-007d Site](<ADR-007d - Site.md>) (module config as the declared source of truth), [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` — here `cluster:vm` and the `ha` service) |
| **Related** | **#528** (restore_ha replays pre-migration priorities → stuck `migrate`), **PR #529** (narrow fix: re-point priorities at the target), the adjacent gap this ADR also covers (`strict`/`comment` dropped on rule recreate); **owner:** `proxmox-controller` (`migrate-vm.sh`), `cluster:vm` / `cluster:ha` services, `module.json` schema |
| **Numbering note** | ADR-018 is reserved by the pending SSH-identity PR #523 ("SSH Identity Resolution Under Sudo"). This ADR takes **019** to avoid the collision; renumber if #523 lands differently. |
| **Changelog** | v0.1 — initial draft: define the full migration matrix (HA / non-HA × live-possible / not × in-policy / not), make offline (stop+start) migration an explicit `--force` action rather than a silent fallback, define when `module.json.node` is rewritten, and require the **full** HA rule (nodes+priorities+`strict`+`comment`) to round-trip. <br> v0.2 — resolve open questions with operator input: `cputype: host` is **too coarse** a live-migration test (tappaas1→tappaas3 migrate live today despite differing CPUs) — a real compatibility test is required and needs its own study; establish the **layering** (proxmox-controller migration primitive ← `module-manager` `modify`/force-migrate ← `site-manager` evacuate); re-homing an HA VM becomes a `module-manager modify` of `.node`/`.HANode`, not a migrate flag; **short term = ship PR #529**, target architecture lands with the `module-manager modify` work; add a **Testing** section (fast stub matrix extending `test-migrate-vm.sh` + a `--deep` live tier that closes the `TESTING.md` "live migration not exercised" gap and runs the CPU-compat experiment). |

## Context

`migrate-vm.sh` (proxmox-controller) moves a module's VM between Proxmox nodes. Two independent
facts make "just move it" wrong more often than right on a real TAPPaaS cluster:

1. **The cluster is CPU-heterogeneous and VMs run `cputype: host`.** On the reference cluster the
   three nodes are three different AMD generations — tappaas1 (EPYC 4464P, Zen 4), tappaas2
   (Ryzen AI MAX+ 395, Zen 5), tappaas3 (Ryzen 7 5825U, Zen 3). `cputype: host` (the schema
   default, chosen for performance) passes the physical CPU's flags into the guest, so a **live**
   migration between two nodes *can* fail — the running guest would see its CPU change underneath it
   — and then the move needs a **stop → migrate → start** (offline), i.e. real downtime. But this is
   **pair-specific, not universal**: tappaas1 → tappaas3 live-migrates fine today despite the
   generation gap. So the platform needs a real per-pair compatibility test, not the blunt assumption
   "`host` ⇒ offline" (Decision 3 / Open Questions).

2. **Some VMs are HA-managed with node-affinity rules that encode placement policy.** e.g.
   `ha-network` pins the OPNsense VM (`vm:110`) to `tappaas1:2,tappaas3:1` with `strict 1` and the
   comment *"WAN-capable nodes only: tappaas2 has no WAN cable."* The rule is not just a
   preference — `strict 1` is a hard constraint, and the priorities decide where the CRM keeps the
   VM. Get them wrong and the CRM fights the operator.

Today's script sits awkwardly between these. It **requires** a `HANode` in `module.json` and dies
without one (no path for a non-HA VM); it **toggles** the VM between `.node` and `.HANode`; and on a
live-migration failure it **silently falls back to a disruptive offline migration** with no operator
consent. #528 exposed the sharpest edge: `restore_ha()` recreated the affinity rule from the
*pre-migration* snapshot, so after a move the rule still preferred the source node, the CRM tried to
live-migrate the VM straight back, that return trip failed on the CPU mismatch, and the service stuck
in state `migrate` until the priorities were fixed by hand. PR #529 fixes that one direction; it does
not define the policy for the rest of the matrix, and it does not preserve `strict`/`comment` when it
recreates the rule (so a `migrate-vm.sh` on `vm:110` silently drops the WAN pin — HA could then place
OPNsense on tappaas2, which has no WAN).

This ADR defines the whole policy **before** widening the fix.

## The two sources of truth

| | Declared (config) | Runtime (cluster) |
|---|---|---|
| **Home node** | `module.json.node` — where the VM belongs / is (re)installed | the node it is currently running on |
| **HA placement** | `module.json.HANode` + `services: [… , ha]` + `cputype` | the HA node-affinity rule in `rules.cfg` (nodes, priorities, `strict`, `comment`) |

Principle: **config is the declared intent; the runtime rule is derived from it.** Migration
reconciles runtime toward a requested placement and updates whichever source of truth is
authoritative for *that kind* of move (see "When `module.json.node` is rewritten").

## Decision

1. **Offline migration is an explicit, consented action — never a silent fallback.** A live
   migration is attempted only when it can succeed (CPU-compatible, see §3). When live is impossible
   or fails, the script **refuses** and tells the operator to rerun with `--force` (which performs the
   stop → migrate → start, incurring downtime). `--offline` remains as the explicit "skip the live
   attempt" form and implies the same consent as `--force`.

2. **`strict`/`comment` and every rule referencing the VM round-trip in full.** `save_ha_state`
   captures the complete node-affinity rule (name, nodes, priorities, `strict`, `comment`) — and any
   other rule (e.g. resource-affinity) that references the VM — and `restore_ha` recreates them
   faithfully, only **re-pointing the node-affinity priorities** at the destination (#528/#529). A
   strict rule's membership is never silently changed.

3. **Live-vs-offline is decided by a real CPU-compatibility test — not by `cputype` alone.**
   `cputype: host` is **too coarse** to mean "cannot live-migrate": on the reference cluster a live
   migration tappaas1 → tappaas3 succeeds today even though the CPUs differ (EPYC Zen 4 vs Ryzen
   Zen 3). So the naive "host ⇒ incompatible" rule would wrongly force downtime on moves that work.
   The gate must be an **actual compatibility check** for the specific source→target pair — and
   getting that right needs its own study (see Open Questions). Until that test exists, keep the
   current live-first-then-report behavior but **stop the silent disruptive fallback** (Decision 1):
   attempt live; if it genuinely fails, refuse and ask for `--force`, rather than stopping the VM
   unasked. `cputype != host` remains trivially live-OK.

4. **`strict` node-affinity is a hard boundary.** Migration to a node **not** in a strict rule's
   membership is refused outright (not overridable by `--force`) — the operator must change the rule
   first. This is what keeps OPNsense off a WAN-less node.

5. **A migration never leaves the VM stopped or the HA resource removed.** Every path ends with the
   VM running on exactly one node and its HA registration + rules restored; a failure rolls back to
   the source.

## Realization & ownership (layering)

Migration is not one script's job — it splits across the three ADR-007f layers, so the imperative
mechanism stays thin and the policy/orchestration lives in the managers:

| Layer | Owns | Responsibility |
|---|---|---|
| **proxmox-controller** (VM controller) | the migration **primitive** | `migrate-vm.sh` (folded into the proxmox-controller) does exactly one thing: move *this* VM from A to B — live if the compatibility test passes, else offline under `--force` — and round-trip the full HA rule. No config knowledge, no fleet logic. |
| **module-manager** | per-module **orchestration + config** | `modify` (below) applies a `.json` change to a live installation and takes the deploy action it implies; a **force-migrate verb** moves an HA-protected module to its declared `HANode` (and back). Calls the controller primitive. |
| **site-manager** | site/fleet **orchestration** | **evacuate a node**: enumerate the modules on `<node>` and, for each, call the *module-manager* migrate code (never the controller directly) so per-module policy (HA rules, `strict`, compat) is honored. |

**`module-manager modify` is where re-homing happens.** Every module `.json` field is modifiable on a
live installation, and `node` + `HANode` are among them. `module-manager modify <module> --set node=…`
(and `HANode=…`) rewrites the config **and takes the appropriate deploy action** — which for a node
change *is* a migration. So:

- A **temporary** move (maintenance, failover) = a **migrate** (force-migrate verb / evacuate): runtime
  placement changes, the affinity priorities re-point, but the declared `.node` is unchanged.
- A **permanent** re-home = a **`modify`** of `.node`/`.HANode`: config changes, and the modify drives
  the migration + rule update to realize it.

This resolves the earlier "does a migrate rewrite `.node`?" question: **migrate does not, modify does.**
(Scenario A's "rewrite `.node`" for non-HA VMs therefore belongs to `modify`, once it exists — see
Phasing.)

### Phasing

- **Short term (now):** ship **PR #529** — the priority-re-point (`ha_nodes_prefer`) that unsticks the
  #528 `migrate` loop. No architecture change; keep the current `migrate-vm.sh` entry point.
- **Target:** land this policy **with the `module-manager modify` work** — the controller primitive,
  the `modify` verb (incl. `node`/`HANode`), the force-migrate verb, and site-manager evacuate — plus
  the real CPU-compatibility test. Track under that issue.

## Scenarios

Legend: **HA?** = module declares the `ha` service / has an affinity rule. **live-OK** = the
CPU-compatibility test (Decision 3, TBD) says this source→target pair can live-migrate — *not* simply
`cputype == host`. `cputype != host` is always live-OK.

### A. Non-HA VM (no `ha` service, no affinity rule)

| # | Situation | Policy |
|---|---|---|
| A1 | Non-HA VM, target reachable, **live-OK** | Plain `qm migrate --online`. On success **rewrite `module.json.node = target`** (this *is* a re-home; the config becomes authoritative so a later reconcile/reinstall lands it there). |
| A2 | Non-HA VM, **live impossible** (compat test / live attempt fails), no `--force` | **Refuse**: "live migration to <target> isn't possible for this VM — rerun with `--force` for a stop/start migration (service downtime)." No silent offline. |
| A3 | Non-HA VM, live impossible, **`--force`/`--offline`** | Stop → `qm migrate` (offline) → start → confirm RUNNING → **rewrite `module.json.node = target`**. |
| A4 | Non-HA VM currently **stopped** | Offline migrate (no live question); start only if it was meant to be running; rewrite `.node`. |
| A5 | Non-HA VM, **`cputype != host`** | Live migrate even across generations; rewrite `.node`. |
| A6 | Target == current node | No-op. |

> Today's script cannot do A at all (it dies on a missing `HANode`). Supporting non-HA migration —
> and having it update `module.json.node` — is a new capability this ADR authorizes. The config
> write happens **as `tappaas`** (never root); see the ownership rule in the SSH/preflight work.

### B. HA VM (`ha` service + node-affinity rule), healthy/running

| # | Situation | Policy |
|---|---|---|
| B1 | On primary (`.node`), migrate to **HANode**, live-OK | Live migrate; **re-point the affinity priorities** so HANode:2, others:1 (#528). Preserve `strict`/`comment`. **Do NOT rewrite `.node`** — this is a runtime placement (e.g. maintenance), the declared home is unchanged. |
| B2 | On HANode, migrate **back to primary**, live-OK | Symmetric to B1: priorities re-pointed to primary; `.node` unchanged. |
| B3 | HA move, **live impossible**, no `--force` | Refuse (as A2). The return-trip-that-cannot-succeed is exactly #528's stuck-`migrate`; never trigger it implicitly. |
| B4 | HA move, live impossible, **`--force`** | HA-aware offline: **remove HA resource → stop → migrate → start → re-add HA → recreate the full rule** with priorities pointed at the target. All-or-nothing; roll back to source on any failure. |
| B5 | Target **not in a `strict` rule's membership** (e.g. `vm:110` → tappaas2) | **Refuse, not overridable.** "target is outside the strict node-affinity rule (WAN-capable nodes only) — change the rule first." |
| B6 | Target in membership but a **non-strict** rule | Allowed; re-point priorities; optionally warn if target has priority 1 (a lower-preference node). |
| B7 | VM already on target | No-op, but **reconcile the rule** if its priorities don't already prefer the current node (heals a rule left wrong by a pre-#529 run). |
| B8 | Multiple rules reference the VM (node- **and** resource-affinity) | Save/restore **all**; only node-affinity priorities are re-pointed; resource-affinity is preserved verbatim. |

### C. HA VM, unhealthy or stopped

| # | Situation | Policy |
|---|---|---|
| C1 | VM **stopped** | No live question — offline migrate; re-point priorities to target; start (or leave stopped if it was administratively stopped). Still `--force`-gated? No: there is no running service to disrupt, so offline is the only mode and needs no downtime consent — but confirm the VM was not mid-transition. |
| C2 | VM in HA state **`migrate`/`error`** (e.g. a prior #528 victim) | First **stabilize**: correct the rule to prefer the current node so the CRM stops fighting, confirm it settles to `started`, *then* perform the requested migration. Migrating a VM the CRM is already fighting just deepens the stuck state. |
| C3 | Requested source node **unreachable** / fenced | This is a failover, not a migration — out of scope for `migrate-vm.sh`; leave it to HA. The script refuses and points at `ha-manager`. |

### D. Fleet / node-level

| # | Situation | Policy |
|---|---|---|
| D1 | **Evacuate a node** (maintenance) — `migrate_to_node` / a `--evacuate <node>` | Move every VM off `<node>` to a policy-valid, **live-OK** target; HA VMs re-pointed; VMs whose only valid target is CPU-incompatible are reported as **requiring `--force`** (downtime) rather than silently stopped. Respect `strict` membership. |
| D2 | **Return VMs home** after maintenance | Move each VM whose `.node`/HANode is `<node>` back; re-point HA priorities home. This is the healthy inverse of D1 and must not itself trigger a bounce. |
| D3 | Interaction with the update sweep's reboot pass (ADR-017 Phase 3) | The reboot pass must use this policy (or delegate to it), not raw `ha-manager`/`qm migrate`, so a heterogeneous-CPU node reboot doesn't strand an HA VM in `migrate`. |

### E. Config / edge

| # | Situation | Policy |
|---|---|---|
| E1 | **Re-home** an HA VM (change its declared primary) | This is a **`module-manager modify`** of `.node`/`.HANode` (see Realization), which rewrites the config **and** drives the migration + rule-membership update to realize it. A plain `migrate`/force-migrate never silently re-homes an HA VM — it only changes runtime placement. |
| E2 | `module.json` missing `vmid` | Die early (can't act). |
| E3 | Config write-back blocked because `config/` is root-owned | Fail with the same guidance as the preflight work: "`chown -R tappaas:users ~/config`; don't use sudo." Never write config as root. |
| E4 | `cputype` is `host` but operator asserts nodes are compatible | Allow an explicit `--assume-live-ok` escape hatch (logged), for a genuinely homogeneous sub-pair — but default to safe refusal. |

## Testing (fast + `--deep`)

Testing follows the two-tier convention (ADR-013 / `src/foundation/TESTING.md`): a **fast** offline
tier (default) and a **deep** live tier gated by `TAPPAAS_TEST_DEEP=1` / `--deep`. There is already a
foundation here to expand, not start from scratch — `proxmox-controller/test-migrate-vm.sh` is a
stub-based unit test that sources `migrate-vm.sh` with `ssh()` and `TAPPAAS_HAVM_EXEC` pointed at a
`stub` script modelling the CRM (`ha-manager`, `pvesh …/ha/rules`, `qm migrate`, `pvesh get
resources`), asserting on the **logged command sequence**. PR #529 already extended it (configurable
rules response; three priority-direction assertions). Note the gap this closes: `TESTING.md` records
cluster's deep tier as *"live migration not exercised."*

**Fast tier — extend the `test-migrate-vm.sh` stub to cover the whole matrix (no cluster).** The stub
already ticks a CRM per command; grow it to model a node-affinity rule with **priorities + `strict` +
`comment`**, and to let a test inject the live-compat verdict and per-node `cputype`. Then assert, per
scenario, on the command log (each is a one-line invariant):

| Scenario | Fast assertion |
|---|---|
| A1/A5 non-HA, live-OK | `qm migrate --online` issued; HA never touched (already asserted at L200); config-write of `.node` once `modify` exists |
| A2 non-HA, live-impossible, no `--force` | **refuses** — no `qm migrate`, VM never stopped |
| A3 non-HA, `--force` | stop → migrate → start; VM **confirmed stopped before** `qm migrate` (existing #434 invariant) |
| B1/B2 HA, live-OK | priorities re-pointed to target (#529); **`strict` + `comment` present in the recreated rule** — new assertion; today they're dropped |
| B3 HA, live-impossible, no `--force` | **refuses** — the un-runnable return trip (#528) is never triggered |
| B4 HA, `--force` | remove → stop → migrate → start → add → recreate **full** rule at target |
| B5 target outside a `strict` rule | **refused, even with `--force`** |
| B7 already on target with a wrong rule | rule **reconciled** to prefer the current node |
| B8 multiple rules on the VM | all saved/restored; only node-affinity priorities re-pointed |
| Rollback | inject a `qm migrate` failure → VM ends **running on source**, HA restored |

Keep the PRs' **mutation-testing** discipline: strip each guarantee (drop the `strict` carry-over, the
refuse-without-`--force`, the re-point) and confirm the *specific* new assertion — and only it — goes
red, so every test is proven to fail for the right reason.

**Deep tier (`--deep`, live cluster, disposable fixture VM).** Closes the `TESTING.md` gap:

1. Create a throwaway HA VM with a node-affinity rule on a **known-compatible** pair, migrate it via
   the module-manager verb, and assert it lands on the target, the rule prefers the target, `strict`
   + `comment` survive, and `ha-manager status` settles to `started` (never stuck in `migrate`). Tear
   it down. Run read-only/self-cleaning, like the existing storage-drift deep test in `cluster/test.sh`.
2. **CPU-compatibility experiment (feeds Open Question 1).** For each ordered node pair, attempt a live
   migrate of a `cputype: host` fixture and record success/failure → the empirical compat matrix that
   the real live-vs-offline predicate is built from (this is how we learn tappaas1 ↔ tappaas3 is fine
   while some other pair may not be). Cluster-specific, run rarely, never on production VMs.

## Consequences

- **Positive:** one coherent policy for every migration; no silent downtime; #528's stuck-`migrate`
  becomes structurally impossible (a move that would need the bad return trip is refused up front);
  the WAN pin (`strict`/`comment`) survives migration; non-HA VMs become migratable and their config
  stays truthful.
- **Cost:** `migrate-vm.sh` grows a CPU-compatibility check and a config-write path (as `tappaas`),
  and gains `--force` semantics — a behavior change from today's silent offline fallback (operators
  who relied on that must add `--force`). PR #529's `ha_nodes_prefer` is retained as the priority
  re-pointing primitive; `save_ha_state`/`restore_ha` grow to carry the full rule set.
- **Superseded behavior:** the current "require `HANode`, toggle `.node`↔`.HANode`, silently fall
  back to offline" flow. `HANode` remains meaningful (the declared HA secondary) but is no longer a
  precondition for migrating at all.

## Open questions

1. **CPU-compatibility test (needs its own study — the key open item).** `cputype: host` is too
   coarse: tappaas1 ↔ tappaas3 live-migrate today despite different CPUs, so a blanket "host ⇒
   offline" is wrong. We need a real per-pair predicate. Candidate inputs to study: the intersection
   of each node's advertised CPU flags (`/nodes/<n>/capabilities/qemu/cpu`, `qm cpu` / `kvm -cpu ?`),
   QEMU/KVM's own live-migration compatibility check, or a cheap **dry-run probe** (attempt the live
   migrate with a short timeout and roll back). Until this exists, follow Decision 3 (attempt live;
   on genuine failure refuse and ask for `--force`) rather than guessing from `cputype`.

*(Resolved by operator input, moved into the design above:)*

- ~~Non-HA re-home always vs `--rehome`~~ → **re-home is a `module-manager modify` of `.node`**, not a
  migrate flag; a plain migrate never re-homes (see Realization / E1).
- ~~Where evacuate/return orchestration lives~~ → **site-manager evacuates, calling module-manager's
  migrate; module-manager calls the proxmox-controller primitive** (see Realization). Ties into
  ADR-017's reboot pass, which must go through this path.

2. **`strict` override** — is there ever a legitimate `--break-strict`, or must a strict rule always be
   changed via `module-manager modify` first? Draft says modify-first only.
