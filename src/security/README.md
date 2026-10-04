# Security stack

Security services for the people of your organisation: a password vault, and a NetBird client
for the overlay network. On the website: [Security Stack](https://tappaas.org/stacks/security/).

These are modules whose *purpose* is security. They are not the whole of TAPPaaS's security
posture — that is built into the platform rather than added on: identity and single sign-on
come from the [foundation](../foundation/README.md), network separation from the zone model
(see [Network Zones](../foundation/tappaas-cicd/manager/network-manager/ZONES.md)), and
off-site, encrypted backup from [backup](../foundation/backup/README.md). A stack groups
modules by what they are *for*; it does not say where the security lives.

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [netbird-client](netbird-client/README.md) | TAPPaaS NetBird Client for accessing private zone (so you can operate as if you are local to TAPPaaS) | Development |
| [vaultwarden](vaultwarden/README.md) | VaultWarden password manager (Bitwarden-compatible) in DMZ | Development |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
