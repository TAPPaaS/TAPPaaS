# logging:logs service

A module's systemd journal in the site's Loki, searchable in Grafana and seen by the
alert rules (#770).

## What a consumer gets

- **A journal client.** While the consumer declares `logging:logs` and logging is
  deployed, the guest runs Alloy with one pipeline (`lib/log-shipping.sh`) that drops
  units handling secrets, scrubs secret-looking values, labels each line `host` (the
  vmname), `zone`, `unit`, `severity`, and pushes to `logging.mgmt.internal:3101`. A
  heartbeat line every 5 minutes keeps a quiet guest from reading as silent.
  - **NixOS VM:** `update-os.sh` writes `/etc/nixos/tappaas-logging.nix`; the NixOS
    baseline imports it.
  - **Debian VM or container (`kind: lxc`):** this service installs Alloy from Grafana's
    Debian repository at a pinned version (the signing key is pinned in the library),
    writes `/etc/alloy/config.alloy`, the push secret and the heartbeat timer, on every
    install and update. A Debian VM is reached over SSH, a container through `pct exec`
    on its node, so it needs no SSH of its own. The guest needs outbound HTTPS to
    `apt.grafana.com` the first time.
- **A push credential of its own** (#165 §1): username = its vmname, kept on the mothership
  (`~tappaas/.loki-push/<host>`), written to the VM as `/etc/secrets/tappaas-logging-push`,
  and added to logging's nginx password file by this service. Logging sets each line's
  `host` from it, so the consumer writes as itself only.
- **Network access**: `pinhole.json` opens TCP 3101 from the consumer's VM to logging —
  push only. Loki's API on 3100 stays mgmt-only and wants the admin credential. logging sits in mgmt, which no zone may otherwise
  pinhole into: `"fromZones": "any"` is the exception, honoured for foundation providers
  only, and still per consumer VM and to this port alone.
- **Delete** reconciles the consumer's rules (the pinhole goes) and removes the push
  credential. A Debian VM's or container's Alloy is removed at once; a NixOS guest's
  fragment goes with its next OS update.

## Alert rules

A module that declares `logging:logs` can ship its own alert rules in `<module>-alerts.json`:
which log lines matter, a window, and how the mail reads. The format, with examples, is in the
module template's *Develop a Module* guide, section *Alert rules for your module*.
`health-manager alerts` lists what is open and what fired in the last day.

## How to use it

```json
"integratesWith": ["logging:logs"]
```

`integratesWith`, not `dependsOn`: a site without logging installs the module anyway, and
it starts shipping at its first update after logging arrives. A consumer outside mgmt also
needs `network:rules` in `dependsOn` to carry the pinhole.

NixOS VMs, Debian VMs and Debian/Ubuntu containers ship their journal. The firewall
(`network`) and the nodes (`pvehost` instances) declare `logging:logs` too and ship by
syslog: this service sets OPNsense's remote destination (:1514) or a node's rsyslog
forwarder (:1515), and removes it on delete; they need no push credential. Every
instance that declares `logging:logs` is what a "scope: all" alert rule, such as
HostSilent, watches (ADR-039). HAOS and Windows guests are not covered.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`logging:logs` owns **2** declared field(s). Each table below carries the field's full definition and, where the service applies it, what a change to it does (in place, a restart, a rebuild).

### `dropUnits`

Units whose journal lines never leave the VM, on top of the platform's generate-.*-secrets.* — the units that read or write the module's own secrets. Unit-name patterns (regex): letters, digits, _ . * @ - only.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Required by | *(none)* |
| Used by | `logging:logs` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** The journal client is rewritten whole by update-os.sh on every OS update (/etc/nixos/tappaas-logging.nix) and applied by that rebuild; alloy reloads its config in place. No downtime for the module.

### `securityPaths`

Files or directories of the module whose changes are recorded as security events while the site's security monitoring is on (ADR-050): its own configuration or state that nothing but TAPPaaS should change. Absolute paths of plain characters; a path the guest does not have is left out. Beside the platform's own (/etc/secrets, /root/.ssh, /etc/ssh).

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Required by | *(none)* |
| Used by | `logging:logs` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** Written into the journal client's fragment (/etc/nixos/tappaas-logging.nix) at the next OS update and applied by its rebuild. NixOS guests only.

<!-- END GENERATED FIELDS -->
