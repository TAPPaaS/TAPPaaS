# Installing the Home stack

Install the modules in the order below, one at a time with `module-manager module add <module>`,
or all at once with `module-manager add-stack home` once #763 is built. Each module's
INSTALL.md says what you must do by hand. What the stack is and why: [README.md](README.md).

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

Install order: a module is listed after every module of this stack it needs or integrates with.

| # | Module | Needs, in this stack | Integrates with, if installed | Needs, installed first |
|---|---|---|---|---|
| 1 | [deconz](deconz/INSTALL.md) | — | — | `backup:vm` (foundation), `cluster:vm` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |
| 2 | [hass](hass/INSTALL.md) | — | — | `alfen:discovery` (?), `alfen:modbus` (?), `alfen:ui` (?), `backup:vm` (foundation), `cluster:vm` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `reolink:rtsp` (?), `sonos:airplay` (?), `sonos:audio` (?) |
| 3 | [immich](immich/INSTALL.md) | — | — | `backup:vm` (foundation), `cluster:vm` (foundation), `identity:identity` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |
| 4 | [jellyfin](jellyfin/INSTALL.md) | — | — | `backup:vm` (foundation), `cluster:vm` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |

<!-- END GENERATED MODULES -->
