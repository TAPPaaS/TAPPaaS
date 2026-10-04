# Home stack

Home automation: Home Assistant, and the Zigbee gateway it talks to — and the household's
media: Jellyfin for movies, series and music, Immich for the photo and video library. On the website:
[Home Stack](https://tappaas.org/stacks/home/).

Device gateways are part of this stack — but **IoT devices are still separated at the
network layer**, which is a different thing from the stack they belong to. They get their
own zones (local-only, cloud-dependent, cameras, untrusted) with firewall boundaries, and
Home Assistant reaches them across those boundaries through controlled pinholes — see
[Network Zones](../foundation/tappaas-cicd/manager/network-manager/ZONES.md).

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [deconz](deconz/README.md) | Zigbee gateway — deCONZ engine (ConBee II, native zigbee for HA) + diyHue front-end (hue-bridge for free@home/SysAP). See README.md / INSTALL.md. | Development |
| [hass](hass/README.md) | Home Assistant OS (HAOS) - home automation platform | Testing |
| [immich](immich/README.md) | Immich self-hosted photo and video backup with ML-powered search, face recognition and mobile auto-upload. | Development |
| [jellyfin](jellyfin/README.md) | Jellyfin open-source media server for personal movie, TV and music libraries. | Development |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
