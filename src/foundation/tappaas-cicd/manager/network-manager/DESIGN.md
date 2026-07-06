# network-manager — design notes

## Language and build

- **CLI:** TypeScript (`src/*.ts`), compiled with `tsc`, **no `node_modules`**
  (Node types from the shared ambient `../../lib/ts/src/env.d.ts`; the CLI
  conventions — colors, `info`/`warn`/`die`, `--help` rendering, config-root
  resolution, atomic JSON writes, spawn env plumbing — come from `../../lib/ts/src/`).
- **Build mechanism:** `default.nix` is a thin import of the shared TS-manager
  builder (`../../lib/nix/ts-manager.nix`), plus a `postInstall` that ships the
  `zones.json` template next to the compiled `main.js`. `install.sh` runs
  `nix-build -A default default.nix` and `ln -sfn`s the resulting
  `result/bin/network-manager` (a Node 22 wrapper) into `~/bin/network-manager`
  (override the bin dir with `TAPPAAS_BIN`).
- **`update.sh`** re-runs `install.sh` (rebuild + relink; idempotent).
- The same `install.sh` also relinks the not-yet-retired legacy bash tools
  (`zone-reconcile`, `zone-state.sh`, `zone-controller`).

## Internal structure

```
src/main.ts          CLI: arg parsing + subcommand dispatch
src/types.ts         Zone model, ZonesDoc, the PlaneClient interface, Plan/report shapes
src/zones.ts         load/CRUD zones.json + VLAN allocation + the mgmt.access-to invariant
src/zonelifecycle.ts add/delete (always includes the switch plane)
src/zonesinit.ts     init template transform (rename srv/home/guest to the system name)
src/zonesmerge.ts    merge: the rename-aware 3-way zones.json reconciliation
                     (current vs .orig baseline vs renamed repo template; port
                     of apply-zones-merge.sh, run from update-tappaas)
src/zonescheck.ts    zones-check offline consistency audit
src/distribute.ts    distribute: push zones.json to the Proxmox nodes
src/planes.ts        CliPlaneClient — spawnSync the four plane controllers; rc -> status
src/reconcile.ts     the dependency-ordered 4-plane reconcile
```

Cross-manager plumbing (colors, `info`/`warn`/`die`, `--help` rendering,
config-root resolution, atomic JSON writes, spawn env, ambient Node types)
lives in the shared `../../lib/ts/src/` — there is no per-manager `help.ts`
or `env.d.ts` under `src/`.

`zones.json` is round-tripped losslessly: documentation blocks (`_`-prefixed
keys) and unknown fields are preserved on save. A core invariant is that the
`mgmt` zone must exist, be Active, and list every standard zone in its
`access-to` for operational visibility.

## The four planes and how it talks to controllers

The reconcile engine depends only on a `PlaneClient` interface; the production
implementation (`CliPlaneClient`) reconciles four planes **in dependency order**
by spawning each plane's controller bin (each overridable by an env var):

1. **opnsense** (L3) — `zone-manager` (`NM_OPNSENSE_BIN`).
   Dry-run `--summary`, apply `--execute`, both with `--no-ssl-verify
   --zones-file <f>`.
2. **proxmox** (L2, per node) — `proxmox-controller` (`NM_PROXMOX_BIN`):
   `reconcile [--apply]` plus `bridge-vids [--apply]`.
3. **switch** (L2, inter-node) — `switch-controller` (`NM_SWITCH_BIN`):
   `reconcile [--apply]`.
4. **ap** (WiFi) — `ap-controller` (`NM_AP_BIN`): `reconcile [--apply]`.

Each controller follows an `rc` convention: `0` in sync, `2` drift (in dry-run) /
needs-manual (after apply), `1`/other error. The engine aggregates per-plane
results: a plane error fails the run; Proxmox still drifting after `--apply` is a
hard failure; switch/ap reporting `needs-manual` after `--apply` is surfaced but
not a hard failure (they cannot always self-apply). In dry-run, drift is reported,
never a failure.

`add`/`delete` always include the switch (and ap) plane — earlier
designs reconciled only opnsense + proxmox, so a new VLAN never reached the
physical switch and off-firewall-node VMs got no IP.

## Testing

`test.sh`:

- **Fast (default):** bash syntax-check of the legacy entry scripts; `tsc
  --noEmit` type-check; compile + run the offline unit tests against an in-memory
  `FakePlaneClient` (zone CRUD, the 4-plane order/flags, per-plane rc
  aggregation, dry-run mutates nothing); plus CLI smoke tests of `init`
  (to a temp `--out`), `zones-check` (good + dangling-ref fixtures), and
  `distribute --dry-run`.
- **Deep (`TAPPAAS_TEST_DEEP=1`):** a live reconcile **dry-run** (non-mutating)
  against the real plane controllers, reconciling the switch plane only as a
  proof of concept; skips gracefully when the bin isn't built or planes are
  unreachable.

## Validation

`validate.sh` is the manager's `validate` operation: it does structural +
reference validation of `zones.json`. `zones-check` is the richer offline audit
available as a CLI subcommand. Tracked follow-up: as a TypeScript manager, this
bash `validate.sh` is slated to become a `network-manager validate` binary
subcommand — the convention end-state.

## Pending / not yet implemented

- **Legacy bash tools not yet retired.** `zone-reconcile`, `zone-controller.sh`,
  and `zone-state.sh` are still present and linked; a later change retires them
  once the TypeScript path fully supersedes them.
- **Deferred legacy-zone sunset.** When `init` would inactivate a zone that
  still hosts deployed modules, it keeps the zone Active and warns the operator to
  migrate those modules to the new system-named zone (or an environment) later —
  the automatic sunset is deferred. (See the warning in `src/main.ts`.)
