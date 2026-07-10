# NetBird Client

Primary audience: business or home users who want a VPN connection into their
TAPPaaS installation.

VPN entry point — a NetBird peer inside a TAPPaaS zone, so remote devices can
operate as if they were local to that zone.

> Status: not currently working. The module still needs conversion to NixOS
> and to the new install system — see [DESIGN.md](./DESIGN.md).

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| VPN access into a TAPPaaS zone | Your remote NetBird peers | NetBird overlay; VM in zone `home` |
| Clients in several zones | — | Multiple instances, one json per zone |

## What is not included

- TAPPaaS management access — that is handled by the separate NetBird client
  installed by default on the `mgmt` network; this module is for end-user
  access only
- A NetBird management server — you need your own NetBird account and
  dashboard to create setup keys and manage peers

## Requirements

- A NetBird account with dashboard access (to create a setup key)
- Debian VM template (`templates:debian`)
- `home` zone by default (override `zone0` for other zones)
- 1 vCPU, 1 GB RAM, 4 GB disk by default

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `cluster:ha` | High availability for the VM |
| `templates:debian` | Debian cloud image base |
| `backup:vm` | VM backups |
| `identity:identity` | Secrets and identity management |
| `network:proxy` | Proxy configuration (allowed from `internet`) |

For installation steps see [INSTALL.md](./INSTALL.md).
