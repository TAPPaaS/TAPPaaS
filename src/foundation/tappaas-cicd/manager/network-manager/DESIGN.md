# network-manager — design notes

## Language and build

- **CLI:** TypeScript (`src/*.ts`), compiled with `tsc`, **no `node_modules`**
  (Node types from an ambient `src/env.d.ts`).
- **Build mechanism:** `install.sh` runs `nix-build -A default default.nix`, which
  runs `tsc -p tsconfig.json`, copies the compiled `dist/` and the shipped
  `zones.json` template into the output, and `makeWrapper`s
  `result/bin/network-manager` (a Node 22 wrapper). It then `ln -sfn`s that into
  `~/bin/network-manager` (override the bin dir with `TAPPAAS_BIN`).
- **`update.sh`** re-runs `install.sh` (rebuild + relink; idempotent).
- The same `install.sh` also relinks the not-yet-retired legacy bash tools
  (`zone-reconcile`, `zone-state.sh`, `zone-controller`).

## Internal structure

```
src/main.ts          CLI: arg parsing + subcommand dispatch
src/types.ts         Zone model, ZonesDoc, the PlaneClient interface, Plan/report shapes
src/zones.ts         load/CRUD zones.json + VLAN allocation + the mgmt.access-to invariant
src/zonelifecycle.ts zone add/delete (always includes the switch plane)
src/zonesinit.ts     zones-init template transform (rename srv/home/guest to the system name)
src/zonescheck.ts    zones-check offline consistency audit
src/distribute.ts    zones-distribute: push zones.json to the Proxmox nodes
src/planes.ts        CliPlaneClient — spawnSync the four plane controllers; rc -> status
src/reconcile.ts     the dependency-ordered 4-plane reconcile
```

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

`zone add`/`zone delete` always include the switch (and ap) plane — earlier
designs reconciled only opnsense + proxmox, so a new VLAN never reached the
physical switch and off-firewall-node VMs got no IP.

## Testing

`test.sh`:

- **Fast (default):** bash syntax-check of the legacy entry scripts; `tsc
  --noEmit` type-check; compile + run the offline unit tests against an in-memory
  `FakePlaneClient` (zone CRUD, the 4-plane order/flags, per-plane rc
  aggregation, dry-run mutates nothing); plus CLI smoke tests of `zones-init`
  (to a temp `--out`), `zones-check` (good + dangling-ref fixtures), and
  `zones-distribute --dry-run`.
- **Deep (`TAPPAAS_TEST_DEEP=1`):** a live reconcile **dry-run** (non-mutating)
  against the real plane controllers, reconciling the switch plane only as a
  proof of concept; skips gracefully when the bin isn't built or planes are
  unreachable.

## Validation

`validate.sh` does structural + reference validation of `zones.json` (managers
ship `validate.sh`); `zones-check` is the richer offline audit available as a CLI
subcommand.

## Pending / not yet implemented

- **Legacy bash tools not yet retired.** `zone-reconcile`, `zone-controller.sh`,
  and `zone-state.sh` are still present and linked; a later change retires them
  once the TypeScript path fully supersedes them.
- **Deferred legacy-zone sunset.** When `zones-init` would inactivate a zone that
  still hosts deployed modules, it keeps the zone Active and warns the operator to
  migrate those modules to the new system-named zone (or an environment) later —
  the automatic sunset is deferred. (See the warning in `src/main.ts`.)
