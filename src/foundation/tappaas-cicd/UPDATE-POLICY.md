# Update policy — what changing a field costs

**Audience:** operators and provider authors.
**Scope:** every field in `module-fields.json` — the 55 a provider service owns,
with their declared change class and what the platform will and will not do with
them, and the 19 that no service owns.

TAPPaaS declares, per `(field, service)` pair, what changing that field costs
*after install*. That declaration lives in `services/<svc>/fields.json` and is
what makes `module-manager module modify <m> --set field=value` a sanctioned
operation instead of a hand-edit. The decision is
[ADR-020](../../../docs/ADR/ADR-020%20-%20Declared-Field%20Change%20Model%20(validate,%20drift,%20modify).md);
how it is built is
[the realization doc](../../../docs/design/ADR-020-field-change-realization.md).

Compiled from the 11 manifests and `schemas/module-fields.json`.

**This document is the vocabulary.** Sections 1–3 define the change classes, the
apply modes, and the policy for fields no service owns. The per-service
classifications live beside their manifests — see
[the index in section 4](#4-the-per-service-manifests).

| | |
|---|---:|
| Schema fields | **74** |
| — owned by at least one service, and classified | **55** |
| — owned by none (section 3) | **19** |
| Classified `(field, service)` pairs | **69** |
| Services owning declared fields | **11** |
| Services owning none (nothing to declare) | **14** |
| Pairs carrying a written rationale | **63** |

---

## 1. The seven change classes

A class answers one question — *what does changing this cost?* — and that answer
determines **where a refusal happens**. This is the load-bearing distinction in
the whole model:

- A refusal derivable from **the schema alone** happens in the **static
  pre-gate**, before `--set` writes a byte. Config that claims something reality
  can never match would drift forever, and every later `reconcile` would report
  a discrepancy nothing can fix.
- A refusal that needs **live state** — is this size change a shrink? does this
  migrate need downtime? — happens in the **converge**, where the snapshot
  wrapper can roll back.

| Class | The converge… | `--set` is | Needs disruption auth? | Refusal point | Escalation rank | Canonical fields |
|---|---|---|---|---|:--:|---|
| **`in-place`** | applies it live | accepted | no | — | 1 | `cores`, `memory`, `cputype`, `vmtag`, `trunks0`, and every `reconcile` field |
| **`grow-only`** | applies a grow; refuses a shrink | accepted | no | **converge** — only the live size says which it is | 1 | `cluster:vm diskSize` |
| **`manual`** | reports it, never acts | accepted | no | **converge** — reported, then left alone | 2 | `cluster:vm storage`, `cluster:lxc node`/`diskSize`/`storage` |
| **`in-place-reboot`** | applies it, then reboots the guest | accepted | **yes** | **converge** — deferred if unauthorized | 3 | `bridge0`, `zone0`, `mac0`, `bridge1`, `zone1`, `mac1` |
| **`migrate`** | relocates or rebuilds runtime state | accepted | **yes** | **converge** — deferred if unauthorized | 3 | `cluster:vm node` |
| **`recreate`** | never applies it | **rejected up front** | n/a | **pre-gate** | 4 | `bios`, `ostype`, `autoInstall`, `sshAccess` |
| **`immutable`** | never applies it | **rejected up front** | n/a | **pre-gate** | 5 | `vmid`, `os`, `image*`, `cloudInit` |

### Reading the columns

**"The converge…"** is the whole behavioural contract. `manual` is the one that
surprises people: it is *not* a refusal — the drift is real, it is reported on
every converge, and an operator is expected to act. Moving a disk is the
archetype: correct to want, wrong to do implicitly halfway through a sweep.

**"`--set` is"** — `accepted` means the pre-gate lets the value be written; it
does **not** promise the converge will apply it. `--set diskSize=16G` on an 80G
disk is accepted, written, and then refused by the converge, which is exactly
right: only the live disk knows it is a shrink, and the snapshot rolls the write
back.

**"Needs disruption auth?"** — only `in-place-reboot` and `migrate`. Authorized by
`module modify --force` (an operator, now) **or** the module's own `rebootOk`
inside the scheduled sweep. Unauthorized, the change is **deferred, not failed**:
everything else applies, a `DEFERRED:` line is printed, and the converge exits 0.
Not applying a change is not a failure; pretending it applied would be.

**"Escalation rank"** composes a composite's ceiling from its inputs, and the
*effective* class comes from the inputs that actually drifted — never the ceiling.
`net0` is built from `bridge0`, `zone0` and `mac0` (all rank 3) plus `trunks0`
(rank 1), so its ceiling is `in-place-reboot`. Change only the **trunks** and the
unit stays `in-place`: no reboot, no DNS pass, because a trunk list is a
bridge-side allow-list the guest never sees. That distinction — bridge-side vs
guest-side — is why `trunks0` is rank 1 and `mac0` is not.

### Two classes that look alike and are not

`recreate` and `immutable` are both pre-gated, and the difference is *why*:

- **`immutable`** — the field is part of the thing's identity or provenance.
  A different `vmid` is a different guest; a different `image` is a different
  build. There is no operation that changes it, only delete and reinstall.
- **`recreate`** — the field is *consumed at creation* and ignored afterwards.
  `bios` picks firmware; `autoInstall` drives an unattended install. The guest
  could in principle be rebuilt with a different value, but nothing about the
  running guest reflects it.

The practical consequence is identical today (both refuse), so if you are only
reading the refusal, treat them as one. The distinction earns its keep the day a
`--recreate` verb exists: `recreate` fields would be legal targets for it,
`immutable` ones never.

---

## 2. The five apply modes

Orthogonal to class. A class says *what a change costs*; an apply mode says *how
it is carried out*. The two are chosen independently — `cores` and `diskSize` are
both applied by the platform, but one is batched into a `qm set` and the other
calls a hook, and that has nothing to do with `cores` being `in-place` and
`diskSize` being `grow-only`.

| Mode | Mechanism | Needs a `report-service.sh`? | Fields |
|---|---|:--:|---:|
| `set` | batched with every other `set` field into ONE provider call (`qm set`, `pct set`) | yes | 10 |
| `hook` | dispatched to `services/<svc>/update-<field>.sh` over the uniform hook CLI | yes | 2 |
| `composite` | an input to a derived provider string; several fields collapse into one call | yes | 12 |
| `reconcile` | the service converges the field itself, inside an idempotent pass it already performs | **no** | 28 |
| `none` | never applied — the value is recorded and compared, and that is all | no | 17 |

### `set` and `hook` — the direct modes

`set` is the cheap path: every drifting `set` field on a service is collected and
handed to the provider as **one** call, so changing `cores`, `memory` and
`vmname` together is a single `qm set --cores 4 --memory 8192 --name web`, not
three. Each field declares the flag it contributes (`setFlag`).

`hook` is the escape hatch for a field whose application is a procedure rather
than an argument. `cluster:vm diskSize` calls `update-disk.sh`, which resolves the
disk, checks the direction, and calls `resize-disk.sh`. A hook is also the only
mode that can **refuse from live state** — `update-disk.sh` exits 20 on a shrink,
`update-node.sh` exits 10 when a migrate needs downtime it has not been granted.

### `composite` — one provider string, many declared fields

Some provider settings are not one value per field. A Proxmox NIC is a single
opaque string:

```
net0: virtio=02:C8:41:33:F4:0D,bridge=lan,tag=200
```

Four declared fields feed it, each naming the same `composite: "net0"` and the
part of the string it owns via `liveKey`:

| Declared field | `liveKey` | Contributes |
|---|---|---|
| `mac0` | `net0.mac` | `virtio=02:C8:41:33:F4:0D` |
| `bridge0` | `net0.bridge` | `bridge=lan` |
| `zone0` | `net0.tag` | `tag=200` (the zone's VLAN tag) |
| `trunks0` | `net0.trunks` | `trunks=…`, absent here |

Three consequences follow, and they are the whole reason the mode exists:

**One call, not four.** The converge parses the live string into its parts,
overlays the parts that drifted, re-renders the whole string, and issues one
`qm set -net0 …`. A field the module does not declare keeps its live value —
which is why an unpinned `mac0` is carried across untouched instead of being
regenerated on every pass.

**The class is the worst input that actually drifted, not the ceiling.** The unit's
declared ceiling is the worst class among its inputs — `in-place-reboot`, from
`bridge0`/`zone0`/`mac0`. But the *effective* class is recomputed from the inputs
that drifted on this pass:

| Drifted this pass | Effective class | Result |
|---|---|---|
| `trunks0` only | `in-place` | one `qm set`, no reboot, no DNS pass |
| `zone0` (± `trunks0`) | `in-place-reboot` | `qm set`, then reboot → wait for lease → re-register DNS |

A trunk list is a **bridge-side** allow-list the guest never sees; a MAC or a VLAN
tag is the guest's own wire identity. Charging a reboot for a trunk edit because
some *other* input to the same string could need one would be a tax on the
declaration, not on the change.

**Side effects are sequenced once.** `net0` declares `reboot`, `wait-ip` and
`dns`. If both NICs drift, the guest still reboots once and DNS re-registers once,
in the fixed order `reboot → wait-ip → dns → ha-repoint`.

### `reconcile` — the common case, and not a shortcut

28 of 69 pairs, and the right answer for most services. A firewall rule set, a
Caddy handler, a PBS job membership are reconciled by adding, changing **and
removing** entries against the provider's own model. A removal cannot be
expressed as a scalar diff, so flattening one so a generic differ could compare it
would *lose* fidelity. The manifest still declares the class — which is the part
that makes `--set` sanctioned — and the apply stays where the domain knowledge is.

The cost is visibility: with no `report-service.sh` there is no actual state to
compare, so `module-manager module drift` reports these fields as
`not-reported`. The converge is trusted to have made config true.

### `none` — recorded, never applied

`none` is not "ignored". The field is still declared, still validated, still
normalized, still compared — the platform simply has no operation that would
apply it. It is the honest mode for a class whose contract is *never applies it*:
`recreate`, `immutable`, and `manual`.

The three flavours read very differently to an operator:

```
$ module-manager module modify web --set vmid=341        # immutable
REFUSED: vmid is immutable on cluster:vm — a different vmid is a different guest.

$ module-manager module modify web --set bios=ovmf       # recreate
REFUSED: bios is recreate on cluster:vm — firmware is chosen at creation.

$ module-manager module modify web --set storage=tanka2  # manual
set storage=tanka2 in /home/tappaas/config/web.json
```

The first two never reach the config: `immutable` and `recreate` are refusable
from the schema alone, so the **pre-gate** stops them before a byte is written.
The third is written and *reported on every converge from then on* — because
`manual` means the drift is real and an operator is expected to act on it.
`storage` is exactly that: moving a disk is correct to want and wrong for a sweep
to do implicitly, so the platform records the intent and says so, repeatedly,
until someone runs the move.

So `apply: "none"` covers two quite different situations — "there is nothing to
apply, ever" and "there is something to apply, but not by us." The **class** is
what separates them; the mode only says the converge will not be the one to act.

### `seed` — a modifier, not a mode

`seed` appears in the per-service tables and is **not** one of the five modes; it
is a per-field flag, `defaultIsDesired: false`, orthogonal to both class and
apply. It answers a third question: *does the schema default count as desired
state?*

Normally it does. A module that declares no `cores` still has a desired `cores` —
the schema's default — and the converge will apply it. `seed` says the default is
an **install-time starting value only**: undeclared, the field has no desired
value at all, nothing is compared, and the live value is left alone.

`cluster:vm diskSize` is the archetype. Its schema default is `8G`, which is what
a new guest is built with. Without `seed`, every module that never mentions
`diskSize` would appear to want 8G — and on an 80G guest that reads as a shrink,
refused, on every converge, forever. With `seed`, an undeclared `diskSize` simply
means "leave the disk alone".

Seven fields carry it, all on `cluster:vm` and `cluster:lxc`:

| Field | Schema default | What `seed` prevents |
|---|---|---|
| `vmtag` | `TAPPaaS` | Overwriting an operator's tags with the default set |
| `diskSize` | `8G` | A permanent phantom shrink on every larger guest |
| `storage` | `tanka1` | Claiming every undeclared disk belongs on `tanka1` |
| `bios` (vm only) | `ovmf` | Permanent drift on a guest legitimately installed on `seabios` |

Read it as: **an omitted field is not a claim.** The distinction only matters for
fields whose schema default is a sensible thing to *create* with but a damaging
thing to *enforce*.

---

## 3. The fields no service owns

The 11 manifests classify 55 of the schema's 74 fields. The other **19** belong to
no provider service: they describe the module itself — its provenance, its
lifecycle, its wiring — rather than anything a provider configures. No service
owns them, so none of them has a change class, and the converge never applies
one.

That is not the same as "safe to change." Several are read by the platform at run
time, and a few are written *by* it.

| Field | Authored where | Policy | What changing it does |
|---|---|---|---|
| `description` | source module file | **free** | Cosmetic. Set on the Proxmox summary page at creation and never pushed again — editing it after install changes the config, not the VM. |
| `version` | source module file | **free** | Module semver. Read to decide whether an upgrade exists. |
| `appVersion` | source module file | **free** | Upstream app version, informational; no format enforced. |
| `releaseDate` | source module file | **free** | Informational. |
| `maintainer` | source module file | **free** | Informational. |
| `status` | source module file (+ tooling) | **operational** | `archived` and `external` take the module **out of the update lifecycle** — `update-module.sh` skips it unless `--force`. Set automatically by `delete-module.sh --archive`. |
| `tier` | source module file | **operational** | `foundation` means mgmt-only, single-instance, and `--force` to delete; it also makes `source: official` a lint requirement. Changing it changes what the platform will let you do to the module. |
| `source` | inferred at deploy; pinned only when the module file must | **operational** | Trust marker. A `foundation` module from a non-`official` source fails the tier/source lint unless `--allow-fork`. |
| `rebootOk` | source module file | **operational** | The [D8 disruption authorization](#reading-the-columns). `false` (the default) means an unattended converge **defers** every `in-place-reboot` and `migrate` change instead of applying it. This is the one unowned field that directly gates the converge. |
| `dependsOn` | source module file | **release-authored** | The service wiring. See the hazard below. |
| `integratesWith` | source module file | **release-authored** | Optional wiring; a missing provider is ignored rather than fatal (#501). Same delta mechanism as `dependsOn`. |
| `provides` | source module file | **release-authored** | What other modules may declare a dependency on. Removing an entry breaks every consumer's resolution. |
| `config` | source module file | **structural** | Pattern-A nesting (#161). Normalized to the flat form at deploy and at validation, so it is an authoring convenience, not a distinct state. |
| `environment` | tooling — `copy-update-json.sh --environment` | **tooling-written** | How `update-module.sh` and `delete-module.sh` resolve the source module file. A wrong value points the lifecycle at the wrong module. |
| `location` | tooling — `copy-update-json.sh` | **tooling-written** | Absolute path to the module directory. `update-module.sh` finds `install.sh`, `update.sh` and the service scripts through it. |
| `kind` | tooling — `install-module.sh` | **tooling-written** | Stamped `module` so `module-manager list/show` can tell a deployed module from other objects in `config/`. |
| `installTime` | tooling — `copy-update-json.sh` | **tooling-written** | Reporting only. |
| `updateTime` | tooling — `update-module.sh` | **tooling-written** | Reporting only. |
| `variant` | — | **retired** | Superseded by `environment` (#438). Never write it; installs strip it. Retained in the schema only so a pre-migration config carrying it is classified rather than reported unknown. |

### Two things this list does not protect against

**The pre-gate accepts all 19 unconditionally.** A field with no service
coordinate is classified `config-only` and written without consulting any
manifest — which is right for `description` and wrong for the rest. All of these
are accepted today:

```
$ module-manager module modify web --set kind=widget
kind=widget  (config-only)
[Info]   set kind=widget in /home/tappaas/config/web.json
```

`variant`, `installTime`, `location` and `environment` behave the same way. There
is no operation that *needs* to write them by hand, and clobbering `location` or
`environment` breaks the module's own lifecycle scripts.

**`--set dependsOn=…` declares without wiring.** `install-service.sh` and
`delete-service.sh` are driven by a **delta** that `update-module.sh` computes
across the 3-way merge: the union of `dependsOn` + `integratesWith` before the
merge, against the same union after. A `--set` writes the *deployed* side, so the
merge sees an operator customization and pins it — before and after agree, the
delta is empty, and **no service script runs**. The config ends up claiming a
dependency that was never wired, or dropping one whose wiring is still in place.

Dependencies are changed by editing the **source module file** and running
`update-module.sh`, which is what makes the delta visible to the merge.

### Recommendation: classify them too

`zones-fields.json` already carries a per-field `changeClass` for exactly this
reason (#538). Giving `module-fields.json` the same annotation for these 19 would
let the existing pre-gate do its job without any new machinery:

- `immutable` — `kind`, `installTime`, `updateTime`, `location`, `environment`
  (tooling writes them; a hand-edit is always a mistake)
- `manual` — `dependsOn`, `integratesWith`, `provides` (refuse with "edit the
  source module file and run update-module.sh")
- `immutable` — `variant`, with the retirement message
- unclassified, as now — the six metadata fields, `tier`, `source`, `status`,
  `rebootOk`, `config`

*Cost: an annotation pass on `module-fields.json` and a branch in `preGateSet()`
for fields with no service coordinate. No change to any manifest.*

---

## 4. The per-service manifests

The classification for each service lives beside its manifest, so a provider
author changing `fields.json` has the rationale in the same directory.

| Service | Fields | Shape | Policy |
|---|---:|---|---|
| `cluster:vm` | 26 | 5 `set` · 8 `composite` · 2 `hook` · 11 `none` | [cluster/services/vm](../cluster/services/vm/UPDATE-POLICY.md) |
| `cluster:lxc` | 15 | 5 `set` · 4 `composite` · 6 `none` | [cluster/services/lxc](../cluster/services/lxc/UPDATE-POLICY.md) |
| `network:proxy` | 9 | all `reconcile` | [network/services/proxy](../network/services/proxy/UPDATE-POLICY.md) |
| `backup:vm` | 7 | all `reconcile` | [backup/services/vm](../backup/services/vm/UPDATE-POLICY.md) |
| `network:rules` | 4 | all `reconcile` | [network/services/rules](../network/services/rules/UPDATE-POLICY.md) |
| `cluster:ha` | 2 | all `reconcile` | [cluster/services/ha](../cluster/services/ha/UPDATE-POLICY.md) |
| `network:discovery` | 2 | all `reconcile` | [network/services/discovery](../network/services/discovery/UPDATE-POLICY.md) |
| `identity:identity` | 1 | `reconcile` | [identity/services/identity](../identity/services/identity/UPDATE-POLICY.md) |
| `network:dns` | 1 | `reconcile` | [network/services/dns](../network/services/dns/UPDATE-POLICY.md) |
| `network:nat` | 1 | `reconcile` | [network/services/nat](../network/services/nat/UPDATE-POLICY.md) |
| `templates:windows` | 1 | `reconcile` | [templates/services/windows](../templates/services/windows/UPDATE-POLICY.md) |

Two services carry the whole apply-mode taxonomy between them, and 9 are pure
reconcilers. That shape is the finding, not an accident of migration order: the
platform's own provider services (Proxmox guests) are the only ones whose state
is a set of independent scalars a differ can compare. Everything else — firewall,
proxy, DNS, backup, SSO — has a *model*, and reconciling against a model is both
what those scripts already did and the only way to express a removal.

---

## 5. What could be improved

Ranked by what they buy. The classifications were read off *what each script
already did*, so the refactor could not change behaviour — the right constraint
while migrating. Recommendations 1–4 are all the same act: revisiting where
"preserve today's behaviour" hardened into "this is what the platform can do."

### 1. Give `network:proxy` a reporter

Nine fields, and `drift` currently reports *"nothing was compared"* for all of
them. That is the estate's most operator-visible surface — what is published, on
what domain, to whom — with no drift detection at all. A hand-edited Caddy
handler is invisible to TAPPaaS today.

`proxyPort`, `proxyDomain`, the three booleans and `aliasType` are plain scalars
Caddy's admin API can report. Move those to `apply: "set"` or a hook; keep
`proxyAllowedZones` and the handler-as-a-whole on `reconcile`.

*Cost: a new `report-service.sh`; 6 of 9 fields change mode.*

### 2. Split `backup:vm` — scalars out, cascade in

Same idea, with one real trap. `pbsStorageName`, `placement`, `placementState`
and `pushTarget` are scalars PBS can report. But `backup` is a **cascade**
(site → environment → module), so the module layer alone is *not* the desired
value — a differ comparing it would report drift against a retention the site
actually set. Keep `backup`, `immutableSnapshots` and `alwaysBackup` on
`reconcile`; promote only the four scalars.

### 3. Reconsider `cluster:lxc diskSize` as `grow-only`

`pct resize` grows a container rootfs live — technically the same `grow-only`
story as `cluster:vm`. It is classed `manual` to preserve the existing warn-only
behaviour, which was right for a refactor whose contract was "change nothing",
but it is now a **deliberate capability gap, not a technical one**. Worth doing
as its own change, with its own deep test.

### 4. `cluster:vm ostype` is stricter than reality

`qm set --ostype` works on a live VM — it is a hint selecting emulated hardware
defaults, not a creation-time fact. It is classed `recreate` because nothing
reconciled it before, which means `--set ostype=…` is refused up front.
Defensible, but strictly more restrictive than the platform. `in-place` with
`apply: "set"` would be the honest classification.

### 5. Break up `identity:identity`

One object field covers the entire SSO wiring — provider type, redirect URIs,
bound groups. You cannot `--set` a redirect URI without rewriting the whole
block, which is the hand-editing the verb exists to replace. Low priority: the
block changes rarely and the reconcile is correct.

---

## 6. A gap in the taxonomy

`cluster:ha HANode` is `in-place`, and that is correct — the guest is not moved,
not rebooted, and stays served throughout. But changing it recreates the ZFS
replication job, which means a **full initial re-sync**: potentially hours of IO.

The class system governs *refusal*, and nothing here should be refused. What is
missing is a way to say **non-disruptive but costly**, so a converge can warn
before it starts. An optional `cost` annotation fits better than an eighth class:
classes decide whether a change is allowed, and this is not that question.

---

## 7. `node` and `HANode` — what happens today (ADR-019's starting point)

`cluster:vm node` is classed `migrate`, and the hook is real. What it does
depends on three things:

| Case | Today |
|---|---|
| Routine converge, non-HA module | **Deferred.** `migrate` is disruptive, so the converge prints `DEFERRED:` and exits 0 without moving anything. |
| `modify --force`, non-HA module | **Migrates.** `update-node.sh` runs `qm migrate <vmid> <target> --online <0\|1>`. |
| Any invocation, HA module | **Never migrates from `cluster:vm`.** It warns and defers to `cluster:ha`, which does its own `ha-manager crm-command migrate` for placement drift. |

**What ADR-019 must still add**, marked as a seam in `update-node.sh`:

- **The live-OK verdict.** Today the hook passes `--online 1` for a running guest
  and lets Proxmox reject an incompatible CPU. ADR-019's rule is to decide
  first and return exit `10` — "needs disruption authorization" — rather than
  silently falling back to an offline migrate. The exit code is already reserved
  and honoured by the runner; nothing computes the verdict.
- **One migrate primitive.** `migrate-vm.sh` exists but requires `HANode` and
  picks "the other node" — it is the HA failover/failback primitive, not an
  arbitrary-target migrate. Teaching it an explicit target would let
  `update-node.sh` call it instead of `qm migrate` directly.
- **`.HANode` moves** are `cluster:ha`'s, not `cluster:vm`'s — classed `in-place`
  / `reconcile`, re-pointing the affinity rule and recreating the replication job.

---

## 8. Coverage

`module-manager validate` enforces this: a service that owns declared fields and
ships no `fields.json` is an **error**. A service that owns none needs none —
14 of the 25 service scripts do registration, wiring and app configuration,
which is not field drift.

One config key is read but undeclared: `cluster:vm/install-service.sh` reads
`zone2` in its stale-`known_hosts` cleanup loop, clearing
`<vmname>.<zone>.internal` for each zone a guest might answer on. No
`bridge2`/`net2` exists, so the third iteration is always empty — harmless
defensive code, not a missing feature. **Two NICs are fully supported**
(`net0` + `net1`) on both the mothership converge and the node-local bootstrap
path; `network.json` itself declares `bridge0: lan` + `bridge1: wan`.
