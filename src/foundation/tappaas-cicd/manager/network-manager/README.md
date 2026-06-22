# network-manager

The **network front door**. It owns `zones.json` (the desired network state) and
reconciles four infrastructure planes — OPNsense, Proxmox, the switch, and access
points — by orchestrating their controllers. Adding or deleting a zone authors
the config *and* drives every plane so a new VLAN actually reaches the firewall,
the Proxmox hosts, the physical switch, and the WiFi.

## What it owns

`zones.json` at `${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json`. Each top-level
key is a zone (keys beginning `_` are documentation blocks, preserved but not
treated as zones). A zone records its `type` / `typeId`, `vlantag`, `ip` (CIDR),
`bridge`, `state`, reachability (`access-to`), per-module pinhole allowance
(`pinhole-allowed-from`), and optional `variant`/`SSID`. Auto-allocated VLANs use
the 60–99 window within each type band; zone names must be camelCase.

## Commands

One compiled CLI, `network-manager`:

```
network-manager zone list
network-manager zone exists <name>
network-manager zone get <name>
network-manager zone add <name>     [options]
network-manager zone delete <name>  [--check]
network-manager reconcile           [--apply] [--only <plane>]
network-manager zones-init  --name <N> [--from <tpl>] [--out <file>] [--force]
network-manager zones-check [--zones <file>] [--config-dir <dir>] [--strict]
network-manager zones-distribute [--zones <file>] [--dry-run]
network-manager -h | --help
```

### `zone` — CRUD on zones.json

```bash
network-manager zone list                 # list zone names
network-manager zone exists srvHome        # exit 0/1
network-manager zone get srvHome           # print the zone object
```

`zone add <name>` authors a new zone **and reconciles all four planes** (so the
VLAN reaches everything). Options:

- `--from-zone <src>` — inherit type/typeId/bridge/access-to/pinhole from `<src>`.
- `--type <T>` — zone type (default `Service`).
- `--typeId <N>` — numeric type band (default `2`).
- `--vlan <tag>` — explicit VLAN tag (else auto-allocated 60–99 in the band).
- `--variant <name>` — tag the zone with this variant (metadata).
- `--no-activate` — author `zones.json` only; skip the all-plane reconcile.
- `--check` — dry-run: show what would change, mutate nothing.

`zone delete <name>` disables the zone, reconciles all planes, then removes the
key. `--check` dry-runs it.

```bash
network-manager zone add labNet --from-zone srvHome --vlan 275
network-manager zone add labNet --check          # preview
network-manager zone delete labNet
```

### `reconcile` — the 4-plane converge loop

```bash
network-manager reconcile                  # dry-run: report drift on every plane
network-manager reconcile --apply          # converge every plane
network-manager reconcile --only switch    # one plane only
network-manager reconcile --apply --only proxmox
```

`--only <plane>` is one of `opnsense | proxmox | switch | ap`. Default is a
non-mutating dry-run. Exit `0` = in sync, `2` = drift reported (dry-run, not a
failure), `1` = a hard error (a plane errored, or Proxmox still drifts after
`--apply`).

### `zones-init` — initialise zones.json from a template

Used at install time to stamp a fresh `zones.json` named for the TAPPaaS system:

```bash
network-manager zones-init --name acme
```

- `--name <N>` (required) — system name; renames the template's `srv` → `<N>`,
  `home` → `<N>-private`, `guest` → `<N>-guest`.
- `--from <tpl>` — source template (default: the `zones.json` shipped with the
  bin).
- `--out <file>` — output (default `$TAPPAAS_CONFIG/zones.json`).
- `--force` — re-apply even if already initialised.

Writing to a non-live `--out` automatically skips distribution.

### `zones-check` — offline consistency audit

```bash
network-manager zones-check
network-manager zones-check --strict       # warnings become errors
```

- `--zones <file>` — zones.json to check (default `$TAPPAAS_CONFIG/zones.json`).
- `--config-dir <dir>` — installed module configs dir (default `$TAPPAAS_CONFIG`).
- `--strict` — promote warnings to errors.

Exit `0` ok, `1` on dangling references / missing required fields / lost zones.

### `zones-distribute` — push zones.json to the Proxmox nodes

```bash
network-manager zones-distribute
network-manager zones-distribute --dry-run  # list target nodes, no copy
```

- `--zones <file>` — zones.json to distribute (default `$TAPPAAS_CONFIG/zones.json`).
- `--dry-run` — list the nodes that would receive it; copy nothing.

## Legacy bash tools (still linked, not retired)

`zone-reconcile`, `zone-controller`, and `zone-state.sh` are linked onto `PATH`
during the transition and will be retired once `network-manager` fully replaces
them. `apply-zones-merge.sh` and `migrate-zone-keys-*.sh` are migration helpers,
not on-PATH tools.
