# Miscellaneous

Modules with no natural stack yet (`stack: misc`). A stack with a single member is usually
`misc` in disguise, so a module stays here until it has company.

Also here: [00-Template](00-Template/README.md), the skeleton every new module starts from
(`stack: template`) — it is copied, never installed.

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [windows-server](windows-server/README.md) | Barebone Windows Server 2025 VM. No roles or application software — a clean starting point for any Windows-based service. | Development |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
