# manager/network-manager

The **network owner + orchestrator** (ADR-007 P4 / ADR-008). It is the single
**front door** for the network: it owns `zones.json` (CRUD + delta) and
reconciles all four infrastructure planes by calling the plane-controller bins.

See `docs/design/ADR-007-implementation.md` → "Network Orchestration:
network-manager" for the full design.

## What this component owns

- **`zones.json`** — the desired network state (stays at
  `${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json` in this chunk). CRUD, VLAN
  allocation, the `mgmt.access-to` operational-visibility invariant.
- **The 4-plane reconcile loop** — converges desired → actual across every
  plane, in dependency order, and reports per-plane drift.

## TypeScript CLI (`network-manager`)

Built with Nix (`tsc`, no `node_modules`, ambient `src/env.d.ts`) — the S-TS
pattern, mirroring `switch-controller` and `people-manager`.

| Command | Purpose |
|---------|---------|
| `zone list` / `zone exists <n>` / `zone get <n>` | read `zones.json` |
| `zone add <n> [--from-zone S] [--type T --typeId N] [--vlan V] [--variant X] [--no-activate] [--check]` | author a zone + reconcile ALL planes (switch always included) |
| `zone delete <n> [--check]` | disable + reconcile ALL planes + remove the key |
| `reconcile [--apply] [--only <plane>]` | the full 4-plane reconcile (default dry-run) |

### The four planes (dependency order)

It calls the **on-PATH** controller bins — the #335/#372/#373 fix, since the old
`zone-reconcile` hardcoded stale `firewall/scripts/` paths and never told the
switch:

1. **opnsense** (L3) — `zone-manager --no-ssl-verify --zones-file <f> {--summary|--execute}`
2. **proxmox** (L2 node) — `proxmox-manager reconcile [--apply]` + `bridge-vids [--apply]`
3. **switch** (L2 inter-node) — `switch-controller reconcile [--apply]` (the TS bin)
4. **ap** (WiFi) — `ap-manager reconcile [--apply]`

rc convention: `0` in-sync, `2` drift (dry-run) / needs-manual (apply), `1`/other
error. A plane error → overall failure; proxmox still drifting after `--apply` →
failure; switch/ap `needs-manual` is surfaced but not a hard failure.

**#372/#373 fix:** `zone-controller.sh` reconciled only opnsense + proxmox on
add/delete. network-manager **always** reconciles the switch (and ap) plane, so a
new VLAN reaches the physical switch and off-firewall-node VMs get an IP.

## Source layout (mirrors people-manager)

```
src/types.ts          Zone model + PlaneClient interface + Plan/report shapes
src/zones.ts          load/CRUD zones.json + VLAN allocation + mgmt invariant
src/planes.ts         CliPlaneClient: spawnSync the 4 plane bins; rc → status
src/reconcile.ts      the dependency-ordered 4-plane reconcile (port of zone-reconcile)
src/zonelifecycle.ts  zone add/delete (port of zone-controller.sh) — switch ALWAYS included
src/main.ts           the CLI
```

## Entry scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | nix-build the TS bin + link `network-manager` into `~/bin`; relink legacy bash (not retired yet) |
| `update.sh` | re-runs `install.sh` |
| `test.sh` | FAST (offline tsc + unit tests) by default; DEEP (`TAPPAAS_TEST_DEEP=1`) live reconcile dry-run |
| `validate.sh` | structural + reference validation of `zones.json` (managers ship `validate.sh`) |

## Coexists with (not yet retired)

`zone-reconcile`, `zone-controller.sh`, `zone-state.sh` are still present and
linked; a later chunk retires them. `apply-zones-merge.sh` and the
`migrate-zone-keys-*.sh` migration helpers are left as-is (not on-PATH tools).
