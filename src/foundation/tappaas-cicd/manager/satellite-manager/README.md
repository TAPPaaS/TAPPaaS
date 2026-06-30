# satellite-manager

Operator front door for TAPPaaS **VPS satellites** (ADR-010) — external hosts
(a VPS or any machine with a public IP) that act as a reverse-proxy frontend,
admin VPN, and/or off-site backup target for a cluster with no public IP.

> **Status:** P1 scaffold. The verb surface is wired and `validate` works; the
> orchestration verbs (`install`/`update`/`status`/`remove`) report
> not-implemented and land in packages P2–P6. See
> [ADR-010-implementation.md](../../../../../docs/design/ADR-010-implementation.md).

## Role

A **manager** (owns config state — here, `~/config/satellite-<name>.json`). Unlike
other managers it provisions an *external* host (via `nixos-anywhere`) rather than a
Proxmox VM, and is **operator-driven** (the satellite is optional — see
[satellite/INSTALL.md](../../../satellite/INSTALL.md)), not part of the mandatory
install chain.

## Verbs

| Verb | Status | Does (target) |
| ---- | ------ | ------------- |
| `install <name>` | P2–P6 | provision + wire (nixos-anywhere, WireGuard, zones+fw, DNS, per-role) |
| `update <name>` | P3 | pull-based config update (cluster never pushes) |
| `status <name>` | P2–P6 | tunnel / role / backup-sync health |
| `remove <name>` | P3 | decommission (tunnel/zone/DNS/secrets) |
| `validate <name>` | ✅ P1 | validate `satellite-<name>.json` |

## Files

`satellite-manager.sh` (entry → `~/bin/satellite-manager`), plus the component
contract: `install.sh`/`update.sh` (link the bin), `test.sh` (fast tests),
`validate.sh` (validate all `satellite-*.json`).
