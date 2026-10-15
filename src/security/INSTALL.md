# Installing the Security stack

Install the modules in the order below, one at a time with `module-manager module add <module>`,
or all at once with `module-manager add-stack security` (`--dry-run` shows the plan first). Each module's
INSTALL.md says what you must do by hand. What the stack is and why: [README.md](README.md).

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

Install order: a module is listed after every module of this stack it needs or integrates with.

| # | Module | Needs, in this stack | Integrates with, if installed | Needs, installed first |
|---|---|---|---|---|
| 1 | [netbird-client](netbird-client/INSTALL.md) | — | — | `backup:vm` (foundation), `cluster:ha` (foundation), `cluster:vm` (foundation), `identity:identity` (foundation), `network:proxy` (foundation), `templates:debian` (foundation) |
| 2 | [vaultwarden](vaultwarden/INSTALL.md) | — | `logging:logs` (foundation) | `backup:vm` (foundation), `cluster:ha` (foundation), `cluster:vm` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |

<!-- END GENERATED MODULES -->
