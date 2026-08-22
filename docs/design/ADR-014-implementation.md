# ADR-014 Implementation — Plan, Decisions & Tracker

**Companion to:** [ADR-014 — Zone ↔ Environment Lifecycle & Operations](<../ADR/ADR-014 - Zone and Environment Lifecycle.md>) (the *why* + the decided design)
**Closes:** #424 (client/IoT zones ↔ environments undefined) · #419 (stale zone references not resolved)
**Purpose of this doc:** one place that (1) records **implementation-level decisions** (including the three forks ADR-014 flagged for confirmation), (2) breaks the work into **packages** with deliverables/dependencies/test criteria, and (3) **tracks live execution state**.
**Status:** In progress — P0 ✅, P1 ✅, P2 ✅, P3 next
**Branch:** `feat/adr-014-zone-lifecycle`, cut from `main`
**Started:** 2026-08-22

> Modeled on [ADR-012-implementation.md](ADR-012-implementation.md). Reviewed against the code as it stands on `main` — every "current behaviour" claim below carries a file/line pointer.

---

## How to read this doc

- **[Confirmed forks](#confirmed-forks--deviations-from-adr-014)** — the three open ADR-014 decisions, now settled, plus what that changes.
- **[Code findings](#code-findings-that-constrain-the-build)** — what the existing implementation actually does. These are the constraints the packages are shaped around; several contradict the ADR's assumptions.
- **[Implementation packages](#implementation-packages)** — P0…P9.
- **[Package tracker](#package-tracker)** — live execution state.
- **[Rollout campaign](#rollout-campaign)** — the three-stage test the operator asked for.
- **[Resolved implementation decisions](#resolved-implementation-decisions)** — R1–R4, the follow-up questions this doc raised, now settled.
- **[Still open](#still-open)** — the one item that is not.

### Convention: `config/` means the target system, not the repo

`config/zones.json`, `config/environments/<env>.json`, `config/site.json` refer to **`~tappaas/config/` on `tappaas-cicd`** — runtime state, not files committed to the repo. The repository ships the **template** (`manager/network-manager/zones.json`), **schemas** (`foundation/schemas/*.json`), and **fixtures**.

### Package gate (Definition of Done)

1. **Plan** — decompose; identify the `test.sh` in scope; list the issues it closes.
2. **Implement** — per CLAUDE.md agent routing.
3. **Validate** — `bash-script-validator` (ShellCheck + security) on every changed script; `tsc --noEmit` on changed TS.
4. **Deep test** — existing + new `test.sh` in deep/regression mode, backgrounded per the long-task rules. Record pass/fail counts.
5. **Gate** — ALL green → stage the change and report; the operator commits. ANY red → stop-the-line, log here, fix, re-test.

**Status legend:** ⬜ not started · 🟦 in progress · 🧪 testing · ✅ done (green, committed) · 🟥 blocked

---

## Confirmed forks — deviations from ADR-014

ADR-014 v0.3 left three decisions flagged for confirmation. All three are now settled (operator, 2026-08-22). **ADR-014 must be updated to match before it moves to Accepted** (P8).

| # | ADR-014 as drafted | **Decision** | Consequence |
|---|---|---|---|
| F1 | D7 renames the trusted-client reference zone `home` → `private` | **Keep `home`.** `private` is not introduced anywhere. | No generic rename-map machinery is built; no `home.internal` → `private.internal` re-domaining; #425/ADR-007d needs **no** edit. The only recorded rename stays `srv → <defaultEnvironment>`. **Removes the single largest risk from the live upgrade.** |
| F2 | D5/R1 puts Service (T1) above trusted clients (T2), making `client → service` an upward **pinhole** | **Adopt R1 as written, phased enforcement.** | The lattice, `tier`, `isolated` and checks I1–I4 ship exactly as drafted. I1 **warns by default**; `validate --strict` remains an opt-in hand-run flag and is wired to **no** gate in this branch (R3). Converting the live `home access-to <env>` edge into per-module pinholes is **explicitly out of scope** for this branch — it gets its own issue. **Firewall behaviour is unchanged by this branch.** |
| F3 | D7 collapses `srv*` out of the template; merge would keep them as permanent orphans | **Auto-delete unoccupied, warn on occupied.** | A one-time migration verb retires a named legacy set when it is Inactive **and** hosts no module; anything Active or occupied is left alone with a loud warning + runbook step. |

**F2 restated, because it governs the whole branch:** this work makes the zone model *expressible and checkable*. It does not re-cut a single firewall rule. Any change to live reachability is a bug in this branch.

---

## Code findings that constrain the build

Verified against `main`. Several of these contradict what ADR-014 assumes, and they are why the packages are ordered as they are.

**C1 — There is no "recorded rename map".** ADR-014 D7 says `home → private` should go "through the recorded rename map (the same mechanism as `srv → <env>`)". No such mechanism exists: the map is a hardcoded literal in two places — [zonesinit.ts:149](../../src/foundation/tappaas-cicd/manager/network-manager/src/zonesinit.ts#L149) and [zonesinit.ts:278](../../src/foundation/tappaas-cicd/manager/network-manager/src/zonesinit.ts#L278). Building one was a hidden cost of the `private` rename. **F1 makes it unnecessary** — but the two literals must stay a single source of truth when `init` becomes profile-based (P6).

**C2 — Deleting a zone from the template never retires it.** `mergeZones`' zone-level rule is "in current, absent in source → KEEP + warn" ([zonesmerge.ts:200](../../src/foundation/tappaas-cicd/manager/network-manager/src/zonesmerge.ts#L200)). So D7's "collapse `srv*`, drop the test zones" is a **no-op on every existing install** — they persist forever as `keptOrphan`. Retirement needs an explicit, guarded migration verb (P6), which is what F3 authorises.

**C3 — `zonesInit`'s idempotency marker is `srv`.** The guard is `!force && name in template && !("srv" in template)` ([zonesinit.ts:130](../../src/foundation/tappaas-cicd/manager/network-manager/src/zonesinit.ts#L130)), and it hard-requires `srv`/`home`/`guest` to be present ([zonesinit.ts:135](../../src/foundation/tappaas-cicd/manager/network-manager/src/zonesinit.ts#L135)). Composable `init core|iot` profiles (D7) must replace both, and `init` must stay re-runnable and non-destructive (#427, `mergeInitWithExisting`).

**C4 — `serves` resolution has nowhere to write.** This is the **biggest design decision in the branch.** D2 says reconcile "expands `serves` to derived `access-to` / `pinhole-allowed-from`". Two consumers read those arrays, and neither goes through `network-manager`:
  - `zone-manager` (OPNsense L3/firewall) — invoked with `--zones-file <ZONES>` ([planes.ts:87](../../src/foundation/tappaas-cicd/manager/network-manager/src/planes.ts#L87)), so it *can* be pointed at another file;
  - `rules_manager.py` (per-module pinhole/egress compilation) — finds `/home/tappaas/config/zones.json` **by its own search path** ([rules_manager.py:1536](../../src/foundation/tappaas-cicd/controller/opnsense-controller/src/opnsense_controller/rules_manager.py#L1536)), independent of network-manager;
  - `access-list.sh` (Caddy allow-lists) — takes `zones_file` as a parameter ([access-list.sh:57](../../src/foundation/network/services/proxy/access-list.sh#L57)).

  Writing derived edges **back into `zones.json` is rejected**: the 3-way merge would see them as operator edits and pin them, so clearing a `serves` link would strand its derived edges forever. **Decision D-C4: render an `authored → effective` split** (see P3).

**C5 — the module 3-way merge already adopts `zone0`.** `_MERGE_AUTO_FIELDS` is `location, installTime, updateTime, releaseDate, variant, environment` ([apply-json-merge.sh:63](../../src/foundation/tappaas-cicd/lib/apply-json-merge.sh#L63)) — `zone0` is **not** pinned. So fixing the stale `zone0` values in the repo's module JSONs **propagates to existing installs automatically** on the next `update-module`, for any operator who has not customised the field. This makes #419's module half far cheaper than the issue implies.

**C6 — `zone0` already has the right default.** `module-fields.json` documents that an **unset** `zone0` falls back to the target environment's `network.zone`, implemented by `resolve_default_zone()` ([install-module.sh:113](../../src/foundation/tappaas-cicd/manager/module-manager/install-module.sh#L113)). The correct #419 fix for `nextcloud`, `nextcloud-hpb`, `euro-office`, `openwebui`, `hass` is therefore to **delete** the hardcoded `zone0`, not to rewrite it — the stale-name class disappears rather than moving.

**C7 — a dropped `proxyAllowedZones` entry is a `warn`, not an error.** [access-list.sh:97](../../src/foundation/network/services/proxy/access-list.sh#L97) skips an unresolvable zone with a warning and continues; it only errors when the whole list resolves empty. This is #419's silent-degradation defect verbatim (`hass` deploys with `home` dropped, locking private-zone clients out).

**C8 — `ensureMgmtAccess` adds every new zone to `mgmt.access-to`** ([zones.ts:324](../../src/foundation/tappaas-cicd/manager/network-manager/src/zones.ts#L324)). I1 (monotonic) and I2 (isolation floor) **must exempt `mgmt`**, exactly as `_README.isolation_invariant.mgmt_exception` already states, or every install fails its own check on day one.

**C9 — zone-name regexes disagree.** `authorZone` enforces camelCase `^[a-z][a-zA-Z0-9]*$` ([zones.ts:173](../../src/foundation/tappaas-cicd/manager/network-manager/src/zones.ts#L173)); `validateName` in zonesinit and `zone_key` in `zones-fields.json` both allow hyphens. #278 says no hyphens. Minor, but the archetype work touches both paths — align on camelCase (P1).

**C10 — this system's live drift, as of today.** `config/zones.json` on `tappaas-cicd` shows exactly the #424 failure mode. `srv` was renamed to `rossen` and `home.access-to` was rewritten to match, but nothing else was:

  | Zone | stale field | value | effect |
  |---|---|---|---|
  | `iotLocal` | `pinhole-allowed-from` | `["srvHome"]` | dangling — `srvHome` is Inactive |
  | `iotCloud` | `pinhole-allowed-from` | `["srvHome","home"]` | half-dangling |
  | `iotCams` | `pinhole-allowed-from` | `["srvHome","srvWork"]` | fully dangling |
  | `iot` | `pinhole-allowed-from` | `["rossen"]` | renamed but zone is Inactive |
  | `mgmt` | `access-to` | lists all five `srv*` + `iot` + tests | noise |

  Five `srv*` zones, `iot`, and four `test*` zones are all Inactive with zero modules — **all ten qualify for F3 auto-retirement.** This is the concrete before/after for the P9 Stage 1 test.

  `work` (Client, Inactive, tier 2) is **not** a retirement candidate despite also being Inactive and unoccupied: it is a legitimate trusted-client zone that is merely switched off, and `enable work` must keep working. The retired set is an explicit list, never "everything Inactive".

---

## Implementation packages

### P0 — Branch, repo pointing, baseline capture

**Deliverables**
- Branch `feat/adr-014-zone-lifecycle` off `main`.
- Point this system at it: `site-manager repository modify TAPPaaS --branch feat/adr-014-zone-lifecycle` then `site-manager repository reconcile --apply`. `pre-update.sh` picks the branch up via `reconcile_repo_checkout` ([pre-update.sh:60](../../src/foundation/tappaas-cicd/pre-update.sh#L60)), so every subsequent `update-tappaas` tracks the branch.
- Baseline capture: copy `config/{zones.json,zones.json.orig,zones.rename.json,site.json}` and `config/environments/` to a dated archive; record `network-manager validate` and `network-manager list` output as the "before" artefact.
- Proxmox snapshot of `tappaas-cicd` — **deferred to immediately before Stage 1** (P9). Taken now it would go stale across P1–P8 and protect nothing; the meaningful rollback point is the moment before the first `update-tappaas` onto this branch. The config baseline above is captured now and is what P1–P8 could ever need.

**Test criteria** — `site-manager repository list` shows the branch; a no-op `update-tappaas` run completes and leaves `zones.json` byte-identical.

> **Operator note:** per the memory rule, uncommitted work never reaches a deployed build — each package must be committed before the system is updated onto it.

---

### P1 — Schema foundation: `tier`, `isolated`, `serves`, archetype catalog

Purely additive. No behaviour change; nothing reads the new fields yet.

**Deliverables**
- `schemas/zones-fields.json`: add `tier` (integer 0–6, optional), `isolated` (boolean, default `false`), `serves` (string, optional, Client/IoT only); add the **archetype catalog** (the D5 table: archetype → `type`/`typeId`/`tier`/`isolated`/`access-to`-seed) as a new top-level block. Align `zone_key` to camelCase (C9).
- `network-manager/src/types.ts`: `tier?: number`, `isolated?: boolean`, `serves?: string` on `Zone`.
- `ZONES.md`: Field Reference entries + a new "Tier lattice & archetypes" section stating R1/R2, replacing the `_README.tier_model` prose.
- `zonesmerge.ts` field policy — **decision:** `serves` joins `AUTO_FIELDS` (operator-authored via `bind`, must never be adopted from the release template); `tier` and `isolated` follow the normal rule (archetype-stamped design intent, so a release correction should land).

**Test criteria** — `tsc --noEmit` clean; existing `network-manager/test.sh` fast tier green unchanged; a `zones.json` carrying the new fields round-trips losslessly through `loadZones`/`saveZones` and through `merge --diff` with no reported change.

**Outcome (2026-08-22): ✅ green — 160 unit + 15 CLI, `tsc --noEmit` clean.** 12 new assertions cover load/save round-trip, the merge field policy (`serves` pinned, `tier` adoptable but pinned when operator-edited), and the rename transform carrying the new fields. Two notes from the build:
- `zone_key` in the schema was tightened from `^[a-z][a-z0-9-]*$` to `^[a-z][a-zA-Z0-9]*$` (C9). This is documentation catching up with enforcement — `authorZone` has always rejected hyphens — and `zones-fields.json` has no programmatic consumer today, so nothing could have relied on the looser pattern. ZONES.md's contradicting "org-scoped zones may use hyphens, e.g. `biz-guest`" sentence was corrected.
- The schema gained `tier_exempt_types: ["Overlay", "WAN"]` as a first-class block rather than a hardcoded list in P2, so R2's exemption is data the checks read. `WAN` is exempted alongside `Overlay` for the same reason: `wan` is the switch-internal ISP hand-off with no interface, DHCP or rules, and no meaningful trust rank.

---

### P2 — Read-side: tier checks (D6) + filtered listing (D4)

Ships the diagnosis before any mutation, so P9 Stage 1 can measure the live damage first.

**Deliverables**
- `zonescheck.ts`: I1 monotonic `access-to` (`tier(A) ≤ tier(B)`; `internet` = tier 5; **`mgmt` exempt** per C8) · I2 isolation floor (`isolated` zone in nobody's `access-to`, mgmt aside) · I3 egress boundary (tier-6 must not list `internet`) · I4 archetype conformance (`(type, tier, isolated)` matches a catalog entry). A **missing** `tier` is a `note`, not a warning, until back-filled.
- **Overlay zones are exempt from I1/I3/I4** (R2): `netbird`/`edge`/`admin` carry no `tier`, and `admin`'s `access-to: ["mgmt"]` must not trip the monotonic check.
- All four are `warn` by default and reuse the existing reporter — no new tool (F2). `--strict` keeps its existing global promote-to-error meaning but is **wired to no gate** in this branch (R3): nothing here can fail an install or an update.
- `main.ts` `list`: `--state`, `--type`, `--tier` filters; `tier` + `serves` columns when `--type Client|IoT`.

**Test criteria** — unit fixtures for each of I1–I4 (violating + conforming); `--strict` exits non-zero on an upward edge and zero on the conforming fixture; an `Overlay` fixture with an upward `access-to` is **not** flagged; `list --state Inactive` and `list --type Client` filter correctly. **Live gate:** `network-manager validate` against this system's `config/zones.json` produces the C10 findings and **exits 0** (warnings only).

**Outcome (2026-08-22): ✅ green — 176 unit + 15 CLI, `tsc --noEmit` clean; live gate exit 0, 0 warnings.**

- **New module `src/archetypes.ts`** holds the lattice constants, the nine-archetype catalog and the exemption rule. It is the *operative* copy: the nix builder narrows the source to `lib/ts` + the component, so `foundation/schemas/` is unreachable at build time, and resolving it at **run** time would make `validate` depend on a deployed file that may be missing or stale on exactly the systems it audits. A unit test reads `schemas/zones-fields.json` from the source tree and pins the two together field-for-field, so drift fails the build instead of shipping.
- **Live gate:** `validate` on `config/zones.json` exits 0 with **zero warnings** and one aggregated note — "20 zone(s) carry no `tier`" (24 zones minus the 4 exempt `Overlay`/`WAN`). The un-back-filled-config path produces no noise, as required.
- **Forward preview (the useful result).** Stamping the archetype tiers onto a *copy* of the live config shows what P6's back-fill will surface: **exactly two I1 warnings**, both the known F2 client→service edges — `home → rossen` and `work → srvWork` — with I2, I3 and I4 all clean, exit 0. That is the predicted Stage 1 output, and it confirms the F2 deferral is two edges wide, not a fleet-wide cleanup.
- The four `test*` zones carry `type: "Test"`, which is in neither the schema's type enum nor the archetype catalog, so they are skipped as untiered rather than flagged. They are retired in P6, so no archetype is invented for them.

---

### P3 — D2 `serves`: the authored → effective split

The core of #424, and the package that carries decision **D-C4**.

**Decision D-C4 — `zones.json` stays purely authored; reconcile renders `zones.effective.json`.**
Derived edges are never written back into `zones.json` (C4). Instead `network-manager reconcile` renders `config/zones.effective.json` = authored zones + `serves`-derived edges, and the consumers read *that*:

| Consumer | Change |
|---|---|
| `zone-manager` (opnsense plane) | `planes.ts` passes the effective file to `--zones-file` |
| `rules_manager.py` | prepend `config/zones.effective.json` to `_find_zones_file`'s search order |
| `access-list.sh` | callers pass the effective path |
| `distribute` | keeps pushing authored `zones.json` (nodes need only `vlantag`/`ip`) |

The effective file is **generated, never hand-edited, never merged** — regenerated on every reconcile, so a cleared `serves` link cleanly drops its derived edges. `validate` gains `--effective` to check the rendered form.

**Deliverables**
- `serves` resolution: `serves: "<env>"` → read `config/environments/<env>.json` `.network.zone`; add that zone to this zone's effective `access-to`, and add this zone to that service zone's effective `pinhole-allowed-from`. An `isolated` zone contributes **only** the pinhole direction, never an `access-to` entry (R2 preserved verbatim).
- `network-manager bind <zone> --environment <env>` / `--unbind` — sets/clears `serves`; rejects a non-Client/IoT zone and an unknown environment.
- Errors: `serves` naming a missing environment is a hard error at reconcile; `serves` on a Service/Management/Overlay zone is a hard error at validate.
- `merge` back-fill: for each Client/IoT zone whose literal `access-to`/`pinhole-allowed-from` references a zone that is the `network.zone` of a known environment, set `serves` and drop the now-derived literal. Idempotent — a converged install re-runs it as a no-op. (**Resolves ADR-014's one open item**: the back-fill runs *inside* `merge`, because merge is already the rename-aware step that holds the environment context.)

**Test criteria** — unit: `serves` renders the right edges both directions; an `isolated` target never gains an inbound `access-to`; clearing `serves` drops the edges on the next render; back-fill is idempotent. **Regression (the ADR's own acceptance line):** after `init` renames `srv → <env>`, a `serves`-linked client zone stays converged across `merge` with no stale service reference.

---

### P4 — D5 archetypes on `add` (subsumes D3)

**Deliverables**
- `network-manager add <name> --archetype <A>` for `control | service | trusted-client | guest | dmz | iot-local | iot-cloud | iot-cams | iot-untrust` — stamps `type`/`typeId`/`tier`/`isolated`/`access-to` seed from the P1 catalog, then reuses the existing `--vlan`/auto-allocation path. `--serves <env>` composes with it.
- `--type`/`--from-zone` remain as low-level escapes. Thin preset layer over `authorZone` — no new code path.

**Test criteria** — every archetype produces a zone that passes I1–I4 with zero edits and a correctly auto-allocated VLAN/IP; `--archetype` + `--type` conflict is rejected.

---

### P5 — D1 env ↔ service zone materialisation

**Deliverables**
- `NetworkClient` gains `createServiceZone(zone)` shelling to `network-manager add <Z> --type Service` (idempotent), extending the existing `clients.ts` seam — environment-manager still never writes `zones.json` directly.
- `environment add <env> [--zone Z] --create-zone` — creates the zone **before** writing the environment file. Opt-in flag (ADR-014 resolved choice #1), so a typo'd `--zone` cannot mint a stray zone.
- `environment reconcile <env>` — when `network.zone` names a **missing Service-type** zone, create it Active (today it only warns, [reconcile.ts:71](../../src/foundation/tappaas-cicd/manager/environment-manager/src/reconcile.ts#L71)). A missing **non-Service** zone stays a hard error.

**Test criteria** — `add --create-zone` yields a working environment + Service zone in one command; `reconcile` materialises a missing Service zone and hard-errors on a missing non-Service zone; both idempotent; `--check`/dry-run mutates nothing.

---

### P6 — D7 composable `init` profiles + template cleanup + legacy retirement

The heaviest package: it rewrites `zonesinit.ts` and carries F3.

**Deliverables**
- `network-manager init core --name <N>` — `mgmt` (T0, Manual) · `<N>` service zone (T1, from the `srv` rename) · `home` (T2, `serves <N>`) · `guest` (T3) · `dmz` (T4, Mandatory) · the three overlays (Manual). **`home`, not `private`** (F1).
- `network-manager init iot` — `iotCloud` (T3) · `iotLocal` (T6) · `iotCams` (T6, isolated) · `iotUntrust` (T3, isolated), all Active, each `serves <defaultEnvironment>`.
- Profiles are additive, idempotent and composable; each only ever adds/activates its own zones. New idempotency marker replacing the `srv`-presence test (C3); `mergeInitWithExisting`'s non-destructive contract (#427) preserved.
- Template cleanup: drop `test`/`testAllowA`/`testAllowB`/`testPinhole` (they move to `test/fixtures/zones.json` only) and collapse `srvHome|srvWork|srvCust|srvDev|srvTest` → ship `srv` alone. Back-fill `tier`/`isolated`/`serves` on every shipped zone.
- **`network-manager retire [--apply]`** (F3, C2) — the one-time migration. For each zone in the retired set — `srv{Home,Work,Cust,Dev,Test}`, **`iot`** (R1) and `test*`; **`srv` is never retired**, it is the rename source: if Inactive **and** no installed module names it (reuse `occupiedZones()` from [zonescheck.ts:98](../../src/foundation/tappaas-cicd/manager/network-manager/src/zonescheck.ts#L98)) → delete it and strip it from every `access-to`/`pinhole-allowed-from`; otherwise leave it and warn with the runbook step. Dry-run by default.

**Test criteria** — `init core` then `init iot` is order-independent and idempotent; neither ships a test zone nor any `srv{Home,…}`; a re-run over a live `zones.json` preserves operator-configured zones (#427 regression); `retire --apply` on a fixture deletes exactly the unoccupied set, **keeps an Active-or-occupied `iot`** (R1's guard), and leaves no dangling reference (P2's I-checks pass afterwards); `srv` survives every run.

---

### P7 — #419: stale module references + validation gates

**Deliverables**
- **Delete** the hardcoded `zone0` from `nextcloud`, `nextcloud-hpb`, `euro-office` (`srv`), `openwebui` (`srvWork`) and `hass` (`srvHome`) so each falls back to the environment's zone (C6). `netbird-client` (`zone0: home`) is a genuine client-zone placement — keep it, it stays valid under F1. Fix `00-Template` (`srvHome`) and the fixture/test JSONs under `foundation/*/test-fixtures/` and `test-vm-creation/`.
- `egress.to: "home"` on `nextcloud`, `nextcloud-hpb`, `euro-office` stays valid under F1 — verify only.
- `openwebui`/`hass` `proxyAllowedZones: ["home"]` stays valid under F1 — verify only.
- **Promote the silent drop to an error** (C7): an unresolvable `proxyAllowedZones` entry fails the install instead of warning, in `access-list.sh`. This is the #419 line "a dropped zone should be an error, not a Warning".
- **Pre-flight zone-ref validation at install start**: `install-module.sh` validates `zone0`, `proxyAllowedZones` and `egress[].to` against `zones.json` **before** any VM work, so a stale name fails fast instead of mid-install.
- Back-compat for existing installs: the module-config merge rewrites a stale zone reference through the same rename map `merge` uses, so a deployed `config/<module>.json` naming `srv` converges to `<env>` (the "backwards-compatibility scope" #419 asks for). `zone0` is not an AUTO_FIELD (C5), so uncustomised values adopt the repo fix for free.

**Test criteria** — every module JSON in the repo resolves against a freshly `init core`-ed `zones.json`; a deliberately stale `proxyAllowedZones` entry fails the install with a clear message (was: warn + reduced allow-list); pre-flight rejects a stale `zone0` before the VM is touched; a fixture install carrying `zone0: srv` converges to `<env>` through the merge.

---

### P8 — Docs, ADR reconciliation, issue closure

**Deliverables**
- Update **ADR-014 to v1.0 / Accepted**, folding in F1–F3: strike the `home → private` rename and its #425/ADR-007d migration note; restate D6 enforcement as phased (F2); add the retirement verb to D7 and the command-surface table; record D-C4 (authored vs. effective) in Schema changes; close the "merge back-fill ordering" open item (it runs inside `merge`).
- `ZONES.md`: `serves`, `bind`, archetypes, the tier lattice + R1/R2, the authored/effective split, and that `enable|disable|manual` already exist (D4's real gap was discoverability).
- Remove `_README.tier_model` / `pr_review_checklist` prose from the shipped `zones.json` — superseded by the machine gates.
- Migration runbook (`docs/design/ADR-014-migration-runbook.md`) for the fleet: baseline → update → `merge` back-fill → `retire --check` → `retire --apply` → `validate`.
- Close #424 and #419 with a short factual comment via `tea` (draft the body in a file first, per CLAUDE.md).

---

### P9 — Rollout campaign

See [Rollout campaign](#rollout-campaign) — three staged tests, gated on P0–P8 green.

---

## Package tracker

| # | Package | Depends on | Status | Tests | Notes |
|---|---------|-----------|--------|-------|-------|
| P0 | Branch + repo pointing + baseline | — | ✅ | baseline captured | branch live at `2f0ffd0`; system tracks it; snapshot deferred to Stage 1 (see note) |
| P1 | Schema foundation (`tier`/`isolated`/`serves` + archetypes) | P0 | ✅ | 160 unit + 15 CLI, `tsc` clean | additive only; +12 new tests |
| P2 | Read-side: I1–I4 + filtered `list` | P1 | ✅ | 176 unit + 15 CLI, `tsc` clean; live gate exit 0 | +16 tests; new `src/archetypes.ts` |
| P3 | `serves` + `bind` + effective rendering | P1, P2 | 🟦 | — | carries D-C4; closes #424 core |
| P4 | Archetypes on `add` | P1 | ⬜ | — | subsumes D3 |
| P5 | `environment add --create-zone` / reconcile materialise | P3 | ⬜ | — | env-mgr seam |
| P6 | `init` profiles + template cleanup + `retire` | P3, P4 | ⬜ | — | heaviest; carries F3 |
| P7 | #419 module refs + validation gates | P6 | ⬜ | — | closes #419 |
| P8 | Docs + ADR-014 → Accepted + issue closure | P1–P7 | ⬜ | — | |
| P9 | Rollout campaign (3 stages) | P8 | ⬜ | — | |

---

## Rollout campaign

Each stage is a gate: a red stage stops the line and the branch is fixed before the next stage runs.

### Stage 1 — this system (`rossen`), upgrade path

The system is already pointed at the branch (P0), so this is a real `update-tappaas` upgrade, not a simulation.

1. Snapshot `tappaas-cicd`; confirm the P0 baseline artefacts exist.
2. `update-tappaas` — `pre-update.sh` pulls the branch, rebuilds the managers, runs `network-manager merge` (which performs the P3 `serves` back-fill) then `network-manager validate`.
3. **Assert (the F2 invariant): `zones.json` gains `tier`/`isolated`/`serves` and loses its stale literals, and NOT ONE firewall rule changes.** Diff the OPNsense rule set before/after; any delta is a bug.
4. `network-manager retire --check` → expect the ten C10 candidates (and **not** `work`). Review, then `retire --apply`.
5. `network-manager validate` → clean; `validate --strict`, run by hand → the known I1 warning for `home → rossen`, documented as expected under F2. It gates nothing (R3).
6. Reachability spot-check from `home`: a service in `rossen`, `iotLocal`/`iotCloud` devices, and Caddy-proxied `hass` (the C7 module) all behave exactly as before.
7. Regression: full `test.sh` deep tier for `network-manager`, `environment-manager`, `module-manager`, `network`.

**Rollback:** restore the P0 `config/` archive and revert the branch pointer with `site-manager repository modify TAPPaaS --branch main`; the Proxmox snapshot is the backstop.

### Stage 2 — a second existing system

Same sequence on a different install, chosen for a **different drift shape** than `rossen` — ideally one that still carries an un-renamed `srv`, or occupied `srv*` zones so the F3 "warn on occupied" branch is exercised for real rather than only in fixtures.

### Stage 3 — blank install from scratch

Full `install.sh` on clean hardware/VMs. Validates the D7 profile path with no migration involved:
- `init core` produces exactly `mgmt` / `<N>` / `home` / `guest` / `dmz` + overlays, and **no** `srv*` or `test*` zones;
- `init iot` composes on top;
- `validate --strict`, run by hand, passes **clean** on a fresh install (nothing legacy to warn about) — the strongest single signal that the model is coherent, though still not a gate (R3);
- a module installs with no `zone0` and lands in `<N>` via C6.

---

## Resolved implementation decisions

Settled by the operator, 2026-08-22, in answer to this doc's original open questions.

**R1 — Retire the flat `iot` zone, subject to the same occupancy guard.** `iot` joins the P6 retired set alongside `srv{Home,Work,Cust,Dev,Test}` and `test*`. The F3 rule applies unchanged and is what protects a system that actually uses it: `retire` deletes a zone only when it is **Inactive and hosts no module** — a site running the flat `iot` topology keeps it, with a warning. `srv` stays in the template regardless: it is the rename source for `srv → <defaultEnvironment>`.

**R2 — Overlays are kept and exempted from the tier checks.** `netbird`, `edge` and `admin` stay exactly as they are. They carry no `tier`, and I1/I3/I4 skip any zone whose `type` is `Overlay` — so `admin`'s `access-to: ["mgmt"]` (an upward edge into Tier 0) does not trip I1, and no `overlay` archetype is invented to satisfy I4. Rationalising the three overlays is deferred to its own ADR (R4) and is out of scope here.

**R3 — No `--strict` gate in this branch.** I1–I4 ship **warn-only**. `--strict` keeps its existing meaning (promote every warning to an error) as an opt-in flag an operator may run by hand, but nothing in CI, `pre-update.sh` or any install path is wired to it in this branch. Turning it into a real pre-deploy gate is a later stage, once Stage 2 has shown what the fleet-wide warning set actually looks like. This makes the F2 phasing concrete: **no check introduced here can fail an install or an update.**

**R4 — Remote-access overlay rationalisation stays deferred.** Confirmed out of scope; it needs its own ADR against ADR-010/#367. Consistent with R2.

---

## Still open

1. **Converting `home access-to <env>` to per-module pinholes** — the F2 deferral. Needs its own issue, sized after Stage 1 shows how many modules a client actually reaches. Nothing in P0–P9 depends on it.
