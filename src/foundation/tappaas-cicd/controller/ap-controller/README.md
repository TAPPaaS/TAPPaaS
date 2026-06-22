# ap-controller

The **wireless access-point network controller** for TAPPaaS. It reconciles WiFi
SSID→VLAN mappings to `zones.json` (the single source of truth) so that a zone
declaring an `SSID` is broadcast on the right VLAN without manual AP
configuration.

WiFi networks are declared per **zone** in `zones.json`: the zone's `SSID` field
is the network name and the zone's `vlantag` is the VLAN it maps to. The
controller keeps the access points in sync with those declarations. AP inventory
and SSIDs live under the `accessPoints` key of the same desired/actual state
files the [`switch-controller`](../switch-controller/) uses.

`managed:auto` APs are programmed through a **vendor plugin**; otherwise the
manual plugin prints the steps and you apply them by hand, then `confirm`.

## CLI: `ap-controller`

A compatibility alias `ap-manager` points at the same binary.

```
ap-controller <command> [args]
```

### Inventory commands

| Command | Purpose |
|---------|---------|
| `add <name> --vendor <v> [--ip <ip>] [--model <m>] [--location <l>]` | Register an AP. |
| `remove <name>` | Remove an AP. |
| `list` | List access points. |
| `show <name>` | Show one AP. |
| `link <ap> --switch <switch> --port <port>` | Associate an AP's uplink with a switch port. |

### SSID commands

| Command | Purpose |
|---------|---------|
| `ssid <ap> add <ssid> --zone <zone> --security <sec> [--vlan <n>] [--radius <srv>] [--captive] [--disabled]` | Add an SSID to an AP. The VLAN defaults from the zone if `--vlan` is omitted. |
| `ssid <ap> remove <ssid>` | Remove an SSID from an AP. |
| `ssid <ap> list` | List the AP's SSIDs. |

`--security` is one of: `open`, `wpa2-personal`, `wpa3-personal`,
`wpa2-enterprise`, `wpa3-enterprise`.

### Reconciliation commands (five-verb provider flow)

| Command | Purpose |
|---------|---------|
| `update-desired` | Track each SSID's VLAN from its zone (`zones.json` → desired). |
| `interrogate` | Pull live AP state into `actual.json` (via the vendor plugin). |
| `delta` | Show desired-vs-actual differences plus zone/SSID/uplink validations. |
| `apply` | Push the delta via the vendor plugin; the manual plugin prints the steps. |
| `confirm` | Record the applied state into `actual.json`. |
| `reconcile [--apply]` | Run all five in order; `--apply` pushes and confirms, otherwise it is a dry-run. |

### Examples

```bash
# Register an AP, link its uplink, and add a guest SSID on its zone's VLAN:
ap-controller add ap-living --vendor unifi --ip 10.0.10.21
ap-controller link ap-living --switch core --port 5
ap-controller ssid ap-living add Guest --zone guest --security wpa2-personal

# Dry-run, then apply:
ap-controller reconcile
ap-controller reconcile --apply
```

## Setup helper: `setup-wlan-secrets.sh`

Interactively sets the real SSID **names** in `zones.json` (replacing the
shipped `<PLACEHOLDER>`) and collects each WPA **passphrase** into a separate
`0600` secrets file (`~/.wlan-secrets.txt` by default) that the vendor plugins
read at apply time. The passphrase is never written to `zones.json` (a committed
config). A blank passphrase means "open / leave unchanged".

```
setup-wlan-secrets.sh          # interactively set SSID names + passphrases
setup-wlan-secrets.sh --list   # show zones/SSIDs and whether a secret is set
setup-wlan-secrets.sh --help
```

The per-SSID security level is chosen in the AP inventory
(`ap-controller ssid <ap> add ... --security`); this helper owns only the SSID
name (in `zones.json`) and the passphrase (in the secrets file).
