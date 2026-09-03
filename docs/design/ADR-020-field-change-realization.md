# ADR-020 realization — the declared-field change model, as built

**Audience:** implementers and provider authors.
**Status:** current — describes the code as it stands after ADR-020 P0–P6.
**Decision record:** [ADR-020](<../ADR/ADR-020 - Declared-Field Change Model (validate, drift, modify).md>).
Per [ADR-013](<../ADR/ADR-013 - Documentation Structure and Standards.md>) §3, the
decision lives in the ADR and *how it is built* lives here.

---

## 1. The pipeline, end to end

```
   module.json  ─────────────────┐
   module-fields.json ───────────┤
                                 ▼
                        module resolve <m>          desired.ts      [TS]
                                 │  the ONE resolver: literal value, else the
                                 │  schema default the field's usedBy admits
                                 ▼
   services/<svc>/fields.json ─► module drift <m> --service <p:s>   [TS]
                                 ▲         │
   report-service.sh <m> ────────┘         │  the ONE differ: declared
        [bash, extract only]               │  normalization on BOTH sides
                                           ▼
                                   the drift record
                                           │
                            update-service.sh --apply-drift        [bash]
                                           │
                                  converge-lib.sh                   [bash]
                          ┌────────────────┼────────────────┐
                     batched set      update-<field>.sh   side effects
                    (one qm/pct set)     hooks            once, in order
```

Four rules hold the shape together, and every one of them exists because it was
once violated:

1. **One resolver.** `lib/ts/src/desired.ts`. Service scripts do not default.
   Before, `cluster:vm/update-service.sh` had a `cfg()` ladder and `inspect.ts`
   had its own defaults, so the value *reported* could differ from the value
   *applied* (#550).
2. **One differ.** `lib/ts/src/drift.ts`. Services report raw state and apply a
   record; they never compare.
3. **Provider-specific decoding lives with the provider.** `report-service.sh`
   knows that Proxmox spells `cputype` as `cpu` and a container's MAC as
   `hwaddr=`. Nothing above it does.
4. **One actual read.** The reporter is the single read of a provider's live
   state — including values no module field declares (a preserved MAC, the
   `queues` that must never be hot-changed, `onboot`). Asking twice invites two
   answers.

## 2. What a provider ships

A provider service that owns declared fields ships two or three things.

### `services/<svc>/fields.json` — the manifest

Per field: a **change class** (what changing it costs after install) and how it
is **applied**. Schema: [`schemas/service-fields.json`](../../src/foundation/schemas/service-fields.json);
vocabulary and lint: `lib/ts/src/service-fields.ts`.

| Class | Meaning | Refused where |
|---|---|---|
| `in-place` | safe live change | — |
| `in-place-reboot` | needs a guest reboot | deferred without authorization |
| `grow-only` | one-way; shrink refused | at apply time (needs live state) |
| `migrate` | relocates runtime state | at apply time (live-OK verdict) |
| `manual` | an operator action the tool will not take silently | reported by the converge |
| `recreate` | takes effect only at creation | **static pre-gate** |
| `immutable` | cannot change in place | **static pre-gate** |

The split between the pre-gate and the converge is the load-bearing decision: a
refusal derivable from the **schema alone** is made before anything is written,
because config claiming what reality can never match would drift forever. A
refusal needing **live state** — is this size change a shrink? does this migrate
need downtime? — happens in the converge, where the snapshot wrapper can roll
back.

Apply modes: `set` (batched into one provider call), `hook`, `composite` (an
input of a derived value such as `net0`), **`reconcile`** (the service converges
the field inside an idempotent reconcile it already performs), `none`.

`reconcile` is not a cop-out, and most services need it. A firewall rule set, a
Caddy handler, a PBS job membership are not scalars a generic differ can compare
and a hook can `set`: reconciling them means adding, changing **and removing**
entries, which the plane controllers already do against the provider's own
model. Flattening such a field to a string so the generic differ could diff it
would *lose* fidelity. The manifest still declares the class, which is what makes
`modify --set proxyAllowedZones=…` a sanctioned operation instead of a hand-edit.

### `services/<svc>/report-service.sh` — actual state

Required only when some field is applied per-field (`needsActualState()`).
Prints one flat JSON object keyed by the manifest's `liveKey`s, **on stdout and
nothing else**.

> **Trap.** `info`/`warn`/`debug` in `common-install-routines.sh` write to
> **stdout**, and `check_json` warns about any field outside the schema. A module
> with one undeclared field therefore emitted a warning line ahead of the JSON
> and every parse failed. `report-lib.sh` holds the real stdout on fd 3 and
> points stdout at stderr; `report_emit` writes to fd 3. Any future
> machine-output script needs the same guard.

Exit codes are part of the contract, because the caller has different things to
say about each (#526): `0` reported · `2` usage · `3` not deployed · `4` no
cluster node answered · `5` guest absent · `6` located but unreadable.

### `services/<svc>/update-service.sh` — apply

Fetches a record (or takes `--apply-drift <file>`), sources
`tappaas-cicd/lib/converge-lib.sh`, and supplies provider callbacks:

```bash
converge_apply_set "<flag>" "<value>" ...   # one batched provider call
converge_side_effect_reboot                 # and _wait_ip / _dns / _ha_repoint
converge_apply "$MODULE" "$SCRIPT_DIR" "$DRIFT_FILE" "$CHECK" "$ALLOW_DISRUPTION" "$FORCE"
```

**Everything that is not field drift stays in this script.** That is the
migration discipline, not a concession: `cluster:lxc` keeps its `onboot=1` policy
assertion (an estate rule, not a per-module tunable, so deliberately not a
declared field), and `network:proxy` keeps its `firewallType: NONE` branch.

## 3. The hook contract

```
update-<name>.sh <module> --unit <file> [--check] [--force]
                          [--field <f> --desired <v> --actual <v>]
```

The **unit file is authoritative**; the trio is passed for single-field units so
a hook is runnable by hand. Exit: `0` applied/in-sync · `10` needs disruption
authorization (→ deferred) · `20` refused · `1` error.

The unit carries the record's `actual`, which is how a hook obtains what no
module field declares — the MAC to preserve when none is pinned, the `queues`
that must never be hot-changed on a running NIC (#194), and the `vmid`/`node`
that say where the guest is. *Handing over the unit alone leaves a hook unable to
reach the guest at all; the deep tier caught exactly that.*

Two ordering rules the runner enforces, both inherited from the imperative loop:

- a **`migrate` unit runs last** — it relocates the guest, and `qm set` is
  node-local;
- **side effects are sequenced once** across the whole record, `reboot →
  wait-ip → dns → ha-repoint`, so two changed NICs still produce one reboot.

## 4. Disruption (D8) — three levers that no longer collide

| Lever | Means |
|---|---|
| `module modify --force` | an operator authorizing downtime, now |
| `rebootOk` + `TAPPAAS_SCHEDULED_PASS` | standing per-module permission, honoured only in the unattended sweep, and only because the site accepts downtime in that window (`automaticReboot`) |
| `update-tappaas --force` | **"run the sweep now"** — a scheduling override, deliberately **never** forwarded |

An unauthorized disruptive change is **deferred, not failed**: everything else
applies, a machine-parseable `DEFERRED:` line is printed, and the converge exits
0. `update-tappaas` collects those into one end-of-sweep summary.

## 5. Migrating a provider

1. **Measure first.** Which fields does `module-fields.json` say the coordinate
   owns (`usedBy`)? Of the 25 service scripts, **14 own none** — they do
   registration and wiring, which is not field drift. They need no manifest, and
   `validate` expects none.
2. **Classify.** Write `fields.json` by reading the class off what the existing
   script *does*, not off what seems tidy. If it warns rather than acting, that
   is `manual`. If it refuses, that is `immutable`/`recreate`.
3. **Decide `reconcile` vs per-field.** Does a generic differ genuinely compare
   these values, or does the provider's own reconciler do it better? Set
   reconciliation (add/change/remove) is the tell: use `apply: "reconcile"`.
4. **Only then** write a reporter and split the script.

`module-manager validate` enforces coverage: a service that owns declared fields
and ships no manifest is an error.

## 6. What this surfaced

Declaring the semantics forced the schema and the code to agree, and they did
not. Each of these was a real, silent divergence:

| Finding | |
|---|---|
| `bridge1` defaulted to `lan` | while both acting paths read an absent `bridge1` as `NONE` — the drift report showed a desired second NIC nothing would ever create |
| `bridge1`/`mac1`/`zone1`/`trunks1` claimed `cluster:lxc` | a container has one NIC; neither the LXC installer nor its updater mentions `net1` |
| `swap` | read from config by `cluster:lxc` for its whole life, never declared |
| `node` defaulted to the first site node | so a module declaring no placement would be migrated back to node 0 after any failover. Expressing no placement is not asking for node 0 |
| `vmtag`/`diskSize`/`storage`/`bios` | the converge deliberately did not act on these when undeclared, on the assumption their defaults were only install-time starting values — but TAPPaaS's own creators build with exactly those defaults, so an undeclared guest already matches them and skipping was hiding a comparison that is free (ADR-020 D9) |
| the bash netopts parser | could not read a container's `hwaddr=` MAC, while its TypeScript twin could |

## 7. Where the pieces live

| Concern | Home |
|---|---|
| Resolve desired (defaults, `.orig`) | `lib/ts/src/desired.ts` |
| Change-class vocabulary + manifest lint | `lib/ts/src/service-fields.ts` |
| Normalize + diff | `lib/ts/src/drift.ts` |
| Assemble a record for one coordinate; the `--set` pre-gate | `manager/module-manager/src/converge.ts` |
| Reporter client + its error model | `manager/module-manager/src/report.ts` |
| The runner | `tappaas-cicd/lib/converge-lib.sh` |
| Locate-and-read mechanism for cluster reporters | `cluster/lib/report-lib.sh` |
| Zone-field classes (the second manager, #538) | `schemas/zones-fields.json` + `manager/network-manager/src/zonemodify.ts` |

A zone field has exactly **one** owner, so unlike a module field there is no
`(field, service)` pair to disambiguate and no separate manifest: the class lives
with the field definition as `changeClass`.

## 8. Tests

| Suite | Covers |
|---|---|
| `module-manager` `manifest.test.ts` | vocabulary parity with the JSON schema, coverage, one mutation per lint rule, and that every field-owning service in the tree ships a clean manifest |
| `resolve.test.ts` | the resolver — including the mutation proof that one change reddens both it and `inspect` |
| `drift.test.ts` | every normalizer symmetric + idempotent; composite escalation; the real `cluster:vm` manifest against a real reporter payload |
| `report.test.ts` | the reporter client's exit-code mapping (#526) |
| `modify.test.ts` | the M1–M9 pre-gate matrix, and the verb wiring: gate → write → converge |
| `tappaas-cicd` `test-converge-lib.sh` | the runner, fully stubbed: one batched set, migrate last, side effects once, deferral is not failure |
| `cluster` deep tier | live: an unauthorized subnet change defers and leaves the guest untouched; the same change under `--force` applies, reboots, re-leases and re-registers DNS |
