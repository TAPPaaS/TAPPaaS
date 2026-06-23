# network:nat service

Provides destination-NAT (port-forward) rules on OPNsense so a module can
expose an internal service port on the firewall's WAN interface.

This is the foundation service behind issue #285: when a module needs a raw TCP
or UDP port reachable from the internet (e.g. SSH, not HTTP), it depends on
`network:nat` and declares the port mappings. The reverse-proxy service
(`network:proxy`) remains the right choice for HTTP(S) — use `network:nat`
only for non-HTTP ports.

Each rule is created as an **rdr-pass** rule on OPNsense (the port-forward's
"Filter rule association: Pass"): OPNsense translates the destination *and*
passes the traffic in a single atomic rule, so no separate WAN filter rule is
needed.

## How a module uses it

Add `network:nat` to `dependsOn` and declare the mappings under the
`network:nat` config block:

```jsonc
{
  "vmname": "forgejo",
  "zone0": "srvWork",
  "dependsOn": [
    "cluster:vm",
    "network:rules",
    "network:dns",
    "network:proxy",   // web UI at https://forgejo.<domain>
    "network:nat"      // raw SSH on the WAN IP
  ],
  "config": {
    "network:nat": {
      "natRules": [
        { "externalPort": 2022, "internalPort": 22, "protocol": "TCP",
          "description": "SSH" }
      ]
    }
  }
}
```

With the above, connecting to `mydomain.org:2022` over SSH is forwarded to the
forgejo VM's port 22.

### `natRules` fields

| Field          | Required | Default         | Description                                            |
|----------------|----------|-----------------|--------------------------------------------------------|
| `externalPort` | yes      | —               | Port exposed on the firewall WAN interface             |
| `internalPort` | no       | `externalPort`  | Service port on the target host                        |
| `protocol`     | no       | `TCP`           | `TCP`, `UDP`, or `TCP/UDP`                              |
| `description`  | no       | `<proto> <ext>` | Human label; combined with the module name for identity|

### Target resolution

All rules for a module forward to one internal target, resolved in order:

1. the module's `ip` field (a static reservation), otherwise
2. DNS lookup of `<vmname>.<zone0>.internal`.

If neither resolves, install fails with a clear error.

## Lifecycle

| Script               | Behaviour                                                                 |
|----------------------|--------------------------------------------------------------------------|
| `install-service.sh` | Creates a port-forward per `natRules` entry, applies once.               |
| `update-service.sh`  | Clean sweep: removes all `TAPPaaS: <module>` rules, recreates from config.|
| `delete-service.sh`  | Removes all `TAPPaaS: <module>` port-forwards.                            |
| `test-service.sh`    | Verifies each configured rule exists (deep mode also checks ports).       |

Rules are identified by a `TAPPaaS: <module> ...` description, so operations are
idempotent and cleanup is reliable even after the config changes.

When `firewallType` is `NONE` (no OPNsense deployed), every script prints the
rules to configure manually and exits successfully.

## Implementation

The scripts drive the `nat-manager` CLI (from the `opnsense-controller`
package), which wraps the OPNsense `firewall/d_nat` API via the
oxl-opnsense-client `raw` module. See
`src/foundation/tappaas-cicd/opnsense-controller/src/opnsense_controller/nat_manager.py`.
