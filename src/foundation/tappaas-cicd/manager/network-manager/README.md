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
network-manager list
network-manager exists <name>
network-manager show <name>         (alias: get)
network-manager add <name>          [options]
network-manager delete <name>       [--check]
network-manager reconcile           [--apply] [--only <plane>]
network-manager init        --name <N> [--from <tpl>] [--out <file>] [--force]
network-manager validate    [--zones <file>] [--config-dir <dir>] [--strict]
network-manager merge       [--diff] [--config-dir <dir>] [--template <tpl>]
network-manager distribute  [--zones <file>] [--dry-run]
network-manager -h | --help
```

The `zone` keyword is an optional, legacy prefix — `add` and `zone add` are
equivalent. (`validate` keeps the alias `zones-check`.)

### `list` / `exists` / `show` / `add` / `delete` — CRUD on zones.json

```bash
network-manager list                 # list zone names
network-manager exists srvHome        # exit 0/1
network-manager show srvHome          # print the zone object (alias: get)
```

`add <name>` authors a new zone **and reconciles all four planes** (so the
VLAN reaches everything). Options:

- `--from-zone <src>` — inherit type/typeId/bridge/access-to/pinhole from `<src>`.
- `--type <T>` — zone type (default `Service`).
- `--typeId <N>` — numeric type band (default `2`).
- `--vlan <tag>` — explicit VLAN tag (else auto-allocated 60–99 in the band).
- `--variant <name>` — tag the zone with this variant (metadata).
- `--no-activate` — author `zones.json` only; skip the all-plane reconcile.
- `--check` — dry-run: show what would change, mutate nothing.

`delete <name>` disables the zone, reconciles all planes, then removes the
key. `--check` dry-runs it.

```bash
network-manager add labNet --from-zone srvHome --vlan 275
network-manager add labNet --check          # preview
network-manager delete labNet
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

### `init` (alias `zones-init`) — initialise zones.json from a template

Used at install time to stamp a fresh `zones.json` named for the TAPPaaS system.
`zones-init` is kept as an alias.

```bash
network-manager init --name acme
```

- `--name <N>` (required) — system name; renames the template's `srv` → `<N>`,
  `home` → `<N>-private`, `guest` → `<N>-guest`.
- `--from <tpl>` — source template (default: the `zones.json` shipped with the
  bin).
- `--out <file>` — output (default `$TAPPAAS_CONFIG/zones.json`).
- `--force` — re-apply even if already initialised.

Writing to a non-live `--out` automatically skips distribution.

### `validate` (alias `zones-check`) — offline consistency audit

`validate` is the standardized verb (ADR-007 #4); `zones-check` is kept as an
alias. Both run the same read-only zones.json audit.

```bash
network-manager validate                   # = zones-check
network-manager zones-check
network-manager validate --strict          # warnings become errors
```

- `--zones <file>` — zones.json to check (default `$TAPPAAS_CONFIG/zones.json`).
- `--config-dir <dir>` — installed module configs dir (default `$TAPPAAS_CONFIG`).
- `--strict` — promote warnings to errors.

Exit `0` ok, `1` on dangling references / missing required fields / lost zones.

### `distribute` (alias `zones-distribute`) — push zones.json to the Proxmox nodes

`zones-distribute` is kept as an alias.

```bash
network-manager distribute
network-manager distribute --dry-run  # list target nodes, no copy
```

- `--zones <file>` — zones.json to distribute (default `$TAPPAAS_CONFIG/zones.json`).
- `--dry-run` — list the nodes that would receive it; copy nothing.

## Legacy bash tools (still linked, not retired)

`zone-reconcile`, `zone-controller`, and `zone-state.sh` are linked onto `PATH`
during the transition and will be retired once `network-manager` fully replaces
them. `migrate-zone-keys-*.sh` is a one-shot migration helper, not an on-PATH
tool. `apply-zones-merge.sh` has been **retired** — its rename-aware successor is
`network-manager merge` (alias `zones-merge`; see the `merge` subcommand and
ADR-007 "Design A").
