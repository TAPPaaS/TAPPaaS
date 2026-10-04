# Installing the Collaboration stack

Install the modules in the order below, one at a time with `module-manager module add <module>`,
or all at once with `module-manager add-stack collaboration` once #763 is built. Each module's
INSTALL.md says what you must do by hand. What the stack is and why: [README.md](README.md).

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

Install order: a module is listed after every module of this stack it needs or integrates with.

| # | Module | Needs, in this stack | Integrates with, if installed | Needs, installed first |
|---|---|---|---|---|
| 1 | [nextcloud](nextcloud/INSTALL.md) | — | — | `backup:vm` (foundation), `cluster:vm` (foundation), `identity:identity` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |
| 2 | [coturn](coturn/INSTALL.md) | `nextcloud:fileservice` | — | `backup:vm` (foundation), `cluster:vm` (foundation), `network:nat` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |
| 3 | [euro-office](euro-office/INSTALL.md) | `nextcloud:fileservice` | — | `backup:vm` (foundation), `cluster:vm` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |
| 4 | [nextcloud-hpb](nextcloud-hpb/INSTALL.md) | `coturn:turn`, `nextcloud:fileservice` | — | `backup:vm` (foundation), `cluster:vm` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |

<!-- END GENERATED MODULES -->
