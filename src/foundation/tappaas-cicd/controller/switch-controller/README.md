# switch-controller

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

## CLI: `switch-controller`

A compatibility alias `switch-manager` points at the same binary.

```
switch-controller <command> [args]
```

### Inventory commands (edit `actual.json`)

| Command | Purpose |
|---------|---------|
| `add-controller <name> --vendor <v> --ip <ip> [--managed auto]` | Register a controller (e.g. a UniFi controller). |
| `remove-controller <name>` | Remove a controller. |
| `add-switch <name> --vendor <v> --managed auto\|manual [--controller <c>] [--ip <ip>] [--model <m>] [--location <l>] [--description <d>]` | Register a switch. |
| `remove-switch <name>` | Remove a switch. |
| `add-port <switch> <port> --type node\|switch\|ap\|device\|uplink [--target <t>] [--target-port <tp>] [--mode trunk\|access] [--zone <z>] [--native <vlan>] [--tagged 210,220] [--description <d>]` | Register a port and what it connects to. |
| `update-port <switch> <port> [ ...same flags... ]` | Change a port's settings. |
| `remove-port <switch> <port>` | Remove a port. |
| `list` | List controllers and switches. |
| `list-ports [<switch>]` | One line per port: actual config and drift vs `zones.json`. |
| `show <controller\|switch>` | Show one inventory entry. |

Port types `node`, `switch`, `ap` and `uplink` are treated as **VLAN trunks**
and carry the full active VLAN set; `device` ports are access ports.

### Reconciliation commands (five-verb provider flow, run in this order)

| Command | Purpose |
|---------|---------|
| `interrogate` | Pull live config from controller/auto switches into `actual.json` (via the vendor plugin). |
| `update-desired` | Compute `desired.json` from the actual topology + `zones.json`. |
| `delta` | Show the desired-vs-actual VLAN differences per port. |
| `apply` | Push the delta via the vendor plugin; the manual plugin prints the steps to apply by hand. |
| `confirm` | Record the applied VLAN config back into `actual.json`. |
| `reconcile [--apply]` | Run all five in order. Without `--apply` it stops at `delta` (dry-run); with `--apply` it pushes and confirms. |

### Examples

```bash
# Register a manually-managed switch and its uplink to a node:
switch-controller add-switch core --vendor netgear --managed manual
switch-controller add-port core 1 --type node --target tappaas1 --target-port eth0

# See what would change, change nothing:
switch-controller reconcile

# Apply (auto switches programmed via plugin; manual switches print steps):
switch-controller reconcile --apply
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
[`ap-controller`](../ap-controller/) and its `setup-wlan-secrets.sh`.
