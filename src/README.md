# TAPPaaS source

Source tree for TAPPaaS. To install, follow the [Installation guide](https://tappaas.org/installation/).

## Layout

| Path | Contents |
|------|----------|
| [foundation/](foundation/README.md) | Foundational infrastructure modules (cluster, network, templates, tappaas-cicd, backup, identity, logging, satellite). |
| [apps/](apps/README.md) | Platform and service modules — each adds a capability to a TAPPaaS installation. |
| [module-catalog.json](module-catalog.json) | Generated catalog of all modules and their IDs. |
| [module-dependencies.md](module-dependencies.md) | Generated Mermaid graph of module dependencies. |
| [STATISTICS.md](STATISTICS.md) | Generated code and documentation statistics. |
| [generate-module-dependencies.sh](generate-module-dependencies.sh) | Regenerates `module-dependencies.md`. |
