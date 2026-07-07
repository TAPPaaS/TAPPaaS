# ADR-007 post-implementation refactor

**Status:** DONE — phases 1–6 implemented, gated, committed (`2ac53ab`) and
verified end-to-end on the test system (only D6-parked items remain open)
**Branch:** ADR007 (no production system runs this branch; the test system is available for deep verification)
**Scope:** `src/foundation/tappaas-cicd/` — the TypeScript managers, the controllers, the shared `lib/`, and the install/update entry scripts (`pre-update.sh`, `update.sh`, `install.sh`, `update-tappaas`).

This document captures the post-ADR-007 code review of the manager/controller
rework, records the decisions taken on it, and tracks the implementation plan.
Update the checkboxes in [§6](#6-implementation-plan--tracking) as work lands.

---

## 1. Review verdict (2026-07-06)

Three independent review passes were run over the tree (cross-manager
duplication, internal quality of the three most complex managers, and
architecture conformance against `tappaas-cicd/README.md` / ADR-007 P4+P10).

**Overall: the structure is sound.** The uniform manager architecture (domain
model + injected client interface + pure planner + thin CLI, unit-tested
against in-memory fakes) is applied consistently across all seven TypeScript
managers; there is zero `any` under `tsc --strict`; every child invocation uses
`spawnSync` with argv arrays (no shell-injection surface); the module
boundaries hold. Nothing in the review calls the manager/controller split or
the per-manager decomposition into question.

The refactoring opportunity is specific: **~18–20% of the TypeScript tree
(~1,800–2,100 LOC) is mechanical duplication maintained "byte-identical by
discipline", and it has already drifted in four places** — plus a small number
of behavioral bugs found in passing, and one controller (opnsense) that sits
entirely outside the ADR-007 component contract.

## 2. Findings

Findings are numbered F1–F14 and referenced from the plan in §6.

### 2.1 Behavioral issues (fix first — safe, local)

- **F1 — config-root resolution: 9 copies, 3 incompatible precedence rules.**
  `CONFIG_DIR ?? TAPPAAS_CONFIG` in backup (`config.ts:30`), health
  (`config.ts:16`), site (`client.ts:29`), network (`planes.ts:49`,
  `distribute.ts:53`); **reversed** in module-manager (`config.ts:14`);
  `TAPPAAS_CONFIG` only (ignores `CONFIG_DIR`) in environment-manager
  (`config.ts:18`), people, site (`config.ts:16`) and network-manager
  (`zones.ts:19`) — network-manager disagrees with *itself*. With both env
  vars set, managers operate on different config roots.
- **F2 — two competing sources of truth for the cluster node list.**
  health-manager and module-manager enumerate nodes from `site.json
  .hardware.nodes[].name`; network-manager `distribute.ts:61-82` still reads
  legacy `configuration.json ."tappaas-nodes"`. On a site.json-only system,
  zone distribution silently targets zero nodes while health checks work.
- **F3 — `backup-manager reconcile --apply` with PBS offline crashes with a raw
  stack trace.** `reconcile.ts:25` warns "preview-only (controller offline)"
  but `main.ts:315-343` does not enforce it; the resulting
  `BackupControllerUnreachable` is not a `DieError` and escapes `run()`'s
  catch. Related: `applyPlan` in backup (`reconcile.ts:85-88`) and people
  (`reconcile.ts:252-257`) has no per-action error handling — a mid-apply
  failure aborts with no "applied N of M" report.
- **F4 — malformed config JSON handled three different ways; one makes
  `validate` lie.** backup-manager `readJson` (`config.ts:35-43`) silently
  returns `null` on parse error, so a corrupted `site.json` resolves every
  module to default policy while `backup-manager validate` prints "hierarchy
  consistent" — the exact failure that verb exists to catch. people-manager's
  unguarded `JSON.parse` (`config.ts:17-26`) crashes every command on one bad
  file with a raw stack trace.

### 2.2 Cross-manager duplication (the structural opportunity)

- **F5 — vendored byte-identical copies.** `help.ts` (76 lines) is
  byte-identical in 6 of 7 managers (health-manager hand-rolls its own
  `usage()` instead); `tsconfig.json` + test tsconfig byte-identical ×7;
  `package.json` differs by 3 lines; `env.d.ts` ~85% shared ×7. The copies
  stay identical only by discipline (help.ts documents itself as "VENDORED …
  keep the copies byte-identical").
- **F6 — CLI scaffolding repeated in every `main.ts`.** Colors +
  `info/warn/die/DieError` verbatim ×7; hand-rolled `parseOpts` loops; the
  `run()` dispatch/try-catch skeleton; the entry guard. ~500 lines essentially
  verbatim, ~450 more same-shape. Drift already visible: only site-manager
  catches generic `Error` cleanly (`main.ts:507-510`) — the other six print
  raw stack traces on unexpected exceptions.
- **F7 — spawnSync plumbing repeated ×7 (~300 LOC)** with an already-drifting
  hard copy-paste: module-manager `client.ts:51-210` admits "Ported from
  health-manager/src/client.ts" (~80 lines of `ssh`/`reachableNodes`/
  `clusterResources`); the mgmt-domain fix (`MM_MGMT_DOMAIN ?? "mgmt.internal"`)
  was applied to only one copy (health hardcodes `"mgmt"`). Also repeated:
  `Unreachable` error classes per manager, `asString`/`asStringArray` helpers,
  the `*_BIN` env-override idiom, the `CONFIG_DIR` env-injection block, the
  atomic write idiom. Naming is inconsistent (`client.ts`/`clients.ts`/
  `planes.ts`/`primitives.ts`; `CliSiteClient` vs `CliClient`), and
  environment-manager declares a `CliModuleClient` that shares a *name* but
  not a *contract* with module-manager's.
- **F8 — shell scaffolding duplication contra the `lib/` doctrine.** The
  identical ~10-line nix-build + gcroot + `ln -sfn` block is pasted into all 7
  TS manager `install.sh` files; one 16-line "link every executable" script is
  pasted ×3 and one 10-line test-runner ×3 on the controller side.
  `lib/README.md` says shared logic "lives here once, **never copied per
  component**" — there is simply no shared verb-script helper (and no shared
  TS) in `lib/` yet.

### 2.3 Architecture conformance

- **F9 — opnsense-controller (the largest controller) sits outside the
  mandatory component contract.** No `install.sh`, no `update.sh` (only
  `test.sh`); it is built by the whole-VM `pre-update.sh:231-273` — exactly
  the pre-ADR-007 behaviour P10 retires. The dispatcher silently skips it, and
  `tappaas-cicd/update.sh:58` carries a comment excusing it. See §4 for the
  ordering analysis.
- **F10 — identity-controller is built twice per update** — once by the
  dispatcher (`pre-update.sh:108-113` → `controller/install.sh` →
  `identity-controller/install.sh`) and again explicitly at
  `pre-update.sh:275-292`. The two paths already use different idioms
  (`ln -sfn` vs `rm`+`ln`; install.sh builds without the gcroot `--out-link`
  the managers use).
- **F11 — TEMPLATE drift.** `manager/TEMPLATE` is a bash stub with none of the
  nix/TS shape 7 of 8 real managers use; `controller/TEMPLATE` still
  recommends `npm ci && npm run build`, which nothing does. Scaffolding per
  the README produces a component unlike any real one.
  **Decision: remove both TEMPLATE dirs (see §3).**
- **F12 — managers ssh straight to the Proxmox plane, bypassing
  proxmox-controller.** health-manager `client.ts:37-150` (`pvesh`, `qm`,
  `df` over ssh), module-manager `client.ts:51-210` (the F7 copy), and
  network-manager `distribute.ts:116-132` (scp of zones.json) — while the
  same network-manager dutifully goes through the four plane controllers in
  `planes.ts`. Also health-manager is a controller by the README's own
  definitions (owns no config, no validate, talks only to runtime state) —
  its own header admits it (`config.ts:7-9`).
- **F13 — contract/doc drift, smaller items.** Three managers ship
  `validate-<name>.sh` instead of the contract's `validate.sh`
  (environment, module, site); stale docs (backup-manager `main.ts:18-19`
  says add/modify/delete are "PARKED" though fully implemented;
  network-manager DESIGN.md omits the 360-line `zonesmerge.ts`); dead
  interface surface taxing every test fake (people `getUser`, backup
  `namespaces()`/`verify()`/`ensure-verify`, the parsed-but-never-read
  `Opts.pbsEndpoint`).

### 2.4 Intra-manager cleanups

- **F14 — local duplication and stranded logic.** network-manager:
  `writeJsonAtomic` ×3 and `isDocKey` ×3 within the one manager, already
  diverging → consolidate into a `jsonio.ts` (the five-file `zones*` split
  itself is a good decomposition; only `zonelifecycle.ts` breaks the naming
  pattern). people-manager: entity normalization implemented twice
  (`config.ts` load path vs `entity.ts` decoders) hard-coding the same
  defaults; the `--deep` relationship queries are pure domain logic stranded
  in `main.ts` where unit tests cannot reach them. backup-manager
  `restore.ts:29-37` buffers-and-replays output because its `env.d.ts` lacks
  `stdio: "inherit"` (network-manager's already declares it) — a long restore
  shows no live output.

## 3. Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Fix F1–F4 now** (config-root precedence, node-list source of truth, backup/people error handling). | Safe, local, prevents real misbehavior. Agreed 2026-07-06. |
| D2 | **Remove `manager/TEMPLATE/` and `controller/TEMPLATE/` entirely** (resolves F11). No replacement scaffold — a new component is created by copying the nearest real component. Update the READMEs (`tappaas-cicd/README.md` "Scaffolding" section, `manager/README.md`, `controller/README.md`) and both dispatchers' TEMPLATE-skip can stay (harmless, defensive). | Templates have drifted beyond usefulness and are a second thing to maintain. Agreed 2026-07-06. |
| D3 | **Build the shared TypeScript library (`lib/ts/`)** covering F5–F7, as compiled-in *source* — not an npm package/workspace — preserving the zero-npm-dependency doctrine and per-manager nix build isolation. | Test system available; no production system on ADR007; the copies have already diverged in four places. Agreed 2026-07-06. |
| D4 | **Bring opnsense-controller into the component contract** (F9): give it `install.sh` + `update.sh`, remove the explicit build blocks from `pre-update.sh`, kill the F10 double-build. Ordering analysis in §4 first-class part of this work. | Agreed 2026-07-06. |
| D5 | **After D4 lands: analyse folding the firewall-facing scripts into the controllers** (§5). Analysis first, then a separate go/no-go per script. | Agreed 2026-07-06 ("once that is done"). |
| D6 | F12 (Proxmox-plane bypass / health-manager classification) and F13 remainders: **parked** — captured here, not scheduled. F12 needs its own design discussion (extend proxmox-controller's read surface vs. document a read-only carve-out). | Not decided yet. |

## 4. Ordering analysis — opnsense-controller into the contract (D4)

### 4.1 The flows today

**First install** (`src/foundation/install.sh` → `[5/5]` →
`cluster/install-platform.sh` → tappaas-cicd module install):

- opnsense-controller and identity-controller reach the fresh VM through the
  **NixOS system profile**: `tappaas-cicd.nix:29-32` imports both packages and
  `environment.systemPackages` exposes their CLIs. No `~/bin` symlinks yet.
- The TS managers are **not** in the system profile; they arrive via their
  `install.sh` (dispatcher). ⚠ *Verification task V1: map exactly where the
  manager dispatcher first runs on a virgin install (install-platform /
  bootstrap / first update-tappaas cycle) on the test system.*

**Every update** (`update-tappaas` systemd timer → Phase 1 foundation loop →
`module-manager modify tappaas-cicd` → `update-module.sh`):

1. Step 3 runs **`tappaas-cicd/pre-update.sh`**:
   - pull repos (line 39-78) → symlink `scripts/*.sh` into `~/bin` (86-101)
   - **run `manager/install.sh` + `controller/install.sh` dispatchers (108-113)** — builds/links all TS managers and identity-controller (first build of the two)
   - configuration.json refresh / site.json migration (122-150)
   - caddy ToDomain patch scp'd + applied on the firewall (159-174)
   - #237 zone-key migration (176-185) — its Stage 5 drives `network:proxy` via caddy-manager
   - `network-manager merge` + `zones-check` (187-229)
   - **explicit nix-build + `~/bin` link of opnsense-controller (231-273)**, **identity-controller again (275-292)**, **update-tappaas (294-302)**
   - OPNsense InterfaceAssign controller patch scp (304-315); credentials skeleton (264-271)
2. Step 5+ runs **`tappaas-cicd/update.sh`**: `nixos-rebuild switch` (which
   also refreshes the *system-profile* copies of both controllers), an inline
   OPNsense plugin retrofit (os-acme-client/os-ddclient, lines 40-53), then
   the manager/controller **update** dispatchers (55-66) — whose comment
   explicitly excuses opnsense-controller.

`~/bin` precedes the system profile in PATH, so after the first update the
pre-update symlinks are what operators and managers actually execute.

### 4.2 What changes and what it means

Giving opnsense-controller a contract `install.sh` (nix-build with the same
gcroot `--out-link` idiom the managers use + link the 11 CLIs + the
`opnsense-manager` alias) and a 4-line `update.sh` stub, then deleting
`pre-update.sh:231-302`, **moves the build from line ~231 to line ~109** (the
dispatcher). Analysis of the intervening steps:

- The configuration/site migrations (122-150) don't touch opnsense bins — unaffected.
- The caddy patch (166-174) is applied to the *firewall*, independent of the local build — unaffected, and it still precedes the zone-key migration.
- **Semantic shift (accepted):** the #237 zone-key migration Stage 5 and the
  zones merge/check currently run with the *previous* build's binaries; after
  the change they run with the *fresh* build. This is an improvement (bins
  match the just-pulled repo) but it is a behavior change to watch on the
  test system.
- `network-manager merge`/`zones-check` need only `network-manager` itself
  (already dispatcher-linked before them today) — unaffected.

**Failure-mode shift (decision needed at implementation time):** today a
failed opnsense nix-build aborts `pre-update.sh` hard (`set -e` at line 234).
Post-change, the dispatcher call is `|| warn` (`pre-update.sh:111`), so a
broken build would warn and the update would proceed **with stale bins**.
Options: (a) accept warn-and-continue (consistent with the dispatcher
philosophy — a component failure never blocks the fleet update); (b) make
`pre-update.sh` treat a non-zero `controller/install.sh` rc as fatal.
**Recommendation: (a)**, plus a Test-11 smoke line that fails the *test* gate
when the linked bin doesn't run — broken builds surface in CI rather than
blocking updates.

Also in scope of D4:

- `update-tappaas/` loses its explicit build block too (294-302). It lives
  outside `manager/`+`controller/`, so give it its own contract
  `install.sh`/`update.sh`/`test.sh` and have `pre-update.sh` call
  `update-tappaas/install.sh` (one line replacing eight). Whether it should
  *move* under `manager/` is out of scope.
- Delete the duplicate identity-controller block (275-292) — the dispatcher
  build is the single path (F10). Align identity-controller's `install.sh`
  to the gcroot `--out-link` idiom while at it.
- Update the excusing comments: `tappaas-cicd/update.sh:55-60` and
  `pre-update.sh:103-113`.
- **Keep** the system-profile imports in `tappaas-cicd.nix` for now — they are
  what makes a virgin VM functional before the first update cycle. Removing
  them is only safe once V1 shows the install path runs the dispatchers;
  revisit after D4 lands.

### 4.3 Verification on the test system

- V1: trace the virgin-install path (where do manager bins first appear?).
- V2: run a full `update-tappaas --force` cycle post-change; confirm all 11
  opnsense CLIs + `opnsense-manager` alias + `authentik-manager` +
  `update-tappaas` in `~/bin` point at fresh `result/`s; confirm gcroots exist.
- V3: re-run the cycle (idempotency: second run is a no-op, nix cache hit).
- V4: break the opnsense build deliberately (syntax error), confirm the chosen
  failure mode (§4.2) behaves as decided, revert.
- V5: `test-module.sh tappaas-cicd` fast slice green; `--deep` green.

## 5. Scripts-into-controllers analysis (D5 — after D4)

The candidates are the *firewall-mutating* steps living outside any component
today. Principle: `install.sh` stays offline-safe (build + link only);
runtime mutation belongs in a controller **verb** (idempotent, reachability-
guarded), invoked from the update flow.

| Candidate | Today | Proposed home |
|---|---|---|
| Caddy ToDomain patch (`opnsense-patch/apply-caddy-isdnsname.sh`) | `pre-update.sh:159-174` scp+ssh | `opnsense-controller ensure-patches` verb |
| InterfaceAssign PHP patch + ACL.xml | `pre-update.sh:304-315` scp | same verb |
| OPNsense plugin retrofit (os-acme-client, os-ddclient) | `tappaas-cicd/update.sh:40-53` inline ssh | same verb (or `ensure-plugins`) |
| `~/.opnsense-credentials.txt` skeleton | `pre-update.sh:264-271` | opnsense-controller first-run check (it owns the credential contract) |
| `scripts/setup-caddy.sh` | scripts/, linked to `~/bin` | fold into opnsense-controller (mutates the firewall; already depends on it per `install.sh:299`) |
| `scripts/acme-setup.sh` | scripts/ | fold into opnsense-controller (ACME lives on the firewall) |
| `scripts/rest-of-foundation.sh`, `migrate-*.sh` | scripts/ | **stay** — orchestration/migration, not device control |

Safety analysis to do per candidate before moving: (a) who calls it today
(grep operators' docs + install-platform + READMEs); (b) is it idempotent and
reachability-guarded; (c) does the ordering in §4.1 constrain it (the caddy
patch must still precede the zone-key migration Stage 5 — so `pre-update.sh`
keeps *calling* the verb at the same point; only the implementation moves).

## 6. Implementation plan — tracking

Each phase gates on: fast test slice green (`test-module.sh tappaas-cicd`),
then `--deep` on the test system before moving on.

### Phase 1 — behavioral fixes (D1) — safe, no structural change

- [x] 1.1 (F1) One canonical config-root rule: `TAPPAAS_CONFIG ?? CONFIG_DIR ?? /home/tappaas/config`, documented in `tappaas-cicd/README.md` ("Config root resolution"); applied to all 10 sites (backup config+client, environment, health, people, site config+client, network zones+planes+distribute).
- [x] 1.2 (F2) network-manager `distribute.ts` enumerates nodes from `site.json .hardware.nodes[].name` with fallback to legacy `configuration.json` (+ unit tests a2/a3 in network.test.ts).
- [x] 1.3 (F3) backup-manager refuses `reconcile --apply` when PBS unreachable; `applyPlan` (backup + people) continues past failing actions and returns `{applied,total,failures}` — callers report "applied N of M" and die on failure.
- [x] 1.4 (F4) Malformed-JSON policy: backup `readJson` throws (naming the file) on present-but-unparseable config; people `readJsonFiles` guards `JSON.parse` per file; both managers' `run()` now catch generic `Error` and print the clean `[Error]` line (site-manager's pattern).
- [x] 1.5 Unit tests: backup applyPlan-failure + malformed-site.json (cascade.test.ts, 66/0); people applyPlan-failure (reconcile.test.ts, block 9b) + malformed-user-JSON (entity.test.ts, block 9); fake clients grew a `failOn` knob.
- Gate: fast slices green on the test system 2026-07-06 — network 17/0, people 22/0, health 23/0, backup unit 66/0, `tsc --noEmit` clean for site/environment/backup.

### Phase 2 — remove TEMPLATEs (D2)

- [x] 2.1 Deleted `manager/TEMPLATE/` and `controller/TEMPLATE/`.
- [x] 2.2 Updated `tappaas-cicd/README.md` (layout tree, dispatch text, Scaffolding → "copy the nearest real component"), `manager/README.md`, `controller/README.md`, `update.sh` comment, `DEPENDENCIES.md`; renamed `scripts/test/test-template-contract.sh` → `test-dispatch-contract.sh` (drops the TEMPLATE-skeleton checks, keeps dispatcher-skip + shellcheck) and re-pointed `test.sh` Test 10.
- [x] 2.3 Dispatchers' TEMPLATE-skip guard left in place (defensive; the contract test still asserts it).
- Gate: test-dispatch-contract.sh 8/0 on the test system 2026-07-06.

### Phase 3 — shared TypeScript library `lib/ts/` (D3)

Design constraints: compiled-in source (each manager's `tsconfig.json`
`extends ../../lib/ts/tsconfig.base.json` and `include`s `../../lib/ts/src`),
**zero npm dependencies preserved**, each manager still builds in isolation via
its own nix derivation (the derivation's `src` widens to lib/ts + the
component — done once in `lib/nix/ts-manager.nix`, imported by each manager's
now-thin `default.nix`).

**Build mechanics (as implemented):** `tsconfig.base.json` sets
`rootDir: "../.."` (paths in an extended config resolve relative to the BASE
file, so rootDir = `tappaas-cicd/` for every extender); each manager keeps only
`outDir` + `include`. Emit therefore mirrors the tree —
`dist/manager/<name>/src/main.js` + `dist/lib/ts/src/*.js` — and the nix
wrapper entry is `$out/lib/manager/<name>/src/main.js`. Unit tsconfigs extend
the same base with `outDir: ../../dist-test`, so compiled tests move to
`dist-test/manager/<name>/test/unit/*.test.js` — **each manager's `test.sh`
node-invocation paths and any `__dirname`-relative fixture walks in the tests
must be updated during migration.**

**Migration recipe per manager** (proven on site-manager): (1) `default.nix` →
thin `lib/nix/ts-manager.nix` import; (2) both tsconfigs → extends-form;
(3) delete `src/help.ts` + `src/env.d.ts`, import `../../../lib/ts/src/help`;
(4) replace local colors/`info`/`warn`/`die`/`DieError` with
`../../../lib/ts/src/cli` imports and the `run()` catch with `guarded()`
(this also gives every manager the clean generic-Error path);
(5) replace spawnSync plumbing with `exec.ts` (`capture`/`captureResult`/
`stream`/`configEnv`) — note env.d.ts now truthfully types raw spawnSync
stdout/stderr as `string | null`, so any remaining direct uses need `?? ""`;
(6) replace `defaultConfigDir`/`asString`/`asStringArray`/atomic-write with
`config-io.ts`; (7) health+module: replace the pasted ssh/pvesh block with
`cluster.ts` (env override becomes `TAPPAAS_MGMT_DOMAIN`, replacing
`MM_MGMT_DOMAIN`); (8) fix `test.sh` dist paths + test `__dirname` walks;
(9) gate: `tsc --noEmit`, unit tests, nix build, bin smoke on the test system.

**Deferral:** `args.ts` (the generic flag parser, old 3.6) is deferred out of
Phase 3 — it is the lowest value-to-risk item (behavioral edge cases per
manager, no drift pressure once cli/exec are shared) and must not block the
migration. Revisit after Phase 6 if still wanted.

- [x] 3.1 `lib/ts/README.md` written (module list, import convention, build mechanics); `lib/README.md` now indexes everything in lib/.
- [x] 3.2 Pilot proven on site-manager: shared `lib/nix/ts-manager.nix` builder, extends-tsconfigs, bin smoke + test.sh 40/0 + unit 12/0 on the test system.
- [x] 3.3 `lib/ts/src/help.ts` (moved verbatim), `cli.ts` (colors, info/warn/die/DieError, `guarded()` — every manager now has the clean generic-Error path), `env.d.ts` (union; spawnSync stdout/stderr truthfully `string | null`).
- [x] 3.4 `lib/ts/src/exec.ts` (`configEnv`/`capture`/`captureResult`/`stream`, unified error format) and `config-io.ts` (`defaultConfigDir` — the Phase-1 rule, `asString`/`asStringArray`, `readJsonObject`, `writeJsonAtomic` — also fixes the old temp-dir leak).
- [x] 3.5 `lib/ts/src/cluster.ts` — health↔module ssh/pvesh dedup; env override unified as `TAPPAAS_MGMT_DOMAIN` (replaces `MM_MGMT_DOMAIN`; health's hardcoded domain now overridable).
- [x] ~~3.6 `args.ts`~~ **deferred** (see "Deferral" above).
- [x] 3.7 All 6 remaining managers migrated (parallel agents on the proven recipe). Per-manager judgment calls kept local where semantics differ from lib: environment's `NetworkUnreachable` wrapper + lenient parsers; module's rc-127 spawn mapping + lenient config readers; people's `AuthentikUnreachable` mapping + people-subdir configDir; backup's `BackupControllerUnreachable` mapping (+ `restoreScriptPath` __dirname depth fix); network keeps its non-throwing `runStreaming`, distribute's null-on-malformed reader, zonesmerge's indent-4 writer, and gained a `postInstall` copying the zones.json template asset the shared builder doesn't know about. test.sh dist paths + test `__dirname` walks fixed in health/people/network/module/backup.
- [x] 3.8 `lib/component-install-lib.sh` (`build_and_link_nix_component`, `link_component_executables`, `run_component_test_scripts`); all 7 manager `install.sh` nix blocks and the ap/proxmox/switch controller install/test scripts are now thin callers.
- [x] 3.9 health-manager folded onto the shared HelpSpec renderer (formatting change intended).
- [x] 3.10 Gate on the test system 2026-07-06: all 7 managers rebuilt via the shared builder (fresh /nix/store paths, `--help` smoke OK), test.sh suites green (site 40/0, people 22/0, environment 21/0, module 53/0, network 17/0, health 23/0, backup 27/0), backup/module/environment unit suites compile+pass at the new `dist-test/manager/<name>/...` paths, network zones.json asset present in the store output. Deep slice deferred to the Phase 4 gate (the ADR007-branch deep run has two PRE-EXISTING failures unrelated to this work: an ap-manager rc-2 test and the opnsense egress-check test, which needs internet the test VM doesn't have).

### Phase 4 — opnsense-controller into the contract (D4, §4)

- [x] 4.0 (V1) **Traced**: `tappaas-cicd/install.sh:183-188` runs the manager/ + controller/ dispatchers on a VIRGIN install (before that, opnsense/identity CLIs come from the `tappaas-cicd.nix` system-profile import). So a contract `install.sh` covers fresh installs automatically — no gap.
- [x] 4.1 `controller/opnsense-controller/install.sh` (shared `build_and_link_nix_component`, gcroot, 11 CLIs + `opnsense-manager` alias linked via the gcroot path) + `update.sh` exec-stub.
- [x] 4.2 `update-tappaas/{install,update,test}.sh`; `pre-update.sh` calls `update-tappaas/install.sh` right after the dispatchers (it sits outside manager/+controller/, so no dispatcher covers it).
- [x] 4.3 `identity-controller/install.sh` rewritten onto the shared helper (gcroot idiom; F10 double-build gone — the dispatcher build is the single path).
- [x] 4.4 `pre-update.sh` build blocks (old lines 231-302) deleted; credentials skeleton kept in place; comments updated in `pre-update.sh` (dispatcher block) and `tappaas-cicd/update.sh` (opnsense excuse removed). Ordering shift per §4.2 is live: the zone-key migration + zones merge now run with FRESH bins.
- [x] 4.5 Failure mode: **warn-and-continue** (option a). V4 proved it: a deliberately broken `default.nix` → install rc 1 with a clear ERROR, previous good `~/bin` links untouched, dispatcher warns, restore rebuilds clean.
- [x] 4.6 Test 11 smoke lines added: `opnsense-controller --help` + `update-tappaas --help` must load — the gate that surfaces a broken build under warn-and-continue.
- [x] 4.7 V2: all 11 opnsense CLIs + alias + authentik-manager + identity-controller + update-tappaas link to fresh gc-rooted store paths (2026-07-06). V3: re-run is a nix no-op. V4: green (see 4.5). V5: fast module gate green; the deep slice carries two PRE-EXISTING environment failures (ap-manager rc-2 check; opnsense egress test needs internet the test VM lacks) — tracked in §7, not caused by this refactor.
- [x] 4.8 Decision: **keep** the `tappaas-cicd.nix` system-profile imports — they make a virgin VM functional before `install.sh` runs its dispatchers; `~/bin` (which precedes the profile in PATH) takes over from the first install/update cycle.

### Phase 5 — scripts folding analysis + execution (D5, §5)

- [x] 5.1 Analysis done. Verdicts: **GO** — patch payloads (`opnsense-patch/` → `controller/opnsense-controller/patches/`), caddy ToDomain patch, InterfaceAssign+ACL copy, plugin retrofit, credentials skeleton (all idempotent, reachability-guardable, callers all within tappaas-cicd). **NO-GO** — `setup-caddy.sh` / `acme-setup.sh`: operator-facing orchestrators invoked by ~/bin name from ~12 callers (install-platform, network proxy services, tests, nix logging selectors); relocation is pure taxonomy with nonzero risk. Revisit when they're rewritten per the TS-first language policy.
- [x] 5.2 `opnsense-ensure-patches` implemented (bash tool in controller/opnsense-controller/, linked explicitly by its install.sh): credentials skeleton → reachability guard (exit 0 + warn when firewall down) → caddy patch → InterfaceAssign+ACL → plugin retrofit. `pre-update.sh` calls it at the pre-migration point (the caddy-before-Stage-5 ordering constraint); the duplicate tail block and `update.sh`'s inline plugin retrofit are removed. Override: `TAPPAAS_FIREWALL_FQDN` / `--firewall`.
- [x] 5.3 Credentials skeleton lives in the verb (step 1, local, runs even offline).
- [x] 5.4 Per 5.1: payloads moved (setup-caddy.sh's `PATCH_SCRIPT` path updated); setup-caddy/acme-setup stay put (documented no-go).
- [x] 5.5 Live verification on the test system 2026-07-06: `opnsense-ensure-patches` against the real firewall — caddy patch ensured ✓, InterfaceAssign+ACL ensured ✓, plugins already present, idempotent re-run rc 0; fast module gate green. ⚠ The full `pre-update.sh` end-to-end cycle (incl. update-tappaas driving it) can only be verified AFTER the operator commits+pushes this branch — pre-update git-pulls the repo, which would stash the synced-but-uncommitted working tree. Run `update-tappaas --force` on the test system as the post-push verification step.

### Phase 6 — cleanups (F13, F14)

- [x] 6.1 network-manager: `isDocKey` consolidated (exported from `zones.ts`, imported by zonesinit/zonesmerge; the three copies were byte-identical). Atomic-write consolidation happened in Phase 3 (zones.ts/main.ts → lib `writeJsonAtomic`; zonesmerge keeps its indent-4 writer deliberately).
- [x] 6.2 people-manager: one set of per-kind decoders (`toRole/toOrg/toGroup/toUser` in config.ts, used by both loadPeople and entity.ts — the only delta was unobservable non-string name/displayName coercion, unified on `asString`); `--deep` queries moved to `src/queries.ts` + new `test/unit/queries.test.ts` (15 checks) wired into test.sh.
- [x] 6.3 restore.ts streaming landed in Phase 3; dead surface pruned: `Opts.pbsEndpoint` (the parseOpts branch still CONSUMES `--pbs <v>` so the value can't leak into `rest` — the live handling is the entry-point pre-scan), `Client.namespaces()`/`verify()`/`"ensure-verify"` (backup), `PrimitiveClient.getUser` (people) — all grep-verified unused.
- [x] 6.4 Stale docs fixed: backup main.ts "PARKED" header; network DESIGN.md structure list (+ zonesmerge.ts, shared-lib note); people DESIGN.md validate text reconciled (TS `validate` = reference checks; `validate.sh` remains the schema path).
- [x] 6.5 Thin `validate.sh` wrappers added to environment/module/site managers (exec the domain-named script, mirroring backup-manager's shape) — the P10 "managers ship validate.sh" contract now holds for all 8.
- Gate 2026-07-06: all six touched manager suites green after one test-fixture fix (the new queries.test.ts probed "no-such-org", which the fixture's dangling-parent org legitimately references — probe renamed); backup units 66/0; fast module gate green.

### Phase 7 — bash→TS retire phase (PROPOSED, not started; caller precheck done 2026-07-06)

The ADR-007 "thin delegation until the retire phase" bash scripts were
inventoried repo-wide (34 domain scripts across the 7 TS managers; every
caller verified line-by-line, comment-only refs excluded). Classification:
**14 SAFE-TO-ABSORB** (no caller outside their own manager), **17 SHARED**
(installer / other foundation modules / satellite / test suites / migration
scripts), **3 OPERATOR-FACING** (runbook commands: module-format.sh,
snapshot-vm.sh, test-module.sh). Every retirement must also update the
`~/bin` presence list in tappaas-cicd/test.sh (Test 1) and drop the
component install.sh symlink line.

Proposed order (each its own test-gated step):
- [x] 7.1 Free retirements DONE (2026-07-06): validate-module.sh (P10 validate.sh now execs the TS verb directly), check-backup-status.sh, inspect-cluster.sh, migrate-configuration-to-site.sh (byte-identical duplicate) — all deleted after re-verifying zero real callers (DEPENDENCIES.md had three STALE claims contradicting code; fixed those rows too). **Scope corrections vs the original list:** check-disk-threshold.sh KEPT — its auto-grow (resize +50% over threshold) is NOT in the TS port (read-only subset); retire it only when health-manager grows a `grow` verb. validate-configuration.sh KEPT — really called by create-configuration.sh:530 (living legacy path); retire together with it. Gate: site 39/0, module 51/0, health green, `module-manager validate` + wrapper OK on the test system.
- [x] 7.2 Bycatch DONE: dead `scripts/zone-controller.sh` guards removed from install.sh + pre-update.sh; the two stale tests re-pointed at the components' new paths — both now pass 9/0 on the test system.
- [x] 7.3 Single-caller ports DONE (2026-07-06): reconcile-module.sh + inspect-vm.sh → native TS in module-manager (`src/reconcile.ts`, `src/inspect.ts`, `src/shlog.ts`; the orchestration still shells out to the KEPT scripts underneath); validate-environment.sh → native TS in environment-manager `src/validate.ts` (+ new `test/unit/validate.test.ts`) — the port turned out feasible (the bash was field-level checks, not a general JSON-schema engine). Both porting agents hit their session limits mid-flight; the retirement tail (script deletion, presence lists, DEPENDENCIES rows) was finished by hand. Follow-up noted: dedicated unit tests for module-manager's inspect pure-diff logic are thinner than planned (the agent was cut before finishing) — extend module.test.ts when convenient. Gate: all 7 manager suites green post-rebuild (module 47/0, environment 26/0, network 15/0 shell + expanded unit suite, backup 26/0 TS-native, health 23/0, site 39/0, people 23/0), converted zone-state test 9/0, fast module gate green.
- [x] 7.4 Backup quartet DONE (2026-07-06): backup-manager.sh, backup-status.sh, backup-restore.sh, lib-cascade.sh, validate-backup.sh deleted (TS backup-manager was already at full parity — `list --json` emits the identical array shape backup-status.sh did: module/environment/enabled/retention/residency/inPbsJob). Callers rewired first: health checks.ts backup-status gate now spawns `backup-manager list --config-dir <dir> --json` (env override renamed BACKUP_STATUS_BIN → BACKUP_MANAGER_BIN; gate name, parser, and SKIP-on-unavailable behavior unchanged); install-module.sh:513 sibling-.sh fallback removed — `backup-manager` on PATH is now REQUIRED there (die with pointer to the component install.sh; resolve-failure stays a warn-and-continue); P10 validate.sh now execs `backup-manager validate` (mirrors module-manager 7.1). backup-manager/test.sh rewritten TS-native: same fixture coverage (cascade 7y→5y→1y, enabled:false, --environment override, list/--disabled-only counts, validator's 4 accept/reject cases) exercised via the compiled `node dist-test/.../src/main.js`, plus it now actually runs `tsc --noEmit` + cascade.test.js (previously the unit suite wasn't wired into test.sh at all). install.sh reduced to the nix build+link (no .sh symlinks); cicd test.sh Test-11 smoke repointed at the installed TS bin; docs/inventories updated (backup-manager README/DESIGN, health README/DESIGN, backup-controller README, DEPENDENCIES.md/csv, PROGRAMS.csv — also dropped the stale check-backup-status.sh row left over from 7.1, site-fields.json description). NOTE for the test-system pass: rm the stale ~/bin symlinks (backup-manager.sh backup-status.sh backup-restore.sh validate-backup.sh).
- [x] 7.5 DONE (2026-07-06): zone-controller.sh + zone-state.sh deleted. Gap found during re-verification: the TS bin had NO state verb — ported as `network-manager enable|disable|manual <zone> [--force]` (zones.ts `changeZoneState` + main.ts dispatch, Mandatory guard preserved; +unit tests in network.test.ts §14). Callers repointed: network/test-variant-public.sh AND test-variants/test-variant-zone-node.sh (second real caller the inventory missed; both used `zone-controller delete … --apply`, an unknown flag the bash script died on — cleanup was silently broken, now fixed) → `network-manager zone add/delete`; common-install-routines hint → `network-manager enable` + `reconcile --apply`; scripts/test/test-zone-state.sh converted to exercise the TS verbs (9 cases kept; usage errors now rc 1 per the shared TS convention, was rc 2; skips if network-manager absent). install.sh links removed + stale ~/bin symlinks rm'd; docs/inventories updated (scripts/README, network-manager README/DESIGN, environment-manager README, DEPENDENCIES.md/csv, PROGRAMS.csv, design doc retirement note). NOT ported (deliberate): delete `--force`/`--keep-bridge-vid` + the ssh VM-occupancy preflight — the VID-removal guard lives in proxmox-controller bridge-vids.
- [ ] NO-GO for now (revisit per script with its own migration plan): update-os.sh (every VM update via templates' update-service.sh), install/update/delete-module.sh, copy-update-json.sh, convert-json-to-config.sh (hard dep of common-install-routines.sh), repository.sh (969 LOC), create-site.sh / migrate-configuration.sh (installer + migration paths), snapshot-vm.sh / test-module.sh / module-format.sh (operator-facing). (create-minimal-environments.sh + user-setup.sh graduated out of this list — retired in Phase 8 below.)

### Phase 8 — installer-path retirements (bootstraps → manager verbs)

- [x] 8.1 create-minimal-environments.sh retired (2026-07-06, working tree): the TS logic already lived in environment-manager `src/bootstrap.ts`; the missing bash parity was the explicit-name form — `add --name <N>` used to create a SINGLE env, now `add` with **no positional `<env>`** always seeds the minimal set and `--name` passes the system name through to the bootstrap (matching `create-minimal-environments.sh --name`; single-env create is `add <env>`). `--out-dir` deliberately NOT ported (zero callers; envs always land in `<config-dir>/environments`). Callers repointed: tappaas-cicd/install.sh:~215 (`environment-manager add --name/--domain`; the managers ARE built+linked by the manager/install.sh dispatch a few lines earlier — ordering verified + noted in a comment), migrate-to-adr007.sh step 3 (+ test-migrate expectation string), rest-of-foundation.sh backfill comment, create-site.sh hint text. env test.sh §6/6b/6c/7 now drive the compiled `node dist-test/.../main.js add` (new `run_bootstrap` helper). install.sh drops the stale ~/bin symlink; docs/inventories updated (env README/DESIGN, INSTALL.md, INSTALL-ENVIRONMENT.md, DEPENDENCIES.md/csv, PROGRAMS.csv — also swept the stale validate-environment.sh rows left from 7.3).
- [x] 8.2 user-setup.sh retired (2026-07-06, working tree): ported as the new `people-manager bootstrap --org O --user U --email E [--minimal-org DIR] [--force] [--skip-validate]` verb (`src/bootstrap.ts` + dispatch/HELP): copies minimal-org/ with `__ORG__/__USER__/__ROOT_EMAIL__/__EMAIL__` substitution (same ordering) in names+contents, same slug/email validation + error texts, same non-empty-destination refusal (exit 1) unless `--force`, all templates parsed+staged before any write (the bash's temp-dir staging property), result written via entity.ts atomicWrite/serialize (now exported). `--people-dir` folded into the manager's `--config-dir`; template dir resolved like backup-manager's restoreScriptPath / env-manager's resolveSchemaDir (PM_MINIMAL_ORG_DIR env → `__dirname` walk-up → mothership-checkout fallback, since the nix store output carries only compiled dist). Post-copy validation = in-process validateRefs (the `people-manager validate` gate) instead of shelling validate.sh — the deeper JSON-Schema pass still runs in test.sh via validate-people.sh on the bootstrap result. Callers repointed: rest-of-foundation.sh:~96, migrate-to-adr007.sh:~409 (both already guard on config/people emptiness, so the refusal semantics are unchanged). New test/unit/bootstrap.test.ts (shape/substitution/validateRefs/guard/--force/bad-args/resolution, PM_MINIMAL_ORG_DIR at the real minimal-org) wired into test.sh as the 4th unit invocation + compiled-CLI drives (bootstrap ok → validate-people.sh passes → re-run refused → missing --email dies). install.sh unlinks + rm's the stale ~/bin/user-setup.sh; docs/inventories updated (people README/DESIGN, validate-site.sh comment, DEPENDENCIES.md/csv, PROGRAMS.csv). NOT yet gated on the test system (no node/nix on the authoring host) — run the two manager test.sh suites + test-migrate-to-adr007.sh on the cicd before commit.
- Phase 8 gate (2026-07-06, test system): environment 26/0, people 17/0 (bash user-setup cases retired, TS bootstrap unit suite + CLI drives in), live smokes green — `people-manager bootstrap` created the org tree and `environment-manager add --name demo` seeded mgmt+demo in a temp config dir.
- Same batch, node-provisioning (docs/design/node-provisioning.md): **N1** node+pool capture in `site-manager reconcile` (+ `node reconcile` scoped verb, update-tappaas Phase 0.5) — live-verified on the operator's 2-node cluster (tappaas3 registered, pools [tanka1, tankc1] discovered+filled; unit 23/0); **N2** `cluster/make-install-media.sh`; **N3** `controller/node-provisioner` + `dhcp-manager pxe` verbs (node-provisioner suite green on cicd, dhcp PXE unit 13/13 in the built env, live `pxe status` reads the firewall; hardware PXE validation pending per the design doc's V-2 list).

### F12 — Proxmox-plane boundary: DECIDED (B) + CLOSED 2026-07-06

Current reality: health- and module-manager query the Proxmox plane directly
(ssh `pvesh`/`qm` via the shared `lib/ts/src/cluster.ts`), network-manager
scp's zones.json to nodes, and health-manager's `update-os` verb delegates to
`update-os.sh` which MUTATES VMs — all without proxmox-controller.

Options considered:
- **(A) Extend proxmox-controller** with read verbs (`guests --json`,
  `vm-config <vmid>` …) and make managers spawn it. Honest taxonomy, but adds
  a bash CLI surface + a spawn per query while `cluster.ts` already provides
  ONE audited choke-point; no control is actually gained.
- **(B) Codify a read-only carve-out (RECOMMENDED)**: managers MAY read
  cluster runtime state, but ONLY through `lib/ts/src/cluster.ts` (or an
  equivalent single shared helper) — direct `pvesh`/`qm`/`ssh` scattered in
  manager code stays forbidden; every runtime WRITE goes through a
  controller. network-manager's zones.json scp is grandfathered as a
  documented exception (it distributes a config artifact, not a device
  mutation). health-manager stays a manager with an explicit
  "read-mostly orchestrator" note; its one write path (`update-os`) is
  revisited when Phase 7 reaches `update-os.sh` (a natural future
  `os-controller` / proxmox-controller verb).
- **(C) New cluster-controller** wrapping the ssh reads. Same taxonomy win as
  (A), same cost, plus yet another component.

- [x] **Operator decision 2026-07-06: (B) adopted.** Carve-out documented in
  `tappaas-cicd/README.md` ("Runtime-state access rule"),
  `controller/README.md`, and health-manager/README.md. F12 CLOSED.

### Parked (D6)

- ~~F12~~ → proposal above.

## 7. Log

| Date | Entry |
|------|-------|
| 2026-07-06 | Review performed (3 passes); findings F1–F14; decisions D1–D6 recorded; plan drafted. |
| 2026-07-06 | **Phases 1–6 implemented and fast-gated on the test system** (working tree only — NOT committed; operator commits). Phase 1: F1–F4 behavioral fixes + unit tests. Phase 2: TEMPLATEs removed, dispatch-contract test 8/0. Phase 3: `lib/ts/` + `lib/nix/ts-manager.nix` + `lib/component-install-lib.sh`; all 7 TS managers migrated (~1.9k LOC of vendored duplication gone); all suites green. Phase 4: opnsense-controller + update-tappaas + identity-controller on the contract; pre-update.sh build blocks deleted; warn-and-continue failure mode proven (V4); Test 11 smokes added. Phase 5: `opnsense-ensure-patches` verb (live-verified against the firewall); patches moved into the component; setup-caddy/acme-setup documented no-go. Phase 6: dedup/dead-code/doc cleanups + validate.sh wrappers (P10 validate contract now holds for all 8 managers). |
| 2026-07-06 | **Known pre-existing deep-run failures on ADR007** (present before this refactor, environmental): (a) ap-controller `test-ap-manager.sh` "after confirm + full coverage → in sync" expects rc 0, gets 2; (b) opnsense-controller `test_egress_down_fails` needs egress to 1.1.1.1:443, which the isolated test VM lacks. Not addressed here. |
| 2026-07-06 | **Post-push verification required** (operator): after commit+push of this branch, run `update-tappaas --force` on the test system — the full pre-update.sh cycle (repo pull → dispatcher builds → ensure-patches → zone merge) could not be tested end-to-end against an uncommitted working tree (pre-update's git pull would auto-stash it). |
| 2026-07-06 | **Virgin-install verification PASSED (V1 live)**: operator wiped the test machine; full unattended `install.sh` run (served entirely from a LAN mirror per docs/SERVE-CODE-LOCALLY.md, TAPPAAS_DEBUG=1) completed **INSTALL-EXIT=0** end-to-end — node/pool/firewall/cutover/platform, network module post-update tests green. Two install bugs found+fixed en route: the ensure-patches fresh-install fatal (`94a4214`) and the stale known_hosts-by-IP hang in `wait_cicd_ssh` (`d601ca1`). **New finding (pre-existing, root cause of the empty-ownerOrg data)**: `create-minimal-environments.sh` bootstraps environments BEFORE any organization exists ("No organization found — ownerOrg left empty") and nothing backfills after `rest-of-foundation.sh` creates the org → environments fail schema validation until fixed by hand. Small fix needed: backfill ownerOrg at org creation (or bootstrap with the site name). |
| 2026-07-06 | **rest-of-foundation live run (fresh system) — 3 pre-existing bugs found, all fixed**: (1) the empty-`ownerOrg` gap closed — `rest-of-foundation.sh` now backfills `ownerOrg` on bootstrap environments via `environment-manager modify <env> --owner <org>` the moment the org is created (verified live: both envs updated, `environment-manager validate` passes with no manual surgery); (2) **TAPPAAS_DEBUG=1 corrupted the captured access-list name** (looked like a read-after-write race at first): `access-list.sh`'s `run_caddy` routed caddy output through `debug()` — which prints to STDOUT — while the file's callers command-substitute the resolved access-list NAME from stdout, so under debug the name became multiline garbage and handler creation failed "Access list '<garbage>' not found" (breaking the logging module's proxy; invisible in normal runs, which is why it survived every non-debug install). Fixed with the missing `>&2` on the debug loop + a LOAD-BEARING comment; verified live under debug (handler created, module tests pass). `caddy_cli.py` also gained a lookup retry (4×2 s) — kept as hardening for genuine API lag; (3) **rest-of-foundation idempotency was broken**: its header claims re-run safety, but `install-module.sh`'s single-instance guard refuses already-installed modules, so a re-run failed on every module that succeeded before — `install_one` now skips modules whose deployed config exists (half-installed modules are repaired with `update-module.sh <m>`, which re-runs the dependency service installers). |
| 2026-07-06 | **Deep-gate finds, fixed**: (a) environment-manager's entry point pre-parses argv OUTSIDE `guarded()`, so a bad flag dumped a raw DieError stack — latent pre-existing bug surfaced by the migration; entry now wrapped in `guarded()`. (b) The test system's live `config/environments/{mgmt,test4}.json` had empty `ownerOrg` (schema-invalid; bootstrap-era data) — fixed via `environment-manager modify <env> --owner test4`; the env deep tier ("live config/environments validate") now passes. Remaining deep failures are the documented environmental ones (tappaas3 node offline → VM-creation/variant suites; ap-manager rc-2; opnsense egress). |
| 2026-07-06 | **Committed as `2ac53ab` and pushed to origin/ADR007** (148 files, +2344/−2965). Post-push verification PASSED: test system fast-forwarded to the commit (operator's local network/test.sh edits turned out to already be upstream), then a full `update-tappaas --force` cycle ran — rc 0, ZERO [Error] lines, `total=7 succeeded=7 failed=0`, reboot pass clean. Log confirms the new paths executed live: dispatcher component builds (manager/ + controller/, incl. the contract opnsense/identity/update-tappaas builds), `opnsense-ensure-patches` (both patches ensured ✓), then the zones 3-way merge. Plan complete; open items: the D6-parked F12 boundary question and the deferred `args.ts`. |
| 2026-07-07 | **Node-provisioning stage 1 (issue #404) COMPLETE — committed `a3a65ef`, pushed to origin/ADR007** (24 files, +1886/−291). Two days of hardware validation on an Intel Atom C3758 found and fixed ~15 real defects (full log: `docs/design/node-provisioning.md` §7.1/§7.2) — highlights: initramfs 4-byte segment alignment (the kernel silently drops a misaligned trailing cpio); the installer's 10 s dhclient window vs NIC link re-train (fixed by shipping a patched `/init` as an override initramfs segment); OPNsense's API rejecting negated dnsmasq tags (PXE trap rewritten as an owned `dnsmasq.conf.d` drop-in that survives reconfigures); the ansible dnsmasq_host module silently dropping `hwaddr` (raw `setHost` now); the installer baking its DHCP lease as a static address (+ into /etc/hosts, which blocks `pvecm add`); strict-BatchMode ssh silently breaking N1 pool discovery (lib-wide `accept-new`). **New operator front door validated end-to-end on hardware**: `site-manager node add <N>` — adopt (default: existing Proxmox at the node's designated mgmt IP) / `--pxe` (netboot install; boot disk asked on the NODE console when not given) / `--config-only`; the join pipeline asks WAN + pools with the node's real hardware listed, then node step → `pvecm add` → reconcile capture. Netboot assets now stage automatically at first-node bootstrap (`prepare-netboot.sh`, live-verified) so node-adding is a latent capability of every install; `make-install-media.sh` runs without any PVE system (Linux deb-extract / macOS Docker re-exec) and asks the boot disk at install time via the same initrd-override mechanism (code-complete, hardware test pending). Post-commit `update-tappaas --force` (operator) ran clean over the 3-node topology — tappaas4 `[tanka1, tankb1]` captured, HA/replication folded. *(A concurrent duplicate update run, assistant-launched, transiently flagged the identity module; the operator's authoritative run was green.)* **Next: stage 2 — MS-S1 Max**, starting with the Realtek r8127 NIC reality check (`node-provisioning.md` §7 step 1). N4 (first-boot auto-join) is superseded by `node add`'s mothership-pull design. Tracker/doc updates for this entry are working-tree only — operator commits. |
