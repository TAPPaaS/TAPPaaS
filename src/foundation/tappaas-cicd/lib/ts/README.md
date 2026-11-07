# lib/ts — shared TypeScript library for the TAPPaaS managers

Shared TS source for the `manager/` components (ADR-007 post-implementation
refactor — see `docs/design/ADR007-post-implement-refactor.md`, Phase 3).
Per the `lib/` doctrine: shared logic lives here **once**, it is **never
copied per component**. This replaces the old "vendored, keep the copies
byte-identical" convention (`help.ts`, `env.d.ts`) that had already drifted.

## How sharing works (no npm, no workspace)

The managers stay **zero-npm-dependency**: there is no package here, no
`node_modules`, no lockfile. Sharing is *compiled-in source*:

- `tsconfig.base.json` holds the common compiler options with
  `rootDir: "../.."` (= `tappaas-cicd/`). Every manager's `tsconfig.json`
  `extends` it, sets its own `outDir`, and `include`s both its own `src/`
  and `../../lib/ts/src/`.
- Because `rootDir` is the cicd root, emit mirrors the tree:
  `dist/manager/<name>/src/main.js` + `dist/lib/ts/src/*.js` — the nix
  wrapper points at `$out/lib/manager/<name>/src/main.js`.
- `lib/nix/ts-manager.nix` is the single derivation builder: a manager's
  `default.nix` is a ~10-line import passing `name` + `componentRel`. The
  nix `src` filter admits only `lib/ts/` + the component dir, so a lib
  change rebuilds every manager (wanted) but unrelated tree changes do not.
- Imports are plain relative paths, e.g. from `manager/x/src/main.ts`:
  `import { die } from "../../../lib/ts/src/cli";`

## Modules

| Module | Contents |
|---|---|
| `env.d.ts` | Ambient Node declarations (union of what all managers use) — the zero-`@types/node` trick. `spawnSync` stdout/stderr are truthfully `string \| null`; use `exec.ts` helpers rather than reading them raw. |
| `cli.ts` | ANSI colors, `info`/`warn`/`die`/`DieError`, and `guarded()` — the standard `run()` catch: `DieError` → 1, other `Error` → clean `[Error]` line + 1. |
| `help.ts` | The shared `HelpSpec`/`renderHelp` --help renderer, and `checkArgs()`, the argument gate every manager's `run()` calls first: `-h`/`--help` in any position prints that verb's help and runs nothing; an option the verb does not declare is refused (#644). A verb accepts what its usage line, `options`, `hidden` and the common options name — so every accepted option is documented. `undocumentedOptions()` lets a manager's tests assert each usage option is described. `--help --json` (no verb) prints `renderManifest()`, the verb manifest the console validates its jobs against (ADR-034 D4): per verb its keys, positionals, options, read or write, preview form, destructive and disruptive marks. |
| `config-io.ts` | `defaultConfigDir()` (the canonical `TAPPAAS_CONFIG ?? CONFIG_DIR ?? /home/tappaas/config` rule), `asString`/`asStringArray`, `readJsonObject` (absent → null; malformed → throws naming the file), `writeJsonAtomic`. |
| `cmdb.ts` | The client of cmdb-controller's API (ADR-040): `cmdbReport` (an undelivered report is spooled under `config/.cmdb-spool/` and replayed first by the next call that gets through; a refusal throws `CmdbRefused`), `cmdbQuery`, `cmdbRelations`, `cmdbShow`, `cmdbRequest`, `replaySpool`. Synchronous: one `curl` per call over `/run/cmdb/cmdb.sock`, or `CMDB_URL` with the token. The `cmdb` CLI is built on it. |
| `job.ts` | The console job a verb runs in (ADR-040 D4, D6): `currentJob()` is `{id, actor}` from `TAPPAAS_JOB_ID` (the console's Activity id; absent outside a job) and `TAPPAAS_ACTOR` (the console user, else the OS user); `changeJob()` the same as a change report's `job` and `actor`. Every reporter reads them through it; the bash managers through `cmdb_current_job` (lib/cmdb-report.sh). |
| `exec.ts`, `config-io.ts`, `TAPPAAS_SIMULATE=1` | `simulating`, `mutators`, `isMutator`: the gate under the console's simulate mode. `capture`, `captureResult`, `stream`, `streamToFile` and `spawnGuarded` skip a command on `lib/simulate-mutators.txt` (log on stderr, exit 0, empty stdout), carry the variable over ssh and export `BASH_ENV=lib/simulate-gate.sh`. `writeJsonAtomic` skips writes under the config root; `writeFileGuarded`, `renameGuarded`, `unlinkGuarded`, `rmGuarded`, `mkdirGuarded`, `rmdirGuarded` and `chmodGuarded` skip any write outside the temp dir. `cmdbRequest` and `cmdbReport` send nothing that records. A raw `spawnSync` or fs write in a manager fails `scripts/test/test-simulate-coverage.sh`. |
| `cmdb-source.ts` | A manager's side of the CMDB (ADR-040 D4): `sendObservation` (its `report [--json]` verb), `reportChange` / `reportObservation` (a verb's change, a validate's or reconcile's read: never fail the verb), `withStubs` (a `{class, name}` reference becomes a ref to a stub in the batch, referenced objects first), and the CI of a module instance (`moduleNodeAttributes`, `releaseOf`, `nodeClassOf`). `TAPPAAS_CMDB=off` turns reporting off (`cmdbReport` in `cmdb.ts` honours it too: nothing is sent or spooled). Test support beside it: `lib/ts/test/cmdb-check.ts` (would cmdb-controller's metamodel take this report). |
| `score.ts` | The one CVE risk score (ADR-045 D3): `moduleScore` (risk 25/10/3/1, open/carried 20/8, only the highest category, each further item at half the one before), `levelOf` (ok 0, low <7, medium <16, high <30, critical ≥30), `zoneScore` with `tierMultiplier`, `siteScores` (zones, environments, the site), `releaseScores` (no multiplier) and `scoreModel` (the tables, for a record). health-manager's `score` verb wraps it; nothing else computes a score. |
| `exec.ts` | `spawnSync` plumbing: `configEnv()`, `capture` (throw on failure, unified message), `captureResult` (rc/stdout/stderr, no throw), `stream` (stdio inherit). |

Planned (added when their consumers migrate): `cluster.ts` (ssh/pvesh
helpers shared by health/module), `args.ts` (generic flag-spec parser).

## Rules

- Anything used by two or more managers belongs here; anything used by one
  stays in that manager.
- Keep this library dependency-free and ambient-typed like the managers.
- A change here rebuilds/re-tests every manager — run the `manager/` test
  dispatcher, not just one component's `test.sh`.
