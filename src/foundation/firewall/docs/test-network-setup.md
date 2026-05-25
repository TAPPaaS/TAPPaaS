# Test Network — Setup & Teardown

A *test network* is a throwaway, isolated network served on a **spare physical
NIC** of the node running the firewall VM — separate from the VLAN trunk that
carries the production zones. Plug a switch or AP into the chosen port and you
get an isolated, internet-connected sandbox without touching `zones.json` or
the trunk. Implements issue #225.

Default network: **172.17.3.0/24**, gateway **172.17.3.1**, DHCP pool
**.50–.250**.

## Routing policy

| From → To | Allowed? | Notes |
|-----------|----------|-------|
| test → internet | ✅ | OPNsense automatic outbound NAT covers `172.16/12` |
| test → internal (incl. mgmt `10.0.0.0/24`) | ❌ | isolation — RFC1918 blocked |
| mgmt → test | ✅ | you can reach test boxes from mgmt |
| test → mgmt | ❌ | stateful return traffic only; test cannot initiate to mgmt |

## Prerequisites

1. **A spare physical port** on the node hosting the firewall VM. The script
   only offers ports that are physical, not enslaved to a bridge/bond, without
   an IP, and not carrying the default route.
2. **The `test-network-manager` CLI must be on `PATH`.** It is a console-script
   entry point in the `opnsense-controller` package, so it appears only after
   that package has been **rebuilt and deployed**:
   ```bash
   update-tappaas            # or: nixos-rebuild switch on tappaas-cicd
   command -v test-network-manager   # verify it resolves
   ```
   Without it, `test-network.sh` exits with a message telling you to rebuild.
3. Run from `tappaas-cicd` (or the repo checkout) as the `tappaas` user — the
   script SSHes to the node and the firewall using the standard keys.

## Setup

Interactive (prompts you to pick a vacant port):
```bash
test-network.sh
```

Non-interactive (name the port up front):
```bash
test-network.sh --port nic2
```

Dry run — show every planned change without making any:
```bash
test-network.sh --check-mode
```

What it does, in order:

1. Finds the node hosting the firewall VM (via `pvesh`).
2. Discovers vacant physical ports and prompts for one (or takes `--port`).
3. Creates a Linux bridge on the node and enslaves the port — persisted in
   `/etc/network/interfaces` (backed up first) and applied with `ifreload`.
4. Attaches the bridge to the firewall VM as a new virtio NIC (`qm set --netN`),
   which appears in OPNsense as `vtnetN`.
5. Assigns the OPNsense interface (static gateway IP), enables DHCP, and installs
   the firewall rules above.
6. Reloads the OPNsense filter so DHCP works immediately on the new interface.

### Options

| Flag | Meaning |
|------|---------|
| `--port PORT` | Physical NIC to use (e.g. `nic2`). Prompted if omitted. |
| `--bridge NAME` | Bridge name on the node (default: `testbr`). |
| `--subnet CIDR` | Test-net gateway + prefix (default: `172.17.3.1/24`). |
| `--vmid ID` | Firewall VM id (default: read from `firewall.json`). |
| `--check-mode` | Dry run — report planned changes, make none. |
| `--yes`, `-y` | Skip confirmation prompts. |
| `--status` | Show current state and exit. |
| `--delete` | Tear the test network down (see below). |
| `--debug` | Verbose logging. |
| `-h`, `--help` | Usage. |

> **Multiple test networks:** give each its own `--bridge`, `--subnet`, and a
> different `--port`. Always pass the matching `--bridge` to `--status` /
> `--delete`.

## Verify

```bash
test-network.sh --status
```
Shows the attached NIC and the OPNsense interface, DHCP, and rules. Expected on
a healthy setup: an `optN` interface, `dhcp_range: True`, and six
`test-net: …` rules. Then plug a client into the chosen port — it should get a
`172.17.3.x` lease and reach the internet but not the mgmt network.

## Teardown

Reverses every step in order (rules → DHCP → interface → VM NIC → node bridge),
leaving the physical port free:

```bash
test-network.sh --delete                    # default bridge 'testbr'
test-network.sh --delete --bridge testbr2   # a non-default bridge
```

All OPNsense artefacts carry a `test-net` description, so teardown removes
exactly what setup created. Safe to re-run; `--delete` is idempotent.

> Teardown also needs `test-network-manager` on `PATH` (see prerequisite 2).
> Tear a test network down **before** undeploying the controller package, or
> you will have to rebuild it again to clean up.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `test-network-manager not found … Rebuild the opnsense-controller package` | The package isn't deployed yet — run `update-tappaas` / `nixos-rebuild switch`. |
| `No vacant physical ports found` | Every physical NIC is already in a bridge/bond, has an IP, or is the default route. Free a port or add a NIC. |
| `Port … is already enslaved / has an IPv4 address / carries the default route — refusing` | You named an in-use port. Pick a genuinely spare one (`--status` of the node, or run without `--port` to see the vacant list). |
| `Create failed partway through …` | A step failed after the bridge/NIC were made. Run the printed `test-network.sh --delete --bridge <name>` to clean up, then retry. |
| Client gets no DHCP lease | Confirm the switch/AP is on the right port; check `test-network.sh --status` shows `dhcp_range: True`; the setup already runs `configctl filter reload`, but a manual `ssh root@firewall.mgmt.internal configctl filter reload` won't hurt. |

## Related

- [`../test-network.sh`](../test-network.sh) — the orchestrator
- [`../README.md`](../README.md) — firewall module overview (test-network section)
- `opnsense-controller` → `test_network_manager.py` / `test_network_cli.py` — OPNsense side
