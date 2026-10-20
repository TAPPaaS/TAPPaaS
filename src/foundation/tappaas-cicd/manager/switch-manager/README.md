# switch-manager

The **physical-switch network controller** for TAPPaaS. It reconciles managed
switches to `zones.json` (the single source of truth) so that every active
zone's VLAN is tagged on every node-uplink trunk port — without hand-editing
switch configs.

The controller maintains two state files (in the config directory):

- `switch-configuration-actual.json` — the inventory you register (controllers,
  switches, the ports and what each connects to) plus the VLAN config currently
  present on the hardware once applied.
- `switch-configuration-desired.json` — regenerated from `actual`'s topology
  plus the active VLAN set; never hand-edited.

`managed:auto` switches are programmed through their **vendor plugin**;
`managed:manual` switches print the VLANs you should tag and you apply them by
hand, then record the result with `confirm`.

## CLI: `switch-manager`

A compatibility alias `switch-manager` points at the same binary.

```
switch-manager <command> [args]
```

### Inventory commands (edit `actual.json`)

| Command | Purpose |
|---------|---------|
| `add-controller <name> --vendor <v> --ip <ip> [--managed auto]` | Register a controller (e.g. a UniFi controller). |
| `remove-controller <name>` | Remove a controller. |
| `add-switch <name> --vendor <v> --managed auto\|manual [--controller <c>] [--ip <ip>] [--model <m>] [--location <l>] [--description <d>]` | Register a switch. |
| `remove-switch <name>` | Remove a switch. |
| `add-port <switch> <port> --type node\|switch\|ap\|device\|uplink [--target <t>] [--target-port <tp>] [--mode trunk\|access] [--zone <z>] [--native <vlan>] [--tagged 210,220] [--description <d>]` | Register a port and what it connects to. |
| `update-port <switch> <port> [ ...same flags... ]` | Change a port's settings. Giving a parked port a `--type` takes it into use (`add-port` may too). |
| `update-port <switch> <port> --park [--park-zone <zone>]` | Park the port: set it **on the switch, at once and alone**, as an access port in iotLocal, then record it parked. |
| `remove-port <switch> <port> [--park-zone <zone>]` | Give the port back: the same as `--park` — the switch first, then the record becomes a parked one. |
| `lag set <switch> <name> --ports <p,p> [--apply]` | Make registered ports one LACP aggregate (LAG). The lowest-numbered port leads it. `--apply` programs that switch at once; otherwise the next `reconcile --apply` does. |
| `lag remove <switch> <name> [--apply]` | Take the aggregate apart again. |
| `lag list [<switch>] [--json]` | The declared aggregates, and whether the switch has formed them. |
| `list [--json]` | List controllers and switches. |
| `list-ports [<switch>] [--json]` | One line per port: actual config and drift vs `zones.json`; `--json` adds what `zones.json` wants on it (`desired`), `drift` (`in-sync`, `drift`, `unmanaged`), `parked`, `link`, `disabled` and `lagLead`. |
| `show <controller\|switch>` | Show one inventory entry. |

**A member follows its lead.** The switch takes an aggregate's VLANs from its
lead port, the lowest-numbered member, and ignores the other members' own port
config while the aggregate stands. Every other member is recorded with
`lagLead: <lead>` (by `lag set`/`lag remove` and at each `interrogate`):
`list-ports` shows it as "follows port <lead>" with the lead's VLANs and no
drift of its own, `delta` has nothing for it, and nothing is pushed to it. The
VLANs the switch reports on the member itself stay in `actual.json` as read.

An aggregate spans ports of **one** switch. Across two switches it needs MC-LAG
(both switches of one vendor that supports it), which is not modelled. A
node's bonded LAN uplink in `lacp` mode drives this itself: `site-manager node
network set <node> --lan-mode lacp --apply` forms the aggregate named
`<node>-lan` once the node speaks LACP, and takes it apart before the node
leaves `lacp`. On a manually managed switch the step is printed instead.

Port types `node`, `switch`, `ap` and `uplink` are treated as **VLAN trunks**
and carry the full active VLAN set; `device` ports are access ports.

### Parked ports (#853)

A port TAPPaaS does not use is **parked**: an access port in the `iotLocal`
zone (tier 6, no internet, nothing else reachable). A device plugged into it
gets an address, so the port is seen to work, and can do no harm. Its record is
`{parked: true, zone: "iotLocal"}` — not a device record — and `update-desired`,
`delta` and `apply` keep it set like any other port.

- `interrogate` records as parked every port of a switch it read that has **no
  record and no link** (the UniFi plugin reports the link). A port with no
  record but a link is left as the switch has it and named: on a fresh
  registration the node uplinks are such ports, and parking them would cut the
  nodes off. A disabled port and a port inside an aggregate are left too.
  `health-manager validate` (`switch-ports`) warns about every port left so.
- `interrogate --no-park` reads and records, and parks nothing — the read after every
  sweep (`tappaas-switch-read`, #860). Every read stamps the switch with `lastRead`,
  which `list-ports --json` carries and the `switch-ports` gate turns into its age.
- `update-port <switch> <port> --park` and `remove-port` park a port on the
  switch first — only that port is pushed, nothing else pending — and change
  its record only once the switch has it. On a manually managed switch the
  step is printed, the record becomes parked and the drift shows until
  `confirm <switch>`.
- The park zone is resolved by name from `zones.json`: `iotLocal`, or
  `--park-zone <zone>` (on `interrogate`, `reconcile`, `update-port --park`,
  `remove-port`). A site without it gets a clear refusal: nothing is parked,
  `interrogate` exits 1, and `reconcile` still converges everything else.
- **The controller's own default profile is never restored.** On UniFi that is
  "All": a trunk of every network with the default network untagged, so
  anything plugged in reaches every VLAN — the exposure parking removes. What
  "default" means also differs per vendor and is no state `zones.json` can
  name. A port given back is parked, a known and harmless state.

### Reconciliation commands (five-verb provider flow, run in this order)

| Command | Purpose |
|---------|---------|
| `interrogate [--park-zone <zone>] [--no-park]` | Pull live config from controller/auto switches into `actual.json` (via the vendor plugin), stamp each switch read with `lastRead`, and record a port with no record and no link as parked (`--no-park`: read only, as after a sweep). A controller or switch that cannot be read is left unchanged, the plugin's reason is shown, and the command exits 1. |
| `update-desired` | Compute `desired.json` from the actual topology + `zones.json`. |
| `delta` | Show the desired-vs-actual VLAN differences per port. |
| `apply` | Push the delta via the vendor plugin; the manual plugin prints the steps to apply by hand. |
| `confirm` | Record the applied VLAN config back into `actual.json`. |
| `reconcile [--apply]` | Run all five in order. Without `--apply` it stops at `delta` (dry-run); with `--apply` it pushes and confirms. If any device could not be read, the delta is shown but **nothing is applied** (exit 1). |

### Examples

```bash
# Register a manually-managed switch and its uplink to a node:
switch-manager add-switch core --vendor netgear --managed manual
switch-manager add-port core 1 --type node --target tappaas1 --target-port eth0

# See what would change, change nothing:
switch-manager reconcile

# Apply (auto switches programmed via plugin; manual switches print steps):
switch-manager reconcile --apply
```

## Setup helper: `setup-switches.sh`

Interactive registration walk-through, normally run at the end of the platform
install but re-runnable any time. It discovers available switch brands from the
plugin library, asks how each brand should be managed, and registers
switches/controllers and node-uplink ports into `switch-configuration-actual.json`.

```
setup-switches.sh                    # interactive
setup-switches.sh --non-interactive  # refuse to prompt (CI / bootstrap default)
setup-switches.sh --help
```

Management modes offered depend on the brand's plugin architecture:

- brand with no plugin ("Other") → manual only;
- controller-arch brand (e.g. UniFi) → manual, use an existing controller, or
  install a controller;
- device-arch brand → manual or register each switch by IP.

This step is switch-only; WiFi SSID↔VLAN setup is handled by the
[`ap-manager`](../ap-manager/) and its `setup-wlan-secrets.sh`.
