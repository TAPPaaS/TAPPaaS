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
| `cmdb.ts` | The client of cmdb-controller's API (ADR-040): `cmdbReport` (an undelivered report is spooled under `config/.cmdb-spool/` and replayed first by the next call that gets through; a refusal throws `CmdbRefused`), `cmdbQuery`, `cmdbShow`, `cmdbRequest`, `replaySpool`. Synchronous: one `curl` per call over `/run/cmdb/cmdb.sock`, or `CMDB_URL` with the token. The `cmdb` CLI is built on it. |
| `cmdb-source.ts` | A manager's side of the CMDB (ADR-040 D4): `sendObservation` (its `report [--json]` verb), `reportChange` / `reportObservation` (a verb's change, a validate's or reconcile's read: never fail the verb), `cmdbJob` (the console job: `TAPPAAS_JOB_ID`, else `TAPPAAS_JOB`; the actor), `withStubs` (a `{class, name}` reference becomes a ref to a stub in the batch, referenced objects first), and the CI of a module instance (`moduleNodeAttributes`, `releaseOf`, `nodeClassOf`). `TAPPAAS_CMDB=off` turns reporting off. Test support beside it: `lib/ts/test/cmdb-check.ts` (would cmdb-controller's metamodel take this report). |
| `exec.ts` | `spawnSync` plumbing: `configEnv()`, `capture` (throw on failure, unified message), `captureResult` (rc/stdout/stderr, no throw), `stream` (stdio inherit). |

Planned (added when their consumers migrate): `cluster.ts` (ssh/pvesh
helpers shared by health/module), `args.ts` (generic flag-spec parser).

## Rules

- Anything used by two or more managers belongs here; anything used by one
  stays in that manager.
- Keep this library dependency-free and ambient-typed like the managers.
- A change here rebuilds/re-tests every manager — run the `manager/` test
  dispatcher, not just one component's `test.sh`.
