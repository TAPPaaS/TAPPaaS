# DevOps stack

Development and delivery tooling: a self-hosted source forge today, with CI and registries
to follow. The code, the issues and the pipelines of your organisation stay on your own
hardware.

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [forgejo](forgejo/README.md) | Forgejo — self-hosted Git service and DevOps platform (Gitea fork) | Testing |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
