# ADR-019 — HA and Cross-Node VM Migration Policy

| | |
|---|---|
| **Status** | **Proposed** — design for the full restructure. The tactical fix (**#528 → PR #529**) is applied first as an interim step; this ADR is the target it is superseded by. |
| **Version** | 0.3 |
| **Date** | 2026-09-01 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007f Realization](<ADR-007f - Realization.md>) (managers orchestrate; controllers do the imperative cluster actions) |
| **Refines** | [ADR-007d Site](<ADR-007d - Site.md>) (module config as the declared source of truth), [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`cluster:vm`, the `ha` service), [ADR-017 Update scheduling](<ADR-017 - Update scheduling and mothership self-update.md>) (the reboot pass that evacuates nodes) |
| **Related** | **#528** (restore_ha replayed pre-migration priorities → stuck `migrate`) — **fixed by PR #529** (`ha_nodes_prefer`), applied after the hrossen.dk health check; **#434** (stop-before-migrate sequencing); **#207** (config normalization); the `strict`/`comment` round-trip gap (open). **owner:** proxmox-controller (migration primitive), `module-manager` (`modify`, `migrate`), `site-manager` (`evacuate`) |
| **Numbering note** | ADR-018 is reserved by the SSH-identity PR #523. This ADR is **019**. |
| **Changelog** | v0.1 initial matrix. v0.2 operator input: `cputype: host` too coarse (needs a real compat test), layering established, re-home = `modify`. v0.3 restructure: treat #528/#529 as done; **goal = node placement and HA management reachable only through the managers**; document how Proxmox HA pinning fails over **and back**; split scenarios A/B into `modify` vs `migrate`; add site-manager **evacuate** as scenario C (incl. the "on its HANode, being evacuated" case); catalogue the **known challenges** already fixed so re-implementation does not reintroduce them. |

## Context

`migrate-vm.sh` (proxmox-controller) moves a module's VM between Proxmox nodes. Two independent facts
make "just move it" wrong more often than right on a real TAPPaaS cluster:

1. **Heterogeneous CPUs + `cputype: host`.** The reference cluster's three nodes are three AMD
   generations — tappaas1 (EPYC 4464P, Zen 4), tappaas2 (Ryzen AI MAX+ 395, Zen 5), tappaas3
   (Ryzen 7 5825U, Zen 3). `cputype: host` passes the physical flags into the guest, so a **live**
   migration *can* fail (the guest would see its CPU change) and then the move needs a stop → migrate
   → start (downtime). But this is **pair-specific, not universal**: tappaas1 → tappaas3 live-migrates
   fine today. A real per-pair compatibility test is needed, not the blunt "`host` ⇒ offline".

2. **HA-managed VMs carry placement policy in Proxmox node-affinity rules.** e.g. `ha-network` pins
   OPNsense (`vm:110`) to `tappaas1:2,tappaas3:1`, `strict 1`, comment *"WAN-capable nodes only:
   tappaas2 has no WAN cable."* Get the priorities or `strict` wrong and the CRM fights the operator —
   which is exactly #528.

The current script grew ad-hoc: it **requires** `HANode`, **toggles** the VM between `.node` and
`.HANode`, **silently falls back** to a disruptive offline migration, and lets callers pass a raw
target node. This ADR replaces that with one policy and one ownership model.

**Goal: node placement and HA management are reachable *only* through the managers.** No operator or
script drives `qm migrate` / `ha-manager` / `pvesh …/ha/rules` directly. Placement *intent* lives in
`module.json` (`.node`, `.HANode`, `cputype`, the `ha` service); the managers realize it; the
proxmox-controller is the only thing that touches the cluster.

## How Proxmox HA pinning works (failover *and* failback)

TAPPaaS pins an HA VM with a **node-affinity rule** so the CRM both fails it over when a node dies and
brings it back when the node returns — automatically, without an operator in the loop:

- **Rule shape:** `nodes = <n1>:<prio>,<n2>:<prio>,…`. **Higher priority wins**; the CRM keeps the VM
  on the highest-priority *online* node in the list. e.g. `tappaas1:2,tappaas3:1` ⇒ "run on tappaas1;
  if tappaas1 is down, run on tappaas3."
- **Failover:** node with the running VM goes down → CRM starts it on the next-highest-priority online
  node (tappaas1 dies → VM comes up on tappaas3).
- **Failback:** the higher-priority node returns → CRM migrates the VM back to it (tappaas1 back ⇒ VM
  returns to tappaas1). This automatic return is *desired* for failover, and is exactly the trip that
  #528 turned pathological when the priorities were left pointing at the wrong node after a *manual*
  migration.
- **`strict 1`:** the node list is a hard boundary — the VM may run **only** on listed nodes (never a
  node absent from the rule). This is what keeps OPNsense off tappaas2 (no WAN).
- **`comment`:** documents the rule's intent; load-bearing for humans, must survive edits.

**Consequence for this ADR:** a *manual* placement change must re-point the priorities so they agree
with where the VM now belongs — otherwise the CRM's automatic failback immediately undoes the move.
Manager code owns that reconciliation; it is never left to the operator.

## The two sources of truth

| | Declared (config) | Runtime (cluster) |
|---|---|---|
| **Home / target nodes** | `module.json.node` (primary), `module.json.HANode` (HA secondary) | the node the VM runs on |
| **HA placement** | `services: […, ha]`, `cputype` | the node-affinity rule (nodes, priorities, `strict`, `comment`) |

Config is intent; the runtime rule is **derived** from it. The rule's membership = `{.node, .HANode}`,
its `strict`/`comment` fixed by policy, its priorities re-pointed to wherever the VM currently belongs.

## Realization & ownership (the layering — this is the goal)

| Layer | Owns | Responsibility |
|---|---|---|
| **proxmox-controller** (VM controller) | the migration **primitive** | move *this* VM A→B: live if the compat test passes, else offline under `--force`; round-trip the **full** HA rule (nodes+priorities+`strict`+`comment`). No config knowledge, no fleet logic. `migrate-vm.sh` folds in here. |
| **module-manager** | per-module orchestration + config | **`modify`** — change any `module.json` field on a live install (incl. `.node`/`.HANode`) and take the deploy action it implies. **`migrate`** — realize the *current* config placement (no node argument). Calls the controller primitive; owns the rule reconciliation. |
| **site-manager** | site/fleet orchestration | **`evacuate <node>`** — clear a node, calling *module-manager* per module (never the controller directly), honoring HA policy. Used by ADR-017's reboot pass. |

## The verb model — `modify` vs `migrate`

- **`module-manager modify <module> --set node=… [--set HANode=…]`** changes *intent*. It rewrites
  `module.json` (as `tappaas`, never root) **and drives the deploy action** to realize it — for a node
  change, that is a migration plus a rule-membership/priority update. **This is the only way to place a
  VM on a node it wasn't already configured for.**
- **`module-manager migrate <module>`** changes *runtime placement only*, within the already-declared
  `{.node, .HANode}`. **It takes no node argument.** Semantics: if the VM is on its primary `.node`,
  move it to `.HANode` (planned failover, e.g. for maintenance); if it is on `.HANode`, move it back to
  `.node` (failback). To go anywhere else, `modify` first. (This replaces the old `migrate-vm.sh
  --node <node>` fleet helper, which is renamed/absorbed — see `evacuate`.)

Rule of thumb: **migrate never invents a destination; modify never leaves config and reality
disagreeing.**

## Scenarios

`live-OK` = the CPU-compat test (see Open Questions) says this source→target pair can live-migrate —
*not* merely `cputype == host`. `cputype != host` is always live-OK.

### A. Non-HA module (no `ha` service, no affinity rule)

**A via `modify` (`.node` changed → re-home):**

| # | Situation | Policy |
|---|---|---|
| A-M1 | `--set node=<new>`, live-OK | Rewrite `.node`; live-migrate to `<new>`. No HA rule exists to touch. |
| A-M2 | `--set node=<new>`, **not** live-OK, no `--force` | Rewrite refused *before* acting (or staged): "moving to `<new>` needs a stop/start (downtime) — rerun with `--force`." No silent offline. |
| A-M3 | `--set node=<new>`, `--force` | Rewrite `.node`; stop → migrate → start → confirm RUNNING. |

**A via `migrate`:** a non-HA module has no `.HANode`, so `migrate` has no second node to move to →
**refuse**: "module has no HANode; use `modify --set node=…` to relocate a non-HA VM." (No silent
invention of a target.)

### B. HA module (`ha` service + node-affinity rule), healthy

**B via `migrate` (runtime only, config unchanged):**

| # | Situation | Policy |
|---|---|---|
| B-G1 | on `.node`, `migrate` → `.HANode`, live-OK | Live-migrate; **re-point priorities** so `.HANode:2`, `.node:1`; preserve `strict`/`comment`. `.node` unchanged. |
| B-G2 | on `.HANode`, `migrate` → `.node`, live-OK | Symmetric: priorities re-pointed to `.node`. |
| B-G3 | `migrate`, **not** live-OK, no `--force` | **Refuse** — never trigger the return trip that cannot run (#528). |
| B-G4 | `migrate`, `--force` | HA-aware offline: remove HA → stop → migrate → start → re-add HA → recreate the **full** rule pointing at the target. Roll back to source on any failure. |
| B-G5 | already on the target of the toggle | No-op — but **reconcile** the rule if its priorities don't already prefer the current node (heals a pre-#529 rule). |

**B via `modify` (intent changed):**

| # | Situation | Policy |
|---|---|---|
| B-M1 | `--set HANode=<new>` | Rewrite `.HANode`; update the rule **membership** to `{.node, <new>}` (keep `strict`/`comment`); no migration unless the VM currently sits on the node being removed, in which case migrate it to a surviving member first. |
| B-M2 | `--set node=<new>` (re-home primary) | Rewrite `.node`; rule membership `{<new>, .HANode}`; migrate the VM to `<new>` (live-OK / `--force` rules apply) and re-point priorities to it. |
| B-M3 | `modify` that would place the VM outside a `strict` rule | Allowed **only** through `modify` (it edits the rule membership too); a bare `migrate` to a non-member is still refused (scenario C/B invariants). |

### C. site-manager `evacuate <node>` (node maintenance)

Clear every VM off `<node>`, per module, honoring HA policy. For each module currently on `<node>`:

| # | Situation | Policy |
|---|---|---|
| C1 | `<node>` is the module's **primary** `.node`; `.HANode` is up & live-OK | `module-manager migrate` → move to `.HANode` (planned failover). Priorities re-pointed to `.HANode`. |
| C2 | `<node>` is the module's **`.HANode`**; primary `.node` is up & live-OK | `migrate` → back to `.node`. |
| C3 | **`<node>` is the module's `.HANode` AND the VM is currently on its `.HANode`** (it had already failed over here) | **This is the case to guard.** The VM is at its failover location; evacuating `<node>` means sending it to `.node`. Allowed **only if** `.node` is online and live-OK. If `.node` is **down/unreachable**, there is **nowhere valid** — `evacuate` must **refuse for this module and report it**: "vm:X is on its HANode (`<node>`) and its primary (`.node`) is unavailable — restore the primary or `modify` its placement before evacuating." Never strand it on an ad-hoc node. |
| C4 | `strict` rule and `<node>` was the last online member | **Refuse** — cannot satisfy `strict`; report it. Do not break `strict` to make room. |
| C5 | non-HA VM on `<node>` | Cannot auto-`migrate` (no `.HANode`); **report as requiring `modify --set node=…`** (a re-home decision), or move only if the operator supplies a target via modify. Not silently relocated. |
| C6 | any module needs `--force` (not live-OK) to leave | **Report as blocked on `--force`** (downtime) rather than silently stopping it. Evacuate proceeds for the rest and returns a clear per-module summary. |

`evacuate` is all-or-summary: it migrates what it safely can, and returns a per-module verdict
(moved / blocked-on-force / refused-no-valid-target / refused-strict / needs-modify) so the reboot
pass (ADR-017) can decide whether the node is safe to take down.

## Known challenges — regression guards (do not reintroduce on re-implementation)

The current `migrate-vm.sh`/`test-migrate-vm.sh` already encode hard-won invariants. The rewrite MUST
carry them forward (and keep their tests green):

| Guard | Origin | Invariant to preserve |
|---|---|---|
| Restored rule prefers where the VM **now is** | **#528 / PR #529** (`ha_nodes_prefer`) | After a move the affinity priorities point at the destination, so the CRM does not immediately fail it back. |
| Stop-before-migrate, confirmed | **#434** | The VM is **confirmed stopped** before `qm migrate`; a stop that never completes **aborts** (no migrate, no HA-remove); the stop result is confirmed, not discarded after N polls. |
| Config read once, flat/Pattern-A agnostic | **#207** | Normalize `module.json` once (`read_module_config`); don't re-parse or assume flat vs nested. |
| Non-HA VM stays non-HA | test invariants | A VM with no `ha` service is never removed from HA, never reported HA-managed, and **never has an affinity rule invented**. |
| HA status parsed exactly | test invariants | `ha-manager status` parsing must not mistake a node name for a state, and a decoy VMID (`vm:1300`) must not answer for `vm:130` (no substring matches). |
| **Full rule round-trip** | this ADR (gap today) | `save`/`restore` carry `strict` **and** `comment` (and any second rule, e.g. resource-affinity) — not just `nodes`. Today they are dropped; on `ha-network` that silently removes the WAN pin. |
| No silent disruptive fallback | this ADR | Live-impossible ⇒ **refuse and require `--force`**, never a surprise stop/start. |
| Never leave the VM stopped / de-HA'd | this ADR | Every path ends VM-running-on-one-node with HA + rules restored; failure rolls back to source. |

## Testing (fast + `--deep`)

Two tiers (ADR-013 / `src/foundation/TESTING.md`): **fast** offline (default) and **deep** live
(`TAPPAAS_TEST_DEEP=1` / `--deep`). Build on the existing `proxmox-controller/test-migrate-vm.sh`
stub (sources the script with a `ssh()`/`TAPPAAS_HAVM_EXEC` stub modelling the CRM, asserts on the
command log; PR #529 already added a configurable rules response + the priority-direction assertions).
`TESTING.md` currently records cluster's deep tier as *"live migration not exercised"* — the deep tier
below closes that.

**Fast tier — extend the stub to the whole matrix (no cluster).** Model a rule with priorities +
`strict` + `comment`, and let a test inject the live-compat verdict + per-node `cputype`. Assert, per
scenario, on the log (one-line invariants):

| Case | Fast assertion |
|---|---|
| A-M1/A-M3 | `.node` rewritten; migrate issued; HA never touched |
| A-M2, B-G3 | **refuses** without `--force`; VM never stopped; no `qm migrate` |
| A-migrate, C5 | non-HA `migrate` refused ("no HANode; use modify") |
| B-G1/B-G2 | priorities re-pointed to target (#529) **and `strict`+`comment` present in the recreated rule** |
| B-G4 | remove → stop → migrate → start → add → recreate full rule |
| B-M1/B-M2 | membership updated to the new `{.node,.HANode}`; migrate only when the VM sits on a removed node |
| C3 (primary down) | evacuate **refuses that module** with the "on HANode, primary unavailable" message |
| C4 | `strict` last-member evacuation refused |
| Rollback | injected `qm migrate` failure → VM ends **running on source**, HA restored |
| #434, #207, non-HA, decoy-VMID | existing guards stay green |

Keep the **mutation-testing** discipline: strip each guarantee (the `strict` carry-over, the
refuse-without-`--force`, the re-point) and confirm the *specific* assertion — and only it — goes red.

**Deep tier (`--deep`, live, disposable fixture VM):**

1. Create a throwaway HA VM with a node-affinity rule on a **known-compatible** pair; `migrate` it via
   the module-manager verb; assert it lands on the target, the rule prefers the target, `strict` +
   `comment` survive, and `ha-manager status` settles to `started` (never stuck `migrate`). Self-clean,
   like `cluster/test.sh`'s storage-drift deep test.
2. **CPU-compatibility experiment (feeds Open Question 1):** for each ordered node pair, attempt a live
   migrate of a `cputype: host` fixture and record success/failure → the empirical matrix the real
   live-vs-offline predicate is built from. Cluster-specific, run rarely, never on production VMs.

## Consequences

- **Positive:** one policy; placement and HA reachable only through managers (auditable, testable);
  #528's stuck-`migrate` structurally impossible; the WAN pin survives migration; non-HA VMs become
  relocatable via `modify`; `evacuate` refuses unsafe moves instead of stranding a VM.
- **Cost:** `migrate` loses its node argument (callers move to `modify` for relocation); the silent
  offline fallback becomes an explicit `--force`; `save`/`restore` grow to the full rule; a real
  compat test must be built. `ha_nodes_prefer` (PR #529) is retained as the re-pointing primitive.
- **Superseded:** the current "require `HANode`, toggle, raw `--node`, silent offline" flow.

## Open questions

1. **CPU-compatibility test (the key study).** `cputype: host` is too coarse — tappaas1 ↔ tappaas3
   live-migrate today. Study candidates: intersect per-node advertised CPU flags
   (`/nodes/<n>/capabilities/qemu/cpu`), KVM's own migration-compat check, or a short-timeout live
   **dry-run + rollback** probe. Until it exists: attempt live, and on genuine failure refuse + ask
   for `--force` (never silent offline).
2. **`strict` override** — is there ever a legitimate `--break-strict`, or must a strict rule always
   change via `module-manager modify` first? Draft: modify-first only.
3. **`evacuate` return-home** — does the reboot pass auto-`migrate` VMs back after the node returns, or
   rely on the CRM's own failback (which the re-pointed priorities now make correct)? Prefer letting
   HA fail back; `evacuate --return` only for non-HA VMs that were `modify`-relocated.
