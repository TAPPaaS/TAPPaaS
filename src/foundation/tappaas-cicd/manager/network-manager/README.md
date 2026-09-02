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

## Changing a zone's policy — `modify --set` (#538)

```
network-manager modify rossen --set access-to=internet,mgmt
network-manager modify rossen --set 'pinhole-allowed-from=["home","work"]'
```

A zone's policy fields — `access-to`, `pinhole-allowed-from`, `description`,
`isolated`, `tier`, the DHCP options — are changed by a verb rather than by
hand-editing `zones.json`, which is the anti-pattern ADR-014 D1 named. Lists
take either the comma form or JSON.

Like `enable`/`disable`/`bind`, this **authors `zones.json` only** and prints the
`reconcile --apply` to run: the operator decides when the firewall changes.

**What it refuses, and why the two refusals read differently** (ADR-020 D6):

| Field | | |
|---|---|---|
| `vlantag`, `ip`, `type`, `typeId`, `subId`, `bridge` | `immutable` | The zone's identity. Changing a VLAN would strand every guest tagged into it — that is delete-and-re-add, with the guests moved deliberately. |
| `state` | has a verb | `enable` / `disable` / `manual`, which guard the Mandatory transition. |
| `serves` | has a verb | `bind --environment`, which resolves the environment first so a typo fails at the command. |

A `--set` naming any of those is refused **before anything is written**, and a
mixed `--set` is rejected whole — `zones.json` and the planes never move apart.
Each field's cost is declared as `changeClass` in `schemas/zones-fields.json`.

## Commands

One compiled CLI, `network-manager`:

```
network-manager list                 [--state S] [--type T] [--tier N] [--json]
network-manager exists <name>
network-manager show <name>         (alias: get)
network-manager add <name>          [options]
network-manager delete <name>       [--check]
network-manager enable|disable|manual <name> [--force]
network-manager bind <zone>         --environment <env> | --unbind
network-manager reconcile           [--apply] [--only <plane>]
network-manager init  [<profile>] --name <N> [--from <tpl>] [--out <f>] [--force]
network-manager retire      [--apply]
network-manager validate    [--zones <file>] [--config-dir <dir>] [--strict]
                            [--effective]
network-manager merge       [--diff] [--config-dir <dir>] [--template <tpl>]
network-manager distribute  [--zones <file>] [--dry-run]
network-manager -h | --help
```

The `zone` keyword is an optional, legacy prefix — `add` and `zone add` are
equivalent. (`validate` keeps the alias `zones-check`.)

### `list` / `exists` / `show` / `add` / `delete` — CRUD on zones.json

```bash
network-manager list                 # name / state / vlan
network-manager list --state Inactive       # which zones are defined-but-off
network-manager list --type Client          # + tier and serves columns
network-manager list --tier 6               # the no-egress zones
network-manager exists srvHome        # exit 0/1
network-manager show srvHome          # print the zone object (alias: get)
```

`list` filters combine (`--state Active --type Service`); `--json` emits the
matching names as an array. `--type Client|IoT|Guest` (and any `--tier` query)
adds `tier`, `serves` and `isolated` columns — which is how you answer "which
client zones exist, and which environment does each belong to?" (ADR-014 D4).

`add <name>` authors a new zone **and reconciles all four planes** (so the
VLAN reaches everything). Options:

- `--archetype <A>` — **the preferred way to create a zone** (ADR-014 D5).
  Stamps a tier-correct `type`/`typeId`/`tier`/`isolated` and the `access-to`
  seed, then auto-allocates the VLAN/IP — no hand editing, and the result passes
  `validate` unmodified. One of: `control`, `service`, `trusted-client`,
  `guest`, `dmz`, `iot-local`, `iot-cloud`, `iot-cams`, `iot-untrust`.
  Cannot be combined with `--type`/`--typeId`/`--from-zone` (the archetype
  already defines them); the combination is refused rather than resolved.
- `--serves <env>` — bind a new Client/IoT/Guest zone to an environment in the
  same command (see `bind` below). Requires `--archetype`.
- `--from-zone <src>` — inherit type/typeId/bridge/access-to/pinhole from `<src>`.
- `--type <T>` — zone type (default `Service`).
- `--typeId <N>` — numeric type band (default `2`).
- `--vlan <tag>` — explicit VLAN tag (else auto-allocated 60–99 in the band).
- `--variant <name>` — tag the zone with this variant (metadata).
- `--no-activate` — author `zones.json` only; skip the all-plane reconcile.
- `--check` — dry-run: show what would change, mutate nothing.

`delete <name>` disables the zone, reconciles all planes, then removes the
key. `--check` dry-runs it.

A zone authored the low-level way (`--type`/`--from-zone`) is deliberately left
**untiered** — `validate` notes it — rather than being given a guessed rank.

```bash
network-manager add cams   --archetype iot-cams --serves warmelo
network-manager add lab    --archetype service
network-manager add labNet --from-zone srvHome --vlan 275   # low-level escape
network-manager add labNet --check          # preview
network-manager delete labNet
```

### `bind` — link a client or IoT zone to an environment (ADR-014 D2, #424)

A client zone reaches its services, and an IoT zone is reached by them. Writing
that as a **literal** service-zone name does not survive install: `init` renames
`srv` → `<defaultEnvironment>`, and the literal is stranded. `bind` records the
**environment** instead, and the edge is derived from that environment's current
zone on every reconcile.

```bash
network-manager bind home    --environment warmelo   # sets serves: warmelo
network-manager bind iotCams --environment warmelo
network-manager bind iotCams --unbind                # clears it
```

Only Client, IoT and Guest zones may carry `serves` — a Service zone *is* an
environment's zone. `bind` refuses an unknown environment up front and prints
the edge the link derives. Like `enable`/`disable` it does not reconcile; apply
with `network-manager reconcile --apply`.

### Authored vs. effective — `zones.json` and `zones.effective.json`

`zones.json` is **authored** state: what the operator wrote. Derived `serves`
edges are never written back into it — if they were, the 3-way merge would treat
them as operator edits and pin them, so clearing a link would strand its edges.

Instead, every authored write (and the start of every `reconcile`) renders
**`zones.effective.json`** beside it, and that is what the consumers read:
`zone-manager` (the OPNsense plane), `rules_manager` (per-module pinhole/egress
validation) and the Caddy access lists. It is generated — never hand-edit it.
`distribute` still pushes the authored file, since the nodes need only
`vlantag`/`ip`.

An unresolvable `serves` link is **non-fatal** on a zone add (a missing
environment file must not block authoring) but **fatal** to `reconcile` and an
**error** in `validate`.

### `enable` / `disable` / `manual` — atomic zone state change

The operator state verbs (was `zone-state.sh`, #209): `enable` → `Active`,
`disable` → `Inactive`, `manual` → `Manual`. They mutate `zones.json`
atomically and deliberately do **not** touch the planes — apply when ready with
`network-manager reconcile --apply`. Guards: an unknown zone is refused (the
known zones are listed), a same-state verb is a no-op (exit 0), and leaving the
`Mandatory` state (e.g. `dmz`) is refused without `--force`. `Mandatory` and
`Disabled` are intentionally not exposed as verbs (`Disabled` is reserved for
the delete lifecycle).

```bash
network-manager enable srvTest
network-manager disable srvTest
network-manager disable dmz --force   # Mandatory zones refused otherwise
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

### `init [<profile>]` (alias `zones-init`) — composable install profiles

`init` applies an **additive, idempotent profile bundle** to `zones.json`
(ADR-014 D7). It replaces the old single flat transform that shipped ~23 zones
and then inactivated the ones it did not want.

| Profile | Zones |
|---------|-------|
| **`core`** (default) | `mgmt` · `wan` · `netbird`/`edge`/`admin` overlays · `<N>` (the renamed `srv`, Active) · `home` · `guest` · `dmz` (Mandatory) |
| **`iot`** | `iotLocal` · `iotCloud` · `iotCams` · `iotUntrust` — all Active, each bound to the default environment |

```bash
network-manager init core --name acme     # the minimal coherent install
network-manager init iot  --name acme     # opt in to the IoT segment set
```

Properties, all unit-asserted:

- **Additive** — a profile only ever adds its zones, plus the `access-to`
  entries its zones need on zones from another profile (`init iot` gives the
  service and client zones reach to the devices). It never removes or
  deactivates anything.
- **Idempotent** — re-applying a profile is a byte-level no-op.
- **Order-independent** — `core` then `iot` == `iot` then `core`.
- **Non-destructive (#427)** — existing zones always win. A re-run can never
  rebuild a live file from template defaults; operator zones, custom states and
  edited access lists survive. `--force` re-stamps *this profile's* zones from
  the template.
- **`srv → <N>`** is the only rename, applied to keys, to every zone reference,
  and to the `serves` placeholder. `home`/`guest` keep their names (#425): the
  zone key drives the client DNS domain `<zone>.internal`.

A site with no smart-home devices simply never runs `init iot` and never carries
those zones. Extra service zones, a second client segment and so on come from
`add --archetype` or `environment add --create-zone`, not from dormant template
entries.

### `retire` — remove zones a release stopped shipping

Deleting a zone from the template does **not** remove it from an existing
install: the 3-way merge keeps anything present locally but absent upstream
(which is right — it is what stops a release silently deleting an operator's
zone). `retire` is the explicit, guarded cleanup.

```bash
network-manager retire            # dry-run: what would go, and what is kept
network-manager retire --apply    # commit
```

It considers exactly `srvHome`, `srvWork`, `srvCust`, `srvDev`, `srvTest`,
`iot`, `test`, `testAllowA`, `testAllowB`, `testPinhole` — an **explicit list,
never "everything Inactive"**. A zone is removed only when it is **both**

- not `Active`/`Mandatory`/`Manual` (it provisions nothing today), **and**
- not named by any installed module's `zone`/`zone0`.

Anything else is kept and reported with the reason. References to a retired zone
are stripped from every other zone's `access-to`/`pinhole-allowed-from`.
`srv` (the rename source) and `work` (a legitimate client zone that is merely
switched off) are **never** retired.

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

### `validate --effective` — audit the graph the planes actually receive

`validate` audits the **authored** `zones.json` by default. A `serves` link
contributes an edge that exists only in the rendered document, so an
authored-scope run cannot judge it — and says so in its output. Add
`--effective` to render the links and check the real graph:

```bash
network-manager validate               # authored: authoring mistakes
network-manager validate --effective   # rendered: what zone-manager receives
```

This matters for the tier checks: a client zone's edge to its service zone lives
only in the render, so `--effective` is where I1 can see it.

### `distribute` (alias `zones-distribute`) — push zones.json to the Proxmox nodes

`zones-distribute` is kept as an alias.

```bash
network-manager distribute
network-manager distribute --dry-run  # list target nodes, no copy
```

- `--zones <file>` — zones.json to distribute (default `$TAPPAAS_CONFIG/zones.json`).
- `--dry-run` — list the nodes that would receive it; copy nothing.

## Legacy bash tools

Only `zone-reconcile` is still linked onto `PATH` during the transition.
`migrate-zone-keys-*.sh` is a one-shot migration helper, not an on-PATH tool.
**Retired** (ADR-007 Phase 7.5 / post-implementation refactor):
`apply-zones-merge.sh` → `network-manager merge` (alias `zones-merge`, ADR-007
"Design A"); `zone-controller.sh` → `network-manager add`/`delete` (the TS zone
lifecycle); `zone-state.sh` → `network-manager enable`/`disable`/`manual`.
