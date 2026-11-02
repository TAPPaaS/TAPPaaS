# Web hosting stack

Websites and what serves them: a public site for the site owner, kept in your own repository
and on your own hardware. Community's `wordpress`, `webhost` and `website` modules are in this stack too.

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [lazysite](lazysite/README.md) | lazysite — the site owner's public website: Markdown pages in a Forgejo repository, served as HTML, with no build step or database. | Development |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
