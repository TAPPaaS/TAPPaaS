# TAPPaaS source

Source tree for TAPPaaS. To install, follow the [install overview](../INSTALL.md).

## Layout

| Path | Contents |
|------|----------|
| [foundation/](foundation/README.md) | Foundational infrastructure modules (cluster, network, templates, tappaas-cicd, backup, identity, logging, satellite). |
| [ai/](ai/README.md) · [collaboration/](collaboration/README.md) · [devops/](devops/README.md) · [home/](home/README.md) · [security/](security/README.md) | The modules of each purpose stack — one directory per stack, each with a README listing its modules in install order (#421). |
| [misc/](misc/README.md) | Modules with no natural stack yet, and `00-Template`, the skeleton for a new module. |
| [module-catalog.json](module-catalog.json) | Generated catalog of all modules and their IDs. |
| [module-dependencies.md](module-dependencies.md) | Generated Mermaid graph of module dependencies. |
| [STATISTICS.md](STATISTICS.md) | Generated code and documentation statistics. |
| [generate-module-dependencies.sh](generate-module-dependencies.sh) | Regenerates `module-dependencies.md`. |
