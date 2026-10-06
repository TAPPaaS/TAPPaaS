# logging:logs service

A module's systemd journal in the site's Loki, searchable in Grafana and seen by the
alert rules (#770).

## What a consumer gets

- **A journal client.** While the consumer declares `logging:logs` and logging is
  deployed, `update-os.sh` writes `/etc/nixos/tappaas-logging.nix` on the VM; the NixOS
  baseline imports it. It is an Alloy pipeline (`lib/log-shipping.sh`) that drops units
  handling secrets, scrubs secret-looking values, labels each line `host` (the vmname),
  `zone`, `unit`, `severity`, and pushes to `logging.mgmt.internal:3101`.
- **A push credential of its own** (#165 §1): username = its vmname, kept on the mothership
  (`~tappaas/.loki-push/<host>`), written to the VM as `/etc/secrets/tappaas-logging-push`,
  and added to logging's nginx password file by this service. Logging sets each line's
  `host` from it, so the consumer writes as itself only.
- **Network access**: `pinhole.json` opens TCP 3101 from the consumer's VM to logging —
  push only. Loki's API on 3100 stays mgmt-only and wants the admin credential. logging sits in mgmt, which no zone may otherwise
  pinhole into: `"fromZones": "any"` is the exception, honoured for foundation providers
  only, and still per consumer VM and to this port alone.
- **Delete** reconciles the consumer's rules (the pinhole goes); its next OS update
  removes the fragment.

## How to use it

```json
"integratesWith": ["logging:logs"]
```

`integratesWith`, not `dependsOn`: a site without logging installs the module anyway, and
it starts shipping at its first update after logging arrives. A consumer outside mgmt also
needs `network:rules` in `dependsOn` to carry the pinhole.

## Fields

| Field | Type | Meaning |
|---|---|---|
| `config."logging:logs".dropUnits` | list of unit patterns | Units whose lines never leave the VM, on top of `generate-.*-secrets.*` — e.g. the units that read or write the module's own secrets |

NixOS guests only. Debian (netbird-client), HAOS, LXC and Windows guests are not covered
yet.
